-- Ride state machine + live ride registry (Phase 3B).
--
-- Ownership: this module owns everything about a ride's *lifecycle* - creation,
-- assignment, cancellation, terminal states, persistence and the views the
-- customer sees. It deliberately knows nothing about the matching algorithm
-- (offers, search radius, cooldowns); those live in server/matching.lua.
--
-- The two modules are decoupled through server events, so there is no require
-- cycle:
--   rides    -> fires 'rideSearching' / 'rideAssigned' / 'rideClosed' / 'driverAvailabilityChanged'
--   matching -> listens to them and calls back into rides.TryAcceptRide
--
-- Runtime state is authoritative; the database only records the request, the
-- accepted driver and the final outcome.

local serverConfig = require 'config.server'
local sharedConfig = require 'config.shared'
local db = require 'server.database'
local drivers = require 'server.drivers'
local fares = require 'server.fares'
local payments = require 'server.payments'
local bikes = require 'server.vehicles'

local M = {}

-- States ---------------------------------------------------------------------

M.STATES = {
    SEARCHING = 'SEARCHING',
    ACCEPTED = 'ACCEPTED',
    DRIVER_ENROUTE = 'DRIVER_ENROUTE',
    DRIVER_ARRIVED = 'DRIVER_ARRIVED',
    PASSENGER_ONBOARD = 'PASSENGER_ONBOARD',
    ENROUTE_DESTINATION = 'ENROUTE_DESTINATION',
    COMPLETED = 'COMPLETED',
    CANCELLED_CUSTOMER = 'CANCELLED_CUSTOMER',
    CANCELLED_DRIVER = 'CANCELLED_DRIVER',
    FAILED = 'FAILED',
}

local TERMINAL = {
    COMPLETED = true,
    CANCELLED_CUSTOMER = true,
    CANCELLED_DRIVER = true,
    FAILED = true,
}

-- Why an accepted ride was released. Statistics semantics depend on this, so the
-- set is closed and explicit:
--
--   manual_driver_cancel - the driver chose to abandon the order. The ONLY origin
--                          that counts against the driver's cancellation record
--                          and the only one that creates the hidden pair
--                          cooldown.
--   driver_disconnect    - connection lost (crash, alt-F4, timeout). Not the
--                          driver's fault, so it must not affect performance
--                          statistics or matchmaking.
--   driver_fired         - a CEO ended the driver's registration mid-ride.
--   server_failure       - the resource/server stopped; recovered on next start.
--
-- Rematching behaviour is identical for every origin: the customer's request is
-- never lost and reopens on the same ride.
M.CANCEL_ORIGINS = {
    manual_driver_cancel = true,
    driver_disconnect = true,
    driver_fired = true,
    server_failure = true,
}

---The one origin that is a voluntary act by the driver.
M.VOLUNTARY_CANCEL_ORIGIN = 'manual_driver_cancel'

---Only a voluntary driver cancellation may touch cancellation performance
---statistics or create the hidden driver <-> customer cooldown.
---@param origin string
---@return boolean voluntary
function M.IsVoluntaryCancel(origin)
    return origin == M.VOLUNTARY_CANCEL_ORIGIN
end

-- Strict transition table. Every status change in the resource goes through
-- SetStatus, so no code path (and no client) can jump straight to COMPLETED.
-- A driver who abandons the ride before pickup returns it to SEARCHING (the
-- request reopens unchanged), which is why SEARCHING is reachable from the
-- pre-pickup states as well.
local ALLOWED_TRANSITIONS = {
    SEARCHING = { ACCEPTED = true, CANCELLED_CUSTOMER = true, FAILED = true },
    ACCEPTED = { SEARCHING = true, DRIVER_ENROUTE = true, CANCELLED_CUSTOMER = true, CANCELLED_DRIVER = true, FAILED = true },
    DRIVER_ENROUTE = { SEARCHING = true, DRIVER_ARRIVED = true, CANCELLED_CUSTOMER = true, CANCELLED_DRIVER = true, FAILED = true },
    DRIVER_ARRIVED = { SEARCHING = true, PASSENGER_ONBOARD = true, CANCELLED_CUSTOMER = true, CANCELLED_DRIVER = true, FAILED = true },
    PASSENGER_ONBOARD = { SEARCHING = true, ENROUTE_DESTINATION = true, CANCELLED_CUSTOMER = true, CANCELLED_DRIVER = true, FAILED = true },
    ENROUTE_DESTINATION = { SEARCHING = true, COMPLETED = true, CANCELLED_CUSTOMER = true, CANCELLED_DRIVER = true, FAILED = true },
    COMPLETED = {},
    CANCELLED_CUSTOMER = {},
    CANCELLED_DRIVER = {},
    FAILED = {},
}

-- Runtime ride fields added in Phase 3C:
--   paymentStatus = 'pending' | 'processing' | 'paid'  (mirrors the DB row)
--   paymentFailed = true while the last completion attempt failed on money
-- Driver proximity radii for the state-changing actions (server-side ped checks,
-- evaluated only when the action is attempted - never per frame).

-- Runtime state --------------------------------------------------------------

M.ActiveRides = {}        -- [rideId]   = ride
M.CustomerActiveRide = {} -- [citizenid] = rideId
M.DriverActiveRide = {}   -- [citizenid] = rideId
M.RideLocks = {}          -- [rideId] = true while one lifecycle mutation owns it

local rideSequence = 0

-- Live driver-position stream (customer marker). One timer per ASSIGNED ride,
-- 2.5 s tick, destroyed the moment the ride stops being active.
local driverLocationTimers = {} -- [rideId] = timer handle

---Terminal states never accept more changes.
---@param status string
---@return boolean
function M.IsTerminal(status)
    return TERMINAL[status] == true
end

