-- Generic job registry (server/registry.lua).
--
-- The registry is the contract between the admin menu and every job, so these
-- specs pin down exactly what a provider may be: a malformed definition is
-- rejected with a reason, re-registration by the SAME owner is idempotent, and
-- ownership is an explicit argument - never a definition field, and never
-- something a second resource can take over.
--
-- Two explicit MODES are covered here:
--
--   * internal - local handlers (the Qbox adapter's shape),
--   * external - serializable export names (the Ojol shape), where a Lua closure
--     crossing the resource boundary must be rejected by name instead of failing
--     mysteriously at call time (that is exactly how a live server rejected Ojol
--     with `give_not_function`).

local h = require 'tests.harness'

-- Ownership is passed in by the caller (server/providerapi.lua resolves it from
-- GetInvokingResource() at the export boundary), so the registry itself needs no
-- host function at all: registering without an owner is simply refused.
local OWNER = 'lifestate_ojol'

local registry = require 'server.registry'

local INTERNAL = registry.MODE_INTERNAL
local EXTERNAL = registry.MODE_EXTERNAL

---Build an INTERNAL provider definition (local handlers). A `false` override
---CLEARS the key: `pairs()` never yields nil values, so `id = nil` would silently
---keep the default and the missing-field cases below would test nothing.
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

---Build an EXTERNAL provider definition: export names only, no closures.
---@param overrides table?
local function externalProvider(overrides)
    local def = {
        id = 'ojol',
        label = 'Ojol',
        type = 'profession',
        resource = 'lifestate_ojol',
        operations = {
            give = 'adminRegisterDriver',
            remove = 'adminRemoveDriver',
            inspect = 'getDriverAdminState',
        },
        actions = {
            { id = 'setCeo', label = 'Set Ojol CEO', export = 'assignCEO', confirm = true },
        },
    }

    for key, value in pairs(overrides or {}) do
        def[key] = value ~= false and value or nil
    end

    return def
end

h.test('an internal provider needs local handler functions', function()
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
        -- Internal providers are called directly, so export names make no sense here.
        { def = provider({ operations = { give = 'someExport' } }), reason = 'operations_not_supported_internal' },
    }

    for i = 1, #cases do
        local ok, reason = registry.Register(cases[i].def, OWNER, INTERNAL)
        h.eq(ok, false, ('case %d rejected'):format(i))
        h.eq(reason, cases[i].reason, ('case %d reason'):format(i))
    end

    h.eq(registry.Count(), 0, 'nothing registered')
end)

h.test('an external provider must carry export names, never closures', function()
    registry.Reset()

    -- The live failure this pass exists for: a closure cannot survive the resource
    -- boundary, so the definition is refused with a name instead of registering and
    -- then blowing up as `give_not_function` at call time.
    local cases = {
        { def = externalProvider({ give = function() end }), reason = 'external_handler_not_serializable' },
        { def = externalProvider({ remove = function() end }), reason = 'external_handler_not_serializable' },
        { def = externalProvider({ inspect = function() end }), reason = 'external_handler_not_serializable' },
        { def = externalProvider({ operations = 'adminRegisterDriver' }), reason = 'operations_not_table' },
        { def = externalProvider({ operations = { give = function() end, remove = 'x' } }),
            reason = 'operations_give_not_export_name' },
        { def = externalProvider({ operations = { give = '', remove = 'x' } }),
            reason = 'operations_give_not_export_name' },
        { def = externalProvider({ operations = { remove = 12 } }), reason = 'operations_remove_not_export_name' },
        { def = externalProvider({ operations = { inspect = {} } }), reason = 'operations_inspect_not_export_name' },
        { def = externalProvider({ operations = false }), reason = 'no_mutation_handler' },
        { def = externalProvider({ operations = { remove = 'adminRemoveDriver' } }), reason = 'registered' },
        { def = externalProvider({ actions = { { id = 'setCeo', label = 'Set Ojol CEO', handler = function() end } } }),
            reason = 'external_action_handler_not_serializable' },
        { def = externalProvider({ actions = { { id = 'setCeo', label = 'Set CEO' } } }), reason = 'invalid_action_1' },
        { def = externalProvider({ messages = { cannot_fire_ceo = function() end } }), reason = 'messages_not_serializable' },
        { def = externalProvider({ messages = 'nope' }), reason = 'messages_not_table' },
    }

    for i = 1, #cases do
        local ok, reason = registry.Register(cases[i].def, OWNER, EXTERNAL)

        if cases[i].reason == 'registered' then
            h.eq(ok, true, ('case %d accepted'):format(i))
        else
            h.eq(ok, false, ('case %d rejected'):format(i))
            h.eq(reason, cases[i].reason, ('case %d reason'):format(i))
        end
    end

    h.eq(registry.Count(), 1, 'only the inspect-only provider was accepted')
end)

