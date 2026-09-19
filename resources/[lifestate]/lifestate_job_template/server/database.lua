local M = {}

function M.EnsureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `example_profession_members` (
            `citizenid` VARCHAR(50) NOT NULL,
            `level` INT UNSIGNED NOT NULL DEFAULT 0,
            `active` TINYINT(1) NOT NULL DEFAULT 1,
            `registered_at` INT UNSIGNED NOT NULL DEFAULT 0,
            `updated_at` INT UNSIGNED NOT NULL DEFAULT 0,
            `completed_tasks` INT UNSIGNED NOT NULL DEFAULT 0,
            PRIMARY KEY (`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
end

function M.FetchAll() return MySQL.query.await('SELECT * FROM `example_profession_members`') or {} end
function M.Insert(citizenid)
    local now = os.time()
    return MySQL.insert.await('INSERT INTO `example_profession_members` (`citizenid`, `registered_at`, `updated_at`) VALUES (?, ?, ?)', { citizenid, now, now })
end
function M.Reactivate(citizenid)
    return MySQL.update.await('UPDATE `example_profession_members` SET `active` = 1, `updated_at` = ? WHERE `citizenid` = ?', { os.time(), citizenid })
end
function M.Deactivate(citizenid)
    return MySQL.update.await('UPDATE `example_profession_members` SET `active` = 0, `updated_at` = ? WHERE `citizenid` = ?', { os.time(), citizenid })
end

return M
