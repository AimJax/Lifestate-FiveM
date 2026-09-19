-- Cross-resource dispatch of an EXTERNAL provider (server/dispatch.lua +
-- server/service.lua + server/providerapi.lua).
--
-- This is the contract that broke on a live server: an external provider sends
-- export NAMES, and the generic side has to reach them as
-- `exports[provider.resource][exportName]`. Here the owner resource is stubbed the
-- way CfxLua presents it (through the exports proxy), so the whole admin path -
-- authorize, resolve target, dispatch, message - runs against a provider that is
-- NOT in this resource.
--
-- What is pinned down:
--
--   * Give/Remove/Inspect/advanced action each go to the export the provider named,
--     with the resolved target, the options and the context;
--   * a resource that is not started is `provider_unavailable` and its exports are
--     never touched;
--   * a missing export, a throwing export and a non-boolean return all fail as
--     `provider_error` instead of taking the menu down;
--   * a provider that names no export for an operation is `unsupported_action`.

local h = require 'tests.harness'

local host = {
    invoking = 'lifestate_ojol',
    resources = {},
    ace = {},
    names = {},
    players = {},
    printed = {},
    calls = {},
}

-- Host stubs ------------------------------------------------------------------

function GetInvokingResource() return host.invoking end
function GetCurrentResourceName() return 'lifestate_jobs' end
function GetResourceState(name) return host.resources[name] or 'started' end
function IsPlayerAceAllowed(source, permission) return host.ace[source] ~= nil and host.ace[source][permission] == true end
function GetPlayerName(source) return host.names[source] end
function AddEventHandler() end

local qbx = {
    IsOptin = function() return true end,
    Notify = function() end,
    GetPlayer = function(source) return host.players[source] end,
}

---The owning resource's exports, exactly as a provider would expose them.
local providerExports = {}

exports = {
    qbx_core = h.exportsProxy(qbx),
    lifestate_ojol = h.exportsProxy(providerExports),
}

local realPrint = print

-- Module logs are captured for assertions, but only when the line STARTS with the
-- prefix. Filtering on "contains" would also swallow a failing assertion whose
-- message quotes the log, hiding the failure from the suite output entirely.
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

package.preload['config.server'] = function()
    return {
        perm = 'admin',
        requireOptin = false,
        defaultJob = 'unemployed',
        frameworkJobs = { enabled = false, blacklist = {}, whitelist = nil },
        showCitizenId = false,
        listUnregisteredProfessions = true,
        categoryThreshold = 25,
        audit = { citizenId = true, resource = true },
    }
end

for _, name in ipairs({
    'config.server', 'server.registry', 'server.dispatch', 'server.service', 'server.providerapi',
}) do
    package.loaded[name] = nil
end

local registry = require 'server.registry'
local service = require 'server.service'
local providerapi = require 'server.providerapi'

-- Fixtures --------------------------------------------------------------------

local ADMIN = 1
local TARGET = 2
local PROVIDER = 'lifestate_ojol'

local function addPlayer(source, citizenid, serverName, charName)
    host.names[source] = serverName
    host.players[source] = {
        PlayerData = {
            source = source,
            citizenid = citizenid,
            charinfo = charName or { firstname = 'Bob', lastname = 'Builder' },
            job = { name = 'unemployed', label = 'Civilian', grade = { name = 'Freelancer', level = 0 }, onduty = true },
            jobs = { unemployed = 0 },
        },
    }
end

---Metadata-only definition, as the Ojol provider registers it.
---@param overrides table?
local function definition(overrides)
    local def = {
        id = 'ojol',
        label = 'Ojol',
        type = 'profession',
        order = 10,
        operations = {
            give = 'adminRegisterDriver',
            remove = 'adminRemoveDriver',
            inspect = 'getDriverAdminState',
        },
        -- Job-specific wording travels as DATA: an external provider cannot return a
        -- closure for the menu to render.
        messages = {
            cannot_fire_ceo = 'This player is the active Ojol CEO. Reassign the CEO first, then remove.',
        },
        actions = {
            { id = 'setCeo', label = 'Set Ojol CEO', confirm = true, export = 'assignCEO' },
        },
    }

    -- A `false` override CLEARS the key, so a fixture can drop `actions`/`operations`
    -- (pairs() never yields nil, so `actions = nil` would silently keep the default).
    for key, value in pairs(overrides or {}) do def[key] = value ~= false and value or nil end
    return def
