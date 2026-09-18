-- Database-side assignment compare-and-set and terminal guards.
--
-- server/database.lua runs for REAL here; only MySQL is replaced. The fake keeps
-- a single ojol_rides row and INTERPRETS the statements the module issues - the
-- WHERE predicates are read out of the SQL text itself, and the parameters are
-- bound from the statement. Nothing here knows the intended answer in advance,
-- which is what makes the negative checks in negative_check.mjs meaningful:
-- deleting a guard from a statement genuinely changes the outcome.
--
-- The transaction stub deliberately mirrors the real oxmysql contract of
-- reporting COMMIT success rather than rows affected, so a statement that is
-- guarded into affecting nothing still "succeeds".

local h = require 'tests.harness'

local store = { ride = nil, ledgerPaid = false, failing = false }

---@param ride table|nil
local function resetStore(ride, ledgerPaid)
    store.ride = ride
    store.ledgerPaid = ledgerPaid == true
    store.failing = false
end

---A ride row in the shape the schema stores it.
---@param overrides table|nil
---@return table
local function liveRide(overrides)
    local ride = {
        ride_id = 'ride-1',
        status = 'SEARCHING',
        driver_citizenid = nil,
        accepted_at = nil,
        compensation_eligible = 0,
        cancelled_at = nil,
        completed_at = nil,
        pickup_x = 100,
        pickup_y = 100,
        pickup_z = 30,
        destination_x = 2000,
        destination_y = 0,
        destination_z = 0,
        distance_meters = 1000,
        fare = 12000,
        driver_payout = 10800,
        company_fee = 1200,
    }

    for key, value in pairs(overrides or {}) do ride[key] = value end

    resetStore(ride)
    return ride
end

---The ride id is whichever parameter names the row this store holds.
---@param row table
---@param params table
---@return string? rideId
local function rideIdFromParams(row, params)
    for i = 1, #params do
        if params[i] == row.ride_id then return row.ride_id end
    end

    return nil
end

---Evaluate the WHERE predicates found in the statement against the row.
---@return boolean matched
---@return boolean recognised
local function whereMatches(sql, row, params)
    local _, where = sql:match('^(.-)%s+WHERE%s+(.*)$')
    if not where then return false, false end

    local ok = true

    if where:find('`ride_id`%s*=%s*%?') and rideIdFromParams(row, params) == nil then
        ok = false
    end

    -- AND `status` = 'SEARCHING'
    if where:find("`status`%s*=%s*'SEARCHING'") and row.status ~= 'SEARCHING' then
        ok = false
    end

    -- AND `driver_citizenid` IS NULL
    if where:find('`driver_citizenid`%s+IS%s+NULL') and row.driver_citizenid ~= nil then
        ok = false
    end

    -- AND `status` NOT IN ('COMPLETED','CANCELLED_CUSTOMER',...)
    local excluded = where:match('`status`%s+NOT%s+IN%s*%(([^)]*)%)')
    if excluded then
        for name in excluded:gmatch("'([^']+)'") do
            if row.status == name then ok = false end
        end
    end

    -- AND EXISTS (... l.`status` = 'paid')
    if where:find("l%.`status`%s*=%s*'paid'") and not store.ledgerPaid then
        ok = false
    end

    return ok, true
end

---Bind the SET clause from the parameters. Columns qualified with a table alias
---(the driver-statistics statement) belong to another table and are not part of
---the ride row modelled here.
local function applySet(sql, row, params)
    local head = sql:match('^(.-)%s+WHERE%s')
    local setClause = head and head:match('SET%s+(.*)$')
    if not setClause then return end

    local slot = 0

    for part in (setClause .. ','):gmatch('(.-),') do
        local column, value = part:match('`([%w_]+)`%s*=%s*(.-)%s*$')
        if column then
            local qualified = part:find('%.`') ~= nil

            if value == '?' then
                slot = slot + 1
                if not qualified then row[column] = params[slot] end
            elseif value == 'NULL' then
                if not qualified then row[column] = nil end
            else
                local literal = value:match("^'(.*)'$")
                if literal and not qualified then row[column] = literal end
            end
        end
    end
end

local function executeUpdate(sql, params)
    if store.failing then error('storage failure', 0) end

    local row = store.ride
    if not row then return 0 end

    local matched, recognised = whereMatches(sql, row, params)
    if not recognised or not matched then return 0 end

    -- UPDATE `ojol_drivers` d JOIN `ojol_rides` r ON r.driver_citizenid = d.citizenid
    -- only means anything when the ride actually names a driver.
    if sql:find('JOIN') and row.driver_citizenid == nil then return 0 end

    applySet(sql, row, params)
    return 1
end

local function executeSingle(sql, params)
    if store.failing then error('storage failure', 0) end

    local row = store.ride
    if not row then return nil end
    if rideIdFromParams(row, params) == nil then return nil end

    if sql:find('driver_citizenid') then
        return { status = row.status, driver_citizenid = row.driver_citizenid }
    end

    return { status = row.status }