---Run one lifecycle mutation without waiting. The lock is always released.
function M.WithRideLock(rideId, fn)
    if M.RideLocks[rideId] then return false, 'ride_busy' end
    M.RideLocks[rideId] = true
    local result = table.pack(xpcall(fn, debug.traceback))
    M.RideLocks[rideId] = nil
    if not result[1] then
        print(('[ojol] lifecycle error for ride %s: %s'):format(tostring(rideId), tostring(result[2])))
        return false, 'internal_error'
    end
    return table.unpack(result, 2, result.n)
end

---Validated status change.
---@param ride table
---@param status string
---@return boolean ok, string? reason
function M.SetStatus(ride, status)
    local allowed = ALLOWED_TRANSITIONS[ride.status]
    if not allowed or not allowed[status] then
        print(('[ojol] rejected illegal ride transition %s -> %s (%s)'):format(
            tostring(ride.status), tostring(status), tostring(ride.rideId)))
        return false, 'invalid_transition'
    end

    ride.status = status
    return true
end

-- ---------------------------------------------------------------------------

---Unique, sortable, human-readable ride id.
---@return string
local function newRideId()
    rideSequence = rideSequence + 1
    return ('%d%04d'):format(os.time(), rideSequence % 10000)
end

---Map position sanity: finite numbers inside the GTA V world bounds.
---@param point any
---@return boolean
local function isSanePoint(point)
    if type(point) ~= 'table' and type(point) ~= 'vector3' then return false end

    local x, y, z = tonumber(point.x), tonumber(point.y), tonumber(point.z)
    if not x or not y or not z then return false end

    -- Reject NaN/inf and anything far outside the playable map.
    if x ~= x or y ~= y or z ~= z then return false end
    if math.abs(x) > 10000.0 or math.abs(y) > 10000.0 or z < -500.0 or z > 5000.0 then return false end

    -- (0,0,0) is the classic "client sent nothing" payload.
    if x == 0.0 and y == 0.0 and z == 0.0 then return false end

    return true
end

local function toPoint(point)
    return { x = point.x + 0.0, y = point.y + 0.0, z = point.z + 0.0 }
end

---Horizontal distance. Pickup snapping is judged on the map plane, so a customer
---on a roof still snaps to the street underneath.
---@param a table|vector3
---@param b table|vector3
---@return number metres
local function horizontalDistance(a, b)
    local dx = (a.x or 0.0) - (b.x or 0.0)
    local dy = (a.y or 0.0) - (b.y or 0.0)
    return math.sqrt(dx * dx + dy * dy)
end

M.IsSanePoint = isSanePoint
M.HorizontalDistance = horizontalDistance

---Resolve the pickup point. The client may propose the road-snapped position it
---computed (CfxLua has no server-side road nodes), but it must sit next to the
---position the server itself sees for that player - so a client can never move
---its pickup somewhere else on the map. An unusable proposal falls back to the
---real ped position rather than failing the request.
---@param customerCitizenid string
---@param proposed any
---@return table? pickup, string? reason
local function resolvePickup(customerCitizenid, proposed)
    local pedCoords = drivers.GetPlayerCoordsByCitizenid(customerCitizenid)
    if not pedCoords then return nil, 'invalid_customer' end

    if not isSanePoint(proposed) then
        return { x = pedCoords.x + 0.0, y = pedCoords.y + 0.0, z = pedCoords.z + 0.0 }
    end

    if horizontalDistance(proposed, pedCoords) > sharedConfig.maxPickupSnapMeters then
        return nil, 'invalid_pickup'
    end

    return toPoint(proposed)
end

---Validate a destination and build the quote the customer app displays.
---The fare returned here is the same value CreateRide locks in.
---@param customerCitizenid string
---@param pickup any
---@param destination any
---@return boolean ok, table|string quoteOrReason
function M.BuildCustomerQuote(customerCitizenid, pickup, destination)
    if M.CustomerActiveRide[customerCitizenid] then return false, 'already_active' end
    if not isSanePoint(destination) then return false, 'invalid_destination' end

    local resolved, reason = resolvePickup(customerCitizenid, pickup)
    if not resolved then return false, reason end

    local quote = fares.BuildQuote(resolved, destination)
    if quote.distanceMeters < serverConfig.minRideDistanceMeters then return false, 'too_close' end
    if quote.distanceMeters > serverConfig.maxRideDistanceMeters then return false, 'too_far' end

    return true, {
        pickup = resolved,
        destination = toPoint(destination),
        distanceMeters = quote.distanceMeters,
        fare = quote.fare,
        fareText = fares.FormatRupiah(quote.fare),
        driverPayout = quote.driverPayout,
        driverPayoutText = fares.FormatRupiah(quote.driverPayout),
        companyFee = quote.companyFee,
    }
end

-- Lookups --------------------------------------------------------------------

---@param rideId string|nil
---@return table? ride
function M.GetRide(rideId)
    return rideId and M.ActiveRides[rideId] or nil
end

---@param citizenid string
---@return table? ride
function M.GetCustomerRide(citizenid)
    return M.GetRide(citizenid and M.CustomerActiveRide[citizenid] or nil)
end

---@param citizenid string
---@return table? ride
function M.GetDriverRide(citizenid)
    return M.GetRide(citizenid and M.DriverActiveRide[citizenid] or nil)
end

-- Client-facing views --------------------------------------------------------

