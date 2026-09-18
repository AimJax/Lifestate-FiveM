-- Pangkalan Ojek dispatcher ped (client/dispatcher.lua).
--
-- The NPC was invisible in game because the module rejected its own config:
-- `sharedConfig.dispatcherLocation` is a vec4, and in CfxLua `type(vec4(...))` is
-- 'vector4' - never 'table' - so a `type(coords) ~= 'table'` guard aborted every
-- spawn attempt. This install proves the rule everywhere (ox_lib zones/points,
-- qbx_teleports, qbx_core, and lifestate_ojol's own client/customer.lua all branch
-- on 'vector3'/'vector4').
--
-- wasmoon has no vector type, so the harness EMULATES the type name for one
-- sentinel value. That is what makes the regression testable: a table-shaped
-- config would pass either way, which is exactly how the bug stayed invisible.
--
-- The other properties asserted here: lib.requestModel's real contract (returns
-- the model, RAISES on timeout) can never escape and kill the ensure/watchdog
-- thread; the ped is created at the configured coordinates verbatim; a broken
-- handle is never trusted; failures retry; the ped self-heals; teardown is clean;
-- and the recovery check stays low frequency.

local h = require 'tests.harness'

local MODEL_HASH = joaat('s_m_m_gentransport')

-- Mirrors the shipped config/shared.lua dispatcher coords (ground-measured Z).
local CONFIGURED = { x = 450.91, y = -636.37, z = 27.51, w = 269.62 }

local CONFIG = {
    dispatcherLocation = CONFIGURED,
    dispatcherDebug = false,
}

package.preload['config.shared'] = function()
    return CONFIG
end

-- Stub client world ------------------------------------------------------------

local world = {
    nextHandle = 100,
    exists = {},
    model = {},
    coords = {},
    created = 0,
    deleted = 0,
    frozen = {},
    invincible = {},
    scenario = {},
    threads = {},  -- coroutines created since the last drain
    running = {},  -- coroutines parked at Wait
    handlers = {},
    commands = {},
    waits = {},
    modelAvailable = true,
    modelRequestFails = false,
    modelRequests = 0,
    breakNextCreate = false,
    groundCalls = 0,
}

local target = {
    added = {},
    removed = 0,
    failing = false,
    options = nil,
}

-- CfxLua vector emulation ------------------------------------------------------
--
-- `type()` is swapped for the duration of one test so the sentinel reports
-- 'vector4', exactly as the real runtime reports a vec4.

local realType = type
local VECTOR4 = nil

type = function(value)
    if value ~= nil and value == VECTOR4 then return 'vector4' end
    return realType(value)
end

-- ---host primitives ----------------------------------------------------------
-- GetEntityModel returns the joaat hash the module compares against, so a
-- "broken" ped is modelled exactly like the real one: it exists, alive, model 0.

DoesEntityExist = function(handle) return world.exists[handle] == true end
IsEntityDead = function() return false end
GetEntityModel = function(handle) return world.model[handle] or 0 end
GetEntityCoords = function(handle)
    local coords = world.coords[handle] or {}
    return { x = coords.x or 0.0, y = coords.y or 0.0, z = coords.z or 0.0 }
end

CreatePed = function(_, _, x, y, z, w)
    world.created = world.created + 1
    world.nextHandle = world.nextHandle + 1

    local handle = world.nextHandle
    world.exists[handle] = true
    world.model[handle] = world.breakNextCreate and 0 or MODEL_HASH
    world.coords[handle] = { x = x, y = y, z = z, w = w }
    world.breakNextCreate = false

    return handle
end

DeletePed = function(handle)
    world.deleted = world.deleted + 1
    world.exists[handle] = nil
end

SetModelAsNoLongerNeeded = function() end
SetEntityInvincible = function(handle) world.invincible[handle] = true end
FreezeEntityPosition = function(handle) world.frozen[handle] = true end
SetBlockingOfNonTemporaryEvents = function() end
SetPedDefaultComponentVariation = function() end
TaskStartScenarioInPlace = function(handle, name) world.scenario[handle] = name end

-- Still stubbed so a re-introduced ground snap would be observable as a call.
GetGroundZFor_3dCoord = function()
    world.groundCalls = world.groundCalls + 1
    return false, 0.0
end

