-- Generic job service (server/service.lua).
--
-- These specs are the server-side contract the admin menu relies on: EVERY read
-- and mutation is authorized and resolved on this side, a provider is always
-- called with a server-verified target, and a broken provider cannot break the
-- menu or another provider.

local h = require 'tests.harness'

-- Host stubs ------------------------------------------------------------------

local host = {
    ace = {},
    optin = {},
    players = {},
    names = {},
    notified = {},
    printed = {},
}

function IsPlayerAceAllowed(source, permission)
    return host.ace[source] ~= nil and host.ace[source][permission] == true
end

function GetPlayerName(source)
    return host.names[source]
end

local qbx = {
    GetPlayer = function(source) return host.players[source] end,
    IsOptin = function(source) return host.optin[source] == true end,
    Notify = function(source, message, kind)
        host.notified[#host.notified + 1] = { source = source, message = message, kind = kind }
    end,
}

exports = { qbx_core = h.exportsProxy(qbx) }

-- Keep the specs readable: module logs are captured, everything else still prints.
local realPrint = print

print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end

    local line = table.concat(parts, ' ')
    if line:find('[lifestate_jobs]', 1, true) then
        host.printed[#host.printed + 1] = line
        return
    end

    realPrint(...)
end

package.preload['config.server'] = function()
    return {
        perm = 'admin',
        requireOptin = true,
        defaultJob = 'unemployed',
        frameworkJobs = { enabled = false, blacklist = {}, whitelist = nil },
        showCitizenId = false,
        listUnregisteredProfessions = true,
        categoryThreshold = 25,
        audit = { citizenId = true, resource = true },
    }
end

h.reload('server.registry', 'server.service')

local registry = require 'server.registry'
local service = require 'server.service'

-- Fixtures --------------------------------------------------------------------

local ADMIN = 1
local TARGET = 2

local function makeAdmin(source)
    host.ace[source] = { admin = true }
    host.optin[source] = true
    host.names[source] = ('Admin%s'):format(source)
end

local function addPlayer(source, citizenid, serverName, charName, primaryJob, jobs)
    host.names[source] = serverName
    host.players[source] = {
        PlayerData = {
            source = source,
            citizenid = citizenid,
            charinfo = charName or { firstname = 'Bob', lastname = 'Builder' },
            job = primaryJob or {
                name = 'unemployed', label = 'Civilian',
                grade = { name = 'Freelancer', level = 0 }, onduty = true,
            },
            jobs = jobs or { unemployed = 0 },
        },
    }
end

makeAdmin(ADMIN)
addPlayer(TARGET, 'CIT-2', 'Bobby', { firstname = 'Bob', lastname = 'Builder' }, nil, { unemployed = 0, police = 2 })

---@param overrides table?
local function provider(overrides)
    local def = {
        id = 'ojol',
        label = 'Ojol',
        type = 'profession',
        resource = 'lifestate_ojol',
        give = function() return true, 'registered' end,
        remove = function() return true, 'removed' end,
        inspect = function() return { registered = true, online = false, busy = false, rank = 'driver' } end,
    }

    for key, value in pairs(overrides or {}) do def[key] = value end
    return def
end

local function lastAudit()
    return host.printed[#host.printed]
end
-- Authorization (server-side, for every entry point) --------------------------

h.test('a non-admin request is denied and never reaches a provider', function()
    registry.Reset()
    host.printed = {}

    local called = 0
    registry.Register(provider({ give = function() called = called + 1 return true, 'registered' end }))

    host.ace[9] = {}
    local result = service.Mutate(9, { action = 'give', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, false, 'denied')
    h.eq(result.outcome, 'no_perms', 'reason')
    h.eq(called, 0, 'provider never called')
    h.contains(lastAudit(), 'audit:', 'the attempt is audited')
    h.contains(lastAudit(), 'no_perms', 'with the reason')
end)

h.test('invalid and non-player sources are denied', function()
    h.eq(select(2, service.Authorize(0)), 'invalid_source', 'console')
    h.eq(select(2, service.Authorize(-1)), 'invalid_source', 'negative')
    h.eq(select(2, service.Authorize('1')), 'invalid_source', 'string')
    h.eq(select(2, service.Authorize(nil)), 'invalid_source', 'nil')
end)

h.test('admin duty is required in addition to the ACE permission', function()
    local source = 40
    host.names[source] = 'Mod'

    h.eq(select(2, service.Authorize(source)), 'no_perms', 'no ace')

    host.ace[source] = { admin = true }
    h.eq(select(2, service.Authorize(source)), 'not_optin', 'no admin duty')

    host.optin[source] = true
    h.eq(service.Authorize(source), true, 'authorized')
end)

-- Target resolution -----------------------------------------------------------

h.test('invalid target ids are rejected before any provider is consulted', function()
    h.eq(select(2, service.ResolveTarget(nil)), 'invalid_target', 'nil')
    h.eq(select(2, service.ResolveTarget('abc')), 'invalid_target', 'text')
    h.eq(select(2, service.ResolveTarget(0)), 'invalid_target', 'zero')
    h.eq(select(2, service.ResolveTarget(2.5)), 'invalid_target', 'fractional')
    h.eq(select(2, service.ResolveTarget(99)), 'invalid_target', 'no such player')
end)

h.test('a target is resolved server-side with identity and framework context', function()
    local target = service.ResolveTarget(TARGET)
    h.ok(target, 'resolved')
    h.eq(target.source, TARGET, 'source')
    h.eq(target.citizenid, 'CIT-2', 'citizenid')
    h.eq(target.name, 'Bob Builder', 'character name')
    h.eq(target.primaryJob.name, 'unemployed', 'primary job')
    h.eq(target.jobs.police, 2, 'job memberships')

    h.eq(service.ResolveTarget('2').source, 2, 'string ids from the client are accepted')
end)

h.test('a player without loaded PlayerData is not a valid target', function()
    host.names[50] = 'Loading'
    h.eq(select(2, service.ResolveTarget(50)), 'invalid_target', 'half-loaded player')

    host.players[51] = { PlayerData = nil }
    host.names[51] = 'Half'
    h.eq(select(2, service.ResolveTarget(51)), 'invalid_target', 'no PlayerData')
end)
-- Mutations ------------------------------------------------------------------

h.test('give reaches the provider with the resolved target and reports success', function()
    registry.Reset()
    host.printed = {}

    local seen = {}
    registry.Register(provider({
        give = function(target, options)
            seen.target, seen.options = target, options
            return true, 'registered'
        end,
    }))

    local result = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, true, 'ok')
    h.eq(result.changed, true, 'changed')
    h.eq(result.outcome, 'registered', 'outcome')
    h.eq(seen.target.citizenid, 'CIT-2', 'provider received the resolved target')
    h.eq(seen.options.source, ADMIN, 'admin source passed through')
    h.eq(result.target.source, TARGET, 'result names the target')
    h.contains(result.message, 'Bob Builder', 'message names the player')
    h.contains(result.message, 'Ojol', 'message names the job')
    h.contains(lastAudit(), 'registered', 'the outcome is audited')
    h.contains(lastAudit(), 'ojol', 'the job id is audited')
    h.contains(lastAudit(), 'CIT-2', 'the target citizenid is audited')
end)

h.test('self-target works with the admin own server id', function()
    registry.Reset()
    addPlayer(ADMIN, 'CIT-1', 'AdminMan', { firstname = 'Aim', lastname = 'Jax' })

    local seen = {}
    registry.Register(provider({ give = function(target) seen.citizenid = target.citizenid return true, 'registered' end }))

    local result = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = ADMIN })

    h.eq(result.ok, true, 'ok')
    h.eq(seen.citizenid, 'CIT-1', 'provider got the admin own citizenid')
end)

h.test('a duplicate give is reported safely instead of as an error', function()
    registry.Reset()
    registry.Register(provider({ give = function() return false, 'already_registered' end }))

    local result = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, true, 'not an error')
    h.eq(result.changed, false, 'nothing changed')
    h.eq(result.outcome, 'already_registered', 'outcome')
    h.contains(result.message, 'already an active', 'explains the no-op')
end)