---Ride payload for the customer app. Contains no citizenid and no database id.
---@param ride table
---@return table
local function buildCustomerView(ride)
    local view = {
        rideId = ride.rideId,
        status = ride.status,
        terminal = TERMINAL[ride.status] == true,
        paymentFailed = ride.paymentFailed == true,
        paymentStatus = ride.paymentStatus,
        rated = ride.rated == true,
        pickup = { x = ride.pickup.x, y = ride.pickup.y, z = ride.pickup.z },
        destination = { x = ride.destination.x, y = ride.destination.y, z = ride.destination.z },
        distanceMeters = ride.distanceMeters,
        fare = ride.fare,
        fareText = fares.FormatRupiah(ride.fare),
        paymentMethod = ride.paymentMethod,
        createdAt = ride.createdAt,
        driver = nil,
    }

    if ride.driverCitizenId then
        local snapshot = drivers.GetDriverStateSnapshot(ride.driverCitizenId)
        view.driver = {
            name = drivers.GetDisplayName(ride.driverCitizenId),
            profilePhoto = snapshot.profilePhoto,
            rating = snapshot.rating,
            rank = snapshot.rank,
        }
    end

    return view
end

---Ride payload for the assigned driver. Public fields only.
---@param ride table
---@return table
function M.BuildDriverRideView(ride)
    return {
        rideId = ride.rideId,
        status = ride.status,
        terminal = TERMINAL[ride.status] == true,
        paymentFailed = ride.paymentFailed == true,
        payoutReceived = ride.payoutReceived,
        customerName = drivers.GetDisplayName(ride.customerCitizenid),
        pickup = { x = ride.pickup.x, y = ride.pickup.y, z = ride.pickup.z },
        destination = { x = ride.destination.x, y = ride.destination.y, z = ride.destination.z },
        distanceMeters = ride.distanceMeters,
        fare = ride.fare,
        fareText = fares.FormatRupiah(ride.fare),
        driverPayout = ride.driverPayout,
        driverPayoutText = fares.FormatRupiah(ride.driverPayout),
        companyFee = ride.companyFee,
        paymentMethod = ride.paymentMethod,
    }
end

local function pushToCustomer(ride)
    local src = drivers.SourceByCitizenid[ride.customerCitizenid]
    if not src then return end

    TriggerClientEvent('lifestate_ojol:client:customerRideChanged', src, buildCustomerView(ride))
end

---Push the ride leg to its assigned driver (offer handling lives in matching).
---@param ride table
local function pushToDriver(ride)
    if not ride.driverCitizenId then return end

    local src = drivers.SourceByCitizenid[ride.driverCitizenId]
    if not src then return end

    TriggerClientEvent('lifestate_ojol:client:driverRideChanged', src, M.BuildDriverRideView(ride))
end

---Push the current state of a ride to both sides.
---@param ride table
function M.PushRideState(ride)
    pushToCustomer(ride)
    pushToDriver(ride)
end

---Customer view for the NPWD app (nil when there is no live ride). A ride that
---is already rated is reported so the app can show COMPLETED_RATED instead of
---prompting for a second rating after a phone reopen.
---@param citizenid string
---@return table? view
function M.GetCustomerView(citizenid)
    local ride = M.GetCustomerRide(citizenid)
    if not ride then
        local ok, row = pcall(db.FetchLatestCompletedUnrated, citizenid)
        if not ok or not row then return nil end
        local snapshot = row.driver_citizenid and drivers.GetDriverStateSnapshot(row.driver_citizenid) or {}
        return {
            rideId = row.ride_id, status = M.STATES.COMPLETED, terminal = true,
            paymentFailed = false, paymentStatus = row.payment_status, rated = false,
            pickup = { x = row.pickup_x, y = row.pickup_y, z = row.pickup_z },
            destination = { x = row.destination_x, y = row.destination_y, z = row.destination_z },
            distanceMeters = row.distance_meters, fare = row.fare,
            fareText = fares.FormatRupiah(row.fare), paymentMethod = row.payment_method,
            createdAt = row.created_at,
            driver = row.driver_citizenid and {
                name = drivers.GetDisplayName(row.driver_citizenid), profilePhoto = snapshot.profilePhoto,
                rating = snapshot.rating, rank = snapshot.rank,
            } or nil,
        }
    end

    if ride.status == M.STATES.COMPLETED and ride.rated == nil then
        local ratedOk, rating = pcall(db.FetchRating, ride.rideId)
        ride.rated = ratedOk and rating ~= nil or false
    end

    return buildCustomerView(ride)
end

-- Driver-location stream (customer marker) -----------------------------------

-- One re-arming timer per ASSIGNED ride (~2.5 s), started on assignment and
-- killed the moment the ride stops being active. A generation counter per ride
-- makes stale ticks harmless after a cancel/reassign, so nothing can resurrect
-- a stream for a ride that already ended.
local streamGenerations = {} -- [rideId] = number

---Kill the live driver marker for a ride (idempotent).
---@param rideId string
local function stopDriverLocationStream(rideId)
    -- Bump the generation: any in-flight tick sees the mismatch and dies
    -- instead of re-arming.
    streamGenerations[rideId] = (streamGenerations[rideId] or 0) + 1
    driverLocationTimers[rideId] = nil
end

---Start streaming the assigned driver's position to the customer.
---@param ride table
local function startDriverLocationStream(ride)
    stopDriverLocationStream(ride.rideId)

    local generation = streamGenerations[ride.rideId]
    local driverCitizenid = ride.driverCitizenId

    local function tick()
        if streamGenerations[ride.rideId] ~= generation then return end

        local live = M.GetRide(ride.rideId)
        if not live or live.driverCitizenId ~= driverCitizenid
            or live.status == M.STATES.SEARCHING or M.IsTerminal(live.status) then
            streamGenerations[ride.rideId] = nil
            driverLocationTimers[ride.rideId] = nil
            return
        end

        local coords = drivers.GetPlayerCoordsByCitizenid(driverCitizenid)
        local src = coords and drivers.SourceByCitizenid[live.customerCitizenid] or nil
        if src then
            TriggerClientEvent('lifestate_ojol:client:driverLocation', src,
                { x = coords.x, y = coords.y, z = coords.z })
        end

        driverLocationTimers[ride.rideId] = SetTimeout(serverConfig.driverLocationStreamMs, tick)
    end

    driverLocationTimers[ride.rideId] = SetTimeout(serverConfig.driverLocationStreamMs, tick)
