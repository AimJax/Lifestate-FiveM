local shared = require 'config.shared'
local server = require 'config.server'
local M = {}
function M.Definition()
    return { id = shared.providerId, label = shared.label, type = 'profession', operations = {
        give = 'adminRegisterExample', remove = 'adminRemoveExample', inspect = 'getExampleAdminState' } }
end
function M.Register()
    if GetResourceState(server.registryResource) ~= 'started' then return false, 'registry_unavailable' end
    return exports[server.registryResource]:RegisterProvider(M.Definition())
end
function M.Start()
    M.Register()
    AddEventHandler('onServerResourceStart', function(resourceName)
        if resourceName == server.registryResource then M.Register() end
    end)
end
return M
