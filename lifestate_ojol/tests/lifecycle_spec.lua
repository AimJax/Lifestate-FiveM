local h = require 'tests.harness'
local paid, finalized = false, 0

for _, name in ipairs({ 'server.rides', 'config.server', 'config.shared', 'server.database',
    'server.drivers', 'server.fares', 'server.payments', 'server.vehicles' }) do
    package.loaded[name] = nil
end
package.preload['server.rides'] = nil
package.preload['config.server'] = function() return {} end
package.preload['config.shared'] = function() return {} end
package.preload['server.database'] = function()
    return {
        IsFareLedgerPaid = function() return paid end,
        FinalizeRide = function() finalized = finalized + 1 return 1 end,
    }
end
package.preload['server.drivers'] = function()
    return { BusyDrivers = {}, SourceByCitizenid = {}, IsDriverOnline = function() return true end }
end
package.preload['server.fares'] = function() return { StraightLineMeters = function() return 0 end } end
package.preload['server.payments'] = function() return {} end
package.preload['server.vehicles'] = function() return {} end
function AddEventHandler() end
function TriggerEvent() end
function TriggerClientEvent() end
function ClearTimeout() end
function SetTimeout() return 1 end

local rides = require 'server.rides'

h.test('ride lifecycle lock fails immediately and releases on success', function()
    local nestedReason
    local ok = rides.WithRideLock('lock-1', function()
        local _, reason = rides.WithRideLock('lock-1', function() return true end)
        nestedReason = reason
        return true
    end)
    h.eq(ok, true, 'outer result')
    h.eq(nestedReason, 'ride_busy', 'nested reason')
    h.eq(select(1, rides.WithRideLock('lock-1', function() return true end)), true, 'released result')
end)

h.test('ride lifecycle lock releases after an exception', function()
    h.eq(select(1, rides.WithRideLock('lock-2', function() error('boom') end)), false, 'exception result')
    h.eq(select(1, rides.WithRideLock('lock-2', function() return true end)), true, 'released result')
end)

h.test('completed terminalization rejects an unpaid fare ledger', function()
    paid, finalized = false, 0
    local ride = {
        rideId = 'ride-unpaid', customerCitizenid = 'customer', driverCitizenId = 'driver',
        status = rides.STATES.ENROUTE_DESTINATION, compensationEligible = false,
    }
    local ok, reason = rides.TerminalizeRide(ride, rides.STATES.COMPLETED)
    h.eq(ok, false, 'result')
    h.eq(reason, 'fare_not_paid', 'reason')
    h.eq(finalized, 0, 'finalization calls')
    h.eq(ride.status, rides.STATES.ENROUTE_DESTINATION, 'ride state')
end)

h.test('paid completion terminalizes once and re-entry returns existing result', function()
    paid, finalized = true, 0
    local ride = {
        rideId = 'ride-paid', customerCitizenid = 'customer', driverCitizenId = 'driver',
        status = rides.STATES.ENROUTE_DESTINATION, compensationEligible = false, driverPayout = 9000,
    }
    rides.ActiveRides[ride.rideId] = ride
    rides.CustomerActiveRide.customer = ride.rideId
    rides.DriverActiveRide.driver = ride.rideId
    h.eq(select(1, rides.TerminalizeRide(ride, rides.STATES.COMPLETED)), true, 'first result')
    h.eq(select(1, rides.TerminalizeRide(ride, rides.STATES.COMPLETED)), true, 're-entry result')
    h.eq(finalized, 1, 'finalization calls')
end)

h.test('after-pickup ride can return to searching for safe rematch', function()
    local ride = { rideId = 'rematch-1', status = rides.STATES.ENROUTE_DESTINATION }
    h.eq(select(1, rides.SetStatus(ride, rides.STATES.SEARCHING)), true, 'transition')
    h.eq(ride.status, rides.STATES.SEARCHING, 'state')
end)
