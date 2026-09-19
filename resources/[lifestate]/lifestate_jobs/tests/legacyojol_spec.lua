local h = require 'tests.harness'
local player
local calls

exports = { qbx_core = h.exportsProxy({
    GetPlayerByCitizenId = function() return player and not player.Offline and player or nil end,
    GetOfflinePlayer = function() return player and player.Offline and player or nil end,
    RemovePlayerFromJob = function(citizenid, job) calls[#calls + 1] = { citizenid, job }; return true end,
}) }

lib = { addCommand = function() end }
package.preload['server.service'] = function() return { Authorize = function() return true end } end
package.loaded['server.legacyojol'] = nil
local migration = require 'server.legacyojol'

h.test('legacy migration only removes a primary ojol job through Qbox', function()
    calls = {}; player = { Offline = true, PlayerData = { citizenid = 'cit', job = { name = 'ojol' } } }
    h.eq(migration.Migrate('cit'), true, 'migrated')
    h.eq(calls[1][1], 'cit', 'citizenid')
    h.eq(calls[1][2], 'ojol', 'job')
end)

h.test('legacy migration leaves unrelated primary jobs untouched', function()
    calls = {}; player = { Offline = true, PlayerData = { citizenid = 'cit', job = { name = 'police' } } }
    h.eq(select(2, migration.Migrate('cit')), 'not_legacy_ojol', 'outcome')
    h.eq(#calls, 0, 'no mutation')
end)