h.test('the stored definition is unambiguous about its mode', function()
    registry.Reset()

    registry.Register(provider(), OWNER, INTERNAL)
    registry.Register(externalProvider({ id = 'external' }), OWNER, EXTERNAL)

    local internal = registry.Get('ojol')
    h.eq(internal.mode, INTERNAL, 'internal mode recorded')
    h.eq(type(internal.give), 'function', 'internal keeps its local handler')
    h.eq(internal.operations, nil, 'internal carries no export names')
    h.eq(internal.resource, OWNER, 'owner recorded even though the definition claimed one')

    local external = registry.Get('external')
    h.eq(external.mode, EXTERNAL, 'external mode recorded')
    h.eq(external.give, nil, 'external carries no handler')
    h.eq(external.operations.give, 'adminRegisterDriver', 'external keeps the export name')
    h.eq(registry.OperationExport(external, 'remove'), 'adminRemoveDriver', 'resolved per operation')
    h.eq(registry.OperationExport(external, 'give'), 'adminRegisterDriver', 'resolved per operation')
    h.eq(registry.OperationExport(external, 'inspect'), 'getDriverAdminState', 'resolved per operation')

    -- An internal provider's exports resolve to nothing, and vice versa.
    h.eq(registry.OperationExport(internal, 'give'), nil, 'internal has no export to dispatch to')
end)

h.test('a registration without an owner or with an unknown mode is refused', function()
    registry.Reset()

    h.eq(select(2, registry.Register(provider(), nil, INTERNAL)), 'owner_required', 'nil owner')
    h.eq(select(2, registry.Register(provider(), '', INTERNAL)), 'owner_required', 'empty owner')
    h.eq(select(2, registry.Register(provider(), OWNER, nil)), 'invalid_mode', 'no mode')
    h.eq(select(2, registry.Register(provider(), OWNER, 'guessed')), 'invalid_mode', 'unknown mode')
    h.eq(registry.Count(), 0, 'nothing registered')
end)

h.test('a valid provider registers once and re-registration is an idempotent update', function()
    registry.Reset()

    local ok, outcome = registry.Register(provider(), OWNER, INTERNAL)
    h.eq(ok, true, 'registered')
    h.eq(outcome, 'registered', 'outcome')
    h.eq(registry.Count(), 1, 'count')

    local updated = select(2, registry.Register(provider({ label = 'Ojol Driver' }), OWNER, INTERNAL))
    h.eq(updated, 'updated', 'second registration is an update')
    h.eq(registry.Count(), 1, 'still one provider')
    h.eq(registry.Get('ojol').label, 'Ojol Driver', 'definition replaced')
end)

h.test('ownership comes from the caller, never from the definition', function()
    registry.Reset()

    -- The definition lies; the owner argument wins.
    registry.Register(provider({ resource = 'some_other_resource' }), OWNER, INTERNAL)
    h.eq(registry.Get('ojol').resource, OWNER, 'definition field ignored')

    -- ...and a definition that omits it is equally fine.
    registry.Register(provider({ id = 'second', resource = false }), 'future_job_resource', INTERNAL)
    h.eq(registry.Get('second').resource, 'future_job_resource', 'owner recorded')
end)

h.test('a provider id cannot be taken over by another owner, with or without a lie', function()
    registry.Reset()
    registry.Register(provider(), OWNER, INTERNAL)

    local ok, reason = registry.Register(provider(), 'some_other_resource', INTERNAL)
    h.eq(ok, false, 'rejected')
    h.eq(reason, 'id_conflict', 'reason')
    h.eq(registry.Get('ojol').resource, OWNER, 'owner unchanged')

    -- Claiming the existing owner in the definition changes nothing.
    local lied, liedReason = registry.Register(provider({ resource = OWNER }), 'some_other_resource', INTERNAL)
    h.eq(lied, false, 'still rejected')
    h.eq(liedReason, 'id_conflict', 'reason')
    h.eq(registry.Get('ojol').resource, OWNER, 'owner unchanged')

    -- There is no overwrite path: an options table is not consulted at all.
    local forged = select(2, registry.Register(provider(), 'some_other_resource', INTERNAL, { overwrite = true }))
    h.eq(forged, 'id_conflict', 'no overwrite argument exists')
    h.eq(registry.Get('ojol').resource, OWNER, 'owner unchanged')

    -- Switching the MODE is not a way around ownership either.
    local crossed = select(2, registry.Register(externalProvider(), 'some_other_resource', EXTERNAL))
    h.eq(crossed, 'id_conflict', 'mode does not affect ownership')
    h.eq(registry.Get('ojol').mode, INTERNAL, 'the stored definition is untouched')
end)