end

local function reset()
    registry.Reset()

    for key in pairs(providerExports) do providerExports[key] = nil end
    host.invoking = PROVIDER
    host.resources = {}
    host.calls = {}
    host.printed = {}
    host.ace = { [ADMIN] = { admin = true } }

    addPlayer(ADMIN, 'CIT-1', 'AdminMan', { firstname = 'Admin', lastname = 'Man' })
    addPlayer(TARGET, 'CIT-2', 'Bobby')
end

---Register the external provider through the real boundary.
local function registerProvider(overrides)
    return providerapi.Register(definition(overrides))
end

---All captured module logs as one searchable blob. A fixed index is not safe here:
---the audit line is always printed after the dispatch line.
---@return string
local function logs()
    return table.concat(host.printed, '\n')
end

---Record the arguments an export was called with.
---@param name string
---@param result table? values to return
local function exportResult(name, ...)
    local returned = { ... }
    providerExports[name] = function(target, options, ctx)
        host.calls[#host.calls + 1] = {
            name = name,
            target = target,
            options = options,
            ctx = ctx,
        }

        return table.unpack(returned)
    end
end

-- Give / Remove -----------------------------------------------------------------

h.test('Give dispatches the export the external provider named', function()
    reset()
    registerProvider()
    exportResult('adminRegisterDriver', true, 'registered', { gradeLabel = 'Rider' })

    local result = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = TARGET, grade = 3 })

    h.eq(result.ok, true, 'the admin request succeeded')
    h.eq(result.outcome, 'registered', 'the provider outcome is reported verbatim')
    h.eq(result.message, 'Bob Builder is now registered as Ojol.', 'generic success wording')

    h.eq(#host.calls, 1, 'exactly one export call')
    h.eq(host.calls[1].name, 'adminRegisterDriver', 'the named export')
    h.eq(host.calls[1].target.citizenid, 'CIT-2', 'the server-resolved target')
    h.eq(host.calls[1].target.name, 'Bob Builder', 'with the character name')
    h.eq(host.calls[1].options.grade, 3, 'the requested grade')
    h.eq(host.calls[1].options.source, ADMIN, 'and who asked (never a client-supplied id)')
    h.eq(host.calls[1].ctx.jobId, 'ojol', 'the context names the job')
end)

