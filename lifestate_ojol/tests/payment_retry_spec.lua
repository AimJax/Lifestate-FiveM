-- Payment ledger RETRY semantics (Phase 3B hardening).
--
-- The existing payment_spec proves a failed fare rolls back. It does NOT prove
-- the next attempt can actually run - which is exactly what was broken: a clean
-- failure or a completed rollback left the steps in a state the following
-- attempt refused ('failure after ...' -> 'database_error' on retry).
--
-- These specs drive the real server/payments.lua against a stub whose ledger
-- implements the same predicates as the SQL in server/database.lua, and assert
-- on money that actually MOVED (refused attempts are counted separately), so
-- "charged exactly once" means exactly that.

local h = require 'tests.harness'

local STEPS = { 'customer', 'driver', 'company' }

---Fresh ledger row, matching the schema defaults.
local function newLedger(action)
    return {
        ledger_id = 'ride:ride-retry:' .. action,
        ride_id = 'ride-retry',
        action = action,
        status = 'pending',
        payment_method = 'cash',
        customer_step = action == 'fare' and 'pending' or 'not_required',
        driver_step = 'pending',
        company_step = 'pending',
        customer_rollback = 'pending',
        driver_rollback = 'pending',
        company_rollback = 'pending',
    }
end

---Model of ResetMoneyLedgerForRetry: the same guard clauses as the single
---UPDATE in server/database.lua.
local function resetForRetry(ledger)
    local okStatus = { pending = true, failed = true, rolled_back = true }
    if not okStatus[ledger.status] then return 0 end

    local okStep = { pending = true, failed = true, applied = true, not_required = true }
    local okRollback = { pending = true, applied = true }

    for _, step in ipairs(STEPS) do
        if not okStep[ledger[step .. '_step']] then return 0 end
        if not okRollback[ledger[step .. '_rollback']] then return 0 end
    end

    for _, step in ipairs(STEPS) do
        if ledger[step .. '_step'] == 'applied' and ledger[step .. '_rollback'] ~= 'applied' then
            return 0
        end
    end

    for _, step in ipairs(STEPS) do
        local forward = ledger[step .. '_step']
        -- Both clean states go back to 'pending': 'failed' never moved money,
        -- 'applied' did but its rollback is confirmed (guarded above).
        if forward == 'applied' or forward == 'failed' then
            ledger[step .. '_step'] = 'pending'
        end
        ledger[step .. '_rollback'] = 'pending'
    end

    ledger.status, ledger.failed_step, ledger.failure_reason = 'pending', nil, nil
    return 1
end

local fareRide = {
    rideId = 'ride-retry', customerCitizenid = 'customer', driverCitizenId = 'driver',
    paymentMethod = 'cash', fare = 10000, driverPayout = 9000, companyFee = 1000,
}

local compensationRide = { rideId = 'ride-retry', driverCitizenId = 'driver', compensationEligible = true }

