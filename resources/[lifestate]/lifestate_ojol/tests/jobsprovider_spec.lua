-- Ojol's registration into the generic admin Job Management system.
--
-- Two things are proven here, both against real modules:
--
--   1. the DEFINITION is serializable metadata only - export NAMES, no closures -
--      because a closure cannot cross a real resource boundary (that is exactly how
--      a live server rejected this provider with `give_not_function`);
--   2. the exports it names are the real server/adminapi.lua ones and keep their
--      semantics: registration/reactivation, soft removal, CEO protection, state
--      snapshot, with only the DB layer stubbed.
--
-- It also pins the retry policy: a dependency that is not up yet is retried with a
-- small bounded backoff, a STRUCTURAL rejection is logged once and never retried.

local h = require 'tests.harness'

-- Host state ------------------------------------------------------------------

local dbState = {
    rows = {},      -- [citizenid] = persistent driver row
    stats = {},     -- [citizenid] = { rating_sum, rating_count, profile_photo }
    calls = {},     -- ordered write log
    fail = {},      -- [method] = true -> the stub raises
}

local host = {
    registryResource = 'lifestate_jobs',
    resourceState = 'started',
    provider = nil,          -- definition captured from the registry export
    providers = {},          -- [provider id] = definition, as the registry holds it
    registerCalls = 0,
    registerOutcome = { true, 'registered' },
    lastOutcome = nil,
    clientEvents = {},
    events = {},
    notifies = {},
    threads = {},
    handlers = {},
    printed = {},
}

