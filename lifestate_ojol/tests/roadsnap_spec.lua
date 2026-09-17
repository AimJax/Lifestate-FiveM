-- Bounded road-snap round trip (server/roadsnap.lua).
--
-- The module is exercised directly, with the FiveM scheduler, net layer and the
-- CfxLua promise primitives replaced by tests/scheduler_stub.lua. Time only moves
-- when a test moves it, so every way the round trip can end - the client's
-- answer, the deadline, the customer dropping, a resource stop - is reached
-- deterministically and without ever waiting.
--
-- Four properties matter: the round trip ALWAYS settles, it never holds its
-- caller past the deadline, a settled request leaves nothing behind, and late,
-- duplicate or spoofed answers change nothing.

local h = require 'tests.harness'
local stub = require 'tests.scheduler_stub'

local CUSTOMER_SOURCE = 11
local OTHER_SOURCE = 12
local POINT = { x = 120.5, y = -300.25, z = 31.0 }
local SPOOFED = { x = -1000.0, y = -1000.0, z = -1000.0 }

package.preload['config.server'] = function()
    return { roadSnapTimeoutMs = 3000 }
end

package.preload['server.drivers'] = function()
    return { SourceByCitizenid = { customer = CUSTOMER_SOURCE, other = OTHER_SOURCE } }
end

-- Install the host primitives BEFORE the module loads: it registers its response
-- handler (RegisterNetEvent) at load time.
stub.Install()

-- The module binds its dependencies as it loads, so earlier specs' cached
-- copies have to go: they would answer from their own stubbed tables.
package.preload['server.roadsnap'] = nil
package.loaded['server.roadsnap'] = nil
package.loaded['server.drivers'] = nil
package.loaded['config.server'] = nil

local roadsnap = require 'server.roadsnap'

---Start each test from a clean clock, timer set and await hook. The stub's
---registered net handlers are deliberately NOT cleared - they belong to the
---module under test.
local function resetStub()
    stub.now = 0
    stub.timers = {}
    stub.clientCalls = {}
    stub.counts = {}
    stub.awaitHook = nil
end

-- The happy path ---------------------------------------------------------------

h.test('a valid answer before the deadline resolves the request', function()
    resetStub()
    stub.RespondWith(POINT)

    local point, reason = roadsnap.Request('customer')

    h.eq(reason, nil, 'no failure reason')
    h.eq(point.x, POINT.x, 'x')
    h.eq(point.y, POINT.y, 'y')
    h.eq(point.z, POINT.z, 'z')
    h.eq(roadsnap.PendingCount(), 0, 'no request left in flight')
    h.eq(stub.TimerCount(), 0, 'deadline cleared')
end)

