-- Lifecycle locking, persistence ordering and runtime/DB divergence.
--
-- These drive the REAL server/rides.lua with controllable stubs. The races are
-- made deterministic by re-entering the public API from inside a persistence
-- hook: db.AcceptRide / db.FinalizeRide / db.ReopenRide run in the middle of the
-- locked section, which is exactly where a competing accept or cancel lands.
--
-- Nothing about the lifecycle is reimplemented here, so a failure means the real
-- ordering or locking is wrong.

local h = require 'tests.harness'

local DRIVER_AT_PICKUP = { x = 100, y = 100, z = 30 }
local CUSTOMER = { x = 100, y = 100, z = 30 }

---Where the customer ends up when they move mid-request. Far outside
---maxPickupSnapMeters (75 m) from CUSTOMER, so the two positions can never be
---confused for one another.
local CUSTOMER_ELSEWHERE = { x = 900, y = 100, z = 30 }

local function freshState()
    return {
        players = {
            customer = { x = CUSTOMER.x, y = CUSTOMER.y, z = CUSTOMER.z },
            driver = { x = 1000, y = 100, z = 30 },
            driver2 = { x = 2000, y = 100, z = 30 },
        },
        sources = { customer = 1, driver = 2, driver2 = 3 },
        balance = 100000,
        events = {},
        handlers = {},
        stats = {},
        compensationPaid = 0,
        roadPickup = { x = 120, y = 100, z = 30 },
        roadSnapReason = nil,
        duringRoadSnap = nil,
        db = {},
    }
end

local function installGlobals(state)
    exports = { qbx_core = {
        GetPlayerByCitizenId = function()
            return { PlayerData = { money = { cash = state.balance, bank = state.balance } } }
        end,
    } }

    function AddEventHandler(name, fn) state.handlers[name] = fn end

    function TriggerEvent(name, ...)
        state.events[name] = (state.events[name] or 0) + 1
        local fn = state.handlers[name]
        if fn then fn(...) end
    end

    function TriggerClientEvent(name) state.events[name] = (state.events[name] or 0) + 1 end
    function GetGameTimer() return 0 end
    function SetTimeout() return 1 end
    function ClearTimeout() end
    function GetPlayerPed(source) return 100 + (tonumber(source) or 0) end
    function GetEntityCoords() return { x = 0, y = 0, z = 0 } end

    -- server/roadsnap.lua registers its response handler as it loads.
    function RegisterNetEvent() end
end

