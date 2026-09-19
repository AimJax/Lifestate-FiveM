local h = require 'tests.harness'
local rows = {}
local dbCalls = { insert = 0, reactivate = 0, deactivate = 0 }
local dbFail = {}

local function resetDb()
    rows = {}
    dbCalls.insert, dbCalls.reactivate, dbCalls.deactivate = 0, 0, 0
    dbFail.insert, dbFail.reactivate, dbFail.deactivate = nil, nil, nil
end

package.preload['server.database'] = function()
    return {
        FetchAll = function() return rows end,
        Insert = function(citizenid)
            dbCalls.insert = dbCalls.insert + 1
            if dbFail.insert then error('insert boom') end
            rows = {{ citizenid = citizenid, level = 0, active = 1, registered_at = 10, completed_tasks = 4 }}
            return 1
        end,
        Reactivate = function(citizenid)
            dbCalls.reactivate = dbCalls.reactivate + 1
            if dbFail.reactivate then error('reactivate boom') end
            for i = 1, #rows do
                if rows[i].citizenid == citizenid then rows[i].active = 1 end
            end
            if #rows == 1 and rows[1].citizenid == nil then rows[1].active = 1 end
            return 1
        end,
        Deactivate = function(citizenid)
            dbCalls.deactivate = dbCalls.deactivate + 1
            if dbFail.deactivate then error('deactivate boom') end
            for i = 1, #rows do
                if rows[i].citizenid == citizenid then rows[i].active = 0 end
            end
            return 1
        end,
    }
end

local profession = require 'server.profession'

local cases = {{1,true},{0,false},{true,true},{false,false},{'1',true},{'0',false},{nil,false}}
for i = 1, #cases do
    h.test('boolean hydration ' .. tostring(cases[i][1]), function()
        resetDb()
        rows = {{ citizenid = 'cit-' .. i, level = 2, active = cases[i][1], registered_at = 10, completed_tasks = 4 }}
        profession.Load()
        h.eq(profession.Inspect('cit-' .. i).active, cases[i][2], 'active')
    end)
end

h.test('startup reload preserves registration and history but resets runtime state', function()
    resetDb()
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
    resetDb()
    rows = {{ citizenid = 'cit', level = 2, active = 0, registered_at = 10, completed_tasks = 4 }}
    profession.Load()
    h.eq(select(2, profession.Register('cit')), 'reactivated', 'outcome')
    local state = profession.Inspect('cit')
    h.eq(state.level, 2, 'level')
    h.eq(state.completedTasks, 4, 'history')
end)

-- DB-failure hardening -------------------------------------------------------

h.test('new registration succeeds only after persistence', function()
    resetDb()
    profession.Load()
    local ok, outcome = profession.Register('new-cit')
    h.eq(ok, true, 'ok')
    h.eq(outcome, 'registered', 'outcome')
    h.eq(dbCalls.insert, 1, 'insert called once')
    h.eq(profession.Members['new-cit'] ~= nil, true, 'runtime member created')
    h.eq(profession.Inspect('new-cit').registered, true, 'registered')
end)

h.test('new registration database failure creates no runtime state', function()
    resetDb()
    profession.Load()
    dbFail.insert = true
    local ok, outcome = profession.Register('new-cit')
    h.eq(ok, false, 'ok')
    h.eq(outcome, 'database_error', 'outcome')
    h.eq(profession.Members['new-cit'], nil, 'no runtime member')
    h.eq(profession.Inspect('new-cit').registered, false, 'not registered')
end)

h.test('reactivation succeeds and preserves history', function()
    resetDb()
    rows = {{ citizenid = 'cit', level = 3, active = 0, registered_at = 10, completed_tasks = 7 }}
    profession.Load()
    local ok, outcome = profession.Register('cit')
    h.eq(ok, true, 'ok')
    h.eq(outcome, 'reactivated', 'outcome')
    h.eq(dbCalls.reactivate, 1, 'reactivate called once')
    local state = profession.Inspect('cit')
    h.eq(state.active, true, 'active')
    h.eq(state.level, 3, 'level')
    h.eq(state.completedTasks, 7, 'history')
end)