---@param action string 'fare' | 'compensation'
---@param fail table|nil operation names that are currently broken
---@return table payments, table ledger, table moves, table blocked, table control, table stats
local function loadPayments(action, fail)
    local ledger = newLedger(action)
    local control = { fail = fail or {} }
    local moves, blocked, stats = {}, {}, {}

    -- Only SUCCESSFUL wallet operations are recorded in `moves`, so the specs
    -- read as net money movement (the spec for "charged once" really means once).
    local function wallet(name)
        if control.fail[name] then
            blocked[#blocked + 1] = name
            return false
        end
        moves[#moves + 1] = name
        return true
    end

    for _, name in ipairs({ 'server.payments', 'server.database', 'server.company', 'config.server' }) do
        package.loaded[name] = nil
    end

    package.preload['config.server'] = function() return { cancelDriverCompensation = 5000 } end

    package.preload['server.database'] = function()
        return {
            EnsureMoneyLedger = function() return ledger end,
            FetchMoneyLedger = function() return ledger end,
            ResetMoneyLedgerForRetry = function() return resetForRetry(ledger) end,
            TransitionMoneyLedgerStep = function(_, field, from, to)
                if ledger[field] ~= from then return 0 end
                ledger[field], ledger.status = to, 'processing'
                return 1
            end,
            MarkMoneyLedgerFailed = function(_, step, why)
                ledger[step] = 'failed'
                ledger.status, ledger.failed_step, ledger.failure_reason = 'failed', step, why
                return 1
            end,
            MarkMoneyLedgerReconciliation = function(_, step, why)
                ledger.status, ledger.failed_step, ledger.failure_reason = 'needs_reconciliation', step, why
                return 1
            end,
            MarkMoneyLedgerRolledBack = function() ledger.status = 'rolled_back' return 1 end,
            MarkMoneyLedgerPaid = function()
                if ledger.action == 'fare' and ledger.customer_step ~= 'applied' then return 0 end
                if ledger.driver_step ~= 'applied' or ledger.company_step ~= 'applied' then return 0 end
                ledger.status = 'paid'
                return 1
            end,
            IncrementDriverStat = function(_, column)
                stats[#stats + 1] = column
                return 1
            end,
            UpdateRidePaymentMethod = function() return 1 end,
        }
    end

    package.preload['server.company'] = function()
        return {
            AddCompanyFunds = function() return wallet('company_add') end,
            RemoveCompanyFunds = function() return wallet('company_remove') end,
        }
    end

    exports = { qbx_core = {
        GetPlayerByCitizenId = function(_, citizenid)
            return {
                PlayerData = { money = { cash = 99999, bank = 99999 } },
                Functions = {
                    AddMoney = function()
                        return wallet(citizenid == 'driver' and 'driver_add' or 'customer_add')
                    end,
                    RemoveMoney = function()
                        return wallet(citizenid == 'customer' and 'customer_remove' or 'driver_remove')
                    end,
                },
            }
        end,
    } }

    return require('server.payments'), ledger, moves, blocked, control, stats
end

local function count(list, wanted)
    local n = 0
    for _, name in ipairs(list) do if name == wanted then n = n + 1 end end
    return n
end

-- 1. Clean failure (insufficient customer funds): nothing moved, retry works.

h.test('clean fare failure is retryable and then charges exactly once', function()
    local payments, ledger, moves, blocked, control = loadPayments('fare', { customer_remove = true })

    h.eq(select(2, payments.PayRide(fareRide)), 'insufficient_funds', 'first reason')
    h.eq(ledger.status, 'failed', 'ledger after the clean failure')
    h.eq(#moves, 0, 'money moved by the failed attempt')
    h.eq(count(blocked, 'customer_remove'), 1, 'refused debits')

    -- The customer tops up; the driver presses finish again.
    control.fail.customer_remove = false
    h.eq(select(1, payments.PayRide(fareRide)), true, 'retry result')
    h.eq(ledger.status, 'paid', 'ledger after the retry')
    h.eq(count(moves, 'customer_remove'), 1, 'customer debits')
    h.eq(count(moves, 'driver_add'), 1, 'driver credits')
    h.eq(count(moves, 'company_add'), 1, 'company credits')
end)

-- 2. Driver credit failure: full rollback, then a successful retry.

h.test('rolled back fare (driver credit) is retryable and settles once', function()
    local payments, ledger, moves, blocked, control = loadPayments('fare', { driver_add = true })

    h.eq(select(1, payments.PayRide(fareRide)), false, 'first result')
    h.eq(ledger.status, 'rolled_back', 'ledger after the rollback')
    h.eq(count(moves, 'customer_remove'), 1, 'debits before the retry')
    h.eq(count(moves, 'customer_add'), 1, 'refunds before the retry')
    h.eq(count(moves, 'driver_add'), 0, 'driver credits before the retry')

    control.fail.driver_add = false
    h.eq(select(1, payments.PayRide(fareRide)), true, 'retry result')
    h.eq(ledger.status, 'paid', 'ledger after the retry')

    h.eq(count(moves, 'customer_remove'), 2, 'total customer debits')
    h.eq(count(moves, 'customer_add'), 1, 'total customer refunds')
    h.eq(count(moves, 'driver_add'), 1, 'driver paid exactly once')
    h.eq(count(moves, 'company_add'), 1, 'company paid exactly once')
    h.eq(count(moves, 'driver_remove'), 0, 'no driver clawback on retry')
end)

-- 3. Company credit failure: driver + customer rolled back, then retry.

h.test('rolled back fare (company credit) is retryable and settles once', function()
    local payments, ledger, moves, blocked, control = loadPayments('fare', { company_add = true })

    local _, reason = payments.PayRide(fareRide)
    h.eq(reason, 'company_failed', 'first reason (' .. table.concat(blocked, ',') .. ')')
    h.eq(ledger.status, 'rolled_back', 'ledger after the rollback')
    h.eq(count(moves, 'driver_remove'), 1, 'driver clawed back')
    h.eq(count(moves, 'customer_add'), 1, 'customer refunded')

    control.fail.company_add = false
    h.eq(select(1, payments.PayRide(fareRide)), true, 'retry result')
    h.eq(ledger.status, 'paid', 'ledger after the retry')
    h.eq(count(moves, 'customer_remove'), 2, 'total customer debits')
    h.eq(count(moves, 'customer_add'), 1, 'total customer refunds')
    h.eq(count(moves, 'driver_add'), 2, 'total driver credits')
    h.eq(count(moves, 'driver_remove'), 1, 'total driver clawbacks')
    h.eq(count(moves, 'company_add'), 1, 'company credited exactly once')
end)

-- 4. Compensation retry: company debit reversed, then paid once.

h.test('rolled back compensation is retryable and pays Rp5.000 once', function()
    local payments, ledger, moves, blocked, control = loadPayments('compensation', { driver_add = true })

    h.eq(select(1, payments.PayCompensation(compensationRide)), false, 'first result')
    h.eq(ledger.status, 'rolled_back', 'ledger after the rollback')
    h.eq(count(moves, 'company_add'), 1, 'company refunded')

    control.fail.driver_add = false
    h.eq(select(1, payments.PayCompensation(compensationRide)), true, 'retry result')
    h.eq(ledger.status, 'paid', 'ledger after the retry')
    h.eq(count(moves, 'company_remove'), 2, 'total company debits')
    h.eq(count(moves, 'company_add'), 1, 'total company refunds')
    h.eq(count(moves, 'driver_add'), 1, 'driver credited exactly once')
end)

h.test('compensation stat is written once, only with a durable paid ledger', function()
    local payments, ledger, moves, _, control, stats = loadPayments('compensation', { driver_add = true })

    payments.PayCompensation(compensationRide)
    h.eq(#stats, 0, 'stats after the rolled back attempt')

    control.fail.driver_add = false
    h.eq(select(1, payments.PayCompensation(compensationRide)), true, 'retry result')
    h.eq(#stats, 1, 'stats after the retry')
    h.eq(stats[1], 'total_compensation', 'stat column')

    h.eq(select(1, payments.PayCompensation(compensationRide)), true, 'replay')
    h.eq(#stats, 1, 'stats after a replay')
    h.eq(ledger.status, 'paid', 'ledger status')
end)

-- 5/6. The reset must never touch an ambiguous or still-out state.

h.test('a rollback that itself failed must not be retried or move money', function()
    local payments, ledger, moves, _, control = loadPayments('compensation',
        { driver_add = true, company_add = true })

    h.eq(select(2, payments.PayCompensation(compensationRide)), 'needs_reconciliation', 'first reason')
    h.eq(ledger.status, 'needs_reconciliation', 'ledger status')
    h.eq(count(moves, 'company_remove'), 1, 'company debit')

    local before = #moves
    h.eq(select(2, payments.PayCompensation(compensationRide)), 'needs_reconciliation', 'retry reason')
    h.eq(#moves, before, 'money moved by the blocked retry')
    h.eq(ledger.status, 'needs_reconciliation', 'ledger status after the blocked retry')
end)

h.test('an ambiguous processing step is quarantined and never retried', function()
    local payments, ledger, moves = loadPayments('fare', {})
    ledger.status, ledger.driver_step = 'pending', 'processing'

    h.eq(select(2, payments.PayRide(fareRide)), 'needs_reconciliation', 'first reason')
    h.eq(#moves, 0, 'money moved')

    h.eq(select(2, payments.PayRide(fareRide)), 'needs_reconciliation', 'retry reason')
    h.eq(#moves, 0, 'money moved by the blocked retry')
end)

h.test('an applied step without a confirmed rollback refuses the reset', function()
    local payments, ledger, moves = loadPayments('fare', {})
    -- The customer's money is still out and was never put back.
    ledger.status = 'rolled_back'
    ledger.customer_step, ledger.driver_step, ledger.company_step = 'applied', 'applied', 'pending'
    ledger.customer_rollback, ledger.driver_rollback = 'applied', 'pending'

    h.eq(select(2, payments.PayRide(fareRide)), 'needs_reconciliation', 'reason')
    h.eq(ledger.status, 'needs_reconciliation', 'ledger status')
    h.eq(#moves, 0, 'money moved')
    h.eq(ledger.driver_step, 'applied', 'unsettled step left alone')
end)

h.test('the retry reset entry points refuse an ambiguous ledger', function()
    local payments, ledger = loadPayments('fare', {})
    ledger.status, ledger.company_step = 'pending', 'processing'

    h.eq(payments.ResetFareLedgerForRetry('ride-retry'), false, 'fare reset')
    h.eq(select(1, payments.ResetCompensationLedgerForRetry('ride-retry')), false, 'compensation reset')
end)

h.test('the retry reset entry points accept a cleanly failed ledger', function()
    local payments, ledger = loadPayments('fare', { customer_remove = true })

    payments.PayRide(fareRide)
    h.eq(ledger.status, 'failed', 'status before the reset')
    h.eq(payments.ResetFareLedgerForRetry('ride-retry'), true, 'fare reset')
    h.eq(ledger.status, 'pending', 'status after the reset')
    h.eq(ledger.customer_step, 'pending', 'customer step after the reset')
end)