local function loadRides(state)
    -- server.roadsnap is cleared too: it binds 'server.drivers' as it loads, so a
    -- cached copy would keep answering from an earlier test's state.
    for _, name in ipairs({ 'server.rides', 'server.roadsnap', 'config.server', 'config.shared',
        'server.database', 'server.drivers', 'server.fares', 'server.payments', 'server.vehicles' }) do
        package.loaded[name] = nil
    end

    -- matching_spec leaves a stub here; this spec needs the real module.
    package.preload['server.rides'] = nil

    package.preload['config.server'] = function()
        return {
            cancelPairCooldownSeconds = 300,
            minRideDistanceMeters = 150,
            maxRideDistanceMeters = 25000,
            arrivalRadiusMeters = 30,
            boardingRadiusMeters = 8,
            destinationRadiusMeters = 40,
            cancelCompensationAfterSeconds = 30,
            cancelCompensationMinMovementMeters = 150,
            cancelDriverCompensation = 5000,
            driverLocationStreamMs = 2500,
        }
    end

    package.preload['config.shared'] = function() return { maxPickupSnapMeters = 75 } end

    local db = state.db
    package.preload['server.database'] = function()
        return {
            InsertRide = function() return 1 end,
            AcceptRide = function(...)
                if db.acceptRide then return db.acceptRide(...) end
                return 1
            end,
            ReopenRide = function(...)
                if db.reopenRide then return db.reopenRide(...) end
                return 1
            end,
            ReopenRideRecalculated = function(...)
                if db.reopenRideRecalculated then return db.reopenRideRecalculated(...) end
                return 1
            end,
            FinalizeRide = function(...)
                if db.finalizeRide then return db.finalizeRide(...) end
                return 1
            end,
            FetchRideStatus = function(...)
                if db.fetchRideStatus then return db.fetchRideStatus(...) end
                return nil
            end,
            FetchRideAssignment = function(...)
                if db.fetchRideAssignment then return db.fetchRideAssignment(...) end
                return { status = 'SEARCHING', driver_citizenid = nil }
            end,
            IsFareLedgerPaid = function() return false end,
            IncrementDriverStat = function(_, column)
                state.stats[#state.stats + 1] = column
                return 1
            end,
            FetchCompletedRide = function() return nil end,
            FetchRating = function() return nil end,
            SubmitRatingTransaction = function() return true end,
            FetchLatestCompletedUnrated = function() return nil end,
        }
    end

    package.preload['server.drivers'] = function()
        return {
            BusyDrivers = {},
            SourceByCitizenid = state.sources,
            IsRegisteredDriver = function() return true end,
            IsDriverOnline = function() return true end,
            GetPlayerCoordsByCitizenid = function(citizenid) return state.players[citizenid] end,
            GetDriverStateSnapshot = function() return { rank = 'driver' } end,
            GetDisplayName = function(citizenid) return citizenid end,
        }
    end

    package.preload['server.fares'] = function()
        return {
            StraightLineMeters = function(a, b)
                local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
                return math.sqrt(dx * dx + dy * dy + dz * dz)
            end,
            BuildQuote = function()
                return { distanceMeters = 1000, fare = 12000, driverPayout = 10800, companyFee = 1200 }
            end,
            FormatRupiah = function(amount) return 'Rp' .. tostring(amount) end,
        }
    end

    package.preload['server.payments'] = function()
        return {
            PayRide = function() return true end,
            PayCompensation = function(ride)
                state.compensationPaid = state.compensationPaid + 1
                state.compensationRide = ride
                return true
            end,
        }
    end

    package.preload['server.vehicles'] = function()
        return { HasValidBike = function() return false end }
    end

    -- The bounded client round trip that resolves an after-pickup recovery
    -- pickup. The round trip itself (deadline, spoof/late/duplicate answers) is
    -- exercised against the real module in roadsnap_spec.lua; here it is stubbed
    -- so these specs can assert what rides.lua DOES with each outcome - the
    -- point it receives, and the reason it fails with.
    package.preload['server.roadsnap'] = function()
        return {
            Request = function()
                -- Runs while the round trip is in flight. This is where a test
                -- moves (or removes) the customer, so the recovery's proximity
                -- check is exercised against where they are when the answer
                -- arrives - not where they were when the request was sent.
                if state.duringRoadSnap then state.duringRoadSnap() end

                if state.roadSnapReason then return nil, state.roadSnapReason end
                return state.roadPickup
            end,
            DropByCitizenid = function() end,
            Shutdown = function() end,
        }
    end

    local rides = require 'server.rides'
    return rides, require 'server.drivers'
end

local function setup()
    local state = freshState()
    installGlobals(state)
    local rides, drivers = loadRides(state)
    return rides, drivers, state
end

local function createRide(rides, state)
    local ok, ride = rides.CreateRide('customer', { x = CUSTOMER.x, y = CUSTOMER.y, z = CUSTOMER.z },
        { x = 2000, y = 0, z = 0 }, 'cash')
    if not ok then error('ride creation failed: ' .. tostring(ride), 2) end
    if state then state.players.customer = { x = CUSTOMER.x, y = CUSTOMER.y, z = CUSTOMER.z } end
    return ride
end

---How many times an event has been dispatched so far. Creating a ride already
---fires rideSearching once, so specs on the cancel path compare deltas.
---@param state table
---@param name string
---@return number
local function dispatched(state, name)
    return state.events[name] or 0
end

---Accept, then drive the real in-trip transitions up to ENROUTE_DESTINATION.
local function acceptAndBoard(rides, state)
    local ride = createRide(rides, state)
    h.eq(select(1, rides.TryAcceptRide(ride.rideId, 'driver')), true, 'assignment')

    state.players.driver = { x = DRIVER_AT_PICKUP.x, y = DRIVER_AT_PICKUP.y, z = DRIVER_AT_PICKUP.z }
    h.eq(select(1, rides.DriverArrived('driver', ride.rideId)), true, 'arrival')
    h.eq(select(1, rides.PassengerBoarded('driver', ride.rideId)), true, 'boarding')
    h.eq(ride.status, rides.STATES.ENROUTE_DESTINATION, 'in-trip state')

    return ride
end

-- Acceptance vs cancellation ---------------------------------------------------

h.test('an accept racing a customer cancellation is rejected with no assignment', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    local raceOk, raceReason
    state.db.finalizeRide = function()
        -- Runs inside the cancellation's lifecycle lock - where a driver's
        -- accept would land in a real race.
        raceOk, raceReason = rides.TryAcceptRide(ride.rideId, 'driver')
        return 1
    end

    h.eq(select(1, rides.CustomerCancel('customer')), true, 'cancellation result')
    h.eq(raceOk, false, 'racing accept result')
    h.eq(raceReason, 'ride_busy', 'racing accept reason')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver assignment')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver busy state')
    h.eq(ride.status, rides.STATES.CANCELLED_CUSTOMER, 'ride status')
    h.eq(rides.ActiveRides[ride.rideId], nil, 'ride registry')
end)

