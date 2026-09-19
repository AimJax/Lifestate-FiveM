-- Qbox primary-job adapter (server/frameworkjobs.lua).
--
-- The adapter is the only place that touches the framework, so these specs pin
-- down the two things the admin menu depends on:
--
--   * providers are DISCOVERED from qbx_core (a job added or removed at runtime
--     appears or disappears with no code change), and
--   * every mutation goes through the supported Qbox API (SetJob /
--     RemovePlayerFromJob) with the job and grade validated first.
--
-- qbx_core itself is stubbed, but only at its export surface: the shapes used are
-- the ones the installed qbx_core actually returns (shared/jobs.lua definitions
-- and the player.lua export signatures).

local h = require 'tests.harness'

local host = {
    jobs = {},
    qbxState = 'started',
    getJobsFails = false,
    setJobResult = { true },
    removeResult = { true },
    calls = {},
    threads = {},
    handlers = {},
    printed = {},
}

package.preload['config.server'] = function()
    return {
        perm = 'admin',
        requireOptin = true,
        defaultJob = 'unemployed',
        frameworkJobs = { enabled = true, blacklist = { ojol = true }, whitelist = nil },
        showCitizenId = false,
        listUnregisteredProfessions = true,
        categoryThreshold = 25,
        audit = { citizenId = true, resource = true },
    }
end

---A job definition in the shape qbx_core's shared/jobs.lua uses.
local function job(label, grades)
    local list = {}

    for level, name in pairs(grades or { [0] = 'Freelancer' }) do
        list[level] = { name = name, payment = 10 }
    end

    return { label = label, defaultDuty = true, offDutyPay = false, grades = list }
end