end

M.StopDriverLocationStream = stopDriverLocationStream

---Stop every stream (resource stop).
function M.ShutdownStreams()
    for rideId in pairs(driverLocationTimers) do
        stopDriverLocationStream(rideId)
    end
end

-- Lifecycle ------------------------------------------------------------------

---Release the runtime slots held by a ride and tell matching to stop looking.
---@param ride table
local function detach(ride)
    M.CustomerActiveRide[ride.customerCitizenid] = nil

    if ride.driverCitizenId then
        M.DriverActiveRide[ride.driverCitizenId] = nil
        drivers.BusyDrivers[ride.driverCitizenId] = nil
    end

    stopDriverLocationStream(ride.rideId)
    M.ActiveRides[ride.rideId] = nil
end

---Close a ride in a terminal state: persist, notify both sides and free the
---driver for other work.
---@param ride table
---@param status string terminal status
---@return boolean ok
function M.TerminalizeRide(ride, status)
    if not ride or not ride.rideId or not TERMINAL[status] then return false, 'invalid_terminal_state' end
    if M.IsTerminal(ride.status) then return ride.status == status, ride.status end

    local allowed = ALLOWED_TRANSITIONS[ride.status]
    if not allowed or not allowed[status] then return false, 'invalid_transition' end

    if status == M.STATES.COMPLETED then
        local paidOk, paid = pcall(db.IsFareLedgerPaid, ride.rideId)
        if not paidOk then return false, 'database_error' end
        if not paid then return false, 'fare_not_paid' end
    end

    local persisted, affected = pcall(db.FinalizeRide, ride, status)
    if not persisted then return false, 'database_error' end
    if affected == false or affected == nil or affected == 0 then return false, 'already_finalized' end

    local previousDriver = ride.driverCitizenId
    ride.status = status
    pushToCustomer(ride)
    if previousDriver then pushToDriver(ride) end
    TriggerEvent('lifestate_ojol:server:rideClosed', ride, status)
    detach(ride)

    if previousDriver then
        local previousDriverSource = drivers.SourceByCitizenid[previousDriver]
        if previousDriverSource then
            TriggerClientEvent('lifestate_ojol:client:driverRideChanged', previousDriverSource, nil)
        end
        TriggerEvent('lifestate_ojol:server:driverAvailabilityChanged', previousDriver,
            drivers.IsDriverOnline(previousDriver))
    end
    return true, status
end

local function closeRide(ride, status) return M.TerminalizeRide(ride, status) end

---Compensation eligibility for a customer cancellation. Server-side only:
---elapsed time plus real ped movement towards the pickup. Phase 3B records the
---eligibility on the ride; the Rp5.000 transfer itself is Phase 3C, because no
---money may move before ride completion exists.
---@param ride table
---@return boolean eligible
local function evaluateCompensation(ride)
    if not ride.driverCitizenId or not ride.acceptedAt then return false end

    local elapsed = os.time() - ride.acceptedAt
    if elapsed < serverConfig.cancelCompensationAfterSeconds then return false end

    local startedAt = ride.driverDistanceToPickupAtAccept
    if not startedAt then return false end

    local coords = drivers.GetPlayerCoordsByCitizenid(ride.driverCitizenId)
    if not coords then return false end

    local closed = startedAt - fares.StraightLineMeters(coords, ride.pickup)
    return closed >= serverConfig.cancelCompensationMinMovementMeters
end

---Create a ride request. All values are computed here; the client only proposes
---a destination and a snapped pickup point.
---@param customerCitizenid string
---@param pickup table
---@param destination table
---@param paymentMethod string 'cash' | 'bank'
---@return boolean ok, table|string rideOrReason
function M.CreateRide(customerCitizenid, pickup, destination, paymentMethod)
    if type(customerCitizenid) ~= 'string' or customerCitizenid == '' then
        return false, 'invalid_customer'
    end

    if M.CustomerActiveRide[customerCitizenid] then return false, 'already_active' end

    if paymentMethod ~= 'cash' and paymentMethod ~= 'bank' then return false, 'invalid_payment' end

    if not isSanePoint(destination) then return false, 'invalid_destination' end

    -- Same pickup validation path the preview quote uses.
    local resolvedPickup, pickupReason = resolvePickup(customerCitizenid, pickup)
    if not resolvedPickup then return false, pickupReason end

    local quote = fares.BuildQuote(resolvedPickup, destination)
    if quote.distanceMeters < serverConfig.minRideDistanceMeters then return false, 'too_close' end
    if quote.distanceMeters > serverConfig.maxRideDistanceMeters then return false, 'too_far' end

    -- Balance is verified at request time; nothing is deducted (Phase 3C charges
    -- the fare on completion).
    local player = exports.qbx_core:GetPlayerByCitizenId(customerCitizenid)
    local money = player and player.PlayerData and player.PlayerData.money
    local balance = tonumber(money and money[paymentMethod]) or 0
    if balance < quote.fare then return false, 'insufficient_funds' end

    local ride = {
        rideId = newRideId(),
        customerCitizenid = customerCitizenid,
        driverCitizenId = nil,
        pickup = resolvedPickup,
        destination = toPoint(destination),
        distanceMeters = quote.distanceMeters,
        fare = quote.fare,
        driverPayout = quote.driverPayout,
        companyFee = quote.companyFee,
        paymentMethod = paymentMethod,
        status = M.STATES.SEARCHING,
        paymentStatus = 'pending',
        paymentFailed = false,
        createdAt = os.time(),
        acceptedAt = nil,
        completedAt = nil,
        cancelledAt = nil,
        acceptLock = false,
        driverDistanceToPickupAtAccept = nil,
        compensationEligible = false,
    }

    local inserted = pcall(db.InsertRide, ride)
    if not inserted then
        print(('[ojol] failed to persist ride request for %s'):format(tostring(customerCitizenid)))
        return false, 'database_error'
    end

    M.ActiveRides[ride.rideId] = ride
    M.CustomerActiveRide[customerCitizenid] = ride.rideId

    TriggerEvent('lifestate_ojol:server:rideSearching', ride)
    M.PushRideState(ride)

    return true, ride