h.test('a cancellation racing an accept fails cleanly and the ride ends once', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    local raceOk, raceReason
    state.db.acceptRide = function()
        raceOk, raceReason = rides.CustomerCancel('customer')
        return 1
    end

    h.eq(select(1, rides.TryAcceptRide(ride.rideId, 'driver')), true, 'accept result')
    h.eq(raceOk, false, 'racing cancellation result')
    h.eq(raceReason, 'ride_busy', 'racing cancellation reason')
    h.eq(ride.status, rides.STATES.DRIVER_ENROUTE, 'ride status after the accept')
    h.eq(rides.DriverActiveRide.driver, ride.rideId, 'assigned driver')
    h.eq(drivers.BusyDrivers.driver, true, 'driver busy')
    h.eq(state.events['lifestate_ojol:server:rideClosed'], nil, 'no closure during the accept')

    -- The same cancellation succeeds once the lock is free, and the ride is
    -- closed exactly once.
    h.eq(select(1, rides.CustomerCancel('customer')), true, 'cancellation after the accept')
    h.eq(ride.status, rides.STATES.CANCELLED_CUSTOMER, 'final status')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver released')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(state.events['lifestate_ojol:server:rideClosed'], 1, 'closure events')
end)

h.test('a second accept during the first cannot double-assign', function()
    local rides, _, state = setup()
    local ride = createRide(rides, state)

    local secondOk, secondReason
    state.db.acceptRide = function()
        secondOk, secondReason = rides.TryAcceptRide(ride.rideId, 'driver2')
        return 1
    end

    h.eq(select(1, rides.TryAcceptRide(ride.rideId, 'driver')), true, 'first accept')
    h.eq(secondOk, false, 'second accept')
    h.eq(secondReason, 'ride_busy', 'second accept reason')
    h.eq(rides.DriverActiveRide.driver, ride.rideId, 'winning driver')
    h.eq(rides.DriverActiveRide.driver2, nil, 'losing driver')
end)

-- Assignment persistence -------------------------------------------------------

h.test('a failed assignment write aborts the accept with no runtime change', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    -- The write matched nothing while storage still looks unassigned and live:
    -- the row moved under us, so the accept is refused rather than guessed.
    state.db.acceptRide = function() return 0 end

    h.eq(select(2, rides.TryAcceptRide(ride.rideId, 'driver')), 'stale_assignment', 'reason')
    h.eq(ride.status, rides.STATES.SEARCHING, 'ride status')
    h.eq(ride.driverCitizenId, nil, 'runtime driver')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver map')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver busy')
    h.eq(rides.ActiveRides[ride.rideId], ride, 'ride still offered')
    h.eq(state.events['lifestate_ojol:server:rideAssigned'], nil, 'assignment event')

    -- And the very same ride is still acceptable afterwards.
    state.db.acceptRide = function() return 1 end
    h.eq(select(1, rides.TryAcceptRide(ride.rideId, 'driver')), true, 'later accept')
    h.eq(ride.status, rides.STATES.DRIVER_ENROUTE, 'final status')
end)

-- Database compare-and-set -----------------------------------------------------
--
-- The assignment is a compare-and-set in storage: only a still-SEARCHING,
-- still-unassigned row can be won. When it matches nothing, the runtime must not
-- advance - and the persisted state decides what actually happened.

