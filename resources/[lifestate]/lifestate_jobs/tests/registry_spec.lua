-- Generic job registry (server/registry.lua).
--
-- The registry is the contract between the admin menu and every job, so these
-- specs pin down exactly what a provider may be: a malformed definition is
-- rejected with a reason, re-registration is idempotent, and one resource can
-- never hijack another resource's provider id.

local h = require 'tests.harness'

local invokingResource = 'lifestate_ojol'

function GetInvokingResource() return invokingResource end

local registry = require 'server.registry'

---Build a provider definition. A `false` override CLEARS the key: `pairs()` never
---yields nil values, so `id = nil` would silently keep the default and the
---missing-field cases below would test nothing.
---@param overrides table?
local function provider(overrides)
    local def = {
        id = 'ojol',
        label = 'Ojol',
        type = 'profession',
        resource = 'lifestate_ojol',
        give = function() return true, 'registered' end,
        remove = function() return true, 'removed' end,
        inspect = function() return { registered = true } end,
    }

    for key, value in pairs(overrides or {}) do
        def[key] = value ~= false and value or nil
    end

    return def
end

h.test('a malformed provider is rejected with a reason and is not registered', function()
    registry.Reset()

    local cases = {
        { def = 'ojol', reason = 'definition_not_table' },
        { def = provider({ id = false }), reason = 'missing_id' },
        { def = provider({ id = '' }), reason = 'missing_id' },
        { def = provider({ label = false }), reason = 'missing_label' },
        { def = provider({ type = 12 }), reason = 'missing_type' },
        { def = provider({ give = 'nope' }), reason = 'give_not_function' },
        { def = provider({ remove = {} }), reason = 'remove_not_function' },
        { def = provider({ inspect = true }), reason = 'inspect_not_function' },
        { def = provider({ grades = 'driver' }), reason = 'grades_not_table_or_function' },
        { def = provider({ order = 'first' }), reason = 'order_not_number' },
        { def = provider({ actions = 'setCeo' }), reason = 'actions_not_table' },
        { def = provider({ give = false, remove = false }), reason = 'no_mutation_handler' },
        { def = provider({ actions = { { id = 'x' } } }), reason = 'invalid_action_1' },
        { def = provider({ actions = { { id = 'x', label = 'X', handler = 'no' } } }), reason = 'invalid_action_1' },
    }

    for i = 1, #cases do
        local ok, reason = registry.Register(cases[i].def)
        h.eq(ok, false, ('case %d rejected'):format(i))
        h.eq(reason, cases[i].reason, ('case %d reason'):format(i))
    end

    h.eq(registry.Count(), 0, 'nothing registered')
end)

h.test('a valid provider registers once and re-registration is an idempotent update', function()
    registry.Reset()

    local ok, outcome = registry.Register(provider())
    h.eq(ok, true, 'registered')
    h.eq(outcome, 'registered', 'outcome')
    h.eq(registry.Count(), 1, 'count')

    local updated = select(2, registry.Register(provider({ label = 'Ojol Driver' })))
    h.eq(updated, 'updated', 'second registration is an update')
    h.eq(registry.Count(), 1, 'still one provider')
    h.eq(registry.Get('ojol').label, 'Ojol Driver', 'definition replaced')
end)

h.test('a provider id can only be taken over by its owner', function()
    registry.Reset()
    registry.Register(provider())

    local ok, reason = registry.Register(provider({ resource = 'some_other_resource' }))
    h.eq(ok, false, 'rejected')
    h.eq(reason, 'id_conflict', 'reason')

    local forced = select(2, registry.Register(provider({ resource = 'some_other_resource' }), { overwrite = true }))
    h.eq(forced, 'updated', 'explicit overwrite is allowed')
    h.eq(registry.Get('ojol').resource, 'some_other_resource', 'owner changed')
end)

h.test('the owning resource defaults to the caller when none is given', function()
    registry.Reset()
    invokingResource = 'future_job_resource'

    registry.Register(provider({ resource = false }))

    h.eq(registry.Get('ojol').resource, 'future_job_resource', 'owner')
end)

h.test('the list is ordered by hint then label, and can be filtered by type', function()
    registry.Reset()

    registry.Register(provider({ id = 'zulu', label = 'Zulu', order = 10 }))
    registry.Register(provider({ id = 'alpha', label = 'Alpha', order = 20 }))
    registry.Register(provider({ id = 'bravo', label = 'Bravo', order = 20 }))
    registry.Register(provider({ id = 'qbx:police', label = 'LSPD', type = 'framework_job', order = 200 }))

    local list = registry.List()
    h.eq(#list, 4, 'four providers')
    h.eq(list[1].id, 'zulu', 'lowest order first')
    h.eq(list[2].id, 'alpha', 'same order sorted by label')
    h.eq(list[3].id, 'bravo', 'same order sorted by label')
    h.eq(list[4].id, 'qbx:police', 'higher order last')

    local frameworkJobs = registry.ByType('framework_job')
    h.eq(#frameworkJobs, 1, 'one framework job')
    h.eq(frameworkJobs[1].id, 'qbx:police', 'framework job id')
end)

h.test('grades can be static, lazy or broken, and are normalized and sorted', function()
    registry.Reset()

    registry.Register(provider({
        id = 'static',
        grades = { { level = 2, label = 'Chief' }, { level = 0, label = 'Recruit', payment = 50 } },
    }))

    local grades = registry.ResolveGrades(registry.Get('static'))
    h.eq(#grades, 2, 'two grades')
    h.eq(grades[1].level, 0, 'sorted ascending')
    h.eq(grades[1].payment, 50, 'payment carried over')
    h.eq(grades[2].label, 'Chief', 'label carried over')

    registry.Register(provider({ id = 'lazy', grades = function() return { { level = 1, label = 'Officer' } } end }))
    h.eq(#(registry.ResolveGrades(registry.Get('lazy'))), 1, 'lazy grades resolved')

    registry.Register(provider({ id = 'broken', grades = function() error('boom') end }))
    local broken, reason = registry.ResolveGrades(registry.Get('broken'))
    h.eq(broken, nil, 'broken grades resolve to nil')
    h.eq(reason, 'grades_error', 'reason')

    registry.Register(provider({ id = 'empty', grades = {} }))
    h.eq(registry.ResolveGrades(registry.Get('empty')), nil, 'empty grade table is not a grade list')

    registry.Register(provider({ id = 'none' }))
    h.eq(registry.ResolveGrades(registry.Get('none')), nil, 'no grades at all')
end)

h.test('providers can be unregistered and the registry reset', function()
    registry.Reset()
    registry.Register(provider())

    h.eq(registry.Unregister('nope'), false, 'unknown id')
    h.eq(registry.Unregister(nil), false, 'invalid id')
    h.eq(select(1, registry.Unregister('ojol')), true, 'unregister')

    h.eq(registry.Count(), 0, 'empty')
    h.eq(registry.Get('ojol'), nil, 'gone')

    registry.Register(provider())
    registry.Reset()
    h.eq(registry.Count(), 0, 'reset clears everything')
end)