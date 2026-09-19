-- Provider API boundary (server/providerapi.lua) + registry cleanup.
--
-- This is the security boundary of the whole Job Management system: it decides who
-- OWNS a provider id. The specs below drive the real boundary module with a
-- controllable GetInvokingResource(), which is exactly the value the caller cannot
-- influence, and then check the real registry it writes into.
--
-- The properties pinned down here:
--
--   * ownership is the invoking resource, never the definition's `resource` field,
--   * another resource can neither take over nor lie its way into an id,
--   * only the owner may unregister, and there is no overwrite path at all,
--   * a stopped resource's providers disappear immediately (and nobody else's do),
--   * the ordered id cache goes with them, so the menu never sees a dead id,
--   * the catalog the admin menu renders reflects all of that.

local h = require 'tests.harness'

local host = {
    invoking = nil,      -- what GetInvokingResource() reports
    handlers = {},
    printed = {},
    ace = {},
    optin = {},
    names = {},
    players = {},
}

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

-- Host primitives -----------------------------------------------------------------

function GetInvokingResource() return host.invoking end
function GetCurrentResourceName() return 'lifestate_jobs' end
function IsPlayerAceAllowed(source, permission) return host.ace[source] and host.ace[source][permission] == true end
function GetPlayerName(source) return host.names[source] end
function AddEventHandler(eventName, fn) host.handlers[eventName] = fn end

local qbx = {
    IsOptin = function(source) return host.optin[source] == true end,
    GetPlayer = function(source) return host.players[source] end,
    Notify = function() end,
}

exports = { qbx_core = h.exportsProxy(qbx) }

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

for _, name in ipairs({ 'server.registry', 'server.service', 'server.providerapi' }) do
    package.loaded[name] = nil
end

-- An earlier spec leaves its config preloaded; without this the require below would
-- hand the service that instance instead of this spec's.
package.loaded['config.server'] = nil

local registry = require 'server.registry'
local service = require 'server.service'
local providerapi = require 'server.providerapi'

-- Fixtures -----------------------------------------------------------------------

local ADMIN = 1
local RESOURCE_A = 'resource_a'
local RESOURCE_B = 'resource_b'

local function asResource(name)
    host.invoking = name
end

---@param overrides table?
local function definition(overrides)
    local def = {
        id = 'ojol',
        label = 'Ojol',
        type = 'profession',
        give = function() return true, 'registered' end,
        remove = function() return true, 'removed' end,
        inspect = function() return { registered = true } end,
    }

    for key, value in pairs(overrides or {}) do def[key] = value end
    return def
end

local function reset()
    registry.Reset()

    host.invoking = RESOURCE_A
    host.handlers = {}
    host.printed = {}
    host.ace = { [ADMIN] = { admin = true } }
    host.optin[ADMIN] = true
    host.names[ADMIN] = 'AdminOne'
end

-- Ownership ----------------------------------------------------------------------