h.test('an accept whose row is already terminal is refused and reconciled', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    state.db.acceptRide = function() return 0 end
    state.db.fetchRideAssignment = function()
        return { status = 'CANCELLED_CUSTOMER', driver_citizenid = nil }
    end
    state.db.fetchRideStatus = function() return 'CANCELLED_CUSTOMER' end

    local ok, reason = rides.TryAcceptRide(ride.rideId, 'driver')

    h.eq(ok, false, 'accept result')
    h.eq(reason, 'order_already_taken', 'reason')
    h.eq(rides.DriverActiveRide.driver, nil, 'no runtime assignment')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(ride.status, rides.STATES.CANCELLED_CUSTOMER, 'runtime adopted the persisted state')
    h.eq(rides.ActiveRides[ride.rideId], nil, 'ride no longer live')
    h.eq(state.events['lifestate_ojol:server:rideAssigned'], nil, 'assignment event')
    h.eq(state.events['lifestate_ojol:server:rideClosed'], 1, 'closure announced')
end)

h.test('an accept whose row storage completed is refused and reconciled', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    state.db.acceptRide = function() return 0 end
    state.db.fetchRideAssignment = function()
        return { status = 'COMPLETED', driver_citizenid = 'driver-a' }
    end
    state.db.fetchRideStatus = function() return 'COMPLETED' end

    h.eq(select(2, rides.TryAcceptRide(ride.rideId, 'driver')), 'order_already_taken', 'reason')
    h.eq(rides.DriverActiveRide.driver, nil, 'no runtime assignment')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(ride.status, rides.STATES.COMPLETED, 'runtime adopted the persisted state')
    h.eq(rides.ActiveRides[ride.rideId], nil, 'ride no longer live')
    h.eq(state.events['lifestate_ojol:server:rideAssigned'], nil, 'assignment event')
end)

h.test('a storage error during the assignment write aborts the accept', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    state.db.acceptRide = function() error('storage down') end

    h.eq(select(2, rides.TryAcceptRide(ride.rideId, 'driver')), 'database_error', 'reason')
    h.eq(ride.status, rides.STATES.SEARCHING, 'ride status')
    h.eq(ride.driverCitizenId, nil, 'runtime driver')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver map')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver busy')
    h.eq(rides.ActiveRides[ride.rideId], ride, 'ride still offered')
    h.eq(state.events['lifestate_ojol:server:rideAssigned'], nil, 'assignment event')

    -- The lifecycle lock was released, so a later attempt is not wedged behind it.
    local _, again = rides.TryAcceptRide(ride.rideId, 'driver')
    h.eq(again == 'ride_busy', false, 'lifecycle lock released')
end)

h.test('an accept whose row already names a driver is refused with no overwrite', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    state.db.acceptRide = function() return 0 end
    state.db.fetchRideAssignment = function()
        return { status = 'SEARCHING', driver_citizenid = 'someone-else' }
    end

    local ok, reason = rides.TryAcceptRide(ride.rideId, 'driver')

    h.eq(ok, false, 'accept result')
    h.eq(reason, 'order_already_taken', 'reason')
    h.eq(rides.DriverActiveRide.driver, nil, 'no runtime assignment')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(state.events['lifestate_ojol:server:rideAssigned'], nil, 'assignment event')

    -- Still offerable: the losing accept consumed nothing.
    h.eq(rides.ActiveRides[ride.rideId], ride, 'ride still live')
end)

h.test('an accept that storage cannot explain is refused as stale', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    state.db.acceptRide = function() return 0 end
    -- Unassigned and non-terminal, yet the compare-and-set matched nothing.
    state.db.fetchRideAssignment = function()
        return { status = 'SEARCHING', driver_citizenid = nil }
    end

    h.eq(select(2, rides.TryAcceptRide(ride.rideId, 'driver')), 'stale_assignment', 'reason')
    h.eq(rides.DriverActiveRide.driver, nil, 'no runtime assignment')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(rides.ActiveRides[ride.rideId], ride, 'ride still live')
end)

h.test('an accept with no persisted row is a storage fault, not a missing order', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    state.db.acceptRide = function() return 0 end
    state.db.fetchRideAssignment = function() return nil end

    h.eq(select(2, rides.TryAcceptRide(ride.rideId, 'driver')), 'database_error', 'reason')
    h.eq(rides.DriverActiveRide.driver, nil, 'no runtime assignment')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(rides.ActiveRides[ride.rideId], ride, 'ride still live')
end)