h.test('reactivation database failure preserves inactive state and history', function()
    resetDb()
    rows = {{ citizenid = 'cit', level = 3, active = 0, registered_at = 10, completed_tasks = 7 }}
    profession.Load()
    dbFail.reactivate = true
    local ok, outcome = profession.Register('cit')
    h.eq(ok, false, 'ok')
    h.eq(outcome, 'database_error', 'outcome')
    local member = profession.Members['cit']
    h.eq(member.active, false, 'remains inactive')
    h.eq(member.level, 3, 'level unchanged')
    h.eq(member.completedTasks, 7, 'history unchanged')
end)

h.test('removal succeeds and clears runtime state', function()
    resetDb()
    rows = {{ citizenid = 'cit', level = 2, active = 1, registered_at = 10, completed_tasks = 4 }}
    profession.Load()
    profession.SetOnline('cit', true)
    profession.SetBusy('cit', true)
    local ok, outcome = profession.Remove('cit')
    h.eq(ok, true, 'ok')
    h.eq(outcome, 'removed', 'outcome')
    h.eq(dbCalls.deactivate, 1, 'deactivate called once')
    h.eq(profession.Members['cit'].active, false, 'inactive')
    local state = profession.Inspect('cit')
    h.eq(state.online, false, 'online cleared')
    h.eq(state.busy, false, 'busy cleared')
end)

h.test('removal database failure preserves active and runtime state', function()
    resetDb()
    rows = {{ citizenid = 'cit', level = 2, active = 1, registered_at = 10, completed_tasks = 4 }}
    profession.Load()
    profession.SetOnline('cit', true)
    profession.SetBusy('cit', true)
    dbFail.deactivate = true
    local ok, outcome = profession.Remove('cit')
    h.eq(ok, false, 'ok')
    h.eq(outcome, 'database_error', 'outcome')
    h.eq(profession.Members['cit'].active, true, 'remains active')
    local state = profession.Inspect('cit')
    h.eq(state.online, true, 'online unchanged')
    h.eq(state.busy, true, 'busy unchanged')
end)

h.test('already registered performs no database mutation', function()
    resetDb()
    rows = {{ citizenid = 'cit', level = 2, active = 1, registered_at = 10, completed_tasks = 4 }}
    profession.Load()
    dbCalls.insert, dbCalls.reactivate, dbCalls.deactivate = 0, 0, 0
    local ok, outcome = profession.Register('cit')
    h.eq(ok, false, 'ok')
    h.eq(outcome, 'already_registered', 'outcome')
    h.eq(dbCalls.insert, 0, 'no insert')
    h.eq(dbCalls.reactivate, 0, 'no reactivate')
    h.eq(dbCalls.deactivate, 0, 'no deactivate')
end)

h.test('invalid citizenid performs no database mutation', function()
    resetDb()
    rows = {}
    profession.Load()
    dbCalls.insert, dbCalls.reactivate, dbCalls.deactivate = 0, 0, 0
    local ok1, reason1 = profession.Register('')
    h.eq(ok1, false, 'empty ok')
    h.eq(reason1, 'invalid_target', 'empty reason')
    local ok2, reason2 = profession.Register(nil)
    h.eq(ok2, false, 'nil ok')
    h.eq(reason2, 'invalid_target', 'nil reason')
    local ok3, reason3 = profession.Register(123)
    h.eq(ok3, false, 'non-string ok')
    h.eq(reason3, 'invalid_target', 'non-string reason')
    h.eq(dbCalls.insert, 0, 'no insert')
    h.eq(dbCalls.reactivate, 0, 'no reactivate')
    h.eq(dbCalls.deactivate, 0, 'no deactivate')
end)
