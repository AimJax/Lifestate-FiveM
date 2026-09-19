local profession = require 'server.profession'
local M = {}
local function citizenid(target) return type(target) == 'table' and target.citizenid or target end
function M.adminRegisterExample(target) return profession.Register(citizenid(target)) end
function M.adminRemoveExample(target) return profession.Remove(citizenid(target)) end
function M.getExampleAdminState(target) return profession.Inspect(citizenid(target)) end
exports('adminRegisterExample', M.adminRegisterExample)
exports('adminRemoveExample', M.adminRemoveExample)
exports('getExampleAdminState', M.getExampleAdminState)
return M