h.test('removing something that is not there is reported safely', function()
    registry.Reset()
    registry.Register(provider({ remove = function() return false, 'not_registered' end }))

    local result = service.Mutate(ADMIN, { action = 'remove', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, true, 'not an error')
    h.eq(result.changed, false, 'nothing changed')
    h.contains(result.message, 'not registered', 'explains the no-op')
end)

h.test('remove passes the resolved target to the provider', function()
    registry.Reset()

    local seen = {}
    registry.Register(provider({ remove = function(target) seen.citizenid = target.citizenid return true, 'removed' end }))

    local result = service.Mutate(ADMIN, { action = 'remove', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, true, 'ok')
    h.eq(result.changed, true, 'changed')
    h.eq(seen.citizenid, 'CIT-2', 'resolved target')
    h.contains(result.message, 'no longer has', 'message')
end)

h.test('a failing provider is isolated and other providers keep working', function()
    registry.Reset()
    host.printed = {}

    registry.Register(provider({
        id = 'broken',
        label = 'Broken',
        give = function() error('provider exploded') end,
    }))
    registry.Register(provider({ id = 'healthy', label = 'Healthy' }))

    local failed = service.Mutate(ADMIN, { action = 'give', jobId = 'broken', target = TARGET })
    h.eq(failed.ok, false, 'failed')
    h.eq(failed.outcome, 'provider_error', 'outcome')
    h.eq(failed.message, 'The job provider failed to complete the request.', 'generic message')
    h.contains(host.printed[#host.printed - 1], 'provider error', 'the failure is logged')
    h.contains(host.printed[#host.printed - 1], 'provider exploded', 'with the provider error')

    local healthy = service.Mutate(ADMIN, { action = 'give', jobId = 'healthy', target = TARGET })
    h.eq(healthy.ok, true, 'the menu is still usable')
end)

h.test('a provider that returns nothing is treated as a failure', function()
    registry.Reset()
    registry.Register(provider({ give = function() end }))

    local result = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = TARGET })
    h.eq(result.ok, false, 'failed')
    h.eq(result.outcome, 'provider_error', 'outcome')
end)

h.test('an unknown job or an unsupported action is refused before any provider runs', function()
    registry.Reset()
    host.printed = {}

    local called = 0
    -- A provider only has to implement what it supports, so this one offers Give
    -- and nothing else (the registry requires at least one mutation handler).
    local giveOnly = provider({ id = 'giveonly', label = 'Give only', give = function() called = called + 1 return true, 'registered' end })
    giveOnly.remove = nil
    giveOnly.inspect = nil
    registry.Register(giveOnly)

    local missing = service.Mutate(ADMIN, { action = 'give', jobId = 'nope', target = TARGET })
    h.eq(missing.ok, false, 'unknown job')
    h.eq(missing.outcome, 'invalid_job', 'reason')
    h.contains(lastAudit(), 'invalid_job', 'audited')

    local unsupported = service.Mutate(ADMIN, { action = 'remove', jobId = 'giveonly', target = TARGET })
    h.eq(unsupported.ok, false, 'unsupported action')
    h.eq(unsupported.outcome, 'unsupported_action', 'reason')

    local badAction = service.Mutate(ADMIN, { action = 'promote', jobId = 'giveonly', target = TARGET })
    h.eq(badAction.ok, false, 'unknown verb')
    h.eq(badAction.outcome, 'invalid_action', 'reason')

    local badPayload = service.Mutate(ADMIN, 'give')
    h.eq(badPayload.ok, false, 'non-table payload')
    h.eq(badPayload.outcome, 'invalid_request', 'reason')

    h.eq(called, 0, 'no handler ever ran')
end)

-- Catalog (the menu is generated from the registry) ---------------------------

h.test('the catalog is generated from the registry, not from a hardcoded list', function()
    registry.Reset()

    registry.Register(provider({
        id = 'alpha_one',
        label = 'Alpha One',
        order = 1,
        grades = { { level = 0, label = 'Recruit', payment = 50 }, { level = 1, label = 'Officer', payment = 75 } },
    }))
    registry.Register(provider({
        id = 'bravo_two',
        label = 'Bravo Two',
        type = 'framework_job',
        order = 2,
        give = function() return true, 'assigned' end,
    }))

    local catalog = service.GetCatalog(ADMIN)

    h.eq(catalog.ok, true, 'ok')
    h.eq(catalog.total, 2, 'both providers appear with no service change')
    h.eq(catalog.providers[1].id, 'alpha_one', 'ordered by hint')
    h.eq(catalog.providers[1].label, 'Alpha One', 'label')
    h.eq(catalog.providers[1].type, 'profession', 'type')
    h.eq(#catalog.providers[1].grades, 2, 'grades resolved for the picker')
    h.eq(catalog.providers[2].id, 'bravo_two', 'second provider')
    h.eq(catalog.providers[2].grades, nil, 'no grades is a valid provider')
    h.eq(catalog.counts.profession, 1, 'counted by type')
    h.eq(catalog.counts.framework_job, 1, 'counted by type')
    h.eq(catalog.hasActions, false, 'nothing exposes provider actions')
    h.eq(catalog.categoryThreshold, 25, 'grouping threshold reachable by the client')
    h.eq(catalog.showCitizenId, false, 'identifiers are not exposed by default')
end)

h.test('a provider with broken grades still appears in the catalog', function()
    registry.Reset()

    registry.Register(provider({ id = 'broken', label = 'Broken', grades = function() error('boom') end }))
    registry.Register(provider({ id = 'healthy', label = 'Healthy' }))

    local catalog = service.GetCatalog(ADMIN)

    h.eq(catalog.total, 2, 'one bad provider does not empty the menu')
    h.eq(catalog.providers[1].grades, nil, 'its grades are simply absent')
    h.eq(catalog.providers[2].label, 'Healthy', 'the rest are intact')
end)

h.test('the catalog exposes provider actions without exposing their handlers', function()
    registry.Reset()

    registry.Register(provider({
        actions = {
            { id = 'setCeo', label = 'Set CEO', description = 'Assign the CEO rank', confirm = true,
              handler = function() return true, 'ceo_assigned' end },
        },
    }))

    local catalog = service.GetCatalog(ADMIN)

    h.eq(catalog.hasActions, true, 'the section offers Advanced provider actions')
    h.eq(#catalog.providers[1].actions, 1, 'one action')
    h.eq(catalog.providers[1].actions[1].id, 'setCeo', 'id')
    h.eq(catalog.providers[1].actions[1].confirm, true, 'confirmation flag')
    h.eq(catalog.providers[1].actions[1].handler, nil, 'the handler never reaches the client')
end)

h.test('a non-admin cannot read the catalog', function()
    registry.Reset()

    local denied = service.GetCatalog(9)
    h.eq(denied.ok, false, 'denied')
    h.eq(denied.outcome, 'no_perms', 'reason')
end)

-- View Player Jobs -------------------------------------------------------------

h.test('inspecting a player reports the primary job and every provider state', function()
    registry.Reset()
    addPlayer(TARGET, 'CIT-2', 'Bobby', { firstname = 'Bob', lastname = 'Builder' }, {
        name = 'police', label = 'LSPD', grade = { name = 'Officer', level = 1 }, onduty = false,
    }, { unemployed = 0, police = 1 })

    registry.Register(provider({
        inspect = function(target)
            return {
                registered = true, active = true, online = true, busy = false, rank = 'driver',
                details = { { label = 'Record', value = 'active' } },
            }
        end,
    }))

    local result = service.Inspect(ADMIN, TARGET)

    h.eq(result.ok, true, 'ok')
    h.eq(result.target.source, TARGET, 'target source')
    h.eq(result.target.name, 'Bob Builder', 'target name')
    h.eq(result.target.citizenid, nil, 'no identifier unless explicitly enabled')
    h.eq(result.primaryJob.name, 'police', 'primary job name')
    h.eq(result.primaryJob.label, 'LSPD', 'primary job label')
    h.eq(result.primaryJob.grade, 1, 'primary job grade')
    h.eq(result.primaryJob.gradeLabel, 'Officer', 'primary job grade label')
    h.eq(result.primaryJob.onDuty, false, 'primary job duty')
    h.eq(result.providers[1].state.rank, 'driver', 'provider state is passed through as-is')
    h.eq(result.providers[1].failed, false, 'provider answered')
end)

h.test('an inspect failure is isolated per provider and never breaks the view', function()
    registry.Reset()
    host.printed = {}

    registry.Register(provider({ id = 'broken', label = 'Broken', inspect = function() error('boom') end }))
    registry.Register(provider({ id = 'healthy', label = 'Healthy' }))

    local result = service.Inspect(ADMIN, TARGET)

    h.eq(result.ok, true, 'the view still renders')
    h.eq(result.providers[1].state, nil, 'the broken provider has no state')
    h.eq(result.providers[1].failed, true, 'and is flagged as failed')
    h.eq(result.providers[2].state.registered, true, 'the healthy provider is unaffected')
    h.contains(host.printed[#host.printed], 'inspect failed', 'the failure is logged')
end)

h.test('inspecting an unknown player is refused', function()
    registry.Reset()

    local result = service.Inspect(ADMIN, 999)
    h.eq(result.ok, false, 'refused')
    h.eq(result.outcome, 'invalid_target', 'reason')
end)

h.test('a non-admin cannot inspect a player', function()
    registry.Reset()

    local result = service.Inspect(9, TARGET)
    h.eq(result.ok, false, 'denied')
    h.eq(result.outcome, 'no_perms', 'reason')
end)

-- Advanced provider actions ----------------------------------------------------

h.test('a provider action runs through the same authorization, resolution and audit path', function()
    registry.Reset()
    host.printed = {}

    local seen = {}
    registry.Register(provider({
        actions = {
            {
                id = 'setCeo',
                label = 'Set CEO',
                handler = function(target, options, ctx)
                    seen.citizenid, seen.ctx = target.citizenid, ctx
                    return true, 'ceo_assigned', { message = 'Boss is now the CEO.' }
                end,
            },
        },
    }))

    local result = service.Mutate(ADMIN, { action = 'action', actionId = 'setCeo', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, true, 'ok')
    h.eq(result.changed, true, 'changed')
    h.eq(result.action, 'action', 'the verb is reported back')
    h.eq(result.outcome, 'ceo_assigned', 'outcome')
    h.eq(result.message, 'Boss is now the CEO.', 'the provider wording is used')
    h.eq(seen.citizenid, 'CIT-2', 'server-resolved target')
    h.eq(seen.ctx.actionId, 'setCeo', 'the action id reaches the handler')
    h.eq(seen.ctx.jobId, 'ojol', 'with the job id')
    h.contains(lastAudit(), 'action:setCeo', 'audited with the action id')
end)

h.test('an unknown or non-admin provider action is refused', function()
    registry.Reset()

    registry.Register(provider({
        actions = { { id = 'setCeo', label = 'Set CEO', handler = function() return true, 'ceo_assigned' end } },
    }))

    local unknown = service.Mutate(ADMIN, { action = 'action', actionId = 'nonsense', jobId = 'ojol', target = TARGET })
    h.eq(unknown.ok, false, 'unknown action')
    h.eq(unknown.outcome, 'invalid_action', 'reason')

    local denied = service.Mutate(9, { action = 'action', actionId = 'setCeo', jobId = 'ojol', target = TARGET })
    h.eq(denied.ok, false, 'non-admin')
    h.eq(denied.outcome, 'no_perms', 'reason')
end)