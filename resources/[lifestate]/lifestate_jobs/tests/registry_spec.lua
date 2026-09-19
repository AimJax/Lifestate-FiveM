-- Generic job registry (server/registry.lua).
--
-- The registry is the contract between the admin menu and every job, so these
-- specs pin down exactly what a provider may be: a malformed definition is
-- rejected with a reason, re-registration by the SAME owner is idempotent, and
-- ownership is an explicit argument - never a definition field, and never
-- something a second resource can take over.

local h = require 'tests.harness'

-- Ownership is passed in by the caller (server/providerapi.lua resolves it from
-- GetInvokingResource() at the export boundary), so the registry itself needs no
-- host function at all: registering without an owner is simply refused.
local OWNER = 'lifestate_ojol'

local registry = require 'server.registry'

---Build a provider definition. A `false` override CLEARS the key: `pairs()` never
---yields nil values, so `id = nil` would silently keep the default and the
---missing-field cases below would test nothing.
---A `resource` field is present and WRONG by default on purpose: the registry must
---ignore it.
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
        local ok, reason = registry.Register(cases[i].def, OWNER)
        h.eq(ok, false, ('case %d rejected'):format(i))
        h.eq(reason, cases[i].reason, ('case %d reason'):format(i))
    end

    h.eq(registry.Count(), 0, 'nothing registered')
end)

h.test('a registration without an owner is refused', function()
    registry.Reset()

    h.eq(select(2, registry.Register(provider(), nil)), 'owner_required', 'nil owner')
    h.eq(select(2, registry.Register(provider(), '')), 'owner_required', 'empty owner')
    h.eq(registry.Count(), 0, 'nothing registered')
end)

h.test('a valid provider registers once and re-registration is an idempotent update', function()
    registry.Reset()

    local ok, outcome = registry.Register(provider(), OWNER)
    h.eq(ok, true, 'registered')
    h.eq(outcome, 'registered', 'outcome')
    h.eq(registry.Count(), 1, 'count')

    local updated = select(2, registry.Register(provider({ label = 'Ojol Driver' }), OWNER))
    h.eq(updated, 'updated', 'second registration is an update')
    h.eq(registry.Count(), 1, 'still one provider')
    h.eq(registry.Get('ojol').label, 'Ojol Driver', 'definition replaced')
end)

h.test('ownership comes from the caller, never from the definition', function()
    registry.Reset()

    -- The definition lies; the owner argument wins.
    registry.Register(provider({ resource = 'some_other_resource' }), OWNER)
    h.eq(registry.Get('ojol').resource, OWNER, 'definition field ignored')

    -- ...and a definition that omits it is equally fine.
    registry.Register(provider({ id = 'second', resource = false }), 'future_job_resource')
    h.eq(registry.Get('second').resource, 'future_job_resource', 'owner recorded')
end)

h.test('a provider id cannot be taken over by another owner, with or without a lie', function()
    registry.Reset()
    registry.Register(provider(), OWNER)

    local ok, reason = registry.Register(provider(), 'some_other_resource')
    h.eq(ok, false, 'rejected')
    h.eq(reason, 'id_conflict', 'reason')
    h.eq(registry.Get('ojol').resource, OWNER, 'owner unchanged')

    -- Claiming the existing owner in the definition changes nothing.
    local lied, liedReason = registry.Register(provider({ resource = OWNER }), 'some_other_resource')
    h.eq(lied, false, 'still rejected')
    h.eq(liedReason, 'id_conflict', 'reason')
    h.eq(registry.Get('ojol').resource, OWNER, 'owner unchanged')

    -- There is no overwrite path: an options table is not consulted at all.
    local forged = select(2, registry.Register(provider(), 'some_other_resource', { overwrite = true }))
    h.eq(forged, 'id_conflict', 'no overwrite argument exists')
    h.eq(registry.Get('ojol').resource, OWNER, 'owner unchanged')
end)

