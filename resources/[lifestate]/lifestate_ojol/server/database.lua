local M = {}

---A ride in one of these states is finished forever: no code path may move it
---back into SEARCHING or reopen it. Kept in one place so the persistence
---guards below cannot drift apart.
local TERMINAL_STATUSES = { 'COMPLETED', 'CANCELLED_CUSTOMER', 'CANCELLED_DRIVER', 'FAILED' }
local TERMINAL_STATUSES_SQL = "'COMPLETED','CANCELLED_CUSTOMER','CANCELLED_DRIVER','FAILED'"

---@param status string
---@return boolean
function M.IsTerminalStatus(status)
    for i = 1, #TERMINAL_STATUSES do
        if TERMINAL_STATUSES[i] == status then return true end
    end
    return false
end

---Create all Ojol tables if missing. Safe to run on every restart (IF NOT EXISTS + INSERT IGNORE).
function M.EnsureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `ojol_drivers` (
            `citizenid` VARCHAR(50) NOT NULL,
            `rank` ENUM('driver','senior_driver','supervisor','ceo') NOT NULL DEFAULT 'driver',
            `active` TINYINT(1) NOT NULL DEFAULT 1,
            `profile_photo` LONGTEXT NULL DEFAULT NULL,
            `registered_by` VARCHAR(50) NULL DEFAULT NULL,
            `registered_at` INT UNSIGNED NOT NULL DEFAULT 0,
            `updated_at` INT UNSIGNED NOT NULL DEFAULT 0,
            `completed_rides` INT UNSIGNED NOT NULL DEFAULT 0,
            `rating_sum` INT UNSIGNED NOT NULL DEFAULT 0,
            `rating_count` INT UNSIGNED NOT NULL DEFAULT 0,
            `cancelled_before_pickup` INT UNSIGNED NOT NULL DEFAULT 0,
            `cancelled_after_pickup` INT UNSIGNED NOT NULL DEFAULT 0,
            `total_earnings` INT UNSIGNED NOT NULL DEFAULT 0,
            PRIMARY KEY (`citizenid`) USING BTREE,
            INDEX `rank` (`rank`) USING BTREE
        ) ENGINE = InnoDB CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `ojol_company` (
            `id` TINYINT UNSIGNED NOT NULL DEFAULT 1,
            `company_balance` BIGINT UNSIGNED NOT NULL DEFAULT 0,
            `updated_at` INT UNSIGNED NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`) USING BTREE
        ) ENGINE = InnoDB CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
    ]])

    -- Single company row. INSERT IGNORE keeps restarts idempotent.
    MySQL.query.await('INSERT IGNORE INTO `ojol_company` (`id`, `company_balance`) VALUES (1, 0)')

    -- Ride history. Live ride state lives in server memory; this table records the
    -- request and its outcome (plus the accepted driver) so history survives a
    -- restart. Position/status are never written per tick.
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `ojol_rides` (
            `ride_id` VARCHAR(32) NOT NULL,
            `customer_citizenid` VARCHAR(50) NOT NULL,
            `driver_citizenid` VARCHAR(50) NULL DEFAULT NULL,
            `pickup_x` DOUBLE NOT NULL DEFAULT 0,
            `pickup_y` DOUBLE NOT NULL DEFAULT 0,
            `pickup_z` DOUBLE NOT NULL DEFAULT 0,
            `destination_x` DOUBLE NOT NULL DEFAULT 0,
            `destination_y` DOUBLE NOT NULL DEFAULT 0,
            `destination_z` DOUBLE NOT NULL DEFAULT 0,
            `distance_meters` INT UNSIGNED NOT NULL DEFAULT 0,
            `fare` INT UNSIGNED NOT NULL DEFAULT 0,
            `driver_payout` INT UNSIGNED NOT NULL DEFAULT 0,
            `company_fee` INT UNSIGNED NOT NULL DEFAULT 0,
            `payment_method` ENUM('cash','bank') NOT NULL DEFAULT 'cash',
            `status` VARCHAR(32) NOT NULL DEFAULT 'SEARCHING',
            `payment_status` VARCHAR(16) NOT NULL DEFAULT 'pending',
            `compensation_eligible` TINYINT(1) NOT NULL DEFAULT 0,
            `compensation_paid` TINYINT(1) NOT NULL DEFAULT 0,
            `paid_at` INT UNSIGNED NULL DEFAULT NULL,
            `created_at` INT UNSIGNED NOT NULL DEFAULT 0,
            `accepted_at` INT UNSIGNED NULL DEFAULT NULL,
            `completed_at` INT UNSIGNED NULL DEFAULT NULL,
            `cancelled_at` INT UNSIGNED NULL DEFAULT NULL,
            PRIMARY KEY (`ride_id`) USING BTREE,
            INDEX `customer_citizenid` (`customer_citizenid`) USING BTREE,
            INDEX `driver_citizenid` (`driver_citizenid`) USING BTREE,
            INDEX `status` (`status`) USING BTREE,
            INDEX `created_at` (`created_at`) USING BTREE
        ) ENGINE = InnoDB CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
    ]])

    -- One rating per completed ride, enforced by the primary key.
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `ojol_ratings` (
            `ride_id` VARCHAR(32) NOT NULL,
            `driver_citizenid` VARCHAR(50) NOT NULL,
            `customer_citizenid` VARCHAR(50) NOT NULL,
            `rating` TINYINT UNSIGNED NOT NULL,
            `created_at` INT UNSIGNED NOT NULL DEFAULT 0,
            PRIMARY KEY (`ride_id`) USING BTREE,
            INDEX `driver_citizenid` (`driver_citizenid`) USING BTREE,
            INDEX `customer_citizenid` (`customer_citizenid`) USING BTREE
        ) ENGINE = InnoDB CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `ojol_money_ledger` (
            `ledger_id` VARCHAR(96) NOT NULL,
            `ride_id` VARCHAR(32) NOT NULL,
            `action` VARCHAR(24) NOT NULL,
            `status` VARCHAR(32) NOT NULL DEFAULT 'pending',
            `payment_method` VARCHAR(16) NULL DEFAULT NULL,
            `customer_amount` INT UNSIGNED NOT NULL DEFAULT 0,
            `driver_amount` INT UNSIGNED NOT NULL DEFAULT 0,
            `company_amount` INT UNSIGNED NOT NULL DEFAULT 0,
            `customer_step` VARCHAR(24) NOT NULL DEFAULT 'pending',
            `driver_step` VARCHAR(24) NOT NULL DEFAULT 'pending',
            `company_step` VARCHAR(24) NOT NULL DEFAULT 'pending',
            `customer_rollback` VARCHAR(24) NOT NULL DEFAULT 'pending',
            `driver_rollback` VARCHAR(24) NOT NULL DEFAULT 'pending',
            `company_rollback` VARCHAR(24) NOT NULL DEFAULT 'pending',
            `failed_step` VARCHAR(48) NULL DEFAULT NULL,
            `failure_reason` VARCHAR(255) NULL DEFAULT NULL,
            `created_at` INT UNSIGNED NOT NULL DEFAULT 0,
            `updated_at` INT UNSIGNED NOT NULL DEFAULT 0,
            `paid_at` INT UNSIGNED NULL DEFAULT NULL,
            PRIMARY KEY (`ledger_id`) USING BTREE,
            INDEX `ride_id` (`ride_id`) USING BTREE,
            INDEX `status` (`status`) USING BTREE
        ) ENGINE = InnoDB CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
    ]])

    -- Migrations. Idempotent by construction:
    --  - MODIFY to the same type is a no-op, so the signed-balance migration can
    --    run on every start (the company may go negative from compensation).
    --  - ADD COLUMN failures (duplicate column) are swallowed. Column existence
    --    is verified with a cheap information_schema lookup instead of guessing.
    MySQL.query.await([[ALTER TABLE `ojol_company`
        MODIFY `company_balance` BIGINT NOT NULL DEFAULT 0]])

    local function addColumnIfMissing(table_, column, definition)
        local existing = MySQL.scalar.await(
            'SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
            { table_, column })
        if existing and existing > 0 then return end

        local ok, err = pcall(MySQL.query.await, ('ALTER TABLE `%s` ADD COLUMN %s'):format(table_, definition))
        if not ok then
            print(('[ojol] schema migration %s.%s failed: %s'):format(table_, column, tostring(err)))
        end
    end

    addColumnIfMissing('ojol_rides', 'payment_status', "`payment_status` VARCHAR(16) NOT NULL DEFAULT 'pending'")
    addColumnIfMissing('ojol_rides', 'compensation_paid', '`compensation_paid` TINYINT(1) NOT NULL DEFAULT 0')
    addColumnIfMissing('ojol_rides', 'paid_at', '`paid_at` INT UNSIGNED NULL DEFAULT NULL')
    addColumnIfMissing('ojol_drivers', 'total_compensation', '`total_compensation` INT UNSIGNED NOT NULL DEFAULT 0')

    -- App Store foundation: persistent per-player installed apps (schema only this phase).
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `lifestate_phone_apps` (
            `citizenid` VARCHAR(50) NOT NULL,
            `app_id` VARCHAR(64) NOT NULL,
            `installed` TINYINT(1) NOT NULL DEFAULT 1,
            `installed_at` INT UNSIGNED NOT NULL DEFAULT 0,
            PRIMARY KEY (`citizenid`, `app_id`) USING BTREE,
            INDEX `app_id` (`app_id`) USING BTREE
        ) ENGINE = InnoDB CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
    ]])
end

-- Registration persistence -------------------------------------------------

---@param citizenid string
---@param rank string
---@param registeredBy string|nil
---@return number lastInsertId
function M.InsertDriver(citizenid, rank, registeredBy)
    local now = os.time()
    return MySQL.insert.await(
        'INSERT INTO `ojol_drivers` (`citizenid`, `rank`, `active`, `registered_by`, `registered_at`, `updated_at`) VALUES (?, ?, 1, ?, ?, ?)',
        { citizenid, rank, registeredBy, now, now })
end

---Soft-deactivate a driver (fire). The row and all of its history - profile,
---registration info and ride statistics - are preserved permanently; only the
---`active` flag changes. Rehire reactivates this same row.
---@param citizenid string
---@return number affectedRows
function M.DeactivateDriver(citizenid)
    local now = os.time()
    return MySQL.update.await(
        'UPDATE `ojol_drivers` SET `active` = 0, `updated_at` = ? WHERE `citizenid` = ?',
        { now, citizenid })
end

---Reactivate a previously fired driver's historical record (rehire).
---Preserves `profile_photo`, `registered_at` and every statistic column; only the
---rank/registrar/active/updated_at fields are touched.
---@param citizenid string
---@param rank string
---@param registeredBy string|nil
---@return number affectedRows
function M.ReactivateDriver(citizenid, rank, registeredBy)
    local now = os.time()
    return MySQL.update.await(
        'UPDATE `ojol_drivers` SET `active` = 1, `rank` = ?, `registered_by` = ?, `updated_at` = ? WHERE `citizenid` = ?',
        { rank, registeredBy, now, citizenid })
end

---@param citizenid string
---@return table? driver row
function M.FetchDriver(citizenid)
    return MySQL.single.await('SELECT * FROM `ojol_drivers` WHERE `citizenid` = ?', { citizenid })
end

---Load every driver record once at startup (small table, one query).
---@return table rows
function M.FetchAllDrivers()
    return MySQL.query.await('SELECT * FROM `ojol_drivers`') or {}
end

---Persist a meaningful driver-field transition (registration state, rank, profile).
---Online/busy are runtime-only and are never written here.
---@param citizenid string
---@param fields table map of column -> value (whitelisted)
---@return number affectedRows
function M.UpdateDriverFields(citizenid, fields)
    local allowed = {
        rank = true,
        active = true,
        profile_photo = true,
    }

    local sets, params = {}, {}

    for column, value in pairs(fields) do
        if allowed[column] then
            sets[#sets + 1] = ('`%s` = ?'):format(column)
            params[#params + 1] = value
        end
    end

    if #sets == 0 then return 0 end

    sets[#sets + 1] = '`updated_at` = ?'
    params[#params + 1] = os.time()
    params[#params + 1] = citizenid

    return MySQL.update.await(('UPDATE `ojol_drivers` SET %s WHERE `citizenid` = ?'):format(table.concat(sets, ', ')), params)
end

-- Ride history ------------------------------------------------------------

---Persist a new ride request. Called once per ride, at creation.
---@param ride table runtime ride
---@return number affectedRows
function M.InsertRide(ride)
    return MySQL.insert.await([[
        INSERT INTO `ojol_rides` (
            `ride_id`, `customer_citizenid`, `pickup_x`, `pickup_y`, `pickup_z`,
            `destination_x`, `destination_y`, `destination_z`, `distance_meters`,
            `fare`, `driver_payout`, `company_fee`, `payment_method`, `status`, `created_at`
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        ride.rideId, ride.customerCitizenid,
        ride.pickup.x, ride.pickup.y, ride.pickup.z,
        ride.destination.x, ride.destination.y, ride.destination.z,
        ride.distanceMeters, ride.fare, ride.driverPayout, ride.companyFee,
        ride.paymentMethod, ride.status, ride.createdAt,
    })
end

---Record the winning driver once a ride is accepted.
---
---This is an atomic compare-and-set, not a blind write: the row may only be
---assigned while storage still considers it SEARCHING and unassigned. A stale
---runtime view (a cancelled or completed row, or a row another driver already
---won) therefore cannot be overwritten, so the database can never name a driver
---for a ride it has already finished.
---
---affectedRows is the single source of truth for the caller:
---  1 = this caller won the row and the assignment is durable
---  0 = the ride was not actually available in storage (never a successful
---      repeat, even if the values happen to match what is already stored)
---@param rideId string
---@param driverCitizenid string
---@param acceptedAt number
---@return number affectedRows
function M.AcceptRide(rideId, driverCitizenid, acceptedAt)
    return MySQL.update.await([[
        UPDATE `ojol_rides`
        SET `driver_citizenid` = ?, `accepted_at` = ?
        WHERE `ride_id` = ?
          AND `status` = 'SEARCHING'
          AND `driver_citizenid` IS NULL
    ]], { driverCitizenid, acceptedAt, rideId })
end

---Persisted ownership/state of a ride row. Used to explain a rejected
---compare-and-set (or any write that should have moved the row) against what
---storage actually holds.
---@param rideId string
---@return table? row { status, driver_citizenid }
function M.FetchRideAssignment(rideId)
    return MySQL.single.await(
        'SELECT `status`, `driver_citizenid` FROM `ojol_rides` WHERE `ride_id` = ?', { rideId })
end

---Record a terminal outcome for a ride. Called once per ride.
---@param ride table
---@param status string terminal state
---@return number affectedRows
function M.FinalizeRide(ride, status)
    local flag = ride.compensationEligible and 1 or 0
    local terminal = TERMINAL_STATUSES_SQL

    if status == 'COMPLETED' then
        local now = os.time()
        local ok = MySQL.transaction.await({
            {
                query = ([[UPDATE `ojol_drivers` d
                    JOIN `ojol_rides` r ON r.`driver_citizenid` = d.`citizenid`
                    SET d.`completed_rides` = d.`completed_rides` + 1,
                        d.`total_earnings` = d.`total_earnings` + ?, d.`updated_at` = ?
                    WHERE r.`ride_id` = ? AND r.`status` NOT IN (%s)
                      AND EXISTS (SELECT 1 FROM `ojol_money_ledger` l
                          WHERE l.`ledger_id` = ? AND l.`status` = 'paid')]]):format(terminal),
                values = { ride.driverPayout, now, ride.rideId, ('ride:%s:fare'):format(ride.rideId) },
            },
            {
                query = ([[UPDATE `ojol_rides`
                    SET `status` = 'COMPLETED', `compensation_eligible` = ?, `completed_at` = ?
                    WHERE `ride_id` = ? AND `status` NOT IN (%s)
                      AND EXISTS (SELECT 1 FROM `ojol_money_ledger` l
                          WHERE l.`ledger_id` = ? AND l.`status` = 'paid')]]):format(terminal),
                values = { flag, now, ride.rideId, ('ride:%s:fare'):format(ride.rideId) },
            },
        })
        if not ok then return 0 end

        -- A committed transaction is NOT the same thing as a moved row: both
        -- statements carry the `status NOT IN (terminal)` guard, so a ride that
        -- somebody else already closed commits happily while affecting nothing.
        -- Confirm against storage, otherwise this call would report closing a
        -- ride whose durable outcome is a different terminal state, and the
        -- caller would finalize the runtime ride instead of reconciling it.
        return M.FetchRideStatus(ride.rideId) == 'COMPLETED' and 1 or 0
    end

    return MySQL.update.await(
        ('UPDATE `ojol_rides` SET `status` = ?, `compensation_eligible` = ?, `cancelled_at` = ? WHERE `ride_id` = ? AND `status` NOT IN (%s)')
            :format(terminal),
        { status, flag, os.time(), ride.rideId })
end

---Crash recovery: any ride that was still live when the resource stopped can
---never resume (its runtime state is gone), so it is closed as FAILED on start.
---A payment that was mid-flight ('processing') stays exactly there: money may
---already have moved, so silently flipping it to pending (double charge) or
---paid (free ride) would both be wrong. The startup log surfaces them.
---@return number affectedRows
function M.FailIncompleteRides()
    return MySQL.update.await([[
        UPDATE `ojol_rides`
        SET `status` = 'FAILED', `cancelled_at` = ?
        WHERE `status` NOT IN ('COMPLETED', 'CANCELLED_CUSTOMER', 'CANCELLED_DRIVER', 'FAILED')
    ]], { os.time() })
end

---Report payments that were mid-flight when the server stopped (admin follow-up).
---@return number count
function M.CountStuckPayments()
    local row = MySQL.single.await(
        "SELECT COUNT(*) AS n FROM `ojol_rides` WHERE `payment_status` = 'processing'")
    return row and tonumber(row.n) or 0
end

---Increment a driver counter column (whitelisted). Only meaningful transitions
---call this - never a tick.
---@param citizenid string
---@param column string one of the whitelisted counters
---@param amount number positive integer
---@return number affectedRows
function M.IncrementDriverStat(citizenid, column, amount)
    local allowed = {
        cancelled_before_pickup = true,
        cancelled_after_pickup = true,
        completed_rides = true,
        total_earnings = true,
        total_compensation = true,
    }

    if not allowed[column] then return 0 end

    local step = math.floor(tonumber(amount) or 1)
    if step <= 0 then return 0 end

    return MySQL.update.await(
        ('UPDATE `ojol_drivers` SET `%s` = `%s` + ? WHERE `citizenid` = ?'):format(column, column),
        { step, citizenid })
end

---Persist a ride's accepted payment method (customer may switch cash/bank
---mid-ride; the fare itself never changes).
---@param rideId string
---@param method string 'cash' | 'bank'
---@return number affectedRows
function M.UpdateRidePaymentMethod(rideId, method)
    return MySQL.update.await(
        'UPDATE `ojol_rides` SET `payment_method` = ? WHERE `ride_id` = ?',
        { method, rideId })
end

-- Durable money ledger -----------------------------------------------------

function M.FetchMoneyLedger(ledgerId)
    return MySQL.single.await('SELECT * FROM `ojol_money_ledger` WHERE `ledger_id` = ?', { ledgerId })
end

function M.EnsureMoneyLedger(ledgerId, ride, action, compensationAmount)
    local fare = action == 'fare'
    local customerStep = fare and 'pending' or 'not_required'
    MySQL.insert.await([[
        INSERT IGNORE INTO `ojol_money_ledger` (
            `ledger_id`, `ride_id`, `action`, `payment_method`,
            `customer_amount`, `driver_amount`, `company_amount`,
            `customer_step`, `created_at`, `updated_at`
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        ledgerId, ride.rideId, action, fare and ride.paymentMethod or 'bank',
        fare and ride.fare or 0,
        fare and ride.driverPayout or math.floor(tonumber(compensationAmount) or 0),
        fare and ride.companyFee or math.floor(tonumber(compensationAmount) or 0),
        customerStep, os.time(), os.time(),
    })
    return M.FetchMoneyLedger(ledgerId)
end

local LEDGER_FIELDS = {
    customer_step = true, driver_step = true, company_step = true,
    customer_rollback = true, driver_rollback = true, company_rollback = true,
}

function M.TransitionMoneyLedgerStep(ledgerId, field, fromState, toState)
    if not LEDGER_FIELDS[field] then return 0 end
    return MySQL.update.await(
        ('UPDATE `ojol_money_ledger` SET `%s` = ?, `status` = \'processing\', `updated_at` = ? WHERE `ledger_id` = ? AND `%s` = ? AND `status` NOT IN (\'paid\', \'needs_reconciliation\')')
            :format(field, field),
        { toState, os.time(), ledgerId, fromState })
end

function M.MarkMoneyLedgerFailed(ledgerId, step, failureReason)
    if not LEDGER_FIELDS[step] then return 0 end
    return MySQL.update.await(([[
        UPDATE `ojol_money_ledger`
        SET `%s` = 'failed', `status` = 'failed', `failed_step` = ?,
            `failure_reason` = ?, `updated_at` = ?
        WHERE `ledger_id` = ? AND `status` NOT IN ('paid', 'needs_reconciliation')
    ]]):format(step), { step, tostring(failureReason), os.time(), ledgerId })
end

function M.MarkMoneyLedgerReconciliation(ledgerId, step, failureReason)
    return MySQL.update.await([[
        UPDATE `ojol_money_ledger`
        SET `status` = 'needs_reconciliation', `failed_step` = ?, `failure_reason` = ?, `updated_at` = ?
        WHERE `ledger_id` = ? AND `status` <> 'paid'
    ]], { step, tostring(failureReason), os.time(), ledgerId })
end

function M.MarkMoneyLedgerRolledBack(ledgerId)
    return MySQL.update.await([[
        UPDATE `ojol_money_ledger`
        SET `status` = 'rolled_back', `updated_at` = ?
        WHERE `ledger_id` = ? AND `status` NOT IN ('paid', 'needs_reconciliation')
    ]], { os.time(), ledgerId })
end

---Return a ledger to a genuinely retryable state.
---
---Called at the start of a payment attempt when a previous one ended in a clean
---failure ('failed') or a fully confirmed rollback ('rolled_back'). A backward
---step in either of those states means the money is provably back where it
---started, so the forward steps can be reset to 'pending' and re-run.
---
---A forward step is clean and re-runnable when it is 'failed' (the operation
---refused, so nothing moved) or 'applied' with its rollback confirmed. Both go
---back to 'pending'; 'not_required' legs (the customer leg of a compensation
---ledger) are left exactly as they are.
---
---This is single-statement and refuses to guess. It affects 0 rows - and the
---caller quarantines instead - whenever:
---  - the ledger is paid, needs reconciliation, or is mid-flight ('processing'),
---  - ANY step (forward or backward) is 'processing' (money may have moved and
---    only the confirmation was lost),
---  - a forward step is 'applied' without its matching rollback being 'applied'
---    (the money is still out - resetting it would move it a second time).
---@param ledgerId string
---@return number affectedRows @>0 means the ledger is now 'pending' and retryable
function M.ResetMoneyLedgerForRetry(ledgerId)
    return MySQL.update.await([[
        UPDATE `ojol_money_ledger`
        SET
            `customer_step` = IF(`customer_step` IN ('applied', 'failed'), 'pending', `customer_step`),
            `driver_step`   = IF(`driver_step`   IN ('applied', 'failed'), 'pending', `driver_step`),
            `company_step`  = IF(`company_step`  IN ('applied', 'failed'), 'pending', `company_step`),
            `customer_rollback` = 'pending',
            `driver_rollback`   = 'pending',
            `company_rollback`  = 'pending',
            `status` = 'pending', `failed_step` = NULL, `failure_reason` = NULL,
            `updated_at` = ?
        WHERE `ledger_id` = ?
          AND `status` IN ('pending', 'failed', 'rolled_back')
          AND `customer_step` IN ('pending', 'failed', 'applied', 'not_required')
          AND `driver_step`   IN ('pending', 'failed', 'applied', 'not_required')
          AND `company_step`  IN ('pending', 'failed', 'applied', 'not_required')
          AND `customer_rollback` IN ('pending', 'applied')
          AND `driver_rollback`   IN ('pending', 'applied')
          AND `company_rollback`  IN ('pending', 'applied')
          AND (`customer_step` <> 'applied' OR `customer_rollback` = 'applied')
          AND (`driver_step`   <> 'applied' OR `driver_rollback`   = 'applied')
          AND (`company_step`  <> 'applied' OR `company_rollback`  = 'applied')
    ]], { os.time(), ledgerId })
end

function M.MarkMoneyLedgerPaid(ledgerId)
    return MySQL.update.await([[
        UPDATE `ojol_money_ledger`
        SET `status` = 'paid', `failed_step` = NULL, `failure_reason` = NULL,
            `paid_at` = ?, `updated_at` = ?
        WHERE `ledger_id` = ? AND `status` <> 'paid' AND (
            (`action` = 'fare' AND `customer_step` = 'applied' AND `driver_step` = 'applied' AND `company_step` = 'applied')
            OR (`action` = 'compensation' AND `driver_step` = 'applied' AND `company_step` = 'applied')
        )
    ]], { os.time(), os.time(), ledgerId })
end

function M.IsFareLedgerPaid(rideId)
    local row = M.FetchMoneyLedger(('ride:%s:fare'):format(rideId))
    return row ~= nil and row.status == 'paid'
end

-- The ride-level `payment_status` machine (MarkPaymentProcessing /
-- ResetPaymentPending / MarkRidePaid / RecordRidePayout / CountStuckPayments)
-- is superseded by the per-ride money ledger above, which is the only place
-- fare money is actually guarded. The columns and helpers are left in place for
-- the ride-history audit trail; nothing in the money path reads them.

function M.QuarantineInterruptedLedgers()
    local rows = MySQL.query.await([[
        SELECT `ledger_id`, `ride_id`, `failed_step` FROM `ojol_money_ledger`
        WHERE `status` = 'processing' OR `customer_step` = 'processing'
           OR `driver_step` = 'processing' OR `company_step` = 'processing'
           OR `customer_rollback` = 'processing' OR `driver_rollback` = 'processing'
           OR `company_rollback` = 'processing'
    ]]) or {}
    for _, row in ipairs(rows) do
        M.MarkMoneyLedgerReconciliation(row.ledger_id, row.failed_step or 'processing', 'restart_with_ambiguous_step')
        print(('[ojol] RECONCILIATION rideId=%s ledgerId=%s step=%s reason=restart_with_ambiguous_step')
            :format(tostring(row.ride_id), tostring(row.ledger_id), tostring(row.failed_step or 'processing')))
    end
    return #rows
end

function M.FinalizeAppliedFareLedgersOnStartup()
    local rows = MySQL.query.await([[
        SELECT r.`ride_id`, r.`driver_citizenid`, r.`driver_payout`, r.`compensation_eligible`
        FROM `ojol_rides` r
        JOIN `ojol_money_ledger` l ON l.`ledger_id` = CONCAT('ride:', r.`ride_id`, ':fare')
        WHERE r.`status` NOT IN ('COMPLETED', 'CANCELLED_CUSTOMER', 'CANCELLED_DRIVER', 'FAILED')
          AND l.`status` <> 'paid' AND l.`customer_step` = 'applied'
          AND l.`driver_step` = 'applied' AND l.`company_step` = 'applied'
    ]]) or {}
    local completed = 0
    for _, row in ipairs(rows) do
        local ledger = ('ride:%s:fare'):format(row.ride_id)
        if M.MarkMoneyLedgerPaid(ledger) > 0 then
            local finalized = M.FinalizeRide({
                rideId = row.ride_id,
                driverCitizenId = row.driver_citizenid,
                driverPayout = row.driver_payout,
                compensationEligible = row.compensation_eligible == 1,
            }, 'COMPLETED')
            if finalized and finalized > 0 then completed = completed + 1 end
        end
    end
    return completed
end

---Payment state machine on the persisted row. The affected-rows count is the
---authoritative idempotency guard: only the FIRST transition away from a state
---actually affects a row.
---@param rideId string
---@param fromStates string[] states the row must currently be in
---@param toState string
---@param paidAt number|nil
---@return number affectedRows
local function transitionPayment(rideId, fromStates, toState, paidAt)
    local placeholders = {}
    local params = { toState }

    for i = 1, #fromStates do
        placeholders[#placeholders + 1] = '?'
        params[#params + 1] = fromStates[i]
    end

    if paidAt then params[#params + 1] = paidAt end
    params[#params + 1] = rideId

    return MySQL.update.await(
        ('UPDATE `ojol_rides` SET `payment_status` = ?%s WHERE `ride_id` = ? AND `payment_status` IN (%s)')
            :format(paidAt and ', `paid_at` = ?' or '', table.concat(placeholders, ', ')),
        params)
end

---Claim the payment lock in the database (crash-visible). Returns > 0 only for
---the first claimant.
---@param rideId string
---@return number affectedRows
function M.MarkPaymentProcessing(rideId)
    return transitionPayment(rideId, { 'pending' }, 'processing', nil)
end

---A payment attempt that failed without moving money goes back to pending.
---@param rideId string
---@return number affectedRows
function M.ResetPaymentPending(rideId)
    return transitionPayment(rideId, { 'processing' }, 'pending', nil)
end

---Mark a ride as paid. Returns > 0 only for the first successful completion.
---@param rideId string
---@return number affectedRows
function M.MarkRidePaid(rideId)
    return transitionPayment(rideId, { 'pending', 'processing' }, 'paid', os.time())
end

---Persist a completed ride's money split (kept alongside the status for
---auditing; the runtime values were locked at creation).
---@param rideId string
---@param payout number
---@param fee number
---@return number affectedRows
function M.RecordRidePayout(rideId, payout, fee)
    return MySQL.update.await(
        'UPDATE `ojol_rides` SET `driver_payout` = ?, `company_fee` = ? WHERE `ride_id` = ?',
        { payout, fee, rideId })
end

---Claim the one-time cancellation compensation payout for a ride.
---@param rideId string
---@return number affectedRows @1 = we may pay, 0 = already paid or absent
function M.ClaimCompensationPaid(rideId)
    return MySQL.update.await(
        'UPDATE `ojol_rides` SET `compensation_paid` = 1 WHERE `ride_id` = ? AND `compensation_paid` = 0',
        { rideId })
end

---Release a compensation claim that failed to deliver (retry later).
---@param rideId string
---@return number affectedRows
function M.ResetCompensationPaid(rideId)
    return MySQL.update.await(
        'UPDATE `ojol_rides` SET `compensation_paid` = 0 WHERE `ride_id` = ?',
        { rideId })
end

---Fetch a completed ride row for rating validation (survives restarts).
---@param rideId string
---@return table? row
function M.FetchCompletedRide(rideId)
    return MySQL.single.await(
        "SELECT `ride_id`, `customer_citizenid`, `driver_citizenid`, `status` FROM `ojol_rides` WHERE `ride_id` = ? AND `status` = 'COMPLETED'",
        { rideId })
end

---Insert a ride rating. The primary key on ride_id makes a second rating for
---the same ride fail (affectedRows 0), which is the server-side "once only" rule.
---@param rideId string
---@param driverCitizenid string
---@param customerCitizenid string
---@param rating number integer 1..5
---@return number affectedRows
function M.InsertRating(rideId, driverCitizenid, customerCitizenid, rating)
    return MySQL.insert.await(
        'INSERT INTO `ojol_ratings` (`ride_id`, `driver_citizenid`, `customer_citizenid`, `rating`, `created_at`) VALUES (?, ?, ?, ?, ?)',
        { rideId, driverCitizenid, customerCitizenid, rating, os.time() })
end

---Has this ride already been rated?
---@param rideId string
---@return number? rating
function M.FetchRating(rideId)
    local row = MySQL.single.await('SELECT `rating` FROM `ojol_ratings` WHERE `ride_id` = ?', { rideId })
    return row and row.rating or nil
end

---Apply a rating to the driver's aggregate (sum + count; average is derived).
---@param driverCitizenid string
---@param rating number integer 1..5
---@return number affectedRows
function M.ApplyRatingAggregate(driverCitizenid, rating)
    return MySQL.update.await(
        'UPDATE `ojol_drivers` SET `rating_sum` = `rating_sum` + ?, `rating_count` = `rating_count` + 1, `updated_at` = ? WHERE `citizenid` = ?',
        { rating, os.time(), driverCitizenid })
end

function M.SubmitRatingTransaction(rideId, driverCitizenid, customerCitizenid, rating)
    return MySQL.transaction.await({
        {
            query = 'INSERT INTO `ojol_ratings` (`ride_id`, `driver_citizenid`, `customer_citizenid`, `rating`, `created_at`) VALUES (?, ?, ?, ?, ?)',
            values = { rideId, driverCitizenid, customerCitizenid, rating, os.time() },
        },
        {
            query = 'UPDATE `ojol_drivers` SET `rating_sum` = `rating_sum` + ?, `rating_count` = `rating_count` + 1, `updated_at` = ? WHERE `citizenid` = ?',
            values = { rating, os.time(), driverCitizenid },
        },
    })
end

function M.FetchLatestCompletedUnrated(customerCitizenid)
    return MySQL.single.await([[
        SELECT r.* FROM `ojol_rides` r
        LEFT JOIN `ojol_ratings` rating ON rating.`ride_id` = r.`ride_id`
        WHERE r.`customer_citizenid` = ? AND r.`status` = 'COMPLETED'
          AND rating.`ride_id` IS NULL
        ORDER BY r.`completed_at` DESC
        LIMIT 1
    ]], { customerCitizenid })
end

---The persisted status of a ride. Used to reconcile the runtime with storage
---when a write that should have moved the row did not affect it.
---@param rideId string
---@return string? status
function M.FetchRideStatus(rideId)
    local row = MySQL.single.await('SELECT `status` FROM `ojol_rides` WHERE `ride_id` = ?', { rideId })
    return row and row.status or nil
end

---True when the row is already exactly where the caller wanted to put it, which
---makes a "no rows affected" write a benign repeat instead of a failure. A row
---that is terminal, absent or still assigned reports false.
---@param rideId string
---@return boolean
local function isAlreadyReleased(rideId)
    local row = MySQL.single.await(
        'SELECT `status`, `driver_citizenid` FROM `ojol_rides` WHERE `ride_id` = ?', { rideId })

    return row ~= nil and row.status == 'SEARCHING' and row.driver_citizenid == nil
end

---Put an in-progress ride back into SEARCHING after its driver abandoned it.
---The ride keeps its identity, pickup, destination, fare and payment method.
---
---A terminal row is never resurrected: if the ride was already closed the
---statement affects nothing and the caller must handle the refusal instead of
---carrying on with a runtime ride that storage considers finished.
---@param rideId string
---@return number affectedRows @>0 only when the row is (now) searching
function M.ReopenRide(rideId)
    local affected = MySQL.update.await(
        ('UPDATE `ojol_rides` SET `driver_citizenid` = NULL, `accepted_at` = NULL, `status` = ? WHERE `ride_id` = ? AND `status` NOT IN (%s)')
            :format(TERMINAL_STATUSES_SQL),
        { 'SEARCHING', rideId })

    if affected and affected > 0 then return affected end
    if isAlreadyReleased(rideId) then return 1 end
    return 0
end

---Reopen after an after-pickup abandon: the pickup moves to the customer's
---current position and the remaining-route fare is recalculated server-side.
---The original destination and the payment method never change. Same terminal
---guard as ReopenRide.
---@param rideId string
---@param values table the validated recovery values to persist
---@return number affectedRows @>0 only when the row is (now) searching
function M.ReopenRideRecalculated(rideId, values)
    local affected = MySQL.update.await(([[
        UPDATE `ojol_rides`
        SET `driver_citizenid` = NULL, `accepted_at` = NULL, `status` = 'SEARCHING',
            `pickup_x` = ?, `pickup_y` = ?, `pickup_z` = ?,
            `distance_meters` = ?, `fare` = ?, `driver_payout` = ?, `company_fee` = ?
        WHERE `ride_id` = ? AND `status` NOT IN (%s)
    ]]):format(TERMINAL_STATUSES_SQL), {
        values.pickup.x, values.pickup.y, values.pickup.z,
        values.distanceMeters, values.fare, values.driverPayout, values.companyFee,
        rideId,
    })

    if affected and affected > 0 then return affected end
    if isAlreadyReleased(rideId) then return 1 end
    return 0
end

-- Phone app install state --------------------------------------------------

---Installed app ids for one character. Keyed by citizenid (Never by source:
---install state is per character and outlives the session).
---@param citizenid string
---@return table<string, boolean> set of app_id
function M.FetchInstalledApps(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return {} end

    local rows = MySQL.query.await(
        'SELECT `app_id` FROM `lifestate_phone_apps` WHERE `citizenid` = ? AND `installed` = 1',
        { citizenid })

    local installed = {}
    for i = 1, #(rows or {}) do
        installed[rows[i].app_id] = true
    end

    return installed
end

---Persist an install/uninstall transition.
---Upsert on purpose: an uninstall keeps the row (installed = 0) so a reinstall
---never needs a fresh identity, and `affectedRows` is NOT used as the success
---signal because MySQL legitimately reports 0 when a write changes nothing.
---@param citizenid string
---@param appId string
---@param installed boolean
---@return boolean success
function M.SetPhoneAppInstalled(citizenid, appId, installed)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    if type(appId) ~= 'string' or appId == '' then return false end

    local ok = pcall(MySQL.update.await, [[
        INSERT INTO `lifestate_phone_apps` (`citizenid`, `app_id`, `installed`, `installed_at`)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE `installed` = VALUES(`installed`), `installed_at` = VALUES(`installed_at`)
    ]], { citizenid, appId, installed and 1 or 0, os.time() })

    return ok == true
end

-- Company account ---------------------------------------------------------

---@return number balance in whole Rupiah
function M.FetchCompanyBalance()
    local row = MySQL.single.await('SELECT `company_balance` FROM `ojol_company` WHERE `id` = 1')
    return row and math.floor(row.company_balance or 0) or 0
end

---Atomically adjust the company balance. Amount must be a signed integer Rupiah value.
---The balance column is SIGNED: compensation the company owes is never blocked by
---a temporary negative operational balance (documented Phase 3C decision).
---@param amount number
---@param reason string @logged for future auditing
---@param rideId string|number|nil @reserved for future ride ledger
---@return boolean success
function M.AdjustCompanyBalance(amount, reason, rideId)
    if type(amount) ~= 'number' or math.floor(amount) ~= amount or amount == 0 then
        return false
    end

    local affected = MySQL.update.await(
        'UPDATE `ojol_company` SET `company_balance` = `company_balance` + ?, `updated_at` = ? WHERE `id` = 1',
        { amount, os.time() })

    if not affected or affected == 0 then return false end

    -- Phase 3A: no per-transaction ledger table yet; reason/rideId are kept in the API
    -- so future ride fares log without changing call sites.
    return true
end

return M