end

---The real API reports whether the TRANSACTION committed, not how many rows it
---moved - which is exactly why a caller must confirm the row afterwards.
local function executeTransaction(statements)
    if store.failing then error('storage failure', 0) end

    for i = 1, #statements do
        executeUpdate(statements[i].query, statements[i].values)
    end

    return true
end

MySQL = {
    update = { await = function(sql, params) return executeUpdate(sql, params or {}) end },
    single = { await = function(sql, params) return executeSingle(sql, params or {}) end },
    query = { await = function() return {} end },
    transaction = { await = function(statements) return executeTransaction(statements) end },
}

package.preload['server.database'] = nil
package.loaded['server.database'] = nil

local db = require 'server.database'

-- Assignment compare-and-set ---------------------------------------------------

h.test('the CAS wins on a still-searching, still-unassigned row', function()
    local ride = liveRide()

    h.eq(db.AcceptRide('ride-1', 'driver-a', 1000), 1, 'affected rows')
    h.eq(ride.driver_citizenid, 'driver-a', 'persisted driver')
    h.eq(ride.accepted_at, 1000, 'persisted acceptance time')
    h.eq(db.FetchRideAssignment('ride-1').driver_citizenid, 'driver-a', 'read back')
end)

h.test('the CAS refuses a row storage already cancelled', function()
    local ride = liveRide({ status = 'CANCELLED_CUSTOMER' })

    h.eq(db.AcceptRide('ride-1', 'driver-a', 1000), 0, 'affected rows')
    h.eq(ride.driver_citizenid, nil, 'no driver written')
    h.eq(ride.accepted_at, nil, 'no acceptance time written')
    h.eq(ride.status, 'CANCELLED_CUSTOMER', 'status untouched')
end)

h.test('the CAS refuses a row storage already completed', function()
    local ride = liveRide({ status = 'COMPLETED' })

    h.eq(db.AcceptRide('ride-1', 'driver-a', 1000), 0, 'affected rows')
    h.eq(ride.driver_citizenid, nil, 'no driver written')
    h.eq(ride.status, 'COMPLETED', 'status untouched')
end)

h.test('the CAS never overwrites a driver storage already names', function()
    local ride = liveRide({ driver_citizenid = 'driver-first', accepted_at = 555 })

    h.eq(db.AcceptRide('ride-1', 'driver-second', 1000), 0, 'affected rows')
    h.eq(ride.driver_citizenid, 'driver-first', 'first assignment preserved')
    h.eq(ride.accepted_at, 555, 'first acceptance time preserved')
end)

h.test('two simultaneous accepts produce exactly one winner', function()
    local ride = liveRide()

    h.eq(db.AcceptRide('ride-1', 'driver-a', 1000), 1, 'first accept')
    h.eq(db.AcceptRide('ride-1', 'driver-b', 1001), 0, 'second accept')
    h.eq(ride.driver_citizenid, 'driver-a', 'exactly one driver')
    h.eq(ride.accepted_at, 1000, 'exactly one acceptance time')
end)

h.test('a storage failure propagates and writes nothing', function()
    local ride = liveRide()
    store.failing = true

    h.eq(pcall(db.AcceptRide, 'ride-1', 'driver-a', 1000), false, 'error propagates')
    h.eq(ride.driver_citizenid, nil, 'no driver written')
    h.eq(ride.accepted_at, nil, 'no acceptance time written')
end)

h.test('a refused CAS consumes nothing and leaves the ride winnable', function()
    local ride = liveRide({ status = 'CANCELLED_CUSTOMER' })

    h.eq(db.AcceptRide('ride-1', 'driver-a', 1000), 0, 'refused accept')
    h.eq(ride.driver_citizenid, nil, 'no partial assignment')

    -- The row is legitimately released (the cancellation was rolled back by an
    -- operator): the same ride can now be won normally.
    ride.status = 'SEARCHING'

    h.eq(db.AcceptRide('ride-1', 'driver-a', 1001), 1, 'later accept')
    h.eq(ride.driver_citizenid, 'driver-a', 'driver assigned once')
end)

h.test('a missing row reports no assignment rather than an empty one', function()
    resetStore(nil)

    h.eq(db.FetchRideAssignment('ride-gone'), nil, 'assignment')
    h.eq(db.FetchRideStatus('ride-gone'), nil, 'status')
    h.eq(db.AcceptRide('ride-gone', 'driver-a', 1000), 0, 'affected rows')
end)

-- Reopening -------------------------------------------------------------------

h.test('a live assigned row is released by ReopenRide', function()
    local ride = liveRide({ status = 'DRIVER_ENROUTE', driver_citizenid = 'driver-a', accepted_at = 555 })

    h.eq(db.ReopenRide('ride-1'), 1, 'affected rows')
    h.eq(ride.status, 'SEARCHING', 'status')
    h.eq(ride.driver_citizenid, nil, 'driver released')
    h.eq(ride.accepted_at, nil, 'acceptance time cleared')
end)