h.test('the list is ordered by hint then label, and can be filtered by type', function()
    registry.Reset()

    registry.Register(provider({ id = 'zulu', label = 'Zulu', order = 10 }), OWNER, INTERNAL)
    registry.Register(provider({ id = 'alpha', label = 'Alpha', order = 20 }), OWNER, INTERNAL)
    registry.Register(provider({ id = 'bravo', label = 'Bravo', order = 20 }), OWNER, INTERNAL)
    registry.Register(provider({ id = 'qbx:police', label = 'LSPD', type = 'framework_job', order = 200 }),
        'qbx_core', INTERNAL)

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
    }), OWNER, INTERNAL)

    local grades = registry.ResolveGrades(registry.Get('static'))
    h.eq(#grades, 2, 'two grades')
    h.eq(grades[1].level, 0, 'sorted ascending')
    h.eq(grades[1].payment, 50, 'payment carried over')
    h.eq(grades[2].label, 'Chief', 'label carried over')

    registry.Register(provider({ id = 'lazy', grades = function() return { { level = 1, label = 'Officer' } } end }),
        OWNER, INTERNAL)
    h.eq(#(registry.ResolveGrades(registry.Get('lazy'))), 1, 'lazy grades resolved')

    registry.Register(provider({ id = 'broken', grades = function() error('boom') end }), OWNER, INTERNAL)
    local broken, reason = registry.ResolveGrades(registry.Get('broken'))
    h.eq(broken, nil, 'broken grades resolve to nil')
    h.eq(reason, 'grades_error', 'reason')

    registry.Register(provider({ id = 'empty', grades = {} }), OWNER, INTERNAL)
    h.eq(registry.ResolveGrades(registry.Get('empty')), nil, 'empty grade table is not a grade list')

    registry.Register(provider({ id = 'none' }), OWNER, INTERNAL)
    h.eq(registry.ResolveGrades(registry.Get('none')), nil, 'no grades at all')

    -- An external provider may only carry DATA as grades, never a lazy closure that
    -- would have to run on the other side of the boundary.
    registry.Register(externalProvider({ id = 'external', grades = { { level = 0, label = 'Rider' } } }),
        OWNER, EXTERNAL)
    h.eq(#(registry.ResolveGrades(registry.Get('external'))), 1, 'static external grades resolve')
end)

h.test('only the owner can unregister a provider', function()
    registry.Reset()
    registry.Register(provider(), OWNER, INTERNAL)

    h.eq(select(2, registry.Unregister('nope', OWNER)), 'not_registered', 'unknown id')
    h.eq(select(2, registry.Unregister(nil, OWNER)), 'invalid_id', 'invalid id')
    h.eq(select(2, registry.Unregister('ojol', nil)), 'owner_required', 'no owner')
    h.eq(select(2, registry.Unregister('ojol', 'some_other_resource')), 'owner_mismatch', 'foreign owner')
    h.eq(registry.Count(), 1, 'still registered after the refused attempts')

    h.eq(registry.Unregister('ojol', OWNER), true, 'the owner can')
    h.eq(registry.Count(), 0, 'empty')
    h.eq(registry.Get('ojol'), nil, 'gone')

    registry.Register(provider(), OWNER, INTERNAL)
    registry.Reset()
    h.eq(registry.Count(), 0, 'reset clears everything')
end)

h.test('UnregisterByResource removes exactly one owner\'s providers', function()
    registry.Reset()

    registry.Register(provider({ id = 'ojol' }), 'resource_a', INTERNAL)
    registry.Register(provider({ id = 'taxi' }), 'resource_a', INTERNAL)
    registry.Register(provider({ id = 'qbx:police', type = 'framework_job' }), 'qbx_core', INTERNAL)

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

    registry.Register(provider({ id = 'zulu', order = 10 }), 'resource_a', INTERNAL)
    registry.Register(provider({ id = 'alpha', order = 20 }), 'resource_b', INTERNAL)

    -- Populate the cache, then remove a provider behind the cache's back.
    h.eq(#registry.List(), 2, 'cache warm')
    registry.UnregisterByResource('resource_a')

    local ids = {}
    for _, entry in ipairs(registry.List()) do ids[#ids + 1] = entry.id end

    h.eq(#ids, 1, 'a stale cache would hand the menu a removed id')
    h.eq(ids[1], 'alpha', 'and would hand it the wrong provider')

    -- A later registration must also be ordered correctly against the survivors.
    registry.Register(provider({ id = 'bravo', order = 15 }), 'resource_b', INTERNAL)
    local ordered = registry.List()
    h.eq(ordered[1].id, 'bravo', 're-sorted after the invalidation')
    h.eq(ordered[2].id, 'alpha', 're-sorted after the invalidation')
end)