end

---Atomic acceptance. Called by matching after it has checked eligibility; every
---precondition is re-checked here, inside the per-ride accept lock, so two
---simultaneous accepts can never both win.
---@param rideId string
---@param driverCitizenid string
---@return boolean ok, string? reason
function M.TryAcceptRide(rideId, driverCitizenid)
    local ride = M.GetRide(rideId)
    if not ride then return false, 'ride_not_found' end
    if ride.status ~= M.STATES.SEARCHING then return false, 'order_already_taken' end
    if ride.acceptLock then return false, 'order_already_taken' end

    ride.acceptLock = true

    local assigned = false
    local reason = 'order_already_taken'

    if ride.status ~= M.STATES.SEARCHING then
        reason = 'order_already_taken'
    elseif ride.customerCitizenid == driverCitizenid then
        reason = 'invalid_driver'
    elseif M.DriverActiveRide[driverCitizenid] then
        reason = 'driver_busy'
    elseif not drivers.IsRegisteredDriver(driverCitizenid) then
        reason = 'not_registered'
    elseif not drivers.IsDriverOnline(driverCitizenid) then
        reason = 'offline'
    elseif not drivers.SourceByCitizenid[driverCitizenid] then
        reason = 'offline'
    else
        ride.driverCitizenId = driverCitizenid
        ride.acceptedAt = os.time()
        ride.compensationEligible = false

        local coords = drivers.GetPlayerCoordsByCitizenid(driverCitizenid)
        ride.driverDistanceToPickupAtAccept = coords and fares.StraightLineMeters(coords, ride.pickup) or nil

        M.DriverActiveRide[driverCitizenid] = ride.rideId
        drivers.BusyDrivers[driverCitizenid] = true

        assigned = M.SetStatus(ride, M.STATES.ACCEPTED)
        if not assigned then reason = 'invalid_transition' end
    end

    ride.acceptLock = false

    if not assigned then return false, reason end

    local persisted = pcall(db.AcceptRide, ride.rideId, driverCitizenid, ride.acceptedAt)
    if not persisted then
        print(('[ojol] failed to persist driver assignment for ride %s'):format(tostring(ride.rideId)))
    end

    M.SetStatus(ride, M.STATES.DRIVER_ENROUTE)

    startDriverLocationStream(ride)

    TriggerEvent('lifestate_ojol:server:rideAssigned', ride)
    M.PushRideState(ride)

    return true
end

---Customer cancellation. Always free for the customer (fee is Rp0); a driver who
---already made meaningful progress becomes eligible for the once-only Rp5.000
---company compensation (paid to the driver's bank here - Phase 3C moved the
---money transfer in).
---@param customerCitizenid string
---@return boolean ok, string? reason, table? ride
local function customerCancelUnlocked(customerCitizenid)
    local ride = M.GetCustomerRide(customerCitizenid)
    if not ride then return false, 'no_ride' end

    if ride.driverCitizenId then
        ride.compensationEligible = evaluateCompensation(ride)
    end

    closeRide(ride, M.STATES.CANCELLED_CUSTOMER)

    if ride.compensationEligible then
        -- Idempotent: the persisted compensation_paid flag guards replays.
        payments.PayCompensation(ride)
    end

    return true, nil, ride
end

function M.CustomerCancel(customerCitizenid)
    local ride = M.GetCustomerRide(customerCitizenid)
    if not ride then return false, 'no_ride' end
    return M.WithRideLock(ride.rideId, function() return customerCancelUnlocked(customerCitizenid) end)
end

