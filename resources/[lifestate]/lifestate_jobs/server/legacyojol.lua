local service = require 'server.service'
local M = {}

function M.Migrate(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'invalid_citizenid' end
    local player = exports.qbx_core:GetPlayerByCitizenId(citizenid) or exports.qbx_core:GetOfflinePlayer(citizenid)
    if not player then return false, 'player_not_found' end
    if not player.PlayerData.job or player.PlayerData.job.name ~= 'ojol' then return false, 'not_legacy_ojol' end
    local ok, err = exports.qbx_core:RemovePlayerFromJob(citizenid, 'ojol')
    return ok == true, ok and 'migrated' or (err and err.code or 'migration_failed')
end

function M.Start()
    lib.addCommand('migratelegacyojol', {
        help = 'Move one legacy Qbox primary Ojol character to unemployed',
        params = {{ name = 'citizenid', help = 'Exact character citizenid', type = 'string' }},
        restricted = 'group.admin',
    }, function(source, args)
        if source > 0 and not service.Authorize(source) then return end
        local ok, outcome = M.Migrate(args.citizenid)
        print(('[lifestate_jobs] legacy Ojol migration: %s'):format(ok and 'migrated' or tostring(outcome)))
    end)
end

return M
