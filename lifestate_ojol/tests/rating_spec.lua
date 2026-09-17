local h = require 'tests.harness'
local existingRating, transactionResult, recoveredRow

for _, name in ipairs({ 'server.rides', 'server.roadsnap', 'config.server', 'config.shared', 'server.database',
    'server.drivers', 'server.fares', 'server.payments', 'server.vehicles' }) do
    package.loaded[name] = nil
end
package.preload['server.rides'] = nil
package.preload['config.server'] = function() return {} end
package.preload['config.shared'] = function() return {} end
package.preload['server.database'] = function()
    return {
        FetchCompletedRide = function()
            return { ride_id = 'rated-1', customer_citizenid = 'customer', driver_citizenid = 'driver' }
        end,
        FetchRating = function() return existingRating end,
        SubmitRatingTransaction = function()
            if transactionResult then existingRating = 5 end
            return transactionResult
        end,
        FetchLatestCompletedUnrated = function() return recoveredRow end,
    }
end
package.preload['server.drivers'] = function()
    return {
        BusyDrivers = {}, SourceByCitizenid = {},
        GetDriverStateSnapshot = function() return { rating = 4.5, rank = 'driver' } end,
        GetDisplayName = function() return 'Driver' end,
    }
end
package.preload['server.fares'] = function()
    return { FormatRupiah = function(amount) return 'Rp' .. tostring(amount) end }
end
package.preload['server.payments'] = function() return {} end
package.preload['server.vehicles'] = function() return {} end

-- server/roadsnap.lua registers its response handler as it loads.
function RegisterNetEvent() end

local rides = require 'server.rides'

h.test('duplicate rating is rejected before aggregate work', function()
    existingRating, transactionResult = 4, true
    local ok, reason = rides.SubmitRating('customer', 'rated-1', 5)
    h.eq(ok, false, 'result')
    h.eq(reason, 'already_rated', 'reason')
end)

h.test('rating transaction failure does not report success', function()
    existingRating, transactionResult = nil, false
    local ok, reason = rides.SubmitRating('customer', 'rated-1', 5)
    h.eq(ok, false, 'result')
    h.eq(reason, 'database_error', 'reason')
    h.eq(existingRating, nil, 'persisted rating')
end)

h.test('completed unrated ride is recovered when no live ride exists', function()
    recoveredRow = {
        ride_id = 'rated-1', driver_citizenid = 'driver', payment_status = 'paid',
        pickup_x = 1, pickup_y = 2, pickup_z = 3,
        destination_x = 4, destination_y = 5, destination_z = 6,
        distance_meters = 1000, fare = 12000, payment_method = 'cash', created_at = 10,
    }
    local view = rides.GetCustomerView('customer')
    h.eq(view.rideId, 'rated-1', 'ride id')
    h.eq(view.status, 'COMPLETED', 'status')
    h.eq(view.rated, false, 'rated flag')
end)
