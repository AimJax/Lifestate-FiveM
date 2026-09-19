local h = require 'tests.harness'
local rows = {}

package.preload['server.database'] = function()
    return {
        FetchAll = function() return rows end,
        Insert = function(citizenid) rows = {{ citizenid = citizenid, level = 0, active = 1, registered_at = 10, completed_tasks = 4 }} end,
        Reactivate = function() rows[1].active = 1 end,
        Deactivate = function() rows[1].active = 0 end,
    }
end

local profession = require 'server.profession'

local cases = {{1,true},{0,false},{true,true},{false,false},{'1',true},{'0',false},{nil,false}}
for i = 1, #cases do
    h.test('boolean hydration ' .. tostring(cases[i][1]), function()
        rows = {{ citizenid = 'cit-' .. i, level = 2, active = cases[i][1], registered_at = 10, completed_tasks = 4 }}
        profession.Load()
        h.eq(profession.Inspect('cit-' .. i).active, cases[i][2], 'active')
    end)
end

h.test('startup reload preserves registration and history but resets runtime state', function()
    rows = {{ citizenid = 'cit', level = 2, active = 1, registered_at = 10, completed_tasks = 4 }}
    profession.Load()
    profession.SetOnline('cit', true)
    profession.SetBusy('cit', true)
    profession.Load()
    local state = profession.Inspect('cit')
    h.eq(state.registered, true, 'registered')
    h.eq(state.level, 2, 'level')
    h.eq(state.completedTasks, 4, 'history')
    h.eq(state.online, false, 'online resets')
    h.eq(state.busy, false, 'busy resets')
end)

h.test('rehire preserves historical fields', function()
    rows = {{ citizenid = 'cit', level = 2, active = 0, registered_at = 10, completed_tasks = 4 }}
    profession.Load()
    h.eq(select(2, profession.Register('cit')), 'reactivated', 'outcome')
    local state = profession.Inspect('cit')
    h.eq(state.level, 2, 'level')
    h.eq(state.completedTasks, 4, 'history')
end)