HasModelLoaded = function(model) return world.modelAvailable == true and model == MODEL_HASH end

lib = {
    -- Mirrors ox_lib exactly: returns the MODEL on success (never a boolean) and
    -- RAISES on timeout (streamingRequest -> waitFor -> `return error(...)`).
    -- `modelRequestFails` selects the raise; `modelAvailable` is what the native
    -- reports, and the two are independent on purpose - a truthy return is not
    -- proof that the model is loaded.
    requestModel = function(model)
        world.modelRequests = world.modelRequests + 1
        if world.modelRequestFails then
            error(("failed to load model '%s' - this may be caused by oversized assets"):format(tostring(model)))
        end
        return model
    end,
}

exports = {
    ox_target = {
        addLocalEntity = function(_, handle, options)
            if target.failing then error('ox_target is not started') end
            target.added[#target.added + 1] = handle
            target.options = options
        end,
        removeLocalEntity = function(_, handle)
            target.removed = target.removed + 1
            for i = #target.added, 1, -1 do
                if target.added[i] == handle then table.remove(target.added, i) end
            end
        end,
    },
}

-- Threads are real coroutines, exactly as the FiveM scheduler runs them: a Wait
-- parks the coroutine and the spec resumes it to reach the next loop iteration.
CreateThread = function(fn)
    world.threads[#world.threads + 1] = coroutine.create(fn)
end

Wait = function(ms)
    world.waits[#world.waits + 1] = ms
    coroutine.yield()
end

AddEventHandler = function(name, fn) world.handlers[name] = fn end
RegisterNetEvent = function(name, fn) world.handlers[name] = fn end
RegisterCommand = function(name, fn) world.commands[name] = fn end
GetCurrentResourceName = function() return 'lifestate_ojol' end
PlayerId = function() return 1 end
IsPlayerAceAllowed = function() return true end

package.preload['client.dispatcher'] = nil
package.loaded['client.dispatcher'] = nil
package.loaded['config.shared'] = nil

local dispatcher = require 'client.dispatcher'

---Resume a coroutine once and report whether it is still alive afterwards.
local function step(co)
    local ok, err = coroutine.resume(co)
    if not ok then error(err, 0) end
    return coroutine.status(co) ~= 'dead'
end

---Start every thread created since the last call and run it to its first Wait.
local function runThreads()
    local pending = world.threads
    world.threads = {}

    for _, co in ipairs(pending) do
        if step(co) then world.running[#world.running + 1] = co end
    end
end

---Resume every parked thread through the next loop iteration.
local function resumeThreads()
    local parked = world.running
    world.running = {}

    for _, co in ipairs(parked) do
        if step(co) then world.running[#world.running + 1] = co end
    end
end

local function resetWorld()
    -- Tear down first: the teardown itself counts natives, and those counters must
    -- describe the test, not the previous one.
    dispatcher.Shutdown()

    world.exists = {}
    world.model = {}
    world.coords = {}
    world.created = 0
    world.deleted = 0
    world.frozen = {}
    world.invincible = {}
    world.scenario = {}
    world.threads = {}
    world.running = {}
    world.waits = {}
    world.commands = {}
    world.modelAvailable = true
    world.modelRequestFails = false
    world.modelRequests = 0
    world.breakNextCreate = false
    world.groundCalls = 0

    target.added = {}
    target.removed = 0
    target.failing = false
    target.options = nil

    CONFIG.dispatcherLocation = CONFIGURED
    VECTOR4 = nil
end

---Count handles that exist and carry the dispatcher model.
local function livePeds()
    local count = 0
    for handle in pairs(world.exists) do
        if world.model[handle] == MODEL_HASH then count = count + 1 end
    end
    return count
end

-- The root cause -----------------------------------------------------------------

h.test('a vector4 config is accepted (type() is never table for a vector)', function()
    resetWorld()

    -- Exactly what the runtime hands us: its own type, with fields.
    VECTOR4 = { x = CONFIGURED.x, y = CONFIGURED.y, z = CONFIGURED.z, w = CONFIGURED.w }
    CONFIG.dispatcherLocation = VECTOR4

    h.eq(type(CONFIG.dispatcherLocation), 'vector4', 'the harness really reports vector4')

    h.eq(dispatcher.Ensure(), true, 'the dispatcher accepts its own config')
    h.eq(livePeds(), 1, 'ped created')

    local ped = dispatcher.GetPed()
    h.eq(world.coords[ped].x, CONFIGURED.x, 'x')
    h.eq(world.coords[ped].z, CONFIGURED.z, 'z')
end)

h.test('coordinates are used verbatim, with no z offset and no ground correction', function()
    resetWorld()
    dispatcher.Ensure()

    local ped = dispatcher.GetPed()
    h.eq(world.coords[ped].z, CONFIGURED.z, 'configured Z is authoritative')
    h.eq(world.groundCalls, 0, 'no ground sampling')
    h.eq(world.coords[ped].w, CONFIGURED.w, 'configured heading')
end)

h.test('a malformed config is refused instead of spawning something wrong', function()
    resetWorld()
    CONFIG.dispatcherLocation = { x = 1.0, y = 2.0, z = 3.0 } -- no heading

    h.eq(dispatcher.Ensure(), false, 'refused')
    h.eq(livePeds(), 0, 'nothing created')

    CONFIG.dispatcherLocation = nil
    h.eq(dispatcher.Ensure(), false, 'refused for nil too')
end)

-- Model streaming ----------------------------------------------------------------

h.test('a failing model request does not escape as an error', function()
    resetWorld()
    world.modelRequestFails = true -- ox_lib raises here

    h.eq(dispatcher.Ensure(), false, 'reports not ready')
    h.eq(livePeds(), 0, 'nothing created')
    h.eq(world.modelRequests > 0, true, 'the request was attempted')

    -- The raise must not have killed anything: the very next call still works.
    world.modelRequestFails = false
    h.eq(dispatcher.Ensure(), true, 'retry succeeds once the model streams')
    h.eq(livePeds(), 1, 'ped created')
end)

h.test('a truthy requestModel result is still confirmed with the native', function()
    resetWorld()
    -- requestModel returns the hash, but the model is NOT loaded: only the native
    -- can tell the difference, and `not <hash>` is false either way.
    world.modelAvailable = false

    h.eq(dispatcher.Ensure(), false, 'not trusting the return value alone')
    h.eq(world.created, 0, 'no CreatePed with an unloaded model')
    h.eq(world.modelRequests > 0, true, 'the request was attempted')
end)

-- Creation and idempotency -------------------------------------------------------

h.test('Ensure creates exactly one ped and registers the interaction', function()
    resetWorld()

    h.eq(dispatcher.Ensure(), true, 'ready')
    h.eq(livePeds(), 1, 'one ped')
    h.eq(world.created, 1, 'one CreatePed')
    h.eq(#target.added, 1, 'one ox_target registration')
    h.eq(target.added[1], dispatcher.GetPed(), 'registered ped is the live one')
end)

h.test('repeated Ensure calls never duplicate the ped', function()
    resetWorld()

    for _ = 1, 10 do dispatcher.Ensure() end

    h.eq(livePeds(), 1, 'still exactly one ped')
    h.eq(world.created, 1, 'no extra CreatePed')
    h.eq(#target.added, 1, 'no extra registration')
end)

h.test('the ped keeps its dispatcher presentation', function()
    resetWorld()
    dispatcher.Ensure()

    local ped = dispatcher.GetPed()
    h.eq(world.frozen[ped], true, 'frozen')
    h.eq(world.invincible[ped], true, 'invincible')
    h.eq(world.scenario[ped], 'WORLD_HUMAN_CLIPBOARD', 'clipboard scenario')
end)

h.test('the interaction offers Ambil Motor through ox_target', function()
    resetWorld()
    dispatcher.Ensure()

    local option = target.options[1]
    h.eq(option.name, 'lifestate_ojol_take_motor', 'option name')
    h.eq(option.label, 'Ambil Motor', 'label')
    h.eq(option.canInteract(), true, 'visible to everyone; authorization happens on select')
end)

h.test('a ped created before the model streamed is never treated as success', function()
    resetWorld()
    world.breakNextCreate = true -- CreatePed returns an entity with model 0

    h.eq(dispatcher.Ensure(), false, 'not ready')
    h.eq(dispatcher.GetPed(), nil, 'no broken handle is kept')
    h.eq(world.deleted, 1, 'the broken entity was deleted')
    h.eq(livePeds(), 0, 'nothing usable in the world')

    h.eq(dispatcher.Ensure(), true, 'the next ensure actually creates the ped')
    h.eq(livePeds(), 1, 'one usable ped')
end)

h.test('an unavailable ox_target costs the interaction, not the ped', function()
    resetWorld()
    target.failing = true

    h.eq(dispatcher.Ensure(), false, 'reports not ready')
    h.eq(livePeds(), 1, 'the ped still exists')
    h.eq(world.created, 1, 'created once')
    h.eq(#target.added, 0, 'no registration yet')

    target.failing = false
    h.eq(dispatcher.Ensure(), true, 'retried')
    h.eq(livePeds(), 1, 'no duplicate ped')
    h.eq(#target.added, 1, 'interaction registered now')
end)

h.test('a ped deleted locally is re-created', function()
    resetWorld()
    dispatcher.Ensure()
    local first = dispatcher.GetPed()

    DeletePed(first)

    h.eq(dispatcher.Ensure(), true, 'recovered')
    h.eq(livePeds(), 1, 'one ped again')
    h.eq(dispatcher.GetPed() ~= first, true, 'a fresh handle')
end)

h.test('a ped that lost its model is replaced', function()
    resetWorld()
    dispatcher.Ensure()
    local first = dispatcher.GetPed()
    world.model[first] = 0 -- as if the handle went stale

    h.eq(dispatcher.Ensure(), true, 'recovered')
    h.eq(dispatcher.GetPed() ~= first, true, 'new handle')
    h.eq(livePeds(), 1, 'one ped')
end)

-- Lifecycle ---------------------------------------------------------------------

h.test('Start creates the ped off the script chunk and arms a slow watchdog', function()
    resetWorld()

    dispatcher.Start({ onSelect = function() end })

    -- Nothing happens inline: Start is called from the script chunk, where waiting
    -- for a model to stream is not guaranteed to be allowed.
    h.eq(#world.threads, 2, 'ensure deferred, watchdog armed')
    h.eq(world.created, 0, 'no native call before the first tick')

    runThreads()

    h.eq(livePeds(), 1, 'ped created on the next tick')
    h.eq(#world.waits, 1, 'the watchdog waited before doing anything')
    h.eq(world.waits[1] >= 10000, true, 'not a per-frame loop')
    h.eq(#world.running, 1, 'the watchdog is the only parked thread')
end)

h.test('Start is idempotent and never arms a second watchdog', function()
    resetWorld()

    dispatcher.Start({ onSelect = function() end })
    runThreads()
    h.eq(livePeds(), 1, 'ped exists')

    dispatcher.Start({ onSelect = function() end })
    runThreads()

    h.eq(#world.running, 1, 'still exactly one watchdog')
    h.eq(livePeds(), 1, 'still one ped')
    h.eq(world.created, 1, 'no extra CreatePed')
end)

h.test('the watchdog re-creates a ped deleted between ticks', function()
    resetWorld()
    dispatcher.Start({ onSelect = function() end })

    runThreads() -- runs to Wait(15000)
    DeletePed(dispatcher.GetPed())
    h.eq(livePeds(), 0, 'gone')

    resumeThreads() -- next tick: the loop body runs Ensure again
    h.eq(livePeds(), 1, 'ped restored')
    h.eq(world.waits[#world.waits] >= 10000, true, 'still a slow loop')
end)

h.test('the watchdog survives a failing model request and recovers later', function()
    resetWorld()
    world.modelAvailable = false

    dispatcher.Start({ onSelect = function() end })
    runThreads()
    resumeThreads()
    h.eq(livePeds(), 0, 'nothing while the model cannot stream')

    world.modelAvailable = true
    resumeThreads()

    h.eq(livePeds(), 1, 'the watchdog thread is still alive and recovered')
end)

h.test('a player loading in mid-session gets the ped', function()
    resetWorld()

    -- The real cold-start shape: resource started while the client was connecting.
    world.modelAvailable = false
    dispatcher.Start({ onSelect = function() end })
    runThreads()
    resumeThreads()
    h.eq(livePeds(), 0, 'nothing yet')

    world.modelAvailable = true
    world.threads = {}
    world.running = {}

    local loaded = world.handlers['QBCore:Client:OnPlayerLoaded']
    h.eq(loaded ~= nil, true, 'player load is wired')
    loaded()
    runThreads()

    h.eq(livePeds(), 1, 'the ped exists once the character is in game')
end)

h.test('an ox_target restart re-registers the interaction', function()
    resetWorld()
    dispatcher.Start({ onSelect = function() end })
    runThreads()

    target.added = {} -- ox_target restarting drops local entity registrations
    world.threads = {}
    world.running = {}

    local restarted = world.handlers['onClientResourceStart']
    h.eq(restarted ~= nil, true, 'ox_target start is wired')
    restarted('ox_target')
    runThreads()

    h.eq(livePeds(), 1, 'no duplicate ped')
    h.eq(#target.added, 1, 'interaction restored')
end)

h.test('the resource-start hook only reacts to this resource', function()
    resetWorld()
    dispatcher.Start({ onSelect = function() end })
    runThreads()
    local ped = dispatcher.GetPed()
    h.eq(ped ~= nil, true, 'ped exists before the check')

    world.threads = {}
    world.running = {}
    world.handlers['onResourceStart']('some_other_resource')
    runThreads()

    h.eq(dispatcher.GetPed(), ped, 'untouched by another resource')

    world.handlers['onResourceStart']('lifestate_ojol')
    runThreads()
    h.eq(livePeds(), 1, 'and still exactly one ped for our own start')
end)

h.test('Shutdown removes the ped and its registration', function()
    resetWorld()
    dispatcher.Start({ onSelect = function() end })
    runThreads()
    local ped = dispatcher.GetPed()

    world.handlers['onResourceStop']('lifestate_ojol')

    h.eq(world.exists[ped], nil, 'ped deleted')
    h.eq(dispatcher.GetPed(), nil, 'handle cleared')
    h.eq(target.removed, 1, 'ox_target registration removed')
    h.eq(#target.added, 0, 'nothing left registered')
end)

h.test('Shutdown is safe when there is no ped, and Ensure still works after it', function()
    resetWorld()
    dispatcher.Shutdown()
    h.eq(target.removed, 0, 'nothing to remove')

    dispatcher.Start({ onSelect = function() end })
    runThreads()
    h.eq(livePeds(), 1, 'restart after teardown')
end)

h.test('the selected interaction calls the injected handler', function()
    resetWorld()
    local calls = 0
    dispatcher.Start({ onSelect = function() calls = calls + 1 end })
    runThreads()

    target.options[1].onSelect()

    h.eq(calls, 1, 'gameplay callback invoked')
end)

-- Diagnostics --------------------------------------------------------------------

h.test('/ojoldebugped reports the live state', function()
    resetWorld()
    dispatcher.Start({ onSelect = function() end })
    runThreads()

    local debug = world.commands['ojoldebugped']
    h.eq(debug ~= nil, true, 'diagnostic command registered')

    local state = dispatcher.DebugState()
    h.eq(state.started, true, 'started')
    h.eq(state.exists, true, 'ped exists')
    h.eq(state.model, MODEL_HASH, 'model')
    h.eq(state.dead, false, 'alive')
    h.eq(state.targetRegistered, true, 'target registered')
    h.eq(type(state.position), 'string', 'live position reported')
    h.eq(state.configured:find('450%.91') ~= nil, true, 'configured coords reported')
    h.eq(state.configured:find('table') ~= nil, true, 'the config container type is reported')

    debug() -- must not error
end)

h.test('DebugState never queries a model on a missing ped', function()
    resetWorld()

    local state = dispatcher.DebugState()
    h.eq(state.exists, false, 'no ped')
    h.eq(state.model, nil, 'no model read')
    h.eq(state.dead, nil, 'no dead check')
    h.eq(state.position, nil, 'no coords read')
end)

h.test('/ojolrespawnped deletes and re-creates exactly one ped', function()
    resetWorld()
    dispatcher.Start({ onSelect = function() end })
    runThreads()
    local first = dispatcher.GetPed()

    local respawn = world.commands['ojolrespawnped']
    h.eq(respawn ~= nil, true, 'respawn command registered')
    respawn()

    h.eq(dispatcher.GetPed() ~= first, true, 'fresh handle')
    h.eq(livePeds(), 1, 'exactly one ped')
    h.eq(#target.added, 1, 'one registration')
end)

return true