package.preload['server.database'] = function()
    return {
        FetchAllDrivers = function()
            local list = {}
            for _, row in pairs(dbState.rows) do
                -- Persistent rating/profile fields travel on the row itself
                -- (SELECT *), which is what hydrates the memory-only driver
                -- snapshot at load.
                local copy = {}
                for key, value in pairs(row) do copy[key] = value end
                for key, value in pairs(dbState.stats[row.citizenid] or {}) do copy[key] = value end
                list[#list + 1] = copy
            end
            return list
        end,
        FetchDriver = function(citizenid)
            return dbState.stats[citizenid] or nil
        end,
        InsertDriver = function(citizenid, rank, registeredBy)
            if dbState.fail.InsertDriver then error('insert failed') end
            dbState.calls[#dbState.calls + 1] = 'InsertDriver'
            dbState.rows[citizenid] = {
                citizenid = citizenid,
                rank = rank,
                active = 1,
                registered_by = registeredBy,
                registered_at = 1000,
            }
        end,
        ReactivateDriver = function(citizenid, rank, registeredBy)
            if dbState.fail.ReactivateDriver then error('reactivate failed') end
            dbState.calls[#dbState.calls + 1] = 'ReactivateDriver'
            local row = dbState.rows[citizenid]
            if row then
                row.active = 1
                row.rank = rank
                row.registered_by = registeredBy
            end
        end,
        DeactivateDriver = function(citizenid)
            if dbState.fail.DeactivateDriver then error('deactivate failed') end
            dbState.calls[#dbState.calls + 1] = 'DeactivateDriver'
            local row = dbState.rows[citizenid]
            if row then row.active = 0 end
        end,
        UpdateDriverFields = function(citizenid, fields)
            if dbState.fail.UpdateDriverFields then error('update failed') end
            dbState.calls[#dbState.calls + 1] = 'UpdateDriverFields:' .. tostring(fields.rank)

            local row = dbState.rows[citizenid]
            if row and fields.rank then row.rank = fields.rank end
        end,
    }
end

-- Host primitives the modules under test expect from CfxLua.
GetCurrentResourceName = function() return 'lifestate_ojol' end
GetResourceState = function(name) return name == host.registryResource and host.resourceState or 'missing' end
GetPlayerName = function(source) return 'Player' .. tostring(source) end

function TriggerEvent(eventName, ...)
    host.events[#host.events + 1] = eventName
    local fn = host.handlers[eventName]
    if fn then fn(...) end
end

function TriggerClientEvent(eventName, target, ...)
    host.clientEvents[#host.clientEvents + 1] = { event = eventName, target = target, args = { ... } }
end

function AddEventHandler(eventName, fn) host.handlers[eventName] = fn end
function CreateThread(fn) host.threads[#host.threads + 1] = fn end
function Wait() end

local realPrint = print

-- Capture module logs by their LEADING prefix only. Filtering on "contains" would
-- also swallow a failing assertion whose message quotes a log line, hiding the
-- failure from the suite output entirely.
local function isModuleLog(line)
    return line:sub(1, 6) == '[ojol]' or line:sub(1, 16) == '[lifestate_jobs]'
end

print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end

    local line = table.concat(parts, ' ')
    if isModuleLog(line) then
        host.printed[#host.printed + 1] = line
        return
    end

    realPrint(...)
end

local qbx = {
    Notify = function(source, message, kind)
        host.notifies[#host.notifies + 1] = { source = source, message = message, kind = kind }
    end,
}

---The registry export, behaving like the real boundary: serializable metadata only,
---one entry per provider id, re-registration by the same owner is an update.
local jobsRegistry = {
    RegisterProvider = function(definition)
        host.registerCalls = host.registerCalls + 1
        host.provider = definition

        for key, value in pairs(definition or {}) do
            if type(value) == 'function' then
                host.lastOutcome = 'external_handler_not_serializable'
                return false, host.lastOutcome
            end
        end

        if host.registerOutcome[1] == false then
            host.lastOutcome = host.registerOutcome[2]
            return false, host.lastOutcome
        end

        local existing = host.providers[definition.id]
        host.providers[definition.id] = definition
        host.lastOutcome = existing and 'updated' or 'registered'

        return true, host.lastOutcome
    end,
    UnregisterProvider = function(id)
        host.providers[id] = nil
        return true
    end,
}

exports = {
    qbx_core = h.exportsProxy(qbx),
    lifestate_jobs = h.exportsProxy(jobsRegistry),
}

-- Fresh modules: the registry exports above must exist before the provider loads.
-- Only package.loaded is cleared for the database: dropping that preload would hand
-- these specs the real MariaDB layer. server.drivers is the opposite case - an
-- earlier spec leaves a tiny stub preloaded, and the real registry is what makes
-- this spec meaningful - so its preload goes.
for _, name in ipairs({ 'server.database', 'server.drivers', 'server.adminapi', 'server.jobsprovider' }) do
    package.loaded[name] = nil
end

package.preload['server.drivers'] = nil

local drivers = require 'server.drivers'
local adminapi = require 'server.adminapi'

-- Inside Ojol, the admin API is reached through its own exports. Wire the real
-- module behind the same names the resource registers, so the exports the generic
-- dispatcher will call are the real ones (and accept both call shapes).
exports.lifestate_ojol = h.exportsProxy({
    adminRegisterDriver = adminapi.RegisterDriver,
    adminRemoveDriver = adminapi.RemoveDriver,
    getDriverAdminState = adminapi.GetState,
    assignCEO = adminapi.AssignCEO,
})

local jobsprovider = require 'server.jobsprovider'

-- Fixtures --------------------------------------------------------------------

local CIT = 'CIT-1'
local SOURCE = 7

---A resolved target, as the generic dispatcher passes it to an external export.
local function target(overrides)
    local resolved = { source = SOURCE, citizenid = CIT, name = 'Bob Builder', serverName = 'Bobby' }
    for key, value in pairs(overrides or {}) do resolved[key] = value end
    return resolved
end

local function reset()
    dbState.rows = {}
    dbState.stats = {}
    dbState.calls = {}
    dbState.fail = {}

    host.provider = nil
    host.providers = {}
    host.registerCalls = 0
    host.registerOutcome = { true, 'registered' }
    host.lastOutcome = nil
    host.resourceState = 'started'
    host.clientEvents = {}
    host.events = {}
    host.notifies = {}
    host.threads = {}
    host.printed = {}

    -- A clean runtime registry, as if the resource had just started.
    drivers.RegisteredDrivers = {}
    drivers.OnlineDrivers = {}
    drivers.BusyDrivers = {}
    drivers.SourceByCitizenid = {}
    drivers.CitizenidBySource = {}
end

local function seeded(overrides)
    local row = {
        citizenid = CIT,
        rank = 'driver',
        active = 1,
        registered_by = 'admin',
        registered_at = 1000,
    }

    for key, value in pairs(overrides or {}) do row[key] = value end
    dbState.rows[CIT] = row
    return row
end

local function clientEvents(eventName)
    local list = {}
    for i = 1, #host.clientEvents do
        if host.clientEvents[i].event == eventName then list[#list + 1] = host.clientEvents[i] end
    end
    return list
end

local function called(name)
    for i = 1, #dbState.calls do
        if dbState.calls[i] == name then return true end
    end
    return false
end

---Deep guard: everything in the definition must survive the resource boundary. That
---means plain data - strings, numbers, booleans and tables of the same - keyed by
---strings or array indices, and specifically NO closures (a function is encoded as a
---`funcref` on the other side, which is how a live server rejected this provider with
---`give_not_function`).
---@param value any
---@param path string
---@return string? path of the first unserializable value
local function serializationProblem(value, path)
    local valueType = type(value)

    if valueType == 'function' or valueType == 'thread' or valueType == 'userdata' then
        return ('%s is a %s'):format(path, valueType)
    end

    if valueType ~= 'table' then return nil end

    for key, entry in pairs(value) do
        local keyType = type(key)
        local arrayIndex = keyType == 'number' and key % 1 == 0
        if keyType ~= 'string' and not arrayIndex then return ('%s has a %s key'):format(path, keyType) end

        local found = serializationProblem(entry, ('%s.%s'):format(path, key))
        if found then return found end
    end

    return nil
end

-- The external contract --------------------------------------------------------

h.test('the provider registers serializable metadata only', function()
    reset()

    local ok = jobsprovider.Register()

    h.eq(ok, true, 'registered')
    h.eq(host.registerCalls, 1, 'one call')
    h.eq(host.lastOutcome, 'registered', 'outcome')

    local definition = host.provider
    h.eq(definition.id, 'ojol', 'provider id')
    h.eq(definition.label, 'Mitra LAJU', 'label')
    h.eq(definition.type, 'profession', 'independent profession')
    h.eq(definition.resource, nil, 'no owner declared: the registry records the caller')
    h.eq(definition.mode, nil, 'no mode declared either: the boundary forces external')

    -- The whole point of this pass: no closure may travel.
    h.eq(serializationProblem(definition, 'definition'), nil, 'the definition is plain serializable data')

    h.eq(definition.operations.give, 'adminRegisterDriver', 'give is an export name')
    h.eq(definition.operations.remove, 'adminRemoveDriver', 'remove is an export name')
    h.eq(definition.operations.inspect, 'getDriverAdminState', 'inspect is an export name')
    h.eq(definition.actions[1].export, 'assignCEO', 'the CEO action is an export name')
    h.eq(definition.actions[1].label, 'Set CEO LAJU', 'the CEO action carries LAJU branding')
    h.eq(definition.actions[1].handler, nil, 'the CEO action carries no handler')
    h.eq(definition.actions[1].confirm, true, 'CEO assignment still asks for confirmation')
    h.contains(definition.messages.cannot_fire_ceo, 'Reassign the CEO first',
        'the CEO refusal wording travels as data')
end)

h.test('every export the definition names exists on this resource', function()
    reset()
    jobsprovider.Register()

    local names = {
        jobsprovider.Register and host.provider.operations.give,
        host.provider.operations.remove,
        host.provider.operations.inspect,
        host.provider.actions[1].export,
    }

    for i = 1, #names do
        h.eq(type(names[i]), 'string', ('name %d is a string'):format(i))
        h.eq(type(exports.lifestate_ojol[names[i]]), 'function', ('export %s exists'):format(names[i]))
    end
end)

-- The exports the dispatcher calls ---------------------------------------------

h.test('Give reaches the real registration path and reports its outcome', function()
    reset()

    local ok, outcome = exports.lifestate_ojol:adminRegisterDriver(target(), { grade = nil, source = 1 })

    h.eq(ok, true, 'ok')
    h.eq(outcome, 'registered', 'outcome')
    h.eq(called('InsertDriver'), true, 'the persistent record is created')
    h.eq(dbState.rows[CIT].rank, 'driver', 'rank is driver, never CEO')
    h.eq(drivers.IsRegisteredDriver(CIT), true, 'immediately authorized')
end)

h.test('the exports still accept the plain citizenid call shape', function()
    reset()

    -- Documented server-side / command shape, and what the Ojol README promises.
    h.eq(select(2, exports.lifestate_ojol:adminRegisterDriver(CIT, 'admin menu')), 'registered', 'give')
    h.eq(exports.lifestate_ojol:getDriverAdminState(CIT).registered, true, 'inspect')
    h.eq(select(2, exports.lifestate_ojol:adminRemoveDriver(CIT, 'admin menu')), 'removed', 'remove')
end)

h.test('a duplicate Give is a safe no-op, not a second record', function()
    reset()

    h.eq(select(2, exports.lifestate_ojol:adminRegisterDriver(target(), {})), 'registered', 'first give')
    local ok, outcome = exports.lifestate_ojol:adminRegisterDriver(target(), {})

    h.eq(ok, false, 'reported as a no-op')
    h.eq(outcome, 'already_registered', 'reason the service reports as informational')
    h.eq(#dbState.calls, 1, 'the database is written exactly once')
end)

h.test('a rehire preserves the historical record and its statistics', function()
    reset()

    local row = seeded({ active = 0, rank = 'driver' })
    dbState.stats[CIT] = { rating_sum = 96, rating_count = 20, profile_photo = 'photo.png' }
    -- A running server has already cached the fired record, which is what makes the
    -- rehire path a reactivation instead of a fresh insert.
    drivers.LoadDrivers()

    local ok, outcome = exports.lifestate_ojol:adminRegisterDriver(target(), {})

    h.eq(ok, true, 'ok')
    h.eq(outcome, 'reactivated', 'reactivation, not a fresh registration')
    h.eq(called('ReactivateDriver'), true, 'the existing row is reactivated')
    h.eq(called('InsertDriver'), false, 'no duplicate record')
    h.eq(row.active, 1, 'active again')
    h.eq(dbState.stats[CIT].rating_sum, 96, 'rating sum untouched')
    h.eq(dbState.stats[CIT].rating_count, 20, 'rating count untouched')
    h.eq(dbState.stats[CIT].profile_photo, 'photo.png', 'profile photo untouched')
end)

h.test('Give never assigns CEO and refreshes the target live', function()
    reset()
    drivers.SourceByCitizenid[CIT] = SOURCE

    exports.lifestate_ojol:adminRegisterDriver(target(), {})

    h.eq(dbState.rows[CIT].rank, 'driver', 'rank stays driver')
    h.eq(called('UpdateDriverFields:ceo'), false, 'no CEO write')
    h.eq(#clientEvents('lifestate_ojol:client:driverStateChanged'), 1, 'driver state pushed')
    h.eq(#clientEvents('lifestate_ojol:client:phoneAppsChanged'), 1, 'phone apps refreshed')
    h.eq(host.notifies[1].source, SOURCE, 'the target is told')
end)

h.test('a database failure during Give is reported and changes no runtime state', function()
    reset()
    dbState.fail.InsertDriver = true

    local ok, outcome = exports.lifestate_ojol:adminRegisterDriver(target(), {})

    h.eq(ok, false, 'failed')
    h.eq(outcome, 'database_error', 'reason')
    h.eq(drivers.IsRegisteredDriver(CIT), false, 'no runtime registration')
    h.eq(drivers.GetOjolDriver(CIT), nil, 'no cached record')
end)

h.test('Give refuses a malformed target', function()
    reset()

    h.eq(select(2, exports.lifestate_ojol:adminRegisterDriver({ citizenid = '' }, {})), 'invalid_target', 'empty')
    h.eq(select(2, exports.lifestate_ojol:adminRegisterDriver(nil, {})), 'invalid_target', 'nil')
    h.eq(#dbState.calls, 0, 'no database write')
end)

h.test('Remove soft-deactivates the driver and revokes authorization', function()
    reset()
    seeded()
    drivers.LoadDrivers()
    drivers.SourceByCitizenid[CIT] = SOURCE
    drivers.OnlineDrivers[CIT] = true
    drivers.BusyDrivers[CIT] = true

    local ok, outcome = exports.lifestate_ojol:adminRemoveDriver(target(), {})

    h.eq(ok, true, 'ok')
    h.eq(outcome, 'removed', 'outcome')
    h.eq(called('DeactivateDriver'), true, 'soft deactivation, not a delete')
    h.eq(drivers.GetOjolDriver(CIT).active, false, 'record kept but inactive')
    h.eq(drivers.IsRegisteredDriver(CIT), false, 'authorization revoked immediately')
    h.eq(drivers.IsDriverOnline(CIT), false, 'online state cleared')
    h.eq(drivers.IsDriverBusy(CIT), false, 'busy state cleared safely')

    local fired = false
    for i = 1, #host.events do
        if host.events[i] == 'lifestate_ojol:server:driverFired' then fired = true end
    end
    h.eq(fired, true, 'driverFired fired for the ride/bike/app hooks')
    h.eq(#clientEvents('lifestate_ojol:client:driverRevoked'), 1, 'the client mirror is revoked')
end)

h.test('Remove refuses the active CEO with the metadata message', function()
    reset()
    seeded({ rank = 'ceo' })
    drivers.LoadDrivers()

    local ok, outcome = exports.lifestate_ojol:adminRemoveDriver(target(), {})

    h.eq(ok, false, 'refused')
    h.eq(outcome, 'cannot_fire_ceo', 'reason the menu renders using messages.cannot_fire_ceo')
    h.eq(called('DeactivateDriver'), false, 'no deactivation write')
    h.eq(drivers.IsCEO(CIT), true, 'the CEO is still active')
end)

h.test('removing someone who is not registered is a safe no-op', function()
    reset()

    local ok, outcome = exports.lifestate_ojol:adminRemoveDriver(target(), {})

    h.eq(ok, false, 'no change')
    h.eq(outcome, 'not_registered', 'reason the service reports as informational')
    h.eq(#dbState.calls, 0, 'no database write')
end)

h.test('a database failure during Remove leaves the driver active', function()
    reset()
    seeded()
    drivers.LoadDrivers()
    dbState.fail.DeactivateDriver = true

    local ok, outcome = exports.lifestate_ojol:adminRemoveDriver(target(), {})

    h.eq(ok, false, 'failed')
    h.eq(outcome, 'database_error', 'reason')
    h.eq(drivers.IsRegisteredDriver(CIT), true, 'runtime and database do not diverge')
end)

h.test('the Set CEO export uses the trusted single-CEO path and names its outcome', function()
    reset()
    seeded()
    drivers.LoadDrivers()
    drivers.SourceByCitizenid[CIT] = SOURCE

    local ok, outcome = exports.lifestate_ojol:assignCEO(target(), {})

    h.eq(ok, true, 'assigned')
    h.eq(outcome, 'ceo_assigned', 'outcome the generic service turns into a sentence')
    h.eq(dbState.rows[CIT].rank, 'ceo', 'rank written')
    h.eq(drivers.IsCEO(CIT), true, 'authoritative in runtime')
    h.eq(#clientEvents('lifestate_ojol:client:driverStateChanged'), 1, 'target refreshed')
    h.eq(host.notifies[1].message, 'Kamu sekarang CEO LAJU.', 'target notified')
end)

h.test('the Set CEO export demotes the previous CEO, so there is only ever one', function()
    reset()
    seeded()

    local OTHER = 'CIT-2'
    dbState.rows[OTHER] = {
        citizenid = OTHER, rank = 'ceo', active = 1,
        registered_by = 'admin', registered_at = 1000,
    }

    drivers.LoadDrivers()
    h.eq(drivers.IsCEO(OTHER), true, 'precondition: other is CEO')

    exports.lifestate_ojol:assignCEO(target(), {})

    h.eq(drivers.IsCEO(CIT), true, 'new CEO')
    h.eq(drivers.GetOjolDriver(OTHER).rank, 'driver', 'previous CEO demoted')
    h.eq(dbState.rows[OTHER].rank, 'driver', 'and persisted')
end)

h.test('the inspect export reports the generic state shape', function()
    reset()
    seeded({ rank = 'senior_driver' })
    drivers.LoadDrivers()

    local state = exports.lifestate_ojol:getDriverAdminState(target())

    h.eq(state.registered, true, 'registered')
    h.eq(state.active, true, 'active')
    h.eq(state.rank, 'senior_driver', 'rank')
    h.eq(state.online, false, 'offline')
    h.eq(state.busy, false, 'not busy')
    h.eq(state.details[1].label, 'Record', 'details are rendered as-is')
end)

h.test('the inspect export reports a fired record without claiming eligibility', function()
    reset()
    seeded({ active = 0 })
    drivers.LoadDrivers()

    local state = exports.lifestate_ojol:getDriverAdminState(target())

    h.eq(state.registered, false, 'not registered')
    h.eq(state.active, false, 'not active')
    h.eq(state.rank, nil, 'no rank exposed')
    h.eq(state.details[1].value, 'inactive (fired)', 'history is still visible to the admin')
end)

h.test('the inspect export reports online/busy/rating and an unknown player', function()
    reset()
    seeded()
    -- Aggregates are read at load (SELECT *), which is what hydrates the
    -- memory-only snapshot: seed them before the drivers load.
    dbState.stats[CIT] = { rating_sum = 47, rating_count = 10 }
    drivers.LoadDrivers()
    drivers.OnlineDrivers[CIT] = true
    drivers.BusyDrivers[CIT] = true

    local state = exports.lifestate_ojol:getDriverAdminState(target())
    h.eq(state.online, true, 'online')
    h.eq(state.busy, true, 'busy')
    h.eq(math.floor(state.rating * 10 + 0.5), 47, 'average rating is derived from the aggregates')

    h.eq(exports.lifestate_ojol:getDriverAdminState({ citizenid = 'NOBODY' }).registered, false, 'unknown player')
    h.eq(exports.lifestate_ojol:getDriverAdminState({ citizenid = '' }).registered, false, 'malformed citizenid')
end)

-- Startup and retry policy -----------------------------------------------------

h.test('a missing registry fails cleanly instead of half-registering', function()
    reset()
    host.resourceState = 'missing'

    local ok, reason = jobsprovider.Register()
    h.eq(ok, false, 'refused')
    h.eq(reason, 'registry_unavailable', 'dependency problem, not a definition problem')
    h.eq(host.registerCalls, 0, 'the registry is never called')
end)

h.test('a registry that is not up yet is retried with a bounded backoff', function()
    reset()
    host.resourceState = 'missing'

    jobsprovider.Start()
    h.eq(#host.threads, 1, 'one retry thread, never a polling loop')
    h.eq(#jobsprovider.RETRY_DELAYS_MS, 4, 'a handful of attempts')
    h.eq(jobsprovider.RETRY_DELAYS_MS[1], 500, 'starting short')
    h.eq(jobsprovider.RETRY_DELAYS_MS[#jobsprovider.RETRY_DELAYS_MS], 5000, 'backing off, not repeating')

    host.resourceState = 'started'
    host.threads[1]()
    h.eq(host.registerCalls, 1, 'the retry registers once the registry is up')
    h.eq(host.providers.ojol ~= nil, true, 'and stops there')
end)

h.test('a retry that still cannot reach the registry gives up with a clear log', function()
    reset()
    host.resourceState = 'missing'

    local registered, reason = jobsprovider.RegisterWithRetry()

    h.eq(registered, false, 'never registered')
    h.eq(reason, 'registry_unavailable', 'reason')
    h.eq(host.registerCalls, 0, 'a registry that is not running is never called at all')
    h.eq(#jobsprovider.RETRY_DELAYS_MS, 4, 'the bounded attempt budget')
    h.contains(host.printed[#host.printed], 'never became available', 'the give-up is logged once')
end)

h.test('a STRUCTURAL rejection is logged once and never retried', function()
    reset()
    host.registerOutcome = { false, 'external_handler_not_serializable' }

    jobsprovider.Start()

    h.eq(host.registerCalls, 1, 'exactly one attempt')
    h.eq(#host.threads, 0, 'no retry thread: retrying cannot fix a bad definition')
    h.eq(jobsprovider.IsRetryable('external_handler_not_serializable'), false, 'not retryable')
    h.eq(jobsprovider.IsRetryable('missing_label'), false, 'nor any other validation reason')
    h.eq(jobsprovider.IsRetryable('id_conflict'), false, 'nor an id conflict')
    h.eq(jobsprovider.IsRetryable('registry_unavailable'), true, 'only the dependency is')
    h.contains(host.printed[#host.printed], 'rejected', 'the reason is logged once')
end)

h.test('a successful registration does not schedule any retry', function()
    reset()

    jobsprovider.Start()

    h.eq(host.registerCalls, 1, 'one call')
    h.eq(#host.threads, 0, 'nothing scheduled')
    h.eq(host.lastOutcome, 'registered', 'registered on the first try')
end)

h.test('re-registering never duplicates the provider, even after a registry restart', function()
    reset()
    jobsprovider.Register()
    h.eq(host.registerCalls, 1, 'registered once')
    h.eq(host.providers.ojol ~= nil, true, 'one provider in the registry')

    jobsprovider.Register()
    h.eq(host.lastOutcome, 'updated', 'a second call is an update')
    h.eq(host.registerCalls, 2, 'but it did go through')

    local count = 0
    for _ in pairs(host.providers) do count = count + 1 end
    h.eq(count, 1, 'still exactly one Ojol provider')

    -- The registry restarted (or cleaned up this owner's entries): re-registering
    -- must restore exactly one provider, not two.
    host.providers = {}
    jobsprovider.Register()
    h.eq(host.lastOutcome, 'registered', 'registered again from scratch')

    count = 0
    for _ in pairs(host.providers) do count = count + 1 end
    h.eq(count, 1, 'one provider after the restart')
end)

h.test('the provider re-registers when the registry resource restarts', function()
    reset()
    jobsprovider.Start()

    h.eq(host.registerCalls, 1, 'registered at start')
    h.ok(host.handlers.onServerResourceStart, 'restart handler wired')

    host.handlers.onServerResourceStart('some_other_resource')
    h.eq(#host.threads, 0, 'an unrelated restart does nothing')

    host.handlers.onServerResourceStart('lifestate_jobs')
    h.eq(#host.threads, 1, 'the registry restart re-registers')

    host.threads[1]()
    h.eq(host.registerCalls, 2, 'registered again after the registry restart')

    -- If the restarted registry has not published its export yet, the re-registration
    -- waits instead of dropping the provider until the next Ojol restart.
    host.providers = {}
    host.resourceState = 'missing'
    host.handlers.onServerResourceStart('lifestate_jobs')
    h.eq(#host.threads, 2, 'a second re-registration is armed')

    host.resourceState = 'started'
    host.threads[2]()
    h.eq(host.providers.ojol ~= nil, true, 'and it lands once the registry is back')
    h.eq(host.registerCalls, 3, 'exactly one extra registration')
end)
