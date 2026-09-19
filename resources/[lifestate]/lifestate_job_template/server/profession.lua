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
    if member then db.Reactivate(citizenid); member.active = true; return true, 'reactivated' end
    db.Insert(citizenid)
    M.Members[citizenid] = { citizenid = citizenid, level = 0, active = true, registeredAt = os.time(), completedTasks = 0 }
    return true, 'registered'
end

function M.Remove(citizenid)
    local member = M.Members[citizenid]
    if not member or not member.active then return false, 'not_registered' end
    db.Deactivate(citizenid); member.active = false; M.Online[citizenid] = nil; M.Busy[citizenid] = nil
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