---Driver releases an accepted ride, for any reason. Before pickup the ride
---returns to SEARCHING unchanged (same id, pickup, destination, fare, payment
---method) and matching restarts - rematching is identical for every origin.
---
---Statistics semantics are NOT identical: only a voluntary cancellation
---(`manual_driver_cancel`) increments the driver's cancel counters and creates
---the hidden pair cooldown. A disconnect, a firing or a server failure must never
---damage a driver's performance record or block them from a customer afterwards.
---
---@param driverCitizenid string
---@param origin string one of M.CANCEL_ORIGINS
---@return boolean ok, string? reason
local function driverCancelUnlocked(driverCitizenid, origin)
    local ride = M.GetDriverRide(driverCitizenid)
    if not ride then return false, 'no_ride' end

    if origin and not M.CANCEL_ORIGINS[origin] then
        print(('[ojol] unknown ride cancel origin %s for ride %s'):format(tostring(origin), tostring(ride.rideId)))
    end

    local voluntary = M.IsVoluntaryCancel(origin)

    local previousDriverSource = drivers.SourceByCitizenid[driverCitizenid]
    M.DriverActiveRide[driverCitizenid] = nil
    drivers.BusyDrivers[driverCitizenid] = nil

    local beforePickup = ride.status == M.STATES.ACCEPTED
        or ride.status == M.STATES.DRIVER_ENROUTE
        or ride.status == M.STATES.DRIVER_ARRIVED

    if voluntary then
        -- Hidden 5-minute driver <-> customer cooldown (matching owns it) and the
        -- driver's cancel statistic. Neither is ever shown to a player, and both
        -- are the driver's own doing - so they only apply to a voluntary cancel.
        TriggerEvent('lifestate_ojol:server:driverCancelledRide', driverCitizenid, ride.customerCitizenid, origin)

        local statColumn = beforePickup and 'cancelled_before_pickup' or 'cancelled_after_pickup'
        local recorded = pcall(db.IncrementDriverStat, driverCitizenid, statColumn, 1)
        if not recorded then
            print(('[ojol] failed to record %s for %s'):format(statColumn, tostring(driverCitizenid)))
        end
    end

    if not beforePickup then
        -- After-pickup abandon (Phase 3C): the passenger is already with the
        -- driver, so the ride must NOT die - the customer is reopened with a
        -- fresh pickup at their current position and a recalculated fare for
        -- the remaining route. The original destination never changes.
        local reopened, reopenReason = M.ReopenRideAfterAbandon(ride)
        if previousDriverSource then
            TriggerClientEvent('lifestate_ojol:client:driverRideChanged', previousDriverSource, nil)
        end
        TriggerEvent('lifestate_ojol:server:driverAvailabilityChanged', driverCitizenid,
            drivers.IsDriverOnline(driverCitizenid))
        return reopened, reopenReason
    end

    -- Back to SEARCHING on the same ride.
    ride.driverCitizenId = nil
    ride.acceptedAt = nil
    ride.driverDistanceToPickupAtAccept = nil
    ride.compensationEligible = false

    local ok = M.SetStatus(ride, M.STATES.SEARCHING)
    if not ok then
        closeRide(ride, M.STATES.FAILED)
        return false, 'invalid_transition'
    end

    local persisted = pcall(db.ReopenRide, ride.rideId)
    if not persisted then
        print(('[ojol] failed to reopen ride %s'):format(tostring(ride.rideId)))
    end

    -- Fresh search from tier 1 for the reopened request.
    TriggerEvent('lifestate_ojol:server:rideSearching', ride)
    M.PushRideState(ride)
    if previousDriverSource then
        TriggerClientEvent('lifestate_ojol:client:driverRideChanged', previousDriverSource, nil)
    end
    TriggerEvent('lifestate_ojol:server:driverAvailabilityChanged', driverCitizenid,
        drivers.IsDriverOnline(driverCitizenid))

    return true
end

function M.DriverCancel(driverCitizenid, origin)
    local ride = M.GetDriverRide(driverCitizenid)
    if not ride then return false, 'no_ride' end
    return M.WithRideLock(ride.rideId, function() return driverCancelUnlocked(driverCitizenid, origin) end)
end

-- In-trip transitions (Phase 3C) --------------------------------------------

---Shared validation for every in-trip driver action.
---@param driverCitizenid string
---@param rideId string|nil
---@return table? ride, string? reason
local function getOwnedRideInState(driverCitizenid, rideId, state)
    if type(rideId) ~= 'string' then return nil, 'invalid_ride' end

    local ride = M.GetRide(rideId)
    if not ride then return nil, 'ride_not_found' end
    if ride.driverCitizenId ~= driverCitizenid then return nil, 'not_ride_owner' end
    if ride.status ~= state then return nil, 'wrong_state' end

    -- The driver must still be a connected, registered, online driver.
    if not drivers.SourceByCitizenid[driverCitizenid] then return nil, 'offline' end
    if not drivers.IsRegisteredDriver(driverCitizenid) then return nil, 'not_registered' end
    if not drivers.IsDriverOnline(driverCitizenid) then return nil, 'offline' end

    -- The customer must still be connected (their identity resolves to a source).
    if not drivers.SourceByCitizenid[ride.customerCitizenid] then return nil, 'customer_offline' end

    return ride
end

---Driver says SAYA SUDAH SAMPAI. Requires DRIVER_ENROUTE + the real server ped
---within the configured radius of the locked pickup. The client never supplies
---coordinates; distance is computed from the peds the server sees.
---@param driverCitizenid string
---@param rideId string
---@return boolean ok, string? reason
function M.DriverArrived(driverCitizenid, rideId)
    local ride, reason = getOwnedRideInState(driverCitizenid, rideId, M.STATES.DRIVER_ENROUTE)
    if not ride then return false, reason end

    local coords = drivers.GetPlayerCoordsByCitizenid(driverCitizenid)
    if not coords then return false, 'offline' end

    if fares.StraightLineMeters(coords, ride.pickup) > serverConfig.arrivalRadiusMeters then
        return false, 'too_far_from_pickup'
    end

    if not M.SetStatus(ride, M.STATES.DRIVER_ARRIVED) then return false, 'invalid_transition' end

    M.PushRideState(ride)
    return true
end

---Boarding validation: customer must be inside the driver's tracked Ojol bike,
---or (fallback) within a very small radius of it. Primary requirement is the
---same-vehicle check because the server can verify it authoritatively.
---@param ride table
---@param driverCoords vector3
---@return boolean ok, string? reason
local function validateBoarding(ride, driverCoords)
    local customerCoords = drivers.GetPlayerCoordsByCitizenid(ride.customerCitizenid)
    if not customerCoords then return false, 'customer_offline' end

    local hasBike, bikeNetId = bikes.HasValidBike(ride.driverCitizenId)
    if hasBike and bikeNetId then
        local okVeh, veh = pcall(NetworkGetEntityFromNetworkId, bikeNetId)
        if okVeh and veh and veh ~= 0 and DoesEntityExist(veh) then
            -- Primary: the customer ped is seated in the tracked bike.
            local okSeat, seated = pcall(GetPedInVehicleSeat, veh, 0)
            if okSeat and seated and seated ~= 0 and seated == GetPlayerPed(drivers.SourceByCitizenid[ride.customerCitizenid]) then
                return true
            end

            -- Fallback: within 8 m of the bike itself (boarding animation).
            if fares.StraightLineMeters(customerCoords, GetEntityCoords(veh)) <= serverConfig.boardingRadiusMeters then
                return true
            end

            return false, 'customer_not_on_bike'
        end
    end

    -- No tracked bike (spawned elsewhere/deleted): strict ped proximity only.
    if fares.StraightLineMeters(customerCoords, driverCoords) <= serverConfig.boardingRadiusMeters then
        return true
    end

    return false, 'customer_not_near'
