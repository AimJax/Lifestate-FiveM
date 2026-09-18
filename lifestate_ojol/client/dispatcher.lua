-- Pangkalan Ojek dispatcher ped (local, per client).
--
-- ROOT CAUSE OF THE MISSING NPC (verified against this install, not guessed):
--
--   `sharedConfig.dispatcherLocation` is a `vec4(...)`, and in CfxLua a vector is
--   its OWN type - `type(vec4(...)) == 'vector4'`, never 'table'. The previous
--   version of this file guarded the config with `if type(coords) ~= 'table'`,
--   which is therefore TRUE for the real config, so `createPed()` returned early
--   on every single ensure and the ped was never created at all. The F8 line to
--   look for in that build was:
--     [lifestate_ojol:dispatcher] config.shared.dispatcherLocation is missing
--   Proof of the type rule from this very server: ox_lib's own zones/points
--   (`_type == 'table' or _type == 'vector4'`), qbx_teleports, qbx_core modules
--   and lifestate_ojol's own client/customer.lua all branch on 'vector3'/'vector4'.
--
-- Two related traps are also fixed here rather than left to chance:
--
--   * `lib.requestModel` RETURNS the model hash on success and *raises an error*
--     on timeout (ox_lib's streamingRequest -> waitFor does `return error(...)`).
--     It never returns nil. Its result is now checked with pcall AND with the
--     native `HasModelLoaded`, and a raised error can no longer escape and kill
--     the ensure/watchdog thread.
--   * The ped is created at exactly the configured coordinates. There is no
--     `z - 1.0` offset and no ground correction: those were unproven transforms on
--     top of a coordinate set that is already correct.
--
-- Idempotency contract: `Ensure()` is safe to call at any time from any event. It
-- leaves exactly one usable ped behind - never two, never a broken one - and ped
-- creation and ox_target registration stay independent, so an unavailable
-- ox_target costs the interaction but never the NPC.

local sharedConfig = require 'config.shared'

local M = {}

local MODEL = `s_m_m_gentransport`
local SCENARIO = 'WORLD_HUMAN_CLIPBOARD'
local MODEL_TIMEOUT_MS = 10000

---A locally deleted ped is only observable by looking, and the watchdog is the
---only periodic work in this system: one native call per interval.
local WATCHDOG_INTERVAL_MS = 15000

---Lifecycle tracing. Set `dispatcherDebug = false` in config/shared.lua once the
---NPC is confirmed in game; failures are logged either way.
local DEBUG = sharedConfig.dispatcherDebug ~= false

local ped = nil
local targetRegistered = false
local started = false
local onSelect = nil
local lastFailure = nil
local lastModelMismatch = nil
local watchdogTicks = 0

---@param message string
local function log(message)
    print(('[lifestate_ojol:dispatcher] %s'):format(message))
end

---@param message string
local function debug(message)
    if DEBUG then log(message) end
end

---Failures are logged once per distinct reason so a retry loop cannot flood F8.
---@param message string
local function warn(message)
    if lastFailure == message then return end
    lastFailure = message
    log('FAILED: ' .. message)
end

---Accepts any coordinate container: a CfxLua vector4/vector3, or a plain table.
---Deliberately field-based, because `type(vec4(...))` is 'vector4', not 'table'.
---@param coords any
---@return boolean
local function hasCoords(coords)
    if not coords then return false end

    return tonumber(coords.x) ~= nil
        and tonumber(coords.y) ~= nil
        and tonumber(coords.z) ~= nil
        and tonumber(coords.w) ~= nil
end

---@return string
local function describe(value)
    if not value then return 'nil' end

    return ('%s(%s, %s, %s, %s)'):format(
        type(value), tostring(value.x), tostring(value.y), tostring(value.z), tostring(value.w))
end

---A handle is only usable when the entity exists, is alive and carries the loaded
---model. A ped created before the model streamed exists but has model 0, which is
---exactly the state a bare `DoesEntityExist` guard mistakes for success.
---`GetEntityModel` is only ever called on a live entity.
---@param handle number|nil
---@return boolean
local function isUsablePed(handle)
    if not handle or handle == 0 then return false end
    if not DoesEntityExist(handle) then return false end
    if IsEntityDead(handle) then return false end

    local model = GetEntityModel(handle)
    if model ~= MODEL then
        if lastModelMismatch ~= model then
            lastModelMismatch = model
            warn(('ped model %s does not match the dispatcher model %s'):format(tostring(model), tostring(MODEL)))
        end
        return false
    end

    return true
end

---@return boolean registered
local function registerTarget()
    if targetRegistered then return true end
    if not isUsablePed(ped) then return false end

    local ok = pcall(function()
        exports.ox_target:addLocalEntity(ped, {
            {
                name = 'lifestate_ojol_take_motor',
                icon = 'fa-solid fa-motorcycle',
                label = 'Ambil Motor',
                distance = 2.5,

                canInteract = function()
                    -- Option stays visible to everyone; authorization is enforced on
                    -- select and again server-side. A registered-but-offline driver
                    -- must be able to see the denial message telling them to clock in.
                    return true
                end,

                onSelect = function()
                    if onSelect then onSelect() end
                end
            }
        })
    end)

    if not ok then
        debug('ox_target is not available yet; the interaction will be retried')
        return false
    end

    targetRegistered = true
    debug('ox_target interaction registered (Ambil Motor)')
    return true
end

local function removeTarget()
    if not targetRegistered then return end

    -- pcall: ox_target may already have stopped during a resource teardown.
    pcall(function() exports.ox_target:removeLocalEntity(ped) end)
    targetRegistered = false
end

local function deletePed()
    removeTarget()

    if ped and DoesEntityExist(ped) then DeletePed(ped) end
    ped = nil
end

---@return boolean created
local function createPed()
    local coords = sharedConfig.dispatcherLocation
    if not hasCoords(coords) then
        warn(('config.shared.dispatcherLocation must expose x/y/z/w, got %s'):format(describe(coords)))
        return false
    end

    -- lib.requestModel yields until the model has loaded and RAISES on timeout, so
    -- it is called under pcall and the outcome is confirmed with the native.
    local ok = pcall(lib.requestModel, MODEL, MODEL_TIMEOUT_MS)
    if not ok or not HasModelLoaded(MODEL) then
        warn(('model %s did not stream (request ok=%s); retrying on the next ensure')
            :format(tostring(MODEL), tostring(ok)))
        return false
    end

    -- Exactly the configured coordinates: no z offset, no ground correction.
    local handle = CreatePed(0, MODEL, coords.x, coords.y, coords.z, coords.w, false, false)
    SetModelAsNoLongerNeeded(MODEL)

    if not handle or handle == 0 or not DoesEntityExist(handle) then
        warn('CreatePed did not return an entity')
        return false
    end

    local model = GetEntityModel(handle)
    debug(('CreatePed returned handle=%s model=%s dead=%s'):format(
        tostring(handle), tostring(model), tostring(IsEntityDead(handle))))

    -- Verified before anything else touches the handle.
    if model ~= MODEL or IsEntityDead(handle) then
        warn(('CreatePed produced an unusable ped (model %s, expected %s); deleted'):format(
            tostring(model), tostring(MODEL)))
        DeletePed(handle)
        return false
    end

    ped = handle
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedDefaultComponentVariation(ped)
    TaskStartScenarioInPlace(ped, SCENARIO, 0, true)

    local position = GetEntityCoords(ped)
    log(('dispatcher ped ready: handle=%s model=%s coords=(%.2f, %.2f, %.2f)')
        :format(tostring(ped), tostring(model), position.x, position.y, position.z))

    lastFailure = nil
    return true
end

---Idempotent: ensures the dispatcher exists and is interactable.
---@return boolean ready
function M.Ensure()
    if isUsablePed(ped) then
        registerTarget()
        return targetRegistered
    end

    -- Stale handle (deleted locally, dead, or created before the model streamed).
    if ped then
        debug(('replacing unusable ped handle %s'):format(tostring(ped)))
        deletePed()
    end

    if not createPed() then return false end

    return registerTarget()
end

---@return number|nil current ped handle
function M.GetPed()
    return ped
end

---Diagnostic snapshot for /ojoldebugped. Reads only what is asked for.
---@return table
function M.DebugState()
    local coords = sharedConfig.dispatcherLocation
    local exists = ped ~= nil and ped ~= 0 and DoesEntityExist(ped) == true

    local state = {
        started = started,
        handle = ped,
        exists = exists,
        model = nil,
        dead = nil,
        position = nil,
        targetRegistered = targetRegistered,
        configured = describe(coords),
        watchdogTicks = watchdogTicks,
        lastFailure = lastFailure,
    }

    -- Never query model/coords on an invalid entity.
    if exists then
        state.model = GetEntityModel(ped)
        state.dead = IsEntityDead(ped)

        local position = GetEntityCoords(ped)
        state.position = ('%.2f, %.2f, %.2f'):format(position.x, position.y, position.z)
    end

    return state
end

---Delete and re-ensure once (diagnostic; see /ojolrespawnped).
---@return boolean ready
function M.Respawn()
    deletePed()
    lastFailure = nil
    lastModelMismatch = nil
    return M.Ensure()
end

function M.Shutdown()
    started = false
    deletePed()
end

---@return boolean allowed
local function isDebugAllowed()
    return IsPlayerAceAllowed(PlayerId(), 'admin')
end

---Diagnostic commands (admin-only; client-local, so they change nothing global).
local function registerDebugCommands()
    RegisterCommand('ojoldebugped', function()
        if not isDebugAllowed() then
            log('/ojoldebugped is admin-only')
            return
        end

        local state = M.DebugState()
        print(('[lifestate_ojol:dispatcher] state: started=%s handle=%s exists=%s model=%s dead=%s target=%s coords=%s configured=%s ticks=%s lastFailure=%s')
            :format(
                tostring(state.started), tostring(state.handle), tostring(state.exists),
                tostring(state.model), tostring(state.dead), tostring(state.targetRegistered),
                tostring(state.position), tostring(state.configured), tostring(state.watchdogTicks),
                tostring(state.lastFailure)))
    end, false)

    RegisterCommand('ojolrespawnped', function()
        if not isDebugAllowed() then
            log('/ojolrespawnped is admin-only')
            return
        end

        log('manual respawn requested')
        log(('respawn result ready=%s'):format(tostring(M.Respawn())))
    end, false)
end

---Wire the lifecycle. Every trigger below is required for the ped to exist for
---*every* connected client, not just the ones present when the resource started.
---@param options { onSelect: fun()? }?
function M.Start(options)
    onSelect = options and options.onSelect or nil
    debug(('Start() called (debug=%s)'):format(tostring(DEBUG)))

    if started then
        -- Already wired: just make sure the ped is there.
        CreateThread(M.Ensure)
        return
    end

    started = true

    AddEventHandler('onResourceStart', function(resourceName)
        if resourceName ~= GetCurrentResourceName() then return end
        debug('trigger: onResourceStart')
        CreateThread(M.Ensure)
    end)

    -- The character is fully in game here, so the ped model streams reliably.
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
        debug('trigger: QBCore:Client:OnPlayerLoaded')
        CreateThread(M.Ensure)
    end)

    -- ox_target restarting drops every local entity registration.
    AddEventHandler('onClientResourceStart', function(resourceName)
        if resourceName ~= 'ox_target' then return end
        debug('trigger: onClientResourceStart(ox_target)')

        targetRegistered = false
        CreateThread(M.Ensure)
    end)

    AddEventHandler('onResourceStop', function(resourceName)
        if resourceName ~= GetCurrentResourceName() then return end
        M.Shutdown()
    end)

    -- Recovery only: one native call per interval, and the only way to notice a ped
    -- deleted locally (there is no entity-deletion event). Never a per-frame loop.
    CreateThread(function()
        debug(('watchdog armed (interval %dms)'):format(WATCHDOG_INTERVAL_MS))

        while started do
            Wait(WATCHDOG_INTERVAL_MS)
            if started then
                watchdogTicks = watchdogTicks + 1
                if watchdogTicks == 1 then debug('watchdog: first tick') end
                M.Ensure()
            end
        end
    end)

    -- Deferred, never inline: Ensure may wait for the model to stream, and Start is
    -- called from the script chunk where waiting is not guaranteed to be allowed.
    CreateThread(M.Ensure)

    registerDebugCommands()
end

return M
