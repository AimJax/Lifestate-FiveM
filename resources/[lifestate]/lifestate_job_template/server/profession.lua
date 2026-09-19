local db = require 'server.database'
local M = { Members = {}, Online = {}, Busy = {} }

local function dbBoolean(value) return value == true or value == 1 or value == '1' end

function M.Load()
    M.Members, M.Online, M.Busy = {}, {}, {}
    for _, row in ipairs(db.FetchAll()) do
        M.Members[row.citizenid] = {
            citizenid = row.citizenid, level = row.level or 0,
            active = dbBoolean(row.active), registeredAt = row.registered_at,
            completedTasks = row.completed_tasks or 0,
        }
    end
end

function M.Register(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'invalid_target' end
    local member = M.Members[citizenid]
    if member and member.active then return false, 'already_registered' end
    if member then
        -- Persistence first: runtime `active` flips only after the row is durable.
        -- NOTE: only a thrown DB exception counts as failure here (same as Ojol).
        -- An update reporting 0 affected rows legitimately means "already same
        -- value" under oxmysql/MySQL, so it must NOT be treated as an error.
        local ok, err = pcall(db.Reactivate, citizenid)
        if not ok then
            print(('[lifestate_job_template] Reactivate DB error for %s: %s'):format(citizenid, tostring(err)))
            return false, 'database_error'
        end
        member.active = true
        return true, 'reactivated'
    end
    -- Persistence first: the runtime record exists only after the row is durable.
    -- Same note as above: only a thrown exception (pcall failure) is a DB error;
    -- insert on this VARCHAR-PK table has no meaningful insert-id to validate.
    local ok, err = pcall(db.Insert, citizenid)
    if not ok then
        print(('[lifestate_job_template] Register DB error for %s: %s'):format(citizenid, tostring(err)))
        return false, 'database_error'
    end
    M.Members[citizenid] = { citizenid = citizenid, level = 0, active = true, registeredAt = os.time(), completedTasks = 0 }
    return true, 'registered'
end

function M.Remove(citizenid)
    local member = M.Members[citizenid]
    if not member or not member.active then return false, 'not_registered' end
    -- Persistence first: runtime duty/busy clear only after deactivation is durable.
    -- Same note: only a thrown exception is failure; 0 affected rows can mean
    -- "already same value" and must not be treated as an error.
    local ok, err = pcall(db.Deactivate, citizenid)
    if not ok then
        print(('[lifestate_job_template] Remove DB error for %s: %s'):format(citizenid, tostring(err)))
        return false, 'database_error'
    end
    member.active = false
    M.Online[citizenid] = nil
    M.Busy[citizenid] = nil
    return true, 'removed'
end

function M.SetOnline(citizenid, value) M.Online[citizenid] = value and true or nil end
function M.SetBusy(citizenid, value) M.Busy[citizenid] = value and true or nil end
function M.Inspect(citizenid)
    local member = M.Members[citizenid]
    if not member then return { registered = false, active = false, online = false, busy = false } end
    return { registered = member.active, active = member.active, level = member.level,
        completedTasks = member.completedTasks, online = M.Online[citizenid] == true, busy = M.Busy[citizenid] == true }
end

return M