end

---Driver confirms PENUMPANG SUDAH NAIK. DRIVER_ARRIVED only; validated by
---same-vehicle or tight proximity. PASSENGER_ONBOARD and ENROUTE_DESTINATION
---are applied atomically - no gameplay happens between them in this phase.
---@param driverCitizenid string
---@param rideId string
---@return boolean ok, string? reason
function M.PassengerBoarded(driverCitizenid, rideId)
    local ride, reason = getOwnedRideInState(driverCitizenid, rideId, M.STATES.DRIVER_ARRIVED)
    if not ride then return false, reason end

    local driverCoords = drivers.GetPlayerCoordsByCitizenid(driverCitizenid)
    if not driverCoords then return false, 'offline' end

    local boardingOk, boardingReason = validateBoarding(ride, driverCoords)
    if not boardingOk then return false, boardingReason end

    if not M.SetStatus(ride, M.STATES.PASSENGER_ONBOARD) then return false, 'invalid_transition' end
    if not M.SetStatus(ride, M.STATES.ENROUTE_DESTINATION) then
        closeRide(ride, M.STATES.FAILED)
        return false, 'invalid_transition'
    end

    -- The pickup leg is over: the driver's client swaps its route to the
    -- destination on this push (the event carries the new status).
    M.PushRideState(ride)
    return true
end

---Driver says SELESAIKAN PERJALANAN. ENROUTE_DESTINATION only; the real driver
---ped must be within the destination radius, the customer must still be
---connected and (soft check) still near the driver. Payment runs BEFORE the
---ride is allowed to complete - an unpaid ride never becomes COMPLETED.
---@param driverCitizenid string
---@param rideId string
---@return boolean ok, string? reason
local function tryCompleteRideUnlocked(driverCitizenid, rideId)
    local ride, reason = getOwnedRideInState(driverCitizenid, rideId, M.STATES.ENROUTE_DESTINATION)
    if not ride then return false, reason end

    local driverCoords = drivers.GetPlayerCoordsByCitizenid(driverCitizenid)
    if not driverCoords then return false, 'offline' end

    if fares.StraightLineMeters(driverCoords, ride.destination) > serverConfig.destinationRadiusMeters then
        return false, 'too_far_from_destination'
    end

    -- Soft same-vehicle/proximity re-check: the passenger should still be with
    -- the driver at arrival. The fare is owed regardless; this is anti-abuse
    -- (a driver "completing" an empty bike far from the customer).
    local boardingOk = validateBoarding(ride, driverCoords)
    if not boardingOk then return false, 'customer_not_near' end

    ride.paymentFailed = false

    local paid, payReason = payments.PayRide(ride)
    if not paid then
        if payReason == 'already_paid_or_processing' then
            -- A previous attempt already moved the money (e.g. a restart after
            -- the DB write). Do not charge again; close the ride as completed.
            local alreadyOk, alreadyPaid = pcall(function()
                local row = db.FetchCompletedRide(ride.rideId)
                return row ~= nil
            end)
            if alreadyOk and alreadyPaid then
                return M.finalizeCompletion(ride)
            end
            return false, 'payment_in_progress'
        end

        if payReason == 'insufficient_funds' then
            -- Deterministic V1: the ride stays alive, the customer must top up
            -- or switch payment method. Nothing completed, nothing charged.
            ride.paymentFailed = true
            M.PushRideState(ride)
            return false, 'insufficient_funds'
        end

        return false, payReason or 'payment_failed'
    end

    ride.payoutReceived = ride.driverPayout
    return M.finalizeCompletion(ride)
end

function M.TryCompleteRide(driverCitizenid, rideId)
    if type(rideId) ~= 'string' then return false, 'invalid_ride' end
    return M.WithRideLock(rideId, function() return tryCompleteRideUnlocked(driverCitizenid, rideId) end)
end

---Shared completion tail: state, stats, persistence, availability.
---@param ride table
---@return boolean ok
function M.finalizeCompletion(ride)
    ride.paymentFailed = false
    ride.payoutReceived = ride.driverPayout
    return M.TerminalizeRide(ride, M.STATES.COMPLETED)
end

---Customer switches the payment method (cash <-> bank) while the ride is alive.
---Allowed in every pre-completion assigned state; the locked fare never changes.
---@param customerCitizenid string
---@param method string
---@return boolean ok, string? reason
function M.CustomerChangePayment(customerCitizenid, method)
    local ride = M.GetCustomerRide(customerCitizenid)
    if not ride then return false, 'no_ride' end
    if M.IsTerminal(ride.status) then return false, 'no_ride' end
    if ride.status == M.STATES.SEARCHING then
        -- Nothing is assigned yet; a plain create with the other method is the flow.
        return false, 'wrong_state'
    end

    return payments.ChangePaymentMethod(ride, method, customerCitizenid)
end

---Customer rates a completed ride (1..5, once, own ride only). Works across
---restarts: the ride row is fetched from the database, not runtime memory.
---@param customerCitizenid string
---@param rideId string
---@param rating any
---@return boolean ok, string? reason
function M.SubmitRating(customerCitizenid, rideId, rating)
    if type(rideId) ~= 'string' then return false, 'invalid_ride' end
    if type(rating) ~= 'number' or math.floor(rating) ~= rating or rating < 1 or rating > 5 then
        return false, 'invalid_rating'
    end

    local rideRow = select(2, pcall(db.FetchCompletedRide, rideId))
    if not rideRow then return false, 'ride_not_found' end
    if rideRow.customer_citizenid ~= customerCitizenid then return false, 'not_ride_owner' end

    local driverCitizenid = rideRow.driver_citizenid
    if not driverCitizenid then return false, 'ride_not_found' end

    local existingOk, existing = pcall(db.FetchRating, rideId)
    if existingOk and existing ~= nil then return false, 'already_rated' end

    local transactionOk, committed = pcall(db.SubmitRatingTransaction,
        rideId, driverCitizenid, customerCitizenid, rating)
    if not transactionOk or not committed then
        local ratedOk, saved = pcall(db.FetchRating, rideId)
        return false, ratedOk and saved ~= nil and 'already_rated' or 'database_error'
    end

    local ride = M.GetRide(rideId)
    if ride then ride.rated = true end

    return true