h.test('an accept fails closed when the reconciliation query itself errors', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    state.db.acceptRide = function() return 0 end
    state.db.fetchRideAssignment = function() error('storage down') end

    h.eq(select(2, rides.TryAcceptRide(ride.rideId, 'driver')), 'database_error', 'reason')
    h.eq(rides.DriverActiveRide.driver, nil, 'no runtime assignment')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(rides.ActiveRides[ride.rideId], ride, 'ride still live')
end)

h.test('a refused accept does not consume the ride assignment state', function()
    local rides, _, state = setup()
    local ride = createRide(rides, state)

    -- Storage holds a stale assignment owned by somebody else, then clears.
    state.db.acceptRide = function() return 0 end
    state.db.fetchRideAssignment = function()
        return { status = 'SEARCHING', driver_citizenid = 'someone-else' }
    end
    h.eq(select(1, rides.TryAcceptRide(ride.rideId, 'driver')), false, 'refused accept')
    h.eq(ride.driverCitizenId, nil, 'runtime driver untouched')

    -- The stale row is released: the same ride can now be won normally.
    state.db.acceptRide = function() return 1 end
    state.db.fetchRideAssignment = function()
        return { status = 'SEARCHING', driver_citizenid = nil }
    end

    h.eq(select(1, rides.TryAcceptRide(ride.rideId, 'driver')), true, 'legitimate accept')
    h.eq(ride.status, rides.STATES.DRIVER_ENROUTE, 'final status')
    h.eq(rides.DriverActiveRide.driver, ride.rideId, 'winning driver')
end)

-- Customer cancellation --------------------------------------------------------

h.test('a customer cancellation that cannot be committed pays no compensation', function()
    local rides, _, state = setup()
    local ride = acceptAndBoard(rides, state)

    -- Make the driver compensation-eligible so the negative case is meaningful.
    ride.acceptedAt = os.time() - 60
    ride.driverDistanceToPickupAtAccept = 900
    state.players.driver = { x = 200, y = 100, z = 30 }

    state.db.finalizeRide = function() return 0 end
    state.db.fetchRideStatus = function() return rides.STATES.PASSENGER_ONBOARD end

    local ok, reason = rides.CustomerCancel('customer')
    h.eq(ok, false, 'cancellation result')
    h.eq(reason, 'already_finalized', 'reason')
    h.eq(state.compensationPaid, 0, 'compensation payouts')
    h.eq(ride.status, rides.STATES.ENROUTE_DESTINATION, 'ride still live')
    h.eq(rides.DriverActiveRide.driver, ride.rideId, 'driver still assigned')
end)

h.test('an eligible customer cancellation pays compensation once, after commit', function()
    local rides, _, state = setup()
    local ride = acceptAndBoard(rides, state)

    ride.acceptedAt = os.time() - 60
    ride.driverDistanceToPickupAtAccept = 900
    state.players.driver = { x = 200, y = 100, z = 30 }

    h.eq(select(1, rides.CustomerCancel('customer')), true, 'cancellation result')
    h.eq(state.compensationPaid, 1, 'compensation payouts')
    h.eq(state.compensationRide.compensationEligible, true, 'eligibility')
    h.eq(ride.compensationEligible, true, 'eligibility kept on the ride')
end)

-- Rematch persistence ----------------------------------------------------------

h.test('a driver cancel that cannot reopen the ride changes nothing', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)
    h.eq(select(1, rides.TryAcceptRide(ride.rideId, 'driver')), true, 'assignment')

    state.db.reopenRide = function() return 0 end
    state.db.fetchRideStatus = function() return rides.STATES.DRIVER_ENROUTE end

    local rematches = dispatched(state, 'lifestate_ojol:server:rideSearching')
    local ok, reason = rides.DriverCancel('driver', 'manual_driver_cancel')

    h.eq(ok, false, 'cancel result')
    h.eq(reason, 'database_error', 'reason')
    h.eq(ride.status, rides.STATES.DRIVER_ENROUTE, 'ride status')
    h.eq(rides.DriverActiveRide.driver, ride.rideId, 'driver still assigned')
    h.eq(drivers.BusyDrivers.driver, true, 'driver still busy')
    h.eq(dispatched(state, 'lifestate_ojol:server:rideSearching'), rematches, 'no rematch')
    h.eq(state.events['lifestate_ojol:server:driverCancelledRide'], nil, 'no cooldown')
    h.eq(#state.stats, 0, 'cancellation statistics')
end)

