-- Ojol's registration into the generic admin Job Management system.
--
-- This drives the REAL server/jobsprovider.lua and the REAL server/adminapi.lua
-- against the REAL server/drivers.lua, with only the MariaDB layer stubbed. It is
-- therefore the proof of the chain the admin menu actually walks:
--
--   lifestate_jobs provider contract -> exports.lifestate_ojol:admin* -> drivers -> DB
--
-- The properties pinned down here are the ones the admin feature promised:
--
--   * one registration call is all a job needs (the contract shape is stable),
--   * a missing registry fails cleanly instead of half-registering,
--   * Give uses the existing server-authoritative path and NEVER assigns CEO,
--   * a rehire reactivates the historical record with statistics intact,
--   * Remove is the existing soft deactivation and cannot touch an active CEO,
--   * Set CEO is the trusted single-CEO path,
--   * the target's client is refreshed immediately (no reconnect).

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
    registerCalls = 0,
    registerOutcome = { true, 'registered' },
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
            for _, row in pairs(dbState.rows) do list[#list + 1] = row end
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

print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end

    local line = table.concat(parts, ' ')
    if line:find('[ojol]', 1, true) or line:find('[lifestate_jobs]', 1, true) then
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

---The registry export, behaving like the real boundary: one entry per provider id,
---re-registration of the same id by the same owner is an update (never a second
---entry), and ownership is decided there, not here.
local jobsRegistry = {
    RegisterProvider = function(definition)
        host.registerCalls = host.registerCalls + 1
        host.provider = definition
        if host.registerOutcome[1] == false then
            host.lastOutcome = host.registerOutcome[2]
            return false, host.registerOutcome[2]
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
-- these specs the real MariaDB layer. server.drivers is the opposite case -- an
-- earlier spec leaves a tiny stub preloaded, and the real registry is what makes
-- this spec meaningful -- so its preload goes.
for _, name in ipairs({ 'server.database', 'server.drivers', 'server.adminapi', 'server.jobsprovider' }) do
    package.loaded[name] = nil
end

package.preload['server.drivers'] = nil

local drivers = require 'server.drivers'
local adminapi = require 'server.adminapi'

-- Inside Ojol, the admin API is reached through its own exports. Wire the real
-- module behind the same names the resource registers, so the provider is driven
-- exactly as the admin menu drives it.
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

local function reset()
    dbState.rows = {}
    dbState.stats = {}
    dbState.calls = {}
    dbState.fail = {}

    host.provider = nil
    host.providers = {}
    host.registerCalls = 0
    host.registerOutcome = { true, 'registered' }
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

-- Registration contract -------------------------------------------------------

h.test('the provider registers itself with the generic registry exactly once', function()
    reset()

    local ok = jobsprovider.Register()

    h.eq(ok, true, 'registered')
    h.eq(host.registerCalls, 1, 'one call')
    h.eq(host.provider.id, 'ojol', 'provider id')
    h.eq(host.provider.label, 'Ojol', 'label')
    h.eq(host.provider.type, 'profession', 'Ojol stays an independent profession')
    h.eq(type(host.provider.give), 'function', 'give handler')
    h.eq(type(host.provider.remove), 'function', 'remove handler')
    h.eq(type(host.provider.inspect), 'function', 'inspect handler')
    -- Ownership is not declared here: lifestate_jobs records the invoking resource
    -- as the owner, which is what stops another resource impersonating Ojol.
    h.eq(host.provider.resource, nil, 'no owner declared in the definition')
    h.eq(#host.provider.actions, 1, 'one provider action')
    h.eq(host.provider.actions[1].id, 'setCeo', 'action id')
    h.eq(host.provider.actions[1].confirm, true, 'CEO assignment asks for confirmation')
end)

h.test('the provider declares no owner of its own: the registry records the caller', function()
    reset()
    jobsprovider.Register()

    -- Ownership is resolved at the registry's export boundary from the invoking
    -- resource, so a `resource` field here would be ignored anyway (and could only
    -- invite impersonation). It must not be declared.
    h.eq(host.provider.resource, nil, 'no resource field in the definition')
end)

h.test('re-registering never duplicates the provider, even after a registry restart', function()
    reset()
    jobsprovider.Register()
    h.eq(host.registerCalls, 1, 'registered once')
    h.eq(host.lastOutcome, 'registered', 'first registration')
    h.eq(host.providers.ojol ~= nil, true, 'one provider in the registry')

    jobsprovider.Register()
    h.eq(host.lastOutcome, 'updated', 'a second call is an update')
    h.eq(host.registerCalls, 2, 'but it did go through')

    local count = 0
    for _ in pairs(host.providers) do count = count + 1 end
    h.eq(count, 1, 'still exactly one olol provider')

    -- The registry restarted (or cleaned up this owner's entries): re-registering
    -- must restore exactly one provider, not two.
    host.providers = {}
    jobsprovider.Register()
    h.eq(host.lastOutcome, 'registered', 'registered again from scratch')

    count = 0
    for _ in pairs(host.providers) do count = count + 1 end
    h.eq(count, 1, 'one provider after the restart')
end)

h.test('a missing registry fails cleanly instead of half-registering', function()
    reset()
    host.resourceState = 'missing'

    h.eq(jobsprovider.Register(), false, 'refused')
    h.eq(host.registerCalls, 0, 'the registry is never called')
    h.contains(host.printed[#host.printed], 'not running', 'the reason is logged')

    -- Start() then falls back to a bounded retry instead of throwing.
    jobsprovider.Start()
    h.eq(#host.threads, 1, 'one retry thread, no polling loop')

    host.resourceState = 'started'
    host.threads[1]()
    h.eq(host.registerCalls, 1, 'the retry registers once the registry is up')
end)

h.test('a registry that rejects the provider is reported and retried, not fatal', function()
    reset()
    host.registerOutcome = { false, 'missing_id' }

    h.eq(jobsprovider.Register(), false, 'rejected')
    h.contains(host.printed[#host.printed], 'rejected', 'logged')
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
end)

-- Give ------------------------------------------------------------------------

h.test('admin Give registers the target through the real registration path', function()
    reset()
    jobsprovider.Register()

    local ok, outcome = host.provider.give({ source = SOURCE, citizenid = CIT, name = 'Bob Builder' })

    h.eq(ok, true, 'ok')
    h.eq(outcome, 'registered', 'outcome')
    h.eq(called('InsertDriver'), true, 'the persistent record is created')
    h.eq(dbState.rows[CIT].active, 1, 'active')
    h.eq(dbState.rows[CIT].rank, 'driver', 'rank is driver, never CEO')
    h.eq(drivers.IsRegisteredDriver(CIT), true, 'immediately authorized')
end)

h.test('admin Give works with the admin own server id (self target)', function()
    reset()
    jobsprovider.Register()

    drivers.SourceByCitizenid = { [CIT] = SOURCE }

    local ok, outcome = host.provider.give({ source = SOURCE, citizenid = CIT, name = 'Admin Man' })
    h.eq(ok, true, 'ok')
    h.eq(outcome, 'registered', 'outcome')
    h.eq(dbState.rows[CIT].registered_by, 'admin', 'recorded as an admin action')
end)

h.test('a duplicate Give is a safe no-op, not a second record', function()
    reset()
    jobsprovider.Register()

    h.eq(select(2, host.provider.give({ source = SOURCE, citizenid = CIT })), 'registered', 'first give')
    local ok, outcome = host.provider.give({ source = SOURCE, citizenid = CIT })

    h.eq(ok, false, 'reported as a no-op')
    h.eq(outcome, 'already_registered', 'reason')
    h.eq(#dbState.calls, 1, 'the database is written exactly once')
end)

h.test('a rehire preserves the historical record and its statistics', function()
    reset()
    jobsprovider.Register()

    local row = seeded({ active = 0, rank = 'driver' })
    dbState.stats[CIT] = { rating_sum = 96, rating_count = 20, profile_photo = 'photo.png' }
    -- A running server has already cached the fired record, which is what makes the
    -- rehire path a reactivation instead of a fresh insert.
    drivers.LoadDrivers()

    local ok, outcome = host.provider.give({ source = SOURCE, citizenid = CIT })

    h.eq(ok, true, 'ok')
    h.eq(outcome, 'reactivated', 'reactivation, not a fresh registration')
    h.eq(called('ReactivateDriver'), true, 'the existing row is reactivated')
    h.eq(called('InsertDriver'), false, 'no duplicate record')
    h.eq(row.active, 1, 'active again')
    h.eq(dbState.stats[CIT].rating_sum, 96, 'rating sum untouched')
    h.eq(dbState.stats[CIT].rating_count, 20, 'rating count untouched')
    h.eq(dbState.stats[CIT].profile_photo, 'photo.png', 'profile photo untouched')
end)

h.test('ordinary Give never assigns CEO and refreshes the target live', function()
    reset()
    jobsprovider.Register()
    h.eq(#host.provider.actions, 1, 'the CEO path is a separate action')

    host.provider.give({ source = SOURCE, citizenid = CIT })

    h.eq(dbState.rows[CIT].rank, 'driver', 'rank stays driver')
    h.eq(called('UpdateDriverFields:ceo'), false, 'no CEO write')

    -- A live target is refreshed so the App Store eligibility updates at once.
    reset()
    jobsprovider.Register()
    drivers.SourceByCitizenid[CIT] = SOURCE
    host.provider.give({ source = SOURCE, citizenid = CIT })

    h.eq(#clientEvents('lifestate_ojol:client:driverStateChanged'), 1, 'driver state pushed')
    h.eq(#clientEvents('lifestate_ojol:client:phoneAppsChanged'), 1, 'phone apps refreshed')
    h.eq(host.notifies[1].source, SOURCE, 'the target is told')
end)

h.test('a database failure during Give is reported and changes no runtime state', function()
    reset()
    jobsprovider.Register()
    dbState.fail.InsertDriver = true

    local ok, outcome = host.provider.give({ source = SOURCE, citizenid = CIT })

    h.eq(ok, false, 'failed')
    h.eq(outcome, 'database_error', 'reason')
    h.eq(drivers.IsRegisteredDriver(CIT), false, 'no runtime registration')
    h.eq(drivers.GetOjolDriver(CIT), nil, 'no cached record')
end)

h.test('Give refuses a malformed citizenid', function()
    reset()
    jobsprovider.Register()

    h.eq(select(2, host.provider.give({ citizenid = '' })), 'invalid_target', 'empty')
    h.eq(select(2, host.provider.give({ citizenid = nil })), 'invalid_target', 'nil')
    h.eq(#dbState.calls, 0, 'no database write')
end)

-- Remove ----------------------------------------------------------------------

h.test('admin Remove soft-deactivates the driver and revokes authorization', function()
    reset()
    jobsprovider.Register()
    seeded()
    drivers.LoadDrivers()
    drivers.SourceByCitizenid[CIT] = SOURCE
    drivers.OnlineDrivers[CIT] = true
    drivers.BusyDrivers[CIT] = true

    local ok, outcome = host.provider.remove({ source = SOURCE, citizenid = CIT, name = 'Bob' })

    h.eq(ok, true, 'ok')
    h.eq(outcome, 'removed', 'outcome')
    h.eq(called('DeactivateDriver'), true, 'soft deactivation, not a delete')
    h.eq(drivers.GetOjolDriver(CIT).active, false, 'record kept but inactive')
    h.eq(drivers.IsRegisteredDriver(CIT), false, 'authorization revoked immediately')
    h.eq(drivers.IsDriverOnline(CIT), false, 'online state cleared')
    h.eq(drivers.IsDriverBusy(CIT), false, 'busy state cleared safely')

    -- The driverFired chain is what the bike, ride and phone-app code hooks into.
    local fired = false
    for i = 1, #host.events do
        if host.events[i] == 'lifestate_ojol:server:driverFired' then fired = true end
    end
    h.eq(fired, true, 'driverFired fired for the ride/bike/app hooks')
    h.eq(#clientEvents('lifestate_ojol:client:driverRevoked'), 1, 'the client mirror is revoked')
end)

h.test('admin Remove refuses the active CEO and explains the safe path', function()
    reset()
    jobsprovider.Register()
    seeded({ rank = 'ceo' })
    drivers.LoadDrivers()

    local ok, outcome, detail = host.provider.remove({ source = SOURCE, citizenid = CIT, name = 'Boss' })

    h.eq(ok, false, 'refused')
    h.eq(outcome, 'cannot_fire_ceo', 'reason')
    h.contains(detail.message, 'Reassign the CEO first', 'tells the admin the safe route')
    h.eq(called('DeactivateDriver'), false, 'no deactivation write')
    h.eq(drivers.GetOjolDriver(CIT).active, true, 'the CEO is still active')
    h.eq(drivers.IsCEO(CIT), true, 'and still the CEO')
end)

h.test('removing someone who is not registered is a safe no-op', function()
    reset()
    jobsprovider.Register()

    local ok, outcome = host.provider.remove({ source = SOURCE, citizenid = CIT })

    h.eq(ok, false, 'no change')
    h.eq(outcome, 'not_registered', 'reason the service reports as informational')
    h.eq(#dbState.calls, 0, 'no database write')
end)

h.test('a database failure during Remove leaves the driver active', function()
    reset()
    jobsprovider.Register()
    seeded()
    drivers.LoadDrivers()
    dbState.fail.DeactivateDriver = true

    local ok, outcome = host.provider.remove({ source = SOURCE, citizenid = CIT })

    h.eq(ok, false, 'failed')
    h.eq(outcome, 'database_error', 'reason')
    h.eq(drivers.IsRegisteredDriver(CIT), true, 'runtime and database do not diverge')
end)

h.test('admin Remove works for an offline and far-away target', function()
    reset()
    jobsprovider.Register()
    seeded()
    drivers.LoadDrivers()

    h.eq(select(1, host.provider.remove({ source = 99, citizenid = CIT })), true, 'no proximity requirement')
    h.eq(#clientEvents('lifestate_ojol:client:driverRevoked'), 0, 'nothing pushed to an absent player')
end)

-- Set CEO ---------------------------------------------------------------------

h.test('the Set CEO action uses the trusted single-CEO path', function()
    reset()
    jobsprovider.Register()
    seeded()
    drivers.LoadDrivers()
    drivers.SourceByCitizenid[CIT] = SOURCE

    local action = host.provider.actions[1]
    local ok, outcome, detail = action.handler({ source = SOURCE, citizenid = CIT, name = 'Boss' })

    h.eq(ok, true, 'assigned')
    h.eq(outcome, 'ceo_assigned', 'outcome')
    h.contains(detail.message, 'now the Ojol CEO', 'message')

    local row = dbState.rows[CIT]
    h.eq(row.rank, 'ceo', 'rank written')
    h.eq(row.active, 1, 'still active')
    h.eq(drivers.IsCEO(CIT), true, 'authoritative in runtime')
    h.eq(#clientEvents('lifestate_ojol:client:driverStateChanged'), 1, 'target refreshed')
    h.eq(host.notifies[1].message, 'Kamu sekarang CEO Ojol.', 'target notified')
end)

h.test('the Set CEO action demotes the previous CEO, so there is only ever one', function()
    reset()
    jobsprovider.Register()
    seeded()

    local OTHER = 'CIT-2'
    dbState.rows[OTHER] = {
        citizenid = OTHER, rank = 'ceo', active = 1,
        registered_by = 'admin', registered_at = 1000,
    }

    drivers.LoadDrivers()
    h.eq(drivers.IsCEO(OTHER), true, 'precondition: other is CEO')

    host.provider.actions[1].handler({ source = SOURCE, citizenid = CIT, name = 'Boss' })

    h.eq(drivers.IsCEO(CIT), true, 'new CEO')
    h.eq(drivers.GetOjolDriver(OTHER).rank, 'driver', 'previous CEO demoted')
    h.eq(dbState.rows[OTHER].rank, 'driver', 'and persisted')
end)

h.test('the Set CEO action can create the record for a never-registered player', function()
    reset()
    jobsprovider.Register()
    h.eq(drivers.GetOjolDriver(CIT), nil, 'precondition: unknown player')

    local ok = host.provider.actions[1].handler({ source = SOURCE, citizenid = CIT, name = 'Boss' })

    h.eq(ok, true, 'assigned')
    h.eq(dbState.rows[CIT].rank, 'ceo', 'created as CEO')
    h.eq(drivers.IsCEO(CIT), true, 'authoritative in runtime')
end)

-- View Player Jobs ------------------------------------------------------------

h.test('the inspect contract reports the generic state shape', function()
    reset()
    jobsprovider.Register()
    seeded({ rank = 'senior_driver' })
    drivers.LoadDrivers()

    local state = host.provider.inspect({ source = SOURCE, citizenid = CIT })

    h.eq(state.registered, true, 'registered')
    h.eq(state.active, true, 'active')
    h.eq(state.rank, 'senior_driver', 'rank')
    h.eq(state.online, false, 'offline')
    h.eq(state.busy, false, 'not busy')
    h.eq(state.details[1].label, 'Record', 'details are rendered as-is')
    h.eq(state.details[1].value, 'active', 'record state')
end)

h.test('the inspect contract reports a fired record without claiming eligibility', function()
    reset()
    jobsprovider.Register()
    seeded({ active = 0 })
    drivers.LoadDrivers()

    local state = host.provider.inspect({ source = SOURCE, citizenid = CIT })

    h.eq(state.registered, false, 'not registered')
    h.eq(state.active, false, 'not active')
    h.eq(state.rank, nil, 'no rank exposed')
    h.eq(state.details[1].value, 'inactive (fired)', 'history is still visible to the admin')
end)

h.test('the inspect contract reports an online, busy driver and an unknown player', function()
    reset()
    jobsprovider.Register()
    seeded()
    drivers.LoadDrivers()
    drivers.OnlineDrivers[CIT] = true
    drivers.BusyDrivers[CIT] = true
    dbState.stats[CIT] = { rating_sum = 47, rating_count = 10 }

    local state = host.provider.inspect({ source = SOURCE, citizenid = CIT })
    h.eq(state.online, true, 'online')
    h.eq(state.busy, true, 'busy')
    h.eq(math.floor(state.rating * 10 + 0.5), 47, 'average rating is derived from the aggregates')

    h.eq(host.provider.inspect({ citizenid = 'NOBODY' }).registered, false, 'unknown player')
    h.eq(host.provider.inspect({ citizenid = '' }).registered, false, 'malformed citizenid')
end)