h.test('the list is ordered by hint then label, and can be filtered by type', function()
    registry.Reset()

    registry.Register(provider({ id = 'zulu', label = 'Zulu', order = 10 }), OWNER)
    registry.Register(provider({ id = 'alpha', label = 'Alpha', order = 20 }), OWNER)
    registry.Register(provider({ id = 'bravo', label = 'Bravo', order = 20 }), OWNER)
    registry.Register(provider({ id = 'qbx:police', label = 'LSPD', type = 'framework_job', order = 200 }), 'qbx_core')

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
    }), OWNER)

    local grades = registry.ResolveGrades(registry.Get('static'))
    h.eq(#grades, 2, 'two grades')
    h.eq(grades[1].level, 0, 'sorted ascending')
    h.eq(grades[1].payment, 50, 'payment carried over')
    h.eq(grades[2].label, 'Chief', 'label carried over')

    registry.Register(provider({ id = 'lazy', grades = function() return { { level = 1, label = 'Officer' } } end }), OWNER)
    h.eq(#(registry.ResolveGrades(registry.Get('lazy'))), 1, 'lazy grades resolved')

    registry.Register(provider({ id = 'broken', grades = function() error('boom') end }), OWNER)
    local broken, reason = registry.ResolveGrades(registry.Get('broken'))
    h.eq(broken, nil, 'broken grades resolve to nil')
    h.eq(reason, 'grades_error', 'reason')

    registry.Register(provider({ id = 'empty', grades = {} }), OWNER)
    h.eq(registry.ResolveGrades(registry.Get('empty')), nil, 'empty grade table is not a grade list')

    registry.Register(provider({ id = 'none' }), OWNER)
    h.eq(registry.ResolveGrades(registry.Get('none')), nil, 'no grades at all')
end)

h.test('only the owner can unregister a provider', function()
    registry.Reset()
    registry.Register(provider(), OWNER)

    h.eq(select(2, registry.Unregister('nope', OWNER)), 'not_registered', 'unknown id')
    h.eq(select(2, registry.Unregister(nil, OWNER)), 'invalid_id', 'invalid id')
    h.eq(select(2, registry.Unregister('ojol', nil)), 'owner_required', 'no owner')
    h.eq(select(2, registry.Unregister('ojol', 'some_other_resource')), 'owner_mismatch', 'foreign owner')
    h.eq(registry.Count(), 1, 'still registered after the refused attempts')

    h.eq(registry.Unregister('ojol', OWNER), true, 'the owner can')
    h.eq(registry.Count(), 0, 'empty')
    h.eq(registry.Get('ojol'), nil, 'gone')

    registry.Register(provider(), OWNER)
    registry.Reset()
    h.eq(registry.Count(), 0, 'reset clears everything')
end)

h.test('UnregisterByResource removes exactly one owner\'s providers', function()
    registry.Reset()

    registry.Register(provider({ id = 'ojol' }), 'resource_a')
    registry.Register(provider({ id = 'taxi' }), 'resource_a')
    registry.Register(provider({ id = 'qbx:police', type = 'framework_job' }), 'qbx_core')

    h.eq(registry.UnregisterByResource('resource_b'), 0, 'nothing owned by the other resource')
    h.eq(registry.Count(), 3, 'untouched')

    h.eq(registry.UnregisterByResource('resource_a'), 2, 'both of resource_a\'s providers')
    h.eq(registry.Count(), 1, 'only the framework provider is left')
    h.eq(registry.Get('ojol'), nil, 'ojol gone')
    h.eq(registry.Get('taxi'), nil, 'taxi gone')
    h.ok(registry.Get('qbx:police'), 'qbx_core is untouched by another resource stopping')

    h.eq(registry.UnregisterByResource('resource_a'), 0, 'idempotent')
    h.eq(registry.UnregisterByResource(nil), 0, 'safe with no name')
    h.eq(registry.Count(), 1, 'still one provider')
end)

h.test('UnregisterByResource invalidates the ordered id cache', function()
    registry.Reset()

    registry.Register(provider({ id = 'zulu', order = 10 }), 'resource_a')
    registry.Register(provider({ id = 'alpha', order = 20 }), 'resource_b')

    -- Populate the cache, then remove a provider behind the cache's back.
    h.eq(#registry.List(), 2, 'cache warm')
    registry.UnregisterByResource('resource_a')

    local ids = {}
    for _, entry in ipairs(registry.List()) do ids[#ids + 1] = entry.id end

    h.eq(#ids, 1, 'a stale cache would hand the menu a removed id')
    h.eq(ids[1], 'alpha', 'and would hand it the wrong provider')

    -- A later registration must also be ordered correctly against the survivors.
    registry.Register(provider({ id = 'bravo', order = 15 }), 'resource_b')
    local ordered = registry.List()
    h.eq(ordered[1].id, 'bravo', 're-sorted after the invalidation')
    h.eq(ordered[2].id, 'alpha', 're-sorted after the invalidation')
end)