h.test('an after-pickup abandon that cannot be persisted keeps the ride in place', function()
    local rides, drivers, state = setup()
    local ride = acceptAndBoard(rides, state)

    state.roadPickup = { x = 120, y = 100, z = 30 }
    state.db.reopenRideRecalculated = function() return 0 end
    state.db.fetchRideStatus = function() return rides.STATES.ENROUTE_DESTINATION end

    local rematches = dispatched(state, 'lifestate_ojol:server:rideSearching')
    local ok, reason = rides.DriverCancel('driver', 'manual_driver_cancel')

    h.eq(ok, false, 'cancel result')
    h.eq(reason, 'database_error', 'reason')
    h.eq(ride.status, rides.STATES.ENROUTE_DESTINATION, 'ride status')
    h.eq(ride.pickup.x, CUSTOMER.x, 'pickup unchanged')
    h.eq(ride.fare, 12000, 'fare unchanged')
    h.eq(rides.DriverActiveRide.driver, ride.rideId, 'driver still assigned')
    h.eq(drivers.BusyDrivers.driver, true, 'driver still busy')
    h.eq(dispatched(state, 'lifestate_ojol:server:rideSearching'), rematches, 'no rematch')
    h.eq(#state.stats, 0, 'cancellation statistics')
end)

h.test('a persisted after-pickup abandon reopens on the recovery road point', function()
    local rides, drivers, state = setup()
    local ride = acceptAndBoard(rides, state)

    local staged
    state.roadPickup = { x = 120, y = 100, z = 30 }
    state.db.reopenRideRecalculated = function(_, values) staged = values return 1 end

    local rematches = dispatched(state, 'lifestate_ojol:server:rideSearching')
    h.eq(select(1, rides.DriverCancel('driver', 'manual_driver_cancel')), true, 'cancel result')

    h.eq(staged.pickup.x, 120, 'persisted pickup')
    h.eq(ride.pickup.x, 120, 'runtime pickup matches persistence')
    h.eq(ride.destination.x, 2000, 'destination preserved')
    h.eq(ride.status, rides.STATES.SEARCHING, 'ride status')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver released')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver available again')
    h.eq(dispatched(state, 'lifestate_ojol:server:rideSearching'), rematches + 1, 'rematch events')
    h.eq(state.events['lifestate_ojol:server:driverCancelledRide'], 1, 'voluntary cooldown')
    h.eq(#state.stats, 1, 'cancellation statistics')
    h.eq(state.stats[1], 'cancelled_after_pickup', 'statistic column')
end)

-- Road-snap trust boundary -----------------------------------------------------

h.test('a recovery road point far from the real ped fails the recovery', function()
    local rides, drivers, state = setup()
    local ride = acceptAndBoard(rides, state)

    state.roadPickup = { x = 5000, y = 100, z = 30 }

    local rematches = dispatched(state, 'lifestate_ojol:server:rideSearching')
    local ok, reason = rides.DriverCancel('driver', 'manual_driver_cancel')

    h.eq(ok, false, 'cancel result')
    h.eq(reason, 'unsafe_recovery_pickup', 'reason')
    h.eq(ride.status, rides.STATES.FAILED, 'ride closed')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver released')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(ride.pickup.x, CUSTOMER.x, 'pickup never replaced with an untrusted point')
    h.eq(dispatched(state, 'lifestate_ojol:server:rideSearching'), rematches, 'no rematch')
end)

h.test('a recovery point that is not sane fails the recovery', function()
    local rides, _, state = setup()
    local ride = acceptAndBoard(rides, state)

    state.roadPickup = { x = 0, y = 0, z = 0 }

    local ok, reason = rides.DriverCancel('driver', 'manual_driver_cancel')
    h.eq(ok, false, 'cancel result')
    h.eq(reason, 'unsafe_recovery_pickup', 'reason')
    h.eq(ride.status, rides.STATES.FAILED, 'ride closed')
end)

h.test('a customer who moves during the round trip is validated where they now are', function()
    local rides, drivers, state = setup()
    local ride = acceptAndBoard(rides, state)

    -- The answer is a road point next to where the customer moved to while the
    -- request was in flight. It sits ~810 m from where they started, so judging
    -- it against a pre-request sample would refuse a perfectly good recovery.
    state.duringRoadSnap = function()
        state.players.customer = { x = CUSTOMER_ELSEWHERE.x, y = CUSTOMER_ELSEWHERE.y, z = CUSTOMER_ELSEWHERE.z }
    end
    state.roadPickup = { x = 910, y = 100, z = 30 }

    local staged
    state.db.reopenRideRecalculated = function(_, values) staged = values return 1 end

    local rematches = dispatched(state, 'lifestate_ojol:server:rideSearching')
    h.eq(select(1, rides.DriverCancel('driver', 'manual_driver_cancel')), true, 'cancel result')

    h.eq(staged ~= nil, true, 'recovery persisted')
    h.eq(staged.pickup.x, 910, 'persisted pickup is the fresh road point')
    h.eq(ride.pickup.x, 910, 'runtime pickup follows persistence')
    h.eq(ride.status, rides.STATES.SEARCHING, 'ride reopened')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver released')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver available again')
    h.eq(dispatched(state, 'lifestate_ojol:server:rideSearching'), rematches + 1, 'rematch event')
    h.eq(#state.stats, 1, 'cancellation statistics')
    h.eq(state.stats[1], 'cancelled_after_pickup', 'statistic column')
end)

h.test('a road point near where the customer used to be is refused', function()
    local rides, _, state = setup()
    local ride = acceptAndBoard(rides, state)

    -- The customer moved away, and the answer is a point next to their OLD
    -- position: 10 m from where they were, 790 m from where they are now. Judged
    -- against a pre-request sample it would sail through.
    state.duringRoadSnap = function()
        state.players.customer = { x = CUSTOMER_ELSEWHERE.x, y = CUSTOMER_ELSEWHERE.y, z = CUSTOMER_ELSEWHERE.z }
    end
    state.roadPickup = { x = 110, y = 100, z = 30 }

    local rematches = dispatched(state, 'lifestate_ojol:server:rideSearching')
    local ok, reason = rides.DriverCancel('driver', 'manual_driver_cancel')

    h.eq(ok, false, 'cancel result')
    h.eq(reason, 'unsafe_recovery_pickup', 'reason')
    h.eq(ride.status, rides.STATES.FAILED, 'ride closed')
    h.eq(ride.pickup.x, CUSTOMER.x, 'pickup never replaced with the stale-position point')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver released')
    h.eq(dispatched(state, 'lifestate_ojol:server:rideSearching'), rematches, 'no rematch')
    h.eq(#state.stats, 0, 'no cancellation statistic')
end)

h.test('a customer who vanishes after answering cannot be recovered', function()
    local rides, _, state = setup()
    local ride = acceptAndBoard(rides, state)

    -- The answer arrives, then the ped is gone before the server judges it.
    state.duringRoadSnap = function() state.players.customer = nil end
    state.roadPickup = { x = 120, y = 100, z = 30 }

    local rematches = dispatched(state, 'lifestate_ojol:server:rideSearching')
    local ok, reason = rides.DriverCancel('driver', 'manual_driver_cancel')

    h.eq(ok, false, 'cancel result')
    h.eq(reason, 'customer_offline', 'reason')
    h.eq(ride.status, rides.STATES.FAILED, 'ride closed')
    h.eq(ride.pickup.x, CUSTOMER.x, 'pickup untouched')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver released')
    h.eq(dispatched(state, 'lifestate_ojol:server:rideSearching'), rematches, 'no rematch')
end)

h.test('an unresponsive client fails the recovery instead of trusting raw ped coordinates', function()
    local rides, drivers, state = setup()
    local ride = acceptAndBoard(rides, state)

    -- The deadline expired, so the bounded round trip produced no point at all.
    -- There is deliberately no fallback to the customer's raw ped position.
    state.roadSnapReason = 'road_snap_timeout'
    state.players.customer = { x = 900, y = 900, z = 30 }

    local rematches = dispatched(state, 'lifestate_ojol:server:rideSearching')
    local ok, reason = rides.DriverCancel('driver', 'manual_driver_cancel')

    h.eq(ok, false, 'cancel result')
    h.eq(reason, 'road_snap_timeout', 'reason')
    h.eq(ride.status, rides.STATES.FAILED, 'ride closed')
    h.eq(ride.pickup.x, CUSTOMER.x, 'pickup never replaced with raw ped coordinates')
    h.eq(ride.fare, 12000, 'locked fare untouched')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver released')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(dispatched(state, 'lifestate_ojol:server:rideSearching'), rematches, 'no rematch')
    h.eq(#state.stats, 0, 'no cancellation statistic for a failed recovery')

    -- The lifecycle lock was released, so the ride is not wedged behind it.
    local _, again = rides.DriverCancel('driver', 'manual_driver_cancel')
    h.eq(again == 'ride_busy', false, 'lifecycle lock released')
end)

h.test('a late recovery answer cannot resurrect a closed recovery', function()
    local rides, drivers, state = setup()
    local ride = acceptAndBoard(rides, state)

    state.roadSnapReason = 'road_snap_timeout'
    h.eq(select(1, rides.DriverCancel('driver', 'manual_driver_cancel')), false, 'cancel result')
    h.eq(ride.status, rides.STATES.FAILED, 'ride closed')

    -- The client answers after the deadline. The request no longer exists and the
    -- ride is terminal, so the answer must change nothing at all.
    state.roadSnapReason = nil
    state.roadPickup = { x = 120, y = 100, z = 30 }

    h.eq(ride.status, rides.STATES.FAILED, 'ride status')
    h.eq(ride.pickup.x, CUSTOMER.x, 'pickup unchanged')
    h.eq(rides.ActiveRides[ride.rideId], nil, 'ride registry')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver assignment')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver busy state')

    local _, reason = rides.DriverCancel('driver', 'manual_driver_cancel')
    h.eq(reason, 'no_ride', 'no recovery path remains open')
end)

h.test('a customer who drops during the recovery ends it safely', function()
    local rides, drivers, state = setup()
    local ride = acceptAndBoard(rides, state)

    state.roadSnapReason = 'customer_offline'

    local rematches = dispatched(state, 'lifestate_ojol:server:rideSearching')
    local ok, reason = rides.DriverCancel('driver', 'manual_driver_cancel')

    h.eq(ok, false, 'cancel result')
    h.eq(reason, 'customer_offline', 'reason')
    h.eq(ride.status, rides.STATES.FAILED, 'ride closed')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver released')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(dispatched(state, 'lifestate_ojol:server:rideSearching'), rematches, 'no rematch')
    h.eq(#state.stats, 0, 'no cancellation statistic')
end)

-- Runtime / database divergence ------------------------------------------------

h.test('a runtime ride whose row is already terminal is reconciled, never kept', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)
    h.eq(select(1, rides.TryAcceptRide(ride.rideId, 'driver')), true, 'assignment')

    state.db.reopenRide = function() return 0 end
    state.db.fetchRideStatus = function() return rides.STATES.CANCELLED_CUSTOMER end

    h.eq(select(1, rides.DriverCancel('driver', 'manual_driver_cancel')), false, 'cancel result')
    h.eq(ride.status, rides.STATES.CANCELLED_CUSTOMER, 'reconciled status')
    h.eq(rides.ActiveRides[ride.rideId], nil, 'ride registry')
    h.eq(rides.DriverActiveRide.driver, nil, 'driver released')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver not busy')
    h.eq(state.events['lifestate_ojol:server:rideClosed'], 1, 'closure announced')
end)

h.test('a finished ride releases the driver for the next order', function()
    local rides, drivers, state = setup()
    local ride = createRide(rides, state)

    h.eq(select(1, rides.TryAcceptRide(ride.rideId, 'driver')), true, 'first assignment')
    h.eq(select(1, rides.CustomerCancel('customer')), true, 'cancellation')
    h.eq(drivers.BusyDrivers.driver, nil, 'driver released')

    local ride2 = createRide(rides, state)
    h.eq(select(1, rides.TryAcceptRide(ride2.rideId, 'driver')), true, 'second assignment')
    h.eq(drivers.BusyDrivers.driver, true, 'driver busy again')
    h.eq(rides.DriverActiveRide.driver, ride2.rideId, 'single ride ownership')
end)