h.test('the request names the customer and hands the client nothing else', function()
    resetStub()
    stub.RespondWith(POINT)

    roadsnap.Request('customer')

    local call = stub.LastClientCall('lifestate_ojol:client:requestRoadPickup')
    h.eq(call ~= nil, true, 'request sent')
    h.eq(call.target, CUSTOMER_SOURCE, 'sent to the customer')
    h.eq(type(call.args[1]), 'string', 'request id')
    h.eq(#call.args, 1, 'the client is given nothing else to echo')
end)

h.test('each request carries a distinct id', function()
    resetStub()
    stub.RespondWith(POINT)
    roadsnap.Request('customer')
    local first = stub.LastRoadSnapRequestId()

    resetStub()
    stub.RespondWith(POINT)
    roadsnap.Request('customer')
    local second = stub.LastRoadSnapRequestId()

    h.eq(type(first), 'string', 'first id')
    h.eq(first ~= second, true, 'request ids are not reused')
end)

-- The deadline -----------------------------------------------------------------

h.test('an unresponsive client settles on the deadline, not on the caller', function()
    resetStub()
    stub.TimeoutDuringWait()

    local point, reason = roadsnap.Request('customer')

    h.eq(point, nil, 'no point: there is no raw-coordinate fallback')
    h.eq(reason, 'road_snap_timeout', 'reason')
    h.eq(roadsnap.PendingCount(), 0, 'request cleaned up')
    h.eq(stub.TimerCount(), 0, 'deadline cleared')
end)

h.test('the deadline is the configured bound', function()
    resetStub()
    stub.TimeoutDuringWait()

    roadsnap.Request('customer')

    h.eq(stub.now, 3000, 'configured deadline honoured')
end)

h.test('a caller-supplied deadline overrides the configured default', function()
    resetStub()
    stub.TimeoutDuringWait()

    local _, reason = roadsnap.Request('customer', 750)

    h.eq(reason, 'road_snap_timeout', 'reason')
    h.eq(stub.now, 750, 'caller deadline honoured')
end)

h.test('a customer with no live source never costs a deadline', function()
    resetStub()

    local point, reason = roadsnap.Request('nobody')

    h.eq(point, nil, 'no point')
    h.eq(reason, 'customer_offline', 'reason')
    h.eq(stub.EventCount('lifestate_ojol:client:requestRoadPickup'), 0, 'no request sent')
    h.eq(stub.TimerCount(), 0, 'no deadline armed')
end)

-- Untrusted answers ------------------------------------------------------------

h.test('a payload that is not a point is refused', function()
    resetStub()
    stub.RespondWith(nil)

    local point, reason = roadsnap.Request('customer')

    h.eq(point, nil, 'no point')
    h.eq(reason, 'unsafe_recovery_pickup', 'reason')
    h.eq(roadsnap.PendingCount(), 0, 'request settled')
    h.eq(stub.TimerCount(), 0, 'no deadline left armed')
end)

h.test('a payload with non-numeric coordinates is refused', function()
    resetStub()
    stub.RespondWith({ x = 'not a number', y = 1, z = 1 })

    local point, reason = roadsnap.Request('customer')

    h.eq(point, nil, 'no point')
    h.eq(reason, 'unsafe_recovery_pickup', 'reason')
end)

h.test('an answer from another player is refused', function()
    resetStub()

    local pendingDuringSpoof
    stub.OnAwait(function()
        local requestId = stub.LastRoadSnapRequestId()

        -- Another player guesses the request id and answers for the customer.
        stub.DispatchNet('lifestate_ojol:server:roadPickupResponse', OTHER_SOURCE, requestId, SPOOFED)

        pendingDuringSpoof = roadsnap.PendingCount()
        stub.DeliverRoadSnap(POINT)
    end)

    local point = roadsnap.Request('customer')

    h.eq(pendingDuringSpoof, 1, 'a spoofed answer does not settle the request')
    h.eq(point.x, POINT.x, 'the rightful answer is used')
    h.eq(point.x ~= SPOOFED.x, true, 'the spoofed point was not used')
    h.eq(roadsnap.PendingCount(), 0, 'settled exactly once')
end)

h.test('an answer naming a request that was never issued is ignored', function()
    resetStub()

    local pendingDuringForgery
    stub.OnAwait(function()
        stub.DispatchNet('lifestate_ojol:server:roadPickupResponse', CUSTOMER_SOURCE, 'road-forged', POINT)
        pendingDuringForgery = roadsnap.PendingCount()
        stub.DeliverRoadSnap(POINT)
    end)

    local point, reason = roadsnap.Request('customer')

    h.eq(pendingDuringForgery, 1, 'a forged request id does not settle anything')
    h.eq(reason, nil, 'no failure')
    h.eq(point.x, POINT.x, 'the real request still resolves')
end)

h.test('a late answer changes nothing', function()
    resetStub()
    stub.TimeoutDuringWait()

    local point, reason = roadsnap.Request('customer')
    h.eq(point, nil, 'no point')
    h.eq(reason, 'road_snap_timeout', 'reason')

    local requestId = stub.LastRoadSnapRequestId()

    -- The client answers after the deadline. The request no longer exists, so
    -- there is nothing to resolve and nothing to mutate.
    stub.DispatchNet('lifestate_ojol:server:roadPickupResponse', CUSTOMER_SOURCE, requestId, POINT)

    h.eq(roadsnap.PendingCount(), 0, 'a late answer creates no request')
    h.eq(stub.TimerCount(), 0, 'a late answer arms no deadline')
    h.eq(stub.EventCount('lifestate_ojol:client:requestRoadPickup'), 1, 'no re-request was sent')
end)

h.test('only the first of two answers is used', function()
    resetStub()

    local settlements = 0
    stub.OnAwait(function()
        local requestId = stub.LastRoadSnapRequestId()
        stub.DeliverRoadSnap(POINT)
        settlements = settlements + 1
        stub.DeliverRoadSnap(SPOOFED)
        settlements = settlements + 1
    end)

    local point = roadsnap.Request('customer')

    h.eq(settlements, 2, 'both answers were delivered')
    h.eq(point.x, POINT.x, 'the first answer wins')
    h.eq(roadsnap.PendingCount(), 0, 'the settled request is not left behind')
    h.eq(stub.TimerCount(), 0, 'no deadline left armed')
end)

-- Dropping and shutdown --------------------------------------------------------

h.test('a customer dropping during the round trip settles it immediately', function()
    resetStub()
    stub.OnAwait(function() roadsnap.DropByCitizenid('customer') end)

    local point, reason = roadsnap.Request('customer')

    h.eq(point, nil, 'no point')
    h.eq(reason, 'customer_offline', 'reason')
    h.eq(roadsnap.PendingCount(), 0, 'request cleaned up')
    h.eq(stub.TimerCount(), 0, 'deadline cleared')
end)

h.test('a different customer dropping leaves the request in flight', function()
    resetStub()

    local pendingAfterDrop
    stub.OnAwait(function()
        roadsnap.DropByCitizenid('other')
        pendingAfterDrop = roadsnap.PendingCount()
        stub.DeliverRoadSnap(POINT)
    end)

    local point = roadsnap.Request('customer')

    h.eq(pendingAfterDrop, 1, 'only the dropped customer is released')
    h.eq(point.x, POINT.x, 'the request still resolves normally')
end)

h.test('a resource stop leaves no pending request and no armed deadline', function()
    resetStub()
    stub.OnAwait(function() roadsnap.Shutdown() end)

    -- Shutdown drops the request without resolving it: the awaiting coroutine
    -- belongs to the resource that is stopping, so it never resumes.
    local point, reason = roadsnap.Request('customer')

    h.eq(point, nil, 'no point')
    h.eq(reason, 'road_snap_unavailable', 'reason')
    h.eq(roadsnap.PendingCount(), 0, 'no pending request survives')
    h.eq(stub.TimerCount(), 0, 'no armed deadline survives')
end)
