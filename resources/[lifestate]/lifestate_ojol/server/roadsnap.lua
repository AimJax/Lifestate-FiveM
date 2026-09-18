-- Bounded client round trip for road snapping.
--
-- CfxLua exposes vehicle path nodes only on the client, so resolving a road point
-- for the customer's current position needs a request to that client. A client
-- can be slow, desynced or hostile, so the reply can never be waited on
-- indefinitely - and the answer is never trusted on its own (the caller still
-- validates the point against the position the server sees for the ped).
--
-- Design: one request, one promise, one deadline. `Request` yields exactly once
-- (Citizen.Await) and is resumed by whichever of these settles first:
--
--   * the client's answer              -> validated, then resolved with the point
--   * the deadline SetTimeout          -> resolved with 'road_snap_timeout'
--   * the customer dropping            -> resolved with 'customer_offline'
--   * a resource stop                  -> timers dropped, coroutine dies with it
--
-- There is no polling, no Wait loop and no background thread: with no request in
-- flight, this module costs nothing and holds no timers.

local serverConfig = require 'config.server'
local drivers = require 'server.drivers'

local M = {}

---[requestId] = { citizenid, source, promise, timer }
---Tiny and short-lived: one entry per in-flight request, removed on settle.
M.Pending = {}

local sequence = 0

---Unguessable enough that a client cannot answer for a request it was not sent.
---The sender check below is the real guard; this just avoids handing out a
---predictable token.
---@return string
local function newRequestId()
    sequence = sequence + 1
    return ('road-%d-%d-%d'):format(os.time(), sequence, math.random(100000, 999999))
end

---Drop a pending entry (and its deadline) without resolving anything.
---@param requestId string
---@return table? entry
local function forget(requestId)
    local entry = M.Pending[requestId]
    if not entry then return nil end

    M.Pending[requestId] = nil
    if entry.timer then ClearTimeout(entry.timer) end

    return entry
end

---Finish a request exactly once. Later answers find no entry and are ignored,
---which is what makes duplicate, late and fabricated replies harmless.
---@param requestId string
---@param point table|nil
---@param reason string|nil
---@return boolean settled
function M.Settle(requestId, point, reason)
    local entry = forget(requestId)
    if not entry then return false end

    entry.promise:resolve({ point = point, reason = reason })
    return true
end

---Ask a customer's client for the nearest usable road point.
---
---Bounded by timeoutMs (or the configured default): the deadline timer always
---fires, so this can never block its caller forever.
---@param citizenid string
---@param timeoutMs number|nil
---@return table? point { x, y, z }
---@return string? reason 'customer_offline' | 'road_snap_timeout' | 'road_snap_unavailable'
function M.Request(citizenid, timeoutMs)
    local source = drivers.SourceByCitizenid[citizenid]
    if not source then return nil, 'customer_offline' end

    local requestId = newRequestId()
    local entry = {
        citizenid = citizenid,
        source = source,
        promise = promise.new(),
        timer = nil,
    }

    M.Pending[requestId] = entry

    entry.timer = SetTimeout(timeoutMs or serverConfig.roadSnapTimeoutMs, function()
        if M.Settle(requestId, nil, 'road_snap_timeout') then
            print(('[ojol] road snap timed out (request %s)'):format(tostring(requestId)))
        end
    end)

    TriggerClientEvent('lifestate_ojol:client:requestRoadPickup', source, requestId)

    local awaited, settled = pcall(Citizen.Await, entry.promise)

    if not awaited or type(settled) ~= 'table' then
        -- Never leave an entry (or its timer) behind if the await itself failed.
        forget(requestId)
        return nil, 'road_snap_unavailable'
    end

    return settled.point, settled.reason
end

---Client answer to a road-snap request. Every field is attacker-controlled, so
---the request id, the sender and the shape of the point are all re-checked here;
---the coordinate itself is only accepted as a *candidate* - the caller still
---verifies it against the server's view of the customer's ped.
RegisterNetEvent('lifestate_ojol:server:roadPickupResponse', function(requestId, point)
    local source = source

    if type(requestId) ~= 'string' then return end

    local entry = M.Pending[requestId]
    if not entry then
        -- Already settled (late or duplicate) or never issued at all.
        print(('[ojol] ignored road snap response for unknown or expired request (source %s)')
            :format(tostring(source)))
        return
    end

    if entry.source ~= source then
        print(('[ojol] ignored spoofed road snap response: request %s belongs to another player (source %s)')
            :format(tostring(requestId), tostring(source)))
        return
    end

    if type(point) ~= 'table' or type(point.x) ~= 'number' or type(point.y) ~= 'number'
        or type(point.z) ~= 'number' then
        M.Settle(requestId, nil, 'unsafe_recovery_pickup')
        return
    end

    M.Settle(requestId, { x = point.x + 0.0, y = point.y + 0.0, z = point.z + 0.0 }, nil)
end)

---The customer left: finish their pending request immediately so the awaiting
---recovery closes out deterministically instead of waiting for the deadline.
---@param citizenid string
function M.DropByCitizenid(citizenid)
    local requestIds = {}

    for requestId, entry in pairs(M.Pending) do
        if entry.citizenid == citizenid then requestIds[#requestIds + 1] = requestId end
    end

    for i = 1, #requestIds do
        M.Settle(requestIds[i], nil, 'customer_offline')
    end
end

---Resource stop/restart: drop every deadline timer. Promises are deliberately
---not resolved - the resource (and the coroutines awaiting them) is going away.
function M.Shutdown()
    for requestId in pairs(M.Pending) do
        forget(requestId)
    end
end

---Test/diagnostics helper: how many requests are in flight.
---@return number
function M.PendingCount()
    local count = 0
    for _ in pairs(M.Pending) do count = count + 1 end
    return count
end

return M