h.test('the invoking resource owns the provider it registers', function()
    reset()
    asResource(RESOURCE_A)

    local ok, outcome = providerapi.Register(definition())

    h.eq(ok, true, 'registered')
    h.eq(outcome, 'registered', 'outcome')
    h.eq(registry.Get('ojol').resource, RESOURCE_A, 'owner is the caller')
    h.contains(host.printed[#host.printed], RESOURCE_A, 'and is logged')
end)

h.test('a definition cannot claim an owner: the caller wins', function()
    reset()
    asResource(RESOURCE_B)

    providerapi.Register(definition({ resource = RESOURCE_A }))

    h.eq(registry.Get('ojol').resource, RESOURCE_B, 'the claimed owner is ignored')
end)

h.test('the same resource may re-register its own provider idempotently', function()
    reset()
    asResource(RESOURCE_A)

    providerapi.Register(definition())
    local ok, outcome = providerapi.Register(definition({ label = 'Ojol Driver' }))

    h.eq(ok, true, 'allowed')
    h.eq(outcome, 'updated', 'an update, not a second provider')
    h.eq(registry.Count(), 1, 'no duplicate')
    h.eq(registry.Get('ojol').resource, RESOURCE_A, 'owner unchanged')
end)

h.test('another resource cannot take over an existing provider id', function()
    reset()
    asResource(RESOURCE_A)
    providerapi.Register(definition())

    asResource(RESOURCE_B)
    local ok, reason = providerapi.Register(definition())

    h.eq(ok, false, 'denied')
    h.eq(reason, 'id_conflict', 'reason')
    h.eq(registry.Get('ojol').resource, RESOURCE_A, 'owner unchanged')
    h.eq(registry.Get('ojol').label, 'Ojol', 'definition unchanged')
end)

h.test('another resource cannot lie its way into an existing provider id', function()
    reset()
    asResource(RESOURCE_A)
    providerapi.Register(definition())

    -- The classic spoof: claim the real owner in the definition.
    asResource(RESOURCE_B)
    local ok, reason = providerapi.Register(definition({ resource = RESOURCE_A }))

    h.eq(ok, false, 'still denied')
    h.eq(reason, 'id_conflict', 'reason')
    h.eq(registry.Get('ojol').resource, RESOURCE_A, 'owner unchanged')
end)

h.test('a forged overwrite argument does not exist', function()
    reset()
    asResource(RESOURCE_A)
    providerapi.Register(definition())

    asResource(RESOURCE_B)
    local ok, reason = providerapi.Register(definition(), { overwrite = true })

    h.eq(ok, false, 'an extra argument changes nothing')
    h.eq(reason, 'id_conflict', 'the boundary passes only (definition, owner)')
    h.eq(registry.Get('ojol').resource, RESOURCE_A, 'owner unchanged')
end)

h.test('a registration with no invoking resource is refused', function()
    reset()

    -- 'missing' stands in for a nil return: ipairs() cannot carry a nil entry.
    for _, value in ipairs({ 'missing', '' }) do
        if value == 'missing' then
            host.invoking = nil
        else
            host.invoking = value
        end

        local ok, reason = providerapi.Register(definition())
        h.eq(ok, false, 'refused')
        h.eq(reason, 'unknown_owner', 'reason')
    end

    h.eq(registry.Count(), 0, 'nothing registered')
    h.contains(host.printed[#host.printed], 'unknown_owner', 'logged')
end)

-- Unregister authorization --------------------------------------------------------

h.test('only the owning resource can unregister its provider', function()
    reset()
    asResource(RESOURCE_A)
    providerapi.Register(definition())

    asResource(RESOURCE_B)
    local denied, reason = providerapi.Unregister('ojol')
    h.eq(denied, false, 'a foreign resource cannot remove it')
    h.eq(reason, 'owner_mismatch', 'reason')
    h.ok(registry.Get('ojol'), 'the provider is still there')

    asResource(RESOURCE_A)
    h.eq(providerapi.Unregister('ojol'), true, 'the owner can')
    h.eq(registry.Get('ojol'), nil, 'gone')

    h.eq(select(2, providerapi.Unregister('ojol')), 'not_registered', 'second attempt is a no-op')
end)

h.test('unregistering with no invoking resource is refused', function()
    reset()
    asResource(RESOURCE_A)
    providerapi.Register(definition())

    host.invoking = nil
    local ok, reason = providerapi.Unregister('ojol')

    h.eq(ok, false, 'refused')
    h.eq(reason, 'unknown_owner', 'reason')
    h.ok(registry.Get('ojol'), 'nothing was removed')
end)

-- Resource stop cleanup -----------------------------------------------------------

h.test('a stopped resource loses exactly its own providers', function()
    reset()
    host.printed = {}

    asResource(RESOURCE_A)
    providerapi.Register(definition({ id = 'ojol' }))
    providerapi.Register(definition({ id = 'taxi' }))

    asResource(RESOURCE_B)
    providerapi.Register(definition({ id = 'mechanic' }))

    h.eq(registry.Count(), 3, 'three providers registered')

    local removed = providerapi.OnResourceStop(RESOURCE_A)

    h.eq(removed, 2, 'resource A owned two')
    h.eq(registry.Count(), 1, 'only B remains')
    h.eq(registry.Get('ojol'), nil, 'ojol gone')
    h.eq(registry.Get('taxi'), nil, 'taxi gone')
    h.ok(registry.Get('mechanic'), 'resource B is untouched')
    h.contains(host.printed[#host.printed], 'removed 2 provider(s) owned by stopped resource ' .. RESOURCE_A,
        'cleanup is logged clearly')
end)

h.test('the stop handler is wired to the real event and does the cleanup', function()
    reset()

    providerapi.Start()
    local handler = host.handlers.onServerResourceStop

    h.ok(handler, 'onServerResourceStop registered')
    h.eq(handler('an_unrelated_resource'), 0, 'an unrelated stop removes nothing')

    asResource(RESOURCE_A)
    providerapi.Register(definition())

    h.eq(handler(RESOURCE_A), 1, 'the handler removes the stopped resource\'s providers')
    h.eq(registry.Count(), 0, 'registry is clean')
end)

h.test('the stop handler ignores malformed names and our own stop', function()
    reset()
    asResource(RESOURCE_A)
    providerapi.Register(definition())

    h.eq(providerapi.OnResourceStop(nil), 0, 'nil name')
    h.eq(providerapi.OnResourceStop(''), 0, 'empty name')
    h.eq(providerapi.OnResourceStop('lifestate_jobs'), 0, 'our own stop tears down with us')
    h.eq(registry.Count(), 1, 'nothing removed by the refusals')

    h.eq(providerapi.OnResourceStop(RESOURCE_B), 0, 'a resource that owns nothing')
    h.eq(registry.Count(), 1, 'still registered')
end)

h.test('cleanup invalidates the ordered id cache', function()
    reset()

    asResource(RESOURCE_A)
    providerapi.Register(definition({ id = 'zulu', order = 10 }))

    asResource(RESOURCE_B)
    providerapi.Register(definition({ id = 'alpha', order = 20 }))

    h.eq(#registry.List(), 2, 'cache warm')

    providerapi.OnResourceStop(RESOURCE_A)

    local ids = {}
    for _, entry in ipairs(registry.List()) do ids[#ids + 1] = entry.id end

    h.eq(#ids, 1, 'a stale cache would keep offering the removed provider')
    h.eq(ids[1], 'alpha', 'the survivor is the only one left')
end)

-- What the admin menu sees ---------------------------------------------------------

h.test('a stopped resource disappears from the catalog, others stay', function()
    reset()

    host.players[ADMIN] = {
        PlayerData = {
            source = ADMIN,
            citizenid = 'CIT-1',
            charinfo = { firstname = 'Admin', lastname = 'One' },
            job = { name = 'unemployed', label = 'Civilian', grade = { name = 'Freelancer', level = 0 }, onduty = true },
            jobs = { unemployed = 0 },
        },
    }

    asResource('lifestate_ojol')
    providerapi.Register(definition())

    asResource(RESOURCE_B)
    providerapi.Register(definition({ id = 'taxi', label = 'Taxi', type = 'profession' }))

    local before = service.GetCatalog(ADMIN)
    h.eq(before.total, 2, 'both providers are offered')

    providerapi.OnResourceStop('lifestate_ojol')

    local after = service.GetCatalog(ADMIN)
    h.eq(after.total, 1, 'the stopped resource\'s provider is gone from the menu')
    h.eq(after.providers[1].id, 'taxi', 'and the healthy one is still offered')
end)