h.test('reopening an already-released row is a benign repeat', function()
    local ride = liveRide()

    h.eq(db.ReopenRide('ride-1'), 1, 'report')
    h.eq(ride.status, 'SEARCHING', 'status')
end)

h.test('no terminal status can ever be resurrected', function()
    local terminal = { 'COMPLETED', 'CANCELLED_CUSTOMER', 'CANCELLED_DRIVER', 'FAILED' }

    for i = 1, #terminal do
        local status = terminal[i]
        local ride = liveRide({ status = status, driver_citizenid = 'driver-a' })

        h.eq(db.ReopenRide('ride-1'), 0, 'ReopenRide on ' .. status)
        h.eq(ride.status, status, 'status preserved for ' .. status)
        h.eq(ride.driver_citizenid, 'driver-a', 'driver preserved for ' .. status)

        h.eq(db.ReopenRideRecalculated('ride-1', {
            pickup = { x = 5, y = 6, z = 7 },
            distanceMeters = 10,
            fare = 11000,
            driverPayout = 9900,
            companyFee = 1100,
        }), 0, 'ReopenRideRecalculated on ' .. status)

        h.eq(ride.pickup_x, 100, 'pickup untouched for ' .. status)
        h.eq(ride.fare, 12000, 'fare untouched for ' .. status)
        h.eq(ride.status, status, 'status preserved after recalculation for ' .. status)
    end
end)

h.test('an after-pickup recovery moves the pickup on a live row', function()
    local ride = liveRide({ status = 'ENROUTE_DESTINATION', driver_citizenid = 'driver-a' })

    h.eq(db.ReopenRideRecalculated('ride-1', {
        pickup = { x = 5, y = 6, z = 7 },
        distanceMeters = 800,
        fare = 11000,
        driverPayout = 9900,
        companyFee = 1100,
    }), 1, 'affected rows')

    h.eq(ride.status, 'SEARCHING', 'status')
    h.eq(ride.driver_citizenid, nil, 'driver released')
    h.eq(ride.pickup_x, 5, 'recalculated pickup')
    h.eq(ride.fare, 11000, 'recalculated fare')
    h.eq(ride.destination_x, 2000, 'destination preserved')
end)

-- Finalization ----------------------------------------------------------------

h.test('a completed trip finalizes idempotently', function()
    local ride = liveRide({ status = 'ENROUTE_DESTINATION', driver_citizenid = 'driver-a' })
    store.ledgerPaid = true

    h.eq(db.FinalizeRide({ rideId = 'ride-1', driverPayout = 10800 }, 'COMPLETED'), 1, 'first finalize')
    h.eq(ride.status, 'COMPLETED', 'status')
    h.eq(ride.completed_at ~= nil, true, 'completion timestamp')

    -- An identical repeat is idempotent: the row is already exactly where the
    -- caller wanted it, so reporting success is correct.
    h.eq(db.FinalizeRide({ rideId = 'ride-1', driverPayout = 10800 }, 'COMPLETED'), 1, 'identical repeat')
end)

h.test('a completion storage already closed differently is never reported as done', function()
    local ride = liveRide({ status = 'CANCELLED_CUSTOMER', driver_citizenid = 'driver-a' })
    store.ledgerPaid = true

    -- Both statements carry the terminal guard, so the transaction COMMITS while
    -- affecting nothing. Reporting success would make the caller finalize the
    -- runtime ride as COMPLETED while storage says the customer cancelled.
    h.eq(db.FinalizeRide({ rideId = 'ride-1', driverPayout = 10800 }, 'COMPLETED'), 0, 'affected rows')
    h.eq(ride.status, 'CANCELLED_CUSTOMER', 'status untouched')
    h.eq(ride.completed_at, nil, 'no completion timestamp')
end)

h.test('a completion without a paid fare ledger is refused', function()
    local ride = liveRide({ status = 'ENROUTE_DESTINATION', driver_citizenid = 'driver-a' })
    store.ledgerPaid = false

    h.eq(db.FinalizeRide({ rideId = 'ride-1', driverPayout = 10800 }, 'COMPLETED'), 0, 'affected rows')
    h.eq(ride.status, 'ENROUTE_DESTINATION', 'status untouched')
    h.eq(ride.completed_at, nil, 'no completion timestamp')
end)

h.test('a non-completed outcome is written once and never overwritten', function()
    local ride = liveRide({ status = 'SEARCHING' })

    h.eq(db.FinalizeRide({ rideId = 'ride-1', compensationEligible = false }, 'CANCELLED_CUSTOMER'), 1, 'first write')
    h.eq(ride.status, 'CANCELLED_CUSTOMER', 'status')
    h.eq(ride.cancelled_at ~= nil, true, 'cancellation timestamp')

    h.eq(db.FinalizeRide({ rideId = 'ride-1', compensationEligible = false }, 'CANCELLED_DRIVER'), 0, 'second write')
    h.eq(ride.status, 'CANCELLED_CUSTOMER', 'terminal status preserved')
end)
