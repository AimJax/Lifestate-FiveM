-- Pangkalan Ojek dispatcher ped (client/dispatcher.lua).
--
-- The ped could not survive a real session before: it was created once from
-- `onResourceStart` - while the client is still connecting, so the ped model may
-- not be streamable - behind a bare `DoesEntityExist` guard. `CreatePed` in that
-- state hands back a handle to a broken (model 0) entity that DOES exist, so the
-- guard reported success forever and the NPC was never seen again. ox_target not
-- being up yet failed the same way, and nothing re-created the ped after a
-- character reload or a local deletion.
--
-- These specs drive the real module against a stub client world. Every property
-- the fix claims is asserted: exactly one ped, no duplicates, a broken handle is
-- never trusted, failures retry instead of sticking, a deleted ped comes back,
-- teardown removes both the ped and its ox_target registration, the recovery
-- check is low frequency (never a per-frame loop), and the ped is placed at the
-- configured coordinates.

local h = require 'tests.harness'

local MODEL_HASH = joaat('s_m_m_gentransport')

local CONFIG = {
    dispatcherLocation = { x = 450.91, y = -636.37, z = 28.52, w = 269.62 },
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
    waits = {},
    modelAvailable = true,
    modelRequests = 0,
    breakNextCreate = false,
    groundFound = false,
    groundZ = 0,
}

local target = {
    added = {},
    removed = 0,
    failing = false,
    options = nil,
}

-- Host primitives. GetEntityModel returns the joaat hash the module compares
-- against, so a "broken" ped is modelled exactly like the real one: it exists but
-- carries no model.
DoesEntityExist = function(handle) return world.exists[handle] == true end
IsEntityDead = function() return false end
GetEntityModel = function(handle) return world.model[handle] or 0 end

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

GetGroundZFor_3dCoord = function()
    return world.groundFound, world.groundZ
end

lib = {
    requestModel = function()
        world.modelRequests = world.modelRequests + 1
        return world.modelAvailable
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

-- Threads are real coroutines here, exactly as the FiveM scheduler runs them: a
-- Wait parks the coroutine and the spec resumes it to reach the next loop
-- iteration. That is what makes the watchdog's recovery path testable.
CreateThread = function(fn)
    world.threads[#world.threads + 1] = coroutine.create(fn)
end

Wait = function(ms)
    world.waits[#world.waits + 1] = ms
    coroutine.yield()
end

AddEventHandler = function(name, fn) world.handlers[name] = fn end
RegisterNetEvent = function(name, fn) world.handlers[name] = fn end
GetCurrentResourceName = function() return 'lifestate_ojol' end

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
    world.modelAvailable = true
    world.modelRequests = 0
    world.breakNextCreate = false
    world.groundFound = false

    target.added = {}
    target.removed = 0
    target.failing = false
    target.options = nil
end

---Count handles that exist and carry the dispatcher model.
local function livePeds()
    local count = 0
    for handle in pairs(world.exists) do
        if world.model[handle] == MODEL_HASH then count = count + 1 end
    end
    return count
end

-- Creation and idempotency -----------------------------------------------------

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

h.test('the ped is placed at the configured coordinates', function()
    resetWorld()
    dispatcher.Ensure()

    local ped = dispatcher.GetPed()
    h.eq(world.coords[ped].x, CONFIG.dispatcherLocation.x, 'x')
    h.eq(world.coords[ped].y, CONFIG.dispatcherLocation.y, 'y')
    h.eq(world.coords[ped].z, CONFIG.dispatcherLocation.z, 'z is the configured Z, not one metre under it')
    h.eq(world.coords[ped].w, CONFIG.dispatcherLocation.w, 'heading')
    h.eq(world.frozen[ped], true, 'frozen')
    h.eq(world.invincible[ped], true, 'invincible')
    h.eq(world.scenario[ped], 'WORLD_HUMAN_CLIPBOARD', 'clipboard scenario')
end)

h.test('the ped is snapped onto real ground only when it is close by', function()
    resetWorld()
    world.groundFound = true
    world.groundZ = CONFIG.dispatcherLocation.z + 1.4

    dispatcher.Ensure()
    h.eq(world.coords[dispatcher.GetPed()].z, world.groundZ, 'snapped up 1.4 m')

    resetWorld()
    world.groundFound = true
    world.groundZ = CONFIG.dispatcherLocation.z + 40.0
    dispatcher.Ensure()
    h.eq(world.coords[dispatcher.GetPed()].z, CONFIG.dispatcherLocation.z, 'far surface ignored')
end)

h.test('the interaction offers Ambil Motor through ox_target', function()
    resetWorld()
    dispatcher.Ensure()

    local option = target.options[1]
    h.eq(option.name, 'lifestate_ojol_take_motor', 'option name')
    h.eq(option.label, 'Ambil Motor', 'label')
    h.eq(option.canInteract(), true, 'visible to everyone; authorization happens on select')
end)

-- The regression -----------------------------------------------------------------

h.test('a ped created before the model streamed is never treated as success', function()
    resetWorld()
    world.breakNextCreate = true -- CreatePed returns an entity with model 0

    h.eq(dispatcher.Ensure(), false, 'not ready')
    h.eq(dispatcher.GetPed(), nil, 'no broken handle is kept')
    h.eq(world.deleted, 1, 'the broken entity was deleted')
    h.eq(livePeds(), 0, 'nothing usable in the world')

    -- The old guard would now consider the ped "present" forever.
    h.eq(dispatcher.Ensure(), true, 'the next ensure actually creates the ped')
    h.eq(livePeds(), 1, 'one usable ped')
end)

h.test('a model that will not stream is retried, not stuck', function()
    resetWorld()
    world.modelAvailable = false

    h.eq(dispatcher.Ensure(), false, 'not ready')
    h.eq(world.created, 0, 'no CreatePed attempted')

    world.modelAvailable = true
    h.eq(dispatcher.Ensure(), true, 'retry succeeds')
    h.eq(livePeds(), 1, 'one ped')
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

h.test('a ped that died is replaced', function()
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

h.test('a player loading in mid-session gets the ped', function()
    resetWorld()

    -- Simulates the real failure: the resource started while the client was still
    -- connecting, so the first attempt had no streamable model.
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

    -- ox_target restarting drops every local entity registration.
    target.added = {}
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

return true
