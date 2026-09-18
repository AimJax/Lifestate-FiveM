-- Deterministic stand-in for the FiveM scheduler, net layer and the CfxLua
-- promise primitives, shared by the specs that load real server modules.
--
-- It exists so tests can drive time and client round trips *exactly*: timers only
-- fire when a test moves the clock, and a client answer is delivered while the
-- code under test is waiting for it. That is how the bounded request/response
-- contract is verified without ever waiting in real time.
--
-- Nothing here reimplements production logic - it only provides the host
-- primitives the resource calls into.

local M = {}

M.now = 0
M.timers = {}       -- [id] = { at, fn }
M.counts = {}       -- [eventName] = dispatches
M.clientCalls = {}  -- { { event, target, args } }
M.serverHandlers = {}
M.netHandlers = {}
M.awaitHook = nil

local function reset()
    M.now = 0
    M.nextTimerId = 0
    M.timers = {}
    M.counts = {}
    M.clientCalls = {}
    M.serverHandlers = {}
    M.netHandlers = {}
    M.awaitHook = nil
end

-- Scheduler ------------------------------------------------------------------

---@return number
function M.GetGameTimer()
    return M.now
end

---One-shot timer, like the real SetTimeout.
---@return number id
function M.SetTimeout(ms, fn)
    M.nextTimerId = M.nextTimerId + 1
    M.timers[M.nextTimerId] = { at = M.now + (tonumber(ms) or 0), fn = fn }
    return M.nextTimerId
end

function M.ClearTimeout(id)
    if id then M.timers[id] = nil end
end

---How many deadlines are still armed.
---@return number
function M.TimerCount()
    local count = 0
    for _ in pairs(M.timers) do count = count + 1 end
    return count
end

---Fire every timer due at or before the (moved) clock.
---@return number fired
function M.FireDue()
    local fired = 0

    while true do
        local earliestId, earliest = nil, nil
        for id, timer in pairs(M.timers) do
            if not earliest or timer.at < earliest then earliestId, earliest = id, timer.at end
        end

        if not earliest or earliest > M.now then break end

        local timer = M.timers[earliestId]
        M.timers[earliestId] = nil
        fired = fired + 1
        timer.fn()
    end

    return fired
end

---Move the clock forward and fire whatever became due.
---@param ms number
---@return number fired
function M.Advance(ms)
    M.now = M.now + (tonumber(ms) or 0)
    return M.FireDue()
end

---Run every armed deadline as though its moment had arrived - the unresponsive
---client case.
---@return number fired
function M.ExpireAllTimers()
    local fired, guard = 0, 0

    while next(M.timers) ~= nil and guard < 64 do
        guard = guard + 1

        local earliest
        for _, timer in pairs(M.timers) do
            if not earliest or timer.at < earliest then earliest = timer.at end
        end

        M.now = math.max(M.now, earliest)
        fired = fired + M.FireDue()
    end

    return fired
end

-- Events ---------------------------------------------------------------------

function M.AddEventHandler(eventName, fn)
    local list = M.serverHandlers[eventName]
    if not list then
        list = {}
        M.serverHandlers[eventName] = list
    end
    list[#list + 1] = fn
end

function M.RegisterNetEvent(eventName, fn)
    M.netHandlers[eventName] = fn
end

function M.TriggerEvent(eventName, ...)
    M.counts[eventName] = (M.counts[eventName] or 0) + 1

    local list = M.serverHandlers[eventName]
    if not list then return end

    for i = 1, #list do
        list[i](...)
    end
end

function M.TriggerClientEvent(eventName, target, ...)
    M.counts[eventName] = (M.counts[eventName] or 0) + 1
    M.clientCalls[#M.clientCalls + 1] = { event = eventName, target = tonumber(target), args = { ... } }
end

---@param eventName string
---@return number dispatches
function M.EventCount(eventName)
    return M.counts[eventName] or 0
end

---@param eventName string
---@return table? { event, target, args } most recent client call
function M.LastClientCall(eventName)
    for i = #M.clientCalls, 1, -1 do
        if M.clientCalls[i].event == eventName then return M.clientCalls[i] end
    end
    return nil
end

---Invoke a client-originated handler with a spoofable `source`, exactly like the
---net layer does. Handler errors are re-raised so a removed guard cannot pass
---silently.
---@param eventName string
---@param src number
function M.DispatchNet(eventName, src, ...)
    local handler = M.netHandlers[eventName]
    if not handler then return false end

    local previous = _G.source
    _G.source = src
    local ok, err = pcall(handler, ...)
    _G.source = previous

    if not ok then error(err, 0) end
    return true
end

---Answer the most recent road-snap request from `src` (default: the player it
---was sent to).
---@param point table|nil
---@param src number|nil
---@return boolean delivered
function M.DeliverRoadSnap(point, src)
    local call = M.LastClientCall('lifestate_ojol:client:requestRoadPickup')
    if not call then return false end

    local requestId = call.args[1]
    if type(requestId) ~= 'string' then return false end

    M.DispatchNet('lifestate_ojol:server:roadPickupResponse', src or call.target, requestId, point)
    return true
end

---@return string? requestId of the most recent road-snap request
function M.LastRoadSnapRequestId()
    local call = M.LastClientCall('lifestate_ojol:client:requestRoadPickup')
    return call and call.args[1] or nil
end

-- Await hooks ----------------------------------------------------------------

---The client answers while the code under test is waiting for it.
---@param point table|nil
---@param src number|nil
function M.RespondWith(point, src)
    M.awaitHook = function() M.DeliverRoadSnap(point, src) end
end

---The client never answers: the request's own deadline fires instead.
function M.TimeoutDuringWait()
    M.awaitHook = function() M.ExpireAllTimers() end
end

---Answer first, then let the deadline fire - proves the deadline is harmless
---once a request has settled.
---@param point table
function M.RespondThenExpire(point)
    M.awaitHook = function()
        M.DeliverRoadSnap(point)
        M.ExpireAllTimers()
    end
end

---Run an arbitrary body at await time.
---@param fn function
function M.OnAwait(fn)
    M.awaitHook = fn
end

-- Promise --------------------------------------------------------------------

M.promise = {
    new = function()
        return {
            state = 0, -- 0 pending, 1 resolved
            value = nil,
            resolve = function(self, value)
                if self.state ~= 0 then return false end
                self.state, self.value = 1, value
                return true
            end,
        }
    end,
}

M.Citizen = {
    ---Yields in the real runtime; here it hands control to the test's await hook.
    ---@param p table
    Await = function(p)
        if type(p) ~= 'table' then error('scheduler_stub: awaited a non-promise', 0) end

        if p.state == 0 and M.awaitHook then M.awaitHook(p) end

        if p.state == 0 then
            error('scheduler_stub: awaited a promise that nothing settled '
                .. '(arm a response or let the deadline expire)', 0)
        end

        return p.value
    end,
}

---Install every stub as a global and reset all state.
function M.Install()
    reset()

    SetTimeout = M.SetTimeout
    ClearTimeout = M.ClearTimeout
    GetGameTimer = M.GetGameTimer
    TriggerEvent = M.TriggerEvent
    AddEventHandler = M.AddEventHandler
    RegisterNetEvent = M.RegisterNetEvent
    TriggerClientEvent = M.TriggerClientEvent
    promise = M.promise
    Citizen = M.Citizen

    return M
end

return M
