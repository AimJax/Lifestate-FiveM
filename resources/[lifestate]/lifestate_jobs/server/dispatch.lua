-- Provider invocation, for both provider modes.
--
-- Internal providers (the Qbox adapter) are local Lua functions and are simply
-- called. External providers live in ANOTHER resource, so they are reached through
-- their resource's server exports - never through functions handed across the
-- boundary, which is what a real server rejected with `give_not_function`.
--
-- The external contract, verified against the installed runtime:
--
--   give / remove / action:  exports[resource]:<exportName>(target, options, ctx)
--   inspect:                 exports[resource]:<exportName>(target)
--
-- `exports[resource][exportName]` raises when the export does not exist, so the
-- lookup happens inside the same pcall as the call. Everything is guarded:
--
--   resource not started   -> provider_unavailable (and the registry removes it on
--                             the resource's stop event anyway)
--   export missing         -> provider_error
--   export throws          -> provider_error
--   non-boolean result     -> provider_error
--
-- A broken provider therefore fails the request it was asked for, and nothing else:
-- the menu keeps working and other providers keep answering.

local registry = require 'server.registry'

local M = {}

local OPERATIONS = { 'give', 'remove', 'inspect' }

---@param value any
---@return string
local function describe(value)
    local valueType = type(value)
    if valueType == 'table' then return 'a table' end
    return ('%s (%s)'):format(tostring(value), valueType)
end

---Turn a provider reply into the service's result shape, rejecting malformed ones.
---@param provider JobProviderDefinition
---@param label string what was called, for the log line
---@param called boolean
---@param succeeded any
---@param outcome any
---@param detail any
---@return table result { ok, outcome, detail }
local function interpret(provider, label, called, succeeded, outcome, detail)
    if not called then
        print(('[lifestate_jobs] provider %s (%s) %s failed: %s'):format(
            provider.id, provider.resource, label, tostring(succeeded)))
        return { ok = false, outcome = 'provider_error' }
    end

    if type(succeeded) ~= 'boolean' then
        print(('[lifestate_jobs] provider %s (%s) %s returned %s instead of a boolean result'):format(
            provider.id, provider.resource, label, describe(succeeded)))
        return { ok = false, outcome = 'provider_error' }
    end

    return {
        ok = succeeded,
        outcome = type(outcome) == 'string' and outcome or (succeeded and 'done' or 'failed'),
        detail = type(detail) == 'table' and detail or nil,
    }
end

---Resolve an external provider's export. Returns nil + reason when it is not
---reachable, so every caller has exactly one failure path.
---@param provider JobProviderDefinition
---@param exportName string
---@return table? proxy, function? export, string? reason
local function resolveExport(provider, exportName)
    local state = GetResourceState(provider.resource)
    if state ~= 'started' then
        return nil, nil, 'provider_unavailable'
    end

    local proxy = exports[provider.resource]

    -- The exports metatable raises for an unknown name, so the lookup is guarded
    -- exactly like the call itself.
    local looked, export = pcall(function() return proxy[exportName] end)
    if not looked or type(export) ~= 'function' then
        print(('[lifestate_jobs] provider %s (%s) exposes no export %s'):format(
            provider.id, provider.resource, tostring(exportName)))
        return nil, nil, 'provider_error'
    end

    return proxy, export, nil
end

---The export an operation or action goes to, or nil when the provider does not
---support it.
---@param provider JobProviderDefinition
---@param operation string
---@param actionId string?
---@return string? exportName
local function exportNameFor(provider, operation, actionId)
    if operation == 'action' then
        local action = registry.FindAction(provider, actionId)
        return action and action.export or nil
    end

    return registry.OperationExport(provider, operation)
end

---Give / Remove / provider action, on either provider mode.
---@param provider JobProviderDefinition
---@param operation string 'give' | 'remove' | 'action'
---@param actionId string? required for 'action'
---@param target JobProviderTarget
---@param options table
---@param ctx table
---@return table result { ok, outcome, detail }
function M.Mutate(provider, operation, actionId, target, options, ctx)
    if provider.mode == registry.MODE_INTERNAL then
        local fn = operation == 'action'
            and (registry.FindAction(provider, actionId) or {}).handler
            or provider[operation]

        if type(fn) ~= 'function' then return { ok = false, outcome = 'unsupported_action' } end

        return interpret(provider, operation, pcall(fn, target, options, ctx))
    end

    local exportName = exportNameFor(provider, operation, actionId)
    if not exportName then return { ok = false, outcome = 'unsupported_action' } end

    local proxy, export, reason = resolveExport(provider, exportName)
    if not export then return { ok = false, outcome = reason } end

    -- Colon equivalent: the resolved export is the wrapper CfxLua returns, which
    -- forwards its first argument as `self`.
    local called, succeeded, outcome, detail = pcall(export, proxy, target, options, ctx)
    return interpret(provider, exportName, called, succeeded, outcome, detail)
end

---Read-only state (View Player Jobs), on either provider mode.
---@param provider JobProviderDefinition
---@param target JobProviderTarget
---@return table? state, boolean failed
function M.Inspect(provider, target)
    if provider.mode == registry.MODE_INTERNAL then
        if type(provider.inspect) ~= 'function' then return nil, false end

        local ok, result = pcall(provider.inspect, target)
        if not ok then
            print(('[lifestate_jobs] provider %s inspect failed: %s'):format(provider.id, tostring(result)))
            return nil, true
        end

        return type(result) == 'table' and result or nil, false
    end

    local exportName = registry.OperationExport(provider, 'inspect')
    if not exportName then return nil, false end

    local proxy, export, reason = resolveExport(provider, exportName)
    if not export then
        if reason ~= 'provider_unavailable' then
            print(('[lifestate_jobs] provider %s inspect unavailable'):format(provider.id))
        end

        return nil, true
    end

    local called, state = pcall(export, proxy, target)
    if not called or type(state) ~= 'table' then
        print(('[lifestate_jobs] provider %s (%s) %s returned %s instead of a state table'):format(
            provider.id, provider.resource, exportName,
            called and describe(state) or tostring(state)))
        return nil, true
    end

    return state, false
end

---Everything the registry needs to know about a provider's operations, for
---diagnostics and tests.
---@return string[]
function M.Operations()
    return OPERATIONS
end

return M
