local h = require 'tests.harness'

local ride = {
    rideId = 'ride-1',
    customerCitizenid = 'customer',
    pickup = { x = 0, y = 0, z = 0 },
    status = 'SEARCHING',
}
local driverCoords = { x = 10, y = 0, z = 0 }
local accepted = 0

package.preload['config.server'] = function()
    return { cancelPairCooldownSeconds = 300, searchRadiusTiers = { 100, 500 }, searchTierSeconds = 30 }
end
package.preload['server.drivers'] = function()
    return {
        SourceByCitizenid = { driver = 7, driver2 = 8 },
        GetCitizenidBySource = function(source)
            if source == 7 then return 'driver' end
            if source == 8 then return 'driver2' end
        end,
        IsRegisteredDriver = function() return true end,
        IsDriverOnline = function() return true end,
        IsDriverBusy = function() return false end,
        GetPlayerCoordsByCitizenid = function() return driverCoords end,
        GetDisplayName = function() return 'Customer' end,
    }
end
package.preload['server.fares'] = function()
    return {
        StraightLineMeters = function(a, b)
            local dx, dy = a.x - b.x, a.y - b.y
            return math.sqrt(dx * dx + dy * dy)
        end,
        FormatRupiah = tostring,
    }
end
package.preload['server.rides'] = function()
    return {
        STATES = { SEARCHING = 'SEARCHING' },
        GetRide = function(id) return id == ride.rideId and ride or nil end,
        TryAcceptRide = function()
            accepted = accepted + 1
            ride.status = 'ACCEPTED'
            return true
        end,
        IsVoluntaryCancel = function() return false end,
    }
end

function GetGameTimer() return 0 end
function SetTimeout() return 1 end
function ClearTimeout() end
function TriggerClientEvent() end
function TriggerEvent() end
function AddEventHandler() end

package.loaded['server.matching'] = nil
local matching = require 'server.matching'

h.test('accept requires an actual stored offer', function()
    matching.DriverOffers.driver = nil
    local ok, reason = matching.AcceptOffer(7, ride.rideId)
    h.eq(ok, false, 'accepted')
    h.eq(reason, 'not_offered', 'reason')
    h.eq(accepted, 0, 'assignment calls')
end)

h.test('accept rechecks the current search radius', function()
    matching.DriverOffers.driver = { [ride.rideId] = true }
    matching.SearchState[ride.rideId] = { tier = 1 }
    driverCoords = { x = 150, y = 0, z = 0 }
    local ok, reason = matching.AcceptOffer(7, ride.rideId)
    h.eq(ok, false, 'accepted')
    h.eq(reason, 'not_eligible', 'reason')
    h.eq(accepted, 0, 'assignment calls')
end)

h.test('only the first of two offered drivers can accept', function()
    accepted, ride.status = 0, 'SEARCHING'
    driverCoords = { x = 10, y = 0, z = 0 }
    matching.DriverOffers.driver = { [ride.rideId] = true }
    matching.DriverOffers.driver2 = { [ride.rideId] = true }
    h.eq(select(1, matching.AcceptOffer(7, ride.rideId)), true, 'first driver')
    h.eq(select(2, matching.AcceptOffer(8, ride.rideId)), 'order_already_taken', 'second driver')
    h.eq(accepted, 1, 'assignment calls')
end)