local qbx = {
    GetJobs = function()
        if host.getJobsFails then error('qbx_core exploded') end
        return host.jobs
    end,
    GetJob = function(name) return host.jobs[name] end,
    SetJob = function(source, name, grade)
        host.calls[#host.calls + 1] = { method = 'SetJob', source = source, name = name, grade = grade }
        return host.setJobResult[1], host.setJobResult[2]
    end,
    RemovePlayerFromJob = function(citizenid, name)
        host.calls[#host.calls + 1] = { method = 'RemovePlayerFromJob', citizenid = citizenid, name = name }
        return host.removeResult[1], host.removeResult[2]
    end,
}

exports = { qbx_core = h.exportsProxy(qbx) }

GetResourceState = function(name) return name == 'qbx_core' and host.qbxState or 'missing' end
AddEventHandler = function(name, fn) host.handlers[name] = fn end
CreateThread = function(fn) host.threads[#host.threads + 1] = fn end

local realPrint = print

-- Capture module logs by their leading prefix only, so a failing assertion that
-- quotes a log line is still printed by the harness instead of being swallowed.
local function isModuleLog(line)
    return line:sub(1, 16) == '[lifestate_jobs]'
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

package.loaded['server.registry'] = nil
package.loaded['server.frameworkjobs'] = nil
-- An earlier spec leaves its own config preloaded (framework adapter disabled), and
-- require() would hand frameworkjobs that instance instead of this spec's.
package.loaded['config.server'] = nil

local registry = require 'server.registry'
local frameworkJobs = require 'server.frameworkjobs'

-- Fixtures --------------------------------------------------------------------

local function reset()
    registry.Reset()

    local config = require 'config.server'
    config.frameworkJobs.blacklist = { ojol = true }
    config.frameworkJobs.whitelist = nil

    host.jobs = {
        unemployed = job('Civilian'),
        police = job('LSPD', { [0] = 'Recruit', [2] = 'Sergeant' }),
        mechanic = job('Mechanic'),
        ojol = job('Legacy Ojol'),
    }

    host.qbxState = 'started'
    host.getJobsFails = false
    host.setJobResult = { true }
    host.removeResult = { true }
    host.calls = {}
    host.threads = {}
    host.printed = {}
end

local function provider(name)
    return registry.Get('qbx:' .. name)
end

local function target(overrides)
    local resolved = {
        source = 3,
        citizenid = 'CIT-3',
        name = 'Bob Builder',
        serverName = 'Bobby',
        primaryJob = { name = 'unemployed', label = 'Civilian', grade = { name = 'Freelancer', level = 0 }, onduty = true },
        jobs = { unemployed = 0 },
    }

    for key, value in pairs(overrides or {}) do resolved[key] = value end
    return resolved
end

-- Discovery --------------------------------------------------------------------

h.test('every Qbox job becomes one provider, excluding the default job', function()
    reset()
    frameworkJobs.Sync()

    h.eq(registry.Count(), 2, 'police and mechanic, not unemployed')
    h.eq(provider('unemployed'), nil, 'the default job is never offered')
    h.eq(provider('ojol'), nil, 'legacy qbx:ojol is never offered')

    local police = provider('police')
    h.ok(police, 'police registered')
    h.eq(police.label, 'LSPD', 'label comes from the Qbox definition')
    h.eq(police.type, 'framework_job', 'type')
    h.eq(police.resource, 'qbx_core', 'owned by the framework')
    h.eq(police.order, 200, 'framework jobs sort after hand-registered professions')
end)

h.test('the adapter is data-driven: a runtime job appears, a removed one disappears', function()
    reset()
    frameworkJobs.Sync()
    h.eq(registry.Count(), 2, 'baseline')

    host.jobs.taxi = job('Downtown Cab')
    local added = frameworkJobs.Sync()

    h.eq(added, 1, 'one new provider')
    h.eq(registry.Count(), 3, 'taxi is offered')
    h.ok(provider('taxi'), 'taxi provider')
    h.eq(provider('taxi').label, 'Downtown Cab', 'label from the new definition')

    host.jobs.police = nil
    frameworkJobs.Sync()

    h.eq(registry.Count(), 2, 'police is gone')
    h.eq(provider('police'), nil, 'no stale provider')
end)

h.test('re-syncing is idempotent and never duplicates a provider', function()
    reset()
    frameworkJobs.Sync()
    local second = frameworkJobs.Sync()

    h.eq(second, 0, 'nothing new on the second pass')
    h.eq(registry.Count(), 2, 'still two')
end)

h.test('a config blacklist or whitelist excludes jobs without touching the code', function()
    reset()

    local config = require 'config.server'
    config.frameworkJobs.blacklist = { mechanic = true }
    frameworkJobs.Sync()

    h.eq(provider('mechanic'), nil, 'blacklisted job is not offered')
    h.ok(provider('police'), 'the rest still are')

    registry.Reset()
    config.frameworkJobs.blacklist = {}
    config.frameworkJobs.whitelist = { mechanic = true }
    frameworkJobs.Sync()

    h.ok(provider('mechanic'), 'whitelisted job is offered')
    h.eq(provider('police'), nil, 'everything else is not')

    config.frameworkJobs.whitelist = nil
end)

h.test('a stopped or broken qbx_core leaves the registry untouched', function()
    reset()
    frameworkJobs.Sync()
    h.eq(registry.Count(), 2, 'baseline')

    host.qbxState = 'stopping'
    h.eq(frameworkJobs.Sync(), 0, 'skipped')
    h.eq(registry.Count(), 2, 'unchanged')

    host.qbxState = 'started'
    host.getJobsFails = true
    h.eq(frameworkJobs.Sync(), 0, 'skipped')
    h.contains(host.printed[#host.printed], 'sync skipped', 'the failure is logged')
    h.eq(registry.Count(), 2, 'the existing providers survive a throwing framework')
end)

h.test('the adapter re-syncs when qbx_core restarts', function()
    reset()
    frameworkJobs.Start()

    h.ok(host.handlers.onServerResourceStart, 'restart handler wired')

    host.handlers.onServerResourceStart('some_other_resource')
    h.eq(#host.threads, 0, 'unrelated restarts are ignored')

    registry.Reset()
    host.handlers.onServerResourceStart('qbx_core')
    h.eq(#host.threads, 1, 'qbx_core restart is followed by a re-sync')

    host.threads[1]()
    h.eq(registry.Count(), 2, 'providers are back after qbx_core reinits its job table')
end)

-- Grades -----------------------------------------------------------------------

h.test('grades come from the live Qbox definition, and update with it', function()
    reset()
    frameworkJobs.Sync()

    local grades = registry.ResolveGrades(provider('police'))
    h.eq(#grades, 2, 'two grades')
    h.eq(grades[1].level, 0, 'sorted by level')
    h.eq(grades[1].label, 'Recruit', 'grade name')
    h.eq(grades[1].payment, 10, 'grade payment')

    host.jobs.police.grades[3] = { name = 'Chief', payment = 150 }
    h.eq(#registry.ResolveGrades(provider('police')), 3, 'a runtime grade change is picked up')
end)

-- Give / Remove ----------------------------------------------------------------

h.test('Give assigns the job through the supported Qbox API', function()
    reset()
    frameworkJobs.Sync()

    local ok, outcome, detail = provider('police').give(target(), { grade = 2 })

    h.eq(ok, true, 'ok')
    h.eq(outcome, 'assigned', 'outcome')
    h.eq(detail.gradeLabel, 'Sergeant', 'grade label reported back')
    h.eq(#host.calls, 1, 'one framework call')
    h.eq(host.calls[1].method, 'SetJob', 'through SetJob')
    h.eq(host.calls[1].source, 3, 'the resolved source')
    h.eq(host.calls[1].name, 'police', 'the job name')
    h.eq(host.calls[1].grade, 2, 'the grade')
end)

h.test('Give defaults to grade 0 and validates the grade first', function()
    reset()
    frameworkJobs.Sync()

    h.eq(select(2, provider('police').give(target())), 'assigned', 'grade defaults to 0')
    h.eq(host.calls[1].grade, 0, 'grade 0 passed through')

    host.calls = {}
    local ok, outcome = provider('police').give(target(), { grade = 9 })

    h.eq(ok, false, 'invalid grade refused')
    h.eq(outcome, 'invalid_grade', 'reason')
    h.eq(#host.calls, 0, 'the framework is never called with an invalid grade')
end)

h.test('Give is a no-op when the player already holds that job and grade', function()
    reset()
    frameworkJobs.Sync()

    local player = target({
        primaryJob = { name = 'police', label = 'LSPD', grade = { name = 'Sergeant', level = 2 }, onduty = true },
        jobs = { police = 2 },
    })

    local ok, outcome = provider('police').give(player, { grade = 2 })

    h.eq(ok, true, 'reported as success')
    h.eq(outcome, 'unchanged', 'nothing to do')
    h.eq(#host.calls, 0, 'no redundant framework call')
end)

h.test('a framework write failure is reported as a database error, never as success', function()
    reset()
    frameworkJobs.Sync()
    host.setJobResult = { false, { code = 'save_failed' } }

    local ok, outcome, detail = provider('police').give(target(), { grade = 2 })

    h.eq(ok, false, 'failed')
    h.eq(outcome, 'database_error', 'reason')
    h.contains(detail.message, 'save_failed', 'the framework error is surfaced')
end)

h.test('Remove replaces the primary job with the configured default job', function()
    reset()
    frameworkJobs.Sync()

    local player = target({
        primaryJob = { name = 'police', label = 'LSPD', grade = { name = 'Recruit', level = 0 }, onduty = true },
        jobs = { police = 0 },
    })

    local ok, outcome = provider('police').remove(player)

    h.eq(ok, true, 'ok')
    h.eq(outcome, 'removed', 'outcome')
    h.eq(#host.calls, 1, 'one call')
    h.eq(host.calls[1].method, 'SetJob', 'the primary job is replaced, not deleted')
    h.eq(host.calls[1].name, 'unemployed', 'default job')
    h.eq(host.calls[1].grade, 0, 'grade 0')
end)

h.test('Remove drops a non-primary membership through the framework API', function()
    reset()
    frameworkJobs.Sync()

    local player = target({
        primaryJob = { name = 'unemployed', label = 'Civilian', grade = { name = 'Freelancer', level = 0 }, onduty = true },
        jobs = { unemployed = 0, police = 1 },
    })

    local ok, outcome = provider('police').remove(player)

    h.eq(ok, true, 'ok')
    h.eq(outcome, 'removed', 'outcome')
    h.eq(host.calls[1].method, 'RemovePlayerFromJob', 'membership removal, not a job replacement')
    h.eq(host.calls[1].citizenid, 'CIT-3', 'the citizenid')
    h.eq(host.calls[1].name, 'police', 'the job name')
end)

h.test('Remove reports a missing job as a safe no-op and a write failure as an error', function()
    reset()
    frameworkJobs.Sync()

    -- The outcome (not the boolean) is what marks this as "already the desired
    -- state": the service treats `not_registered` as a successful no-op.
    local ok, outcome = provider('police').remove(target())
    h.eq(ok, true, 'no-op')
    h.eq(outcome, 'not_registered', 'reason the service reports as informational')
    h.eq(#host.calls, 0, 'nothing written')

    local player = target({
        primaryJob = { name = 'police', label = 'LSPD', grade = { name = 'Recruit', level = 0 }, onduty = true },
        jobs = { police = 0 },
    })
    host.setJobResult = { false }

    local failed, reason, detail = provider('police').remove(player)
    h.eq(failed, false, 'failed')
    h.eq(reason, 'database_error', 'reason')
    h.contains(detail.message, 'unemployed', 'names the default job it could not set')
end)

-- Inspect ----------------------------------------------------------------------

h.test('inspect reports the primary job versus a mere membership', function()
    reset()
    frameworkJobs.Sync()

    local primary = provider('police').inspect(target({
        primaryJob = { name = 'police', label = 'LSPD', grade = { name = 'Sergeant', level = 2 }, onduty = true },
        jobs = { police = 2 },
    }))

    h.eq(primary.registered, true, 'registered')
    h.eq(primary.active, true, 'is the primary job')
    h.eq(primary.rank, 'Sergeant', 'rank label')
    h.eq(primary.grade, 2, 'grade level')
    h.eq(primary.details[1].value, 'yes', 'reported as the primary job')

    local secondary = provider('police').inspect(target({ jobs = { unemployed = 0, police = 1 } }))
    h.eq(secondary.registered, true, 'a membership still counts as registered')
    h.eq(secondary.active, false, 'but not as the primary job')

    local none = provider('police').inspect(target())
    h.eq(none.registered, false, 'not registered')
    h.eq(none.rank, nil, 'no rank')
end)

h.test('framework providers are owned by qbx_core, so its stop cleans them up', function()
    reset()
    frameworkJobs.Sync()

    h.eq(provider('police').resource, frameworkJobs.OWNER, 'the adapter passes its owner explicitly')
    h.eq(frameworkJobs.OWNER, 'qbx_core', 'the framework owns its own providers')

    -- Same call the onServerResourceStop handler makes in providerapi.
    local removed = registry.UnregisterByResource('qbx_core')

    h.eq(removed, 2, 'both framework providers are dropped')
    h.eq(registry.Count(), 0, 'no stale provider is left behind')
end)

h.test('a qbx_core restart repopulates the framework providers without duplicates', function()
    reset()
    frameworkJobs.Start()
    h.eq(registry.Count(), 2, 'baseline')

    -- qbx_core stops: its providers go (the registry no longer holds references into
    -- a framework that is not running).
    registry.UnregisterByResource('qbx_core')
    h.eq(registry.Count(), 0, 'cleaned up')

    -- ...then it starts again, which the adapter hooks.
    host.handlers.onServerResourceStart('qbx_core')
    h.eq(#host.threads, 1, 're-sync scheduled')
    host.threads[1]()

    h.eq(registry.Count(), 2, 'providers are back')
    h.ok(provider('police'), 'police is offered again')

    local added = frameworkJobs.Sync()
    h.eq(added, 0, 'a further sync adds nothing')
    h.eq(registry.Count(), 2, 'and creates no duplicates')
end)

h.test('the provider id is the prefixed job name, so it cannot collide with a profession', function()
    reset()
    h.eq(frameworkJobs.ProviderId('police'), 'qbx:police', 'prefix')
    h.eq(frameworkJobs.PREFIX, 'qbx:', 'prefix constant')
    h.eq(frameworkJobs.TYPE, 'framework_job', 'type constant')
end)