end

---After-pickup abandon recovery. The customer's ride reopens from their
---current position: a new pickup is snapped from the server-side ped (the
---client-supplied road snap is not trusted here), the fare/distance/split are
---recalculated for the remaining route, the payment method is kept, and the
---driver slot is freed. Origin semantics were already applied by DriverCancel.
---@param ride table
---@return boolean ok, string? reason
function M.ReopenRideAfterAbandon(ride)
    local customerCoords = drivers.GetPlayerCoordsByCitizenid(ride.customerCitizenid)
    if not customerCoords then
        -- Customer gone too (or mid-reconnect): nothing to reopen onto.
        closeRide(ride, M.STATES.CANCELLED_DRIVER)
        return true
    end

    local customerSource = drivers.SourceByCitizenid[ride.customerCitizenid]
    local callbackOk, proposed = pcall(function()
        return lib.callback.await('lifestate_ojol:client:getRoadPickup', customerSource)
    end)
    if not callbackOk or not isSanePoint(proposed)
        or horizontalDistance(proposed, customerCoords) > sharedConfig.maxPickupSnapMeters then
        closeRide(ride, M.STATES.FAILED)
        return false, 'unsafe_recovery_pickup'
    end

    local newPickup = toPoint(proposed)
    local quote = fares.BuildQuote(newPickup, ride.destination)

    ride.pickup = newPickup
    ride.distanceMeters = quote.distanceMeters
    ride.fare = quote.fare
    ride.driverPayout = quote.driverPayout
    ride.companyFee = quote.companyFee
    ride.driverCitizenId = nil
    ride.acceptedAt = nil
    ride.driverDistanceToPickupAtAccept = nil
    ride.compensationEligible = false
    ride.paymentFailed = false
    ride.payoutReceived = nil

    if not M.SetStatus(ride, M.STATES.SEARCHING) then
        closeRide(ride, M.STATES.FAILED)
        return false, 'invalid_transition'
    end

    local persisted = pcall(db.ReopenRideRecalculated, ride.rideId, ride)
    if not persisted then
        print(('[ojol] failed to persist recalculated reopen for ride %s'):format(tostring(ride.rideId)))
    end

    -- Fresh search from tier 1; the customer's app returns to MENCARI DRIVER
    -- automatically (no manual re-request).
    TriggerEvent('lifestate_ojol:server:rideSearching', ride)
    M.PushRideState(ride)

    return true
end

-- Disconnects / staff actions -------------------------------------------------

---A player dropped: finish (or reopen) whatever they were part of. Called before
---the connection mapping is cleared, so identity resolution still works.
---@param citizenid string
function M.HandlePlayerDropped(citizenid)
    if not citizenid then return end

    if M.DriverActiveRide[citizenid] then
        -- The customer's request safely reopens instead of being lost. A
        -- disconnect carries no fault, so it records no cancellation statistic
        -- and creates no pair cooldown.
        M.DriverCancel(citizenid, 'driver_disconnect')
    end

    if M.CustomerActiveRide[citizenid] then
        local ride = M.GetCustomerRide(citizenid)
        if ride then
            if ride.driverCitizenId then
                ride.compensationEligible = evaluateCompensation(ride)
            end
            closeRide(ride, M.STATES.CANCELLED_CUSTOMER)

            if ride.compensationEligible then
                -- The driver may himself be the one who dropped; the offline
                -- wallet path inside payments covers that (bank + persisted).
                payments.PayCompensation(ride)
            end
        end
    end
end

---A driver was fired: drop any accepted ride and reopen the customer's request.
---Firing is a staff action against the driver, not a voluntary abandon, so it
---records no cancellation statistic and creates no pair cooldown.
---@param citizenid string
function M.HandleDriverFired(citizenid)
    if M.DriverActiveRide[citizenid] then
        M.DriverCancel(citizenid, 'driver_fired')
    end
end

-- Conversation with matching --------------------------------------------------

-- Search bookkeeping belongs to matching; rides only announces intent.
AddEventHandler('lifestate_ojol:server:driverFired', function(citizenid)
    M.HandleDriverFired(citizenid)
end)

---Server-failure recovery ('server_failure' origin). Rides that were still live
---when the resource stopped have lost their runtime state, so the database is
---closed out as FAILED at startup. This deliberately touches no driver
---statistics and no cooldowns: an outage is not a driver's cancellation.
---A payment left 'processing' by the crash is NOT silently resolved - money may
---already have moved - it is only counted and reported for admin follow-up.
---@return number affectedRows
function M.RecoverOnStartup()
    local stuckOk, stuck = pcall(db.QuarantineInterruptedLedgers)
    if stuckOk and stuck and stuck > 0 then
        print(('[ojol] WARNING: %d ambiguous money ledger(s) quarantined for manual reconciliation'):format(stuck))
    end

    local finalizeOk, finalized = pcall(db.FinalizeAppliedFareLedgersOnStartup)
    if finalizeOk and finalized and finalized > 0 then
        print(('[ojol] finalized %d financially complete ride(s) without replaying wallets'):format(finalized))
    end

    local ok, err = pcall(db.FailIncompleteRides)
    if not ok then
        print(('[ojol] ride recovery failed: %s'):format(tostring(err)))
        return 0
    end

    return err or 0
end

return M
