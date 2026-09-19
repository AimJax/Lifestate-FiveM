local h = require 'tests.harness'
local calls = {}
local state = { registered = false, active = false, online = false, busy = false }

package.preload['server.profession'] = function()
    return {
        Register = function(citizenid) calls[#calls + 1] = {'give', citizenid}; state.registered=true; state.active=true; return true, 'registered' end,
        Remove = function(citizenid) calls[#calls + 1] = {'remove', citizenid}; state.active=false; return true, 'removed' end,
        Inspect = function() return state end,
    }
end

package.loaded['server.profession'] = nil
package.loaded['server.adminapi'] = nil
package.loaded['server.jobsprovider'] = nil

exports = function() end
local api = require 'server.adminapi'
local provider = require 'server.jobsprovider'

h.test('provider metadata is serializable export names only', function()
    local definition = provider.Definition()
    h.eq(definition.id, 'example_profession', 'id')
    h.eq(definition.operations.give, 'adminRegisterExample', 'give export')
    h.eq(definition.operations.remove, 'adminRemoveExample', 'remove export')
    h.eq(definition.operations.inspect, 'getExampleAdminState', 'inspect export')
    for _, value in pairs(definition.operations) do h.eq(type(value), 'string', 'operation metadata') end
end)

h.test('give remove inspect contract delegates to trusted profession state', function()
    calls = {}
    h.eq(api.adminRegisterExample({ citizenid = 'cit' }, {}), true, 'give')
    h.eq(api.getExampleAdminState({ citizenid = 'cit' }).active, true, 'inspect')
    h.eq(api.adminRemoveExample({ citizenid = 'cit' }, {}), true, 'remove')
    h.eq(#calls, 2, 'mutations')
end)
