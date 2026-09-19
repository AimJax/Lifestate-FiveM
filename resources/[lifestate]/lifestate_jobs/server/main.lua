-- Lifestate Job Management - server entry point.
--
-- One generic service, N registered providers. The Qbox admin menu reaches this
-- resource through the two relay events at the bottom; everything else is called
-- by the menu client through lib.callback, and every one of those calls is
-- authorized and resolved again on this side.

local registry = require 'server.registry'
local service = require 'server.service'
local frameworkJobs = require 'server.frameworkjobs'
local providerapi = require 'server.providerapi'
local config = require 'config.server'
local legacyOjol = require 'server.legacyojol'

-- Provider API ----------------------------------------------------------------
-- What a future job needs to appear in the admin menu: one registration call.
-- The menu itself is generated from the registry, so nothing else changes.
--
-- Ownership is implicit: server/providerapi.lua resolves it from
-- GetInvokingResource(), so a provider cannot claim (or take over) somebody
-- else's id, and only its owner can unregister it.

---@param definition JobProviderDefinition
---@return boolean ok, string outcomeOrReason
exports('RegisterProvider', function(definition)
    return providerapi.Register(definition)
end)

---@param id string
---@return boolean ok, string? reason
exports('UnregisterProvider', function(id)
    return providerapi.Unregister(id)
end)

---Read-only diagnostics: id / label / type / owning resource of every provider.
---@return table[]
exports('GetProviders', function()
    local list = {}

    for _, provider in ipairs(registry.List()) do
        list[#list + 1] = {
            id = provider.id,
            label = provider.label,
            type = provider.type,
            resource = provider.resource,
        }
    end

    return list
end)

-- Callbacks (admin menu) ------------------------------------------------------

lib.callback.register('lifestate_jobs:server:getCatalog', function(source)
    -- Re-sync the framework adapter on open: jobs created/removed at runtime show
    -- up immediately, still without any per-job code.
    frameworkJobs.Sync()

    return service.GetCatalog(source)
end)

lib.callback.register('lifestate_jobs:server:getPlayerJobs', function(source, target)
    frameworkJobs.Sync()

    return service.Inspect(source, target)
end)

lib.callback.register('lifestate_jobs:server:mutate', function(source, payload)
    return service.Mutate(source, payload)
end)

-- Admin-menu relay ------------------------------------------------------------
-- The only thing the qbx_adminmenu hook does is trigger the first one; the
-- permission check happens here, so the section can never be reached by a
-- non-admin even if the client event is forged.

RegisterNetEvent('lifestate_jobs:server:openMenu', function()
    local authorized, reason = service.Authorize(source)

    if not authorized then
        service.Denied(source, reason)
        return
    end

    TriggerClientEvent('lifestate_jobs:client:openMenu', source)
end)

RegisterNetEvent('lifestate_jobs:server:backToAdminMenu', function()
    local authorized = service.Authorize(source)

    if not authorized then return end

    TriggerClientEvent('qbx_admin:client:openMenu', source)
end)

-- Lifecycle -------------------------------------------------------------------

-- Drop every provider that belonged to a stopped resource, so the registry never
-- keeps a function reference into a resource that is gone (Ojol stopping removes
-- the Ojol provider; qbx_core stopping removes the framework jobs, which the
-- adapter repopulates on its next start/sync).
providerapi.Start()
legacyOjol.Start()

AddEventHandler('onServerResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    frameworkJobs.Start()

    print(('[lifestate_jobs] ready: %d provider(s) registered (perm: %s, optin: %s)'):format(
        registry.Count(), tostring(config.perm), config.requireOptin and 'required' or 'off'))
end)
