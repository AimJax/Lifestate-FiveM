-- Provider API boundary (the only way into the registry from outside).
--
-- Ownership is resolved HERE, from GetInvokingResource(), and nowhere else: the
-- native reports the resource that actually invoked the export, so a definition
-- cannot claim to be owned by somebody else. A caller-supplied `resource` field is
-- therefore ignored (overwritten with the real owner), which is what makes
-- impersonation by another server resource impossible:
--
--   exports.lifestate_jobs:RegisterProvider(definition)  -- owner = the caller
--   exports.lifestate_jobs:UnregisterProvider(id)        -- only the owner may
--
-- Providers do NOT need to declare `resource = GetCurrentResourceName()` anymore,
-- and they must NOT send Lua functions: an external definition carries export NAMES
-- (`operations.give = 'myExport'`), because a closure is encoded as a `funcref`
-- when it crosses the real resource boundary instead of arriving as a function.
-- See server/registry.lua for the external schema.
--
-- The same module wires lifecycle cleanup: when a resource stops, every provider
-- it owned is dropped from the registry immediately, so the menu can never hold a
-- stale reference into a resource that is gone. (lifestate_ojol stopping removes
-- its Ojol provider; qbx_core stopping removes the framework-job providers, which
-- frameworkjobs.Sync() repopulates when qbx_core starts again.)
--
-- The registry itself stays host-free: it takes the owner as an explicit argument.

local registry = require 'server.registry'

local M = {}

---Resource behind the current export call. Cannot be supplied by the caller.
---@return string? owner
local function invokingResource()
    local called, name = pcall(GetInvokingResource)
    if not called or type(name) ~= 'string' or name == '' then return nil end

    return name
end

---@param definition JobProviderDefinition
---@return boolean ok, string outcomeOrReason
function M.Register(definition)
    local owner = invokingResource()
    if not owner then
        print('[lifestate_jobs] provider rejected (unknown_owner: no invoking resource)')
        return false, 'unknown_owner'
    end

    -- Anything arriving through this export came from ANOTHER resource, so it is
    -- registered as an external provider and must carry serializable metadata only
    -- (export names, no closures). The mode is forced here, never taken from the
    -- definition: a caller cannot talk its way into the internal mode.
    local ok, outcome = registry.Register(definition, owner, registry.MODE_EXTERNAL)

    if ok then
        print(('[lifestate_jobs] provider %s %s (%s, owner %s)'):format(
            tostring(definition and definition.id), outcome,
            tostring(definition and definition.type), owner))
    end

    return ok, outcome
end

---@param id string
---@return boolean ok, string? reason
function M.Unregister(id)
    local owner = invokingResource()
    if not owner then return false, 'unknown_owner' end

    return registry.Unregister(id, owner)
end

---The stop handler's body (separated so it is directly testable and so the
---handler itself stays a one-liner).
---@param resourceName string
---@return number removed
function M.OnResourceStop(resourceName)
    if type(resourceName) ~= 'string' or resourceName == '' then return 0 end
    -- Our own stop tears the registry down with us: nothing to clean, and the
    -- start path would repopulate anyway.
    if resourceName == GetCurrentResourceName() then return 0 end

    local removed = registry.UnregisterByResource(resourceName)
    if removed > 0 then
        print(('[lifestate_jobs] removed %d provider(s) owned by stopped resource %s'):format(removed, resourceName))
    end

    return removed
end

---Wire the lifecycle handler.
function M.Start()
    AddEventHandler('onServerResourceStop', function(resourceName)
        return M.OnResourceStop(resourceName)
    end)
end

return M
