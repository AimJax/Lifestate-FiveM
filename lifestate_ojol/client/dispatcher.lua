-- Pangkalan Ojek dispatcher ped (local, per client).
--
-- The ped used to be created exactly once from `onResourceStart` and guarded by a
-- bare `DoesEntityExist` check. That is not enough to survive a real session:
--
--   * `onResourceStart` fires while the client is still connecting, when the ped
--     model may not be streamable yet. `CreatePed` then hands back a handle to a
--     broken entity that DOES exist - so the old guard treated it as "already
--     there" forever and the NPC was never visible again.
--   * ox_target may not be running yet when the ped is created; the registration
--     error aborted the handler and, thanks to the same guard, was never retried.
--   * nothing re-created the ped after a character reload or a local deletion.
--
-- This module owns only the ped lifecycle: model, placement, invincibility,
-- scenario and the ox_target interaction. What the interaction *does* is injected
-- by the caller (see client/main.lua), because that is gameplay, not spawning.
--
-- Idempotency contract: `Ensure()` is safe to call at any time from any event. It
-- leaves exactly one usable ped behind - never two, never a broken one.

local sharedConfig = require 'config.shared'

local M = {}

local MODEL = `s_m_m_gentransport`
local SCENARIO = 'WORLD_HUMAN_CLIPBOARD'
local MODEL_TIMEOUT_MS = 10000

---A ped that no longer streams at the configured spot would silently drift; the
---watchdog re-checks often enough that a tight interval is pointless.
local WATCHDOG_INTERVAL_MS = 15000

---Only snap the ped onto the ground when the resolved surface is at the
---configured spot. A larger difference means the collision is not loaded (or the
---config is wrong) and the configured Z stays authoritative.
local GROUND_SNAP_TOLERANCE = 2.0

local ped = nil
local targetRegistered = false
local started = false
local onSelect = nil
local lastFailure = nil

---@param message string
local function log(message)
    print(('[lifestate_ojol:dispatcher] %s'):format(message))
end

---Log only when the failure *changes*, so a long loading screen or a watchdog
---retry cannot spam the console with the same line.
---@param message string
local function fail(message)
    if lastFailure == message then return end
    lastFailure = message
    log(message)
end

---A handle is only usable when the entity exists, is alive and still carries the
---loaded model. A ped created before the model streamed exists but has model 0 -
---exactly the state the previous implementation mistook for success.
---@param handle number|nil
---@return boolean
local function isUsablePed(handle)
    if not handle or handle == 0 then return false end
    if not DoesEntityExist(handle) then return false end
    if IsEntityDead(handle) then return false end
    return GetEntityModel(handle) == MODEL
end

---The ped's Z as configured, corrected onto the real ground when (and only when)
---that surface resolves close to it. This keeps the NPC at the configured
---location instead of burying it under the pavement.
---@param coords vector4
---@return number
local function resolveGroundZ(coords)
    local found, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 1.0, false)
    if found and groundZ and math.abs(groundZ - coords.z) <= GROUND_SNAP_TOLERANCE then
        return groundZ
    end

    return coords.z
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

---(Re)register the ox_target interaction. Kept separate from creation so an
---unavailable ox_target never costs us the ped itself.
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
        fail('ox_target is not available yet; the interaction will be retried')
        return false
    end

    targetRegistered = true
    lastFailure = nil
    return true
end

---@return boolean created
local function createPed()
    local coords = sharedConfig.dispatcherLocation
    if type(coords) ~= 'table' then
        fail('config.shared.dispatcherLocation is missing')
        return false
    end

    if not lib.requestModel(MODEL, MODEL_TIMEOUT_MS) then
        fail('s_m_m_gentransport did not stream; retrying on the next ensure')
        return false
    end

    local z = resolveGroundZ(coords)
    local handle = CreatePed(0, MODEL, coords.x, coords.y, z, coords.w, false, false)
    SetModelAsNoLongerNeeded(MODEL)

    if not isUsablePed(handle) then
        -- Never keep a broken handle: it would satisfy a naive existence guard.
        if handle and handle ~= 0 and DoesEntityExist(handle) then DeletePed(handle) end
        fail('CreatePed did not produce a usable ped; retrying on the next ensure')
        return false
    end

    ped = handle
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedDefaultComponentVariation(ped)
    TaskStartScenarioInPlace(ped, SCENARIO, 0, true)

    lastFailure = nil
    return true
end

---Idempotent ensures the dispatcher exists and is interactable.
---@return boolean ready
function M.Ensure()
    if isUsablePed(ped) then
        registerTarget()
        return targetRegistered
    end

    -- Stale handle (deleted locally, dead, or created before streaming finished).
    if ped then deletePed() end
    if not createPed() then return false end

    return registerTarget()
end

---@return number|nil current ped handle
function M.GetPed()
    return ped
end

function M.Shutdown()
    started = false
    deletePed()
end

---Wire the lifecycle. Every trigger below is required for the ped to exist for
---*every* connected client, not just the ones present when the resource started.
---@param options { onSelect: fun()? }?
function M.Start(options)
    onSelect = options and options.onSelect or nil

    if started then
        -- Already wired: just make sure the ped is there.
        CreateThread(M.Ensure)
        return
    end

    started = true

    AddEventHandler('onResourceStart', function(resourceName)
        if resourceName ~= GetCurrentResourceName() then return end
        CreateThread(M.Ensure)
    end)

    -- The character is fully in game here, so the ped model streams reliably.
    -- This is the trigger the old implementation was missing entirely.
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
        CreateThread(M.Ensure)
    end)

    -- ox_target restarting drops every local entity registration.
    AddEventHandler('onClientResourceStart', function(resourceName)
        if resourceName ~= 'ox_target' then return end

        targetRegistered = false
        CreateThread(M.Ensure)
    end)

    AddEventHandler('onResourceStop', function(resourceName)
        if resourceName ~= GetCurrentResourceName() then return end
        M.Shutdown()
    end)

    -- Low-frequency recovery only: one native call per interval, and it is the only
    -- way to notice a ped deleted locally (there is no entity-deletion event).
    -- Never a per-frame loop.
    CreateThread(function()
        while started do
            Wait(WATCHDOG_INTERVAL_MS)
            if started then M.Ensure() end
        end
    end)

    -- Deferred, never inline: Ensure may wait for the model to stream, and Start is
    -- called from the script chunk where waiting is not guaranteed to be allowed.
    CreateThread(M.Ensure)
end

return M