h.test('Remove dispatches its own export, and Give is never called twice', function()
    reset()
    registerProvider()
    exportResult('adminRemoveDriver', true, 'removed')
    exportResult('adminRegisterDriver', true, 'registered')

    local result = service.Mutate(ADMIN, { action = 'remove', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, true, 'removed')
    h.eq(result.message, 'Bob Builder no longer has Ojol.', 'generic removal wording')
    h.eq(#host.calls, 1, 'one call')
    h.eq(host.calls[1].name, 'adminRemoveDriver', 'the remove export')
end)

h.test('the provider refusal wording travels as data', function()
    reset()
    registerProvider()
    -- The CEO refusal is a `messages` entry on the definition, because an external
    -- provider cannot return a closure for the menu to render.
    exportResult('adminRemoveDriver', false, 'cannot_fire_ceo')

    local result = service.Mutate(ADMIN, { action = 'remove', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, false, 'refused')
    h.contains(result.message, 'Reassign the CEO first', 'the provider\'s own sentence is used')
    h.eq(result.outcome, 'cannot_fire_ceo', 'with the outcome name')
end)

h.test('an operation the provider does not offer is refused before dispatch', function()
    reset()
    -- Give only: this provider has no Remove export, and no Inspect export either.
    registerProvider({ operations = { give = 'adminRegisterDriver' }, actions = false })

    local result = service.Mutate(ADMIN, { action = 'remove', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, false, 'refused')
    h.eq(result.outcome, 'unsupported_action', 'reason')
    h.eq(#host.calls, 0, 'nothing was dispatched')

    local inspected = service.Inspect(ADMIN, TARGET)
    h.eq(inspected.providers[1].state, nil, 'a provider with no inspect export reports no state')
    h.eq(inspected.providers[1].failed, false, 'and is not treated as broken')
end)

-- Advanced actions ---------------------------------------------------------------

h.test('an advanced action dispatches the export it names', function()
    reset()
    registerProvider()
    exportResult('assignCEO', true, 'ceo_assigned')

    local result = service.Mutate(ADMIN, { action = 'action', actionId = 'setCeo', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, true, 'assigned')
    h.eq(result.message, 'Bob Builder is now the Ojol CEO.', 'the generic CEO wording is reused')
    h.eq(#host.calls, 1, 'one call')
    h.eq(host.calls[1].name, 'assignCEO', 'the action export')
    h.eq(host.calls[1].ctx.actionId, 'setCeo', 'the context names the action')
end)

h.test('the catalog offers the action without exposing any handler', function()
    reset()
    registerProvider()

    local catalog = service.GetCatalog(ADMIN)

    h.eq(catalog.total, 1, 'one provider')
    h.eq(catalog.providers[1].id, 'ojol', 'the external provider is offered')
    h.eq(catalog.providers[1].actions[1].id, 'setCeo', 'with its action')
    h.eq(catalog.providers[1].actions[1].confirm, true, 'and its confirm flag')
    h.eq(catalog.providers[1].actions[1].export, nil, 'the export name stays server-side')
    h.eq(catalog.providers[1].actions[1].handler, nil, 'no handler crosses to the client')
end)

-- Inspect -----------------------------------------------------------------------

h.test('View Player Jobs inspects the provider through its export', function()
    reset()
    registerProvider()
    exportResult('getDriverAdminState', {
        registered = true,
        active = true,
        rank = 'driver',
        details = { { label = 'Record', value = 'active' } },
    })

    local result = service.Inspect(ADMIN, TARGET)

    h.eq(result.ok, true, 'the view renders')
    h.eq(result.providers[1].state.rank, 'driver', 'the provider state is passed through as-is')
    h.eq(result.providers[1].failed, false, 'and is not flagged as failed')
    h.eq(#host.calls, 1, 'one export call')
    h.eq(host.calls[1].name, 'getDriverAdminState', 'the inspect export')
    h.eq(host.calls[1].target.citizenid, 'CIT-2', 'called with the resolved target')
end)

h.test('a broken inspect export is isolated to that provider', function()
    reset()
    registerProvider()
    providerExports.getDriverAdminState = function() error('driver table exploded') end

    local result = service.Inspect(ADMIN, TARGET)

    h.eq(result.ok, true, 'the view still renders')
    h.eq(result.providers[1].state, nil, 'no state')
    h.eq(result.providers[1].failed, true, 'flagged as failed')
    h.eq(result.providers[1].label, 'Ojol', 'but the provider is still listed by name')
end)

-- Failure modes -------------------------------------------------------------------

h.test('a stopped provider resource is unavailable and its exports are never called', function()
    reset()
    registerProvider()
    exportResult('adminRegisterDriver', true, 'registered')

    host.resources[PROVIDER] = 'stopped'

    local result = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, false, 'refused')
    h.eq(result.outcome, 'provider_unavailable', 'reason')
    h.contains(result.message, 'not running', 'explains why')
    h.eq(#host.calls, 0, 'nothing was dispatched into a dead resource')
end)

h.test('a missing export fails as provider_error and is logged', function()
    reset()
    registerProvider()
    host.printed = {}

    local result = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, false, 'refused')
    h.eq(result.outcome, 'provider_error', 'reason')
    h.eq(#host.calls, 0, 'no export existed to call')
    h.contains(logs(), 'exposes no export adminRegisterDriver', 'the missing export is named in the log')
end)

h.test('a throwing export fails as provider_error, with the reason logged', function()
    reset()
    registerProvider()
    providerExports.adminRegisterDriver = function() error('driver table exploded') end
    host.printed = {}

    local result = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, false, 'refused')
    h.eq(result.outcome, 'provider_error', 'reason')
    h.contains(logs(), 'driver table exploded', 'the provider error is logged, not swallowed')
end)

h.test('an export that does not return a boolean fails as provider_error', function()
    reset()
    registerProvider()
    exportResult('adminRegisterDriver', 'yes')
    host.printed = {}

    local result = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, false, 'refused')
    h.eq(result.outcome, 'provider_error', 'reason')
    h.contains(logs(), 'instead of a boolean', 'the malformed result is logged')

    -- ...and a boolean-less nil return is equally refused, without being mistaken
    -- for a safe no-op.
    reset()
    registerProvider()
    exportResult('adminRegisterDriver')
    local empty = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = TARGET })
    h.eq(empty.outcome, 'provider_error', 'nil is not an outcome')

    -- An inspect export that returns a non-table is refused too.
    reset()
    registerProvider()
    exportResult('getDriverAdminState', 'not a table')
    local inspected = service.Inspect(ADMIN, TARGET)
    h.eq(inspected.providers[1].failed, true, 'inspect result must be a state table')
end)

h.test('a provider that stops answering does not break other providers', function()
    reset()
    registerProvider()
    registerProvider({ id = 'taxi', label = 'Taxi', operations = { give = 'hireTaxi' } })

    providerExports.adminRegisterDriver = function() error('ojol is down') end
    exportResult('hireTaxi', true, 'assigned')

    local broken = service.Mutate(ADMIN, { action = 'give', jobId = 'ojol', target = TARGET })
    h.eq(broken.ok, false, 'the Ojol request failed')

    local healthy = service.Mutate(ADMIN, { action = 'give', jobId = 'taxi', target = TARGET })
    h.eq(healthy.ok, true, 'Taxi still works')
    h.eq(host.calls[#host.calls].name, 'hireTaxi', 'Taxi got its own export')
end)

-- Security ------------------------------------------------------------------------

h.test('the client cannot influence the target citizenid or the caller identity', function()
    reset()
    registerProvider()
    exportResult('adminRegisterDriver', true, 'registered')

    -- The payload only carries a server id; anything else a client might smuggle in
    -- is ignored because the target is resolved server-side.
    local result = service.Mutate(ADMIN, {
        action = 'give',
        jobId = 'ojol',
        target = TARGET,
        citizenid = 'CIT-HACKER',
        source = 99,
        outcome = 'registered',
    })

    h.eq(result.ok, true, 'the request itself is legitimate')
    h.eq(host.calls[1].target.citizenid, 'CIT-2', 'the resolved character, not the supplied one')
    h.eq(host.calls[1].options.source, ADMIN, 'the real admin source')
end)

h.test('a non-admin cannot dispatch anything', function()
    reset()
    registerProvider()
    exportResult('adminRegisterDriver', true, 'registered')

    local result = service.Mutate(99, { action = 'give', jobId = 'ojol', target = TARGET })

    h.eq(result.ok, false, 'denied')
    h.eq(result.outcome, 'no_perms', 'reason')
    h.eq(#host.calls, 0, 'the provider was never reached')

    -- A forged client payload cannot reach the provider either: the event handler
    -- authorizes the SOURCE, not anything the caller sent.
    h.eq(service.Mutate(0, { action = 'give', jobId = 'ojol', target = TARGET }).outcome, 'invalid_source',
        'a bogus source is rejected outright')
    h.eq(#host.calls, 0, 'still nothing dispatched')
end)
