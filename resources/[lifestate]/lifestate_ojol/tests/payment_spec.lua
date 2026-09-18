local h = require 'tests.harness'

local ride = {
    rideId = 'ride-2', customerCitizenid = 'customer', driverCitizenId = 'driver',
    paymentMethod = 'cash', fare = 10000, driverPayout = 9000, companyFee = 1000,
}

local function loadPayments(options)
    options = options or {}
    local ledger = options.ledger or {
        ledger_id = 'ride:ride-2:fare', ride_id = 'ride-2', action = 'fare', status = 'pending',
        customer_step = 'pending', driver_step = 'pending', company_step = 'pending',
        customer_rollback = 'pending', driver_rollback = 'pending', company_rollback = 'pending',
    }
    local calls, reconciled, paidWrites = {}, nil, 0
    local function record(name) calls[#calls + 1] = name end
    local function fails(name)
        return options.failOperation == name
            or type(options.failOperation) == 'table' and options.failOperation[name] == true
    end

    package.loaded['server.payments'] = nil
    package.loaded['server.database'] = nil
    package.loaded['server.company'] = nil
    package.loaded['config.server'] = nil
    package.preload['config.server'] = function() return { cancelDriverCompensation = 5000 } end
    package.preload['server.database'] = function()
        return {
            EnsureMoneyLedger = function() return ledger end,
            FetchMoneyLedger = function() return ledger end,
            TransitionMoneyLedgerStep = function(_, field, from, to)
                if options.failTransition == field .. ':' .. to then return 0 end
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
                reconciled = { step, why }
                return 1
            end,
            MarkMoneyLedgerRolledBack = function() ledger.status = 'rolled_back' return 1 end,
            MarkMoneyLedgerPaid = function()
                paidWrites = paidWrites + 1
                if options.paidAfterWrite then ledger.status = 'paid' return 0 end
                if options.failPaid and paidWrites == 1 then return 0 end
                ledger.status = 'paid'
                return 1
            end,
            IncrementDriverStat = function() record('stat') return 1 end,
            UpdateRidePaymentMethod = function() return 1 end,
        }
    end
    package.preload['server.company'] = function()
        return {
            AddCompanyFunds = function()
                record('company_add')
                return not fails('company_add')
            end,
            RemoveCompanyFunds = function()
                record('company_remove')
                return not fails('company_remove')
            end,
        }
    end
    exports = { qbx_core = {
        GetPlayerByCitizenId = function(_, citizenid)
            return { PlayerData = { money = { cash = 99999, bank = 99999 } }, Functions = {
                AddMoney = function(_, _, _, why)
                    local name = citizenid == 'driver' and 'driver_add' or 'customer_add'
                    record(name)
                    return not fails(name)
                end,
                RemoveMoney = function(_, _, _, why)
                    local name = citizenid == 'customer' and 'customer_remove' or 'driver_remove'
                    record(name)
                    return not fails(name)
                end,
            } }
        end,
    } }
    return require('server.payments'), ledger, calls,
        function() return reconciled, paidWrites end
end

local function count(calls, wanted)
    local n = 0
    for _, name in ipairs(calls) do if name == wanted then n = n + 1 end end
    return n
end

h.test('successful fare moves each amount once and replay moves none', function()
    local payments, ledger, calls = loadPayments()
    h.eq(select(1, payments.PayRide(ride)), true, 'first payment')
    h.eq(ledger.status, 'paid', 'ledger status')
    h.eq(select(1, payments.PayRide(ride)), true, 'replay')
    h.eq(#calls, 3, 'total money calls')
end)

h.test('failure before customer debit moves no money', function()
    local payments, _, calls = loadPayments({ failTransition = 'customer_step:processing' })
    h.eq(select(1, payments.PayRide(ride)), false, 'result')
    h.eq(#calls, 0, 'money calls')
end)

for _, step in ipairs({ 'customer_step', 'driver_step', 'company_step' }) do
    h.test('failure after ' .. step .. ' application is quarantined without replay', function()
        local payments, ledger, calls = loadPayments({ failTransition = step .. ':applied' })
        h.eq(select(2, payments.PayRide(ride)), 'needs_reconciliation', 'reason')
        local before = #calls
        h.eq(select(2, payments.PayRide(ride)), 'needs_reconciliation', 'replay reason')
        h.eq(#calls, before, 'replayed money calls')
        h.eq(ledger.status, 'needs_reconciliation', 'ledger status')
    end)
end

h.test('driver credit failure rolls customer debit back', function()
    local payments, ledger, calls = loadPayments({ failOperation = 'driver_add' })
    local result = payments.PayRide(ride)
    h.eq(result, false, 'result (' .. table.concat(calls, ',') .. ')')
    h.eq(count(calls, 'customer_remove'), 1, 'customer debits')
    h.eq(count(calls, 'customer_add'), 1, 'customer rollbacks')
    h.eq(ledger.status, 'rolled_back', 'ledger status')
end)

h.test('company credit failure rolls driver and customer back', function()
    local payments, ledger, calls = loadPayments({ failOperation = 'company_add' })
    local result = payments.PayRide(ride)
    h.eq(result, false, 'result (' .. table.concat(calls, ',') .. ')')
    h.eq(count(calls, 'driver_remove'), 1, 'driver rollbacks')
    h.eq(count(calls, 'customer_add'), 1, 'customer rollbacks')
    h.eq(ledger.status, 'rolled_back', 'ledger status')
end)

h.test('rollback failure quarantines the ledger', function()
    local payments, ledger, calls = loadPayments({
        failOperation = { company_add = true, driver_remove = true },
    })
    h.eq(select(2, payments.PayRide(ride)), 'needs_reconciliation', 'reason')
    h.eq(ledger.status, 'needs_reconciliation', 'ledger status')
    h.eq(count(calls, 'driver_remove'), 1, 'failed rollback calls')
end)

h.test('all-applied failed final write is quarantined then DB-only finalized', function()
    local applied = {
        ledger_id = 'ride:ride-2:fare', ride_id = 'ride-2', action = 'fare', status = 'processing',
        customer_step = 'applied', driver_step = 'applied', company_step = 'applied',
        customer_rollback = 'pending', driver_rollback = 'pending', company_rollback = 'pending',
    }
    local payments, ledger, calls = loadPayments({ ledger = applied, failPaid = true })
    h.eq(select(2, payments.PayRide(ride)), 'needs_reconciliation', 'first reason')
    h.eq(#calls, 0, 'first money calls')
    h.eq(select(1, payments.PayRide(ride)), true, 'DB-only recovery')
    h.eq(ledger.status, 'paid', 'final status')
    h.eq(#calls, 0, 'recovery money calls')
end)

h.test('paid write response lost is recognized without replay', function()
    local payments, ledger, calls = loadPayments({ paidAfterWrite = true })
    h.eq(select(1, payments.PayRide(ride)), true, 'result')
    h.eq(ledger.status, 'paid', 'status')
    h.eq(#calls, 3, 'money calls')
end)

local compensationRide = {
    rideId = ride.rideId, driverCitizenId = ride.driverCitizenId,
    compensationEligible = true,
}
local function compensationLedger()
    return {
        ledger_id = 'ride:ride-2:compensation', ride_id = 'ride-2', action = 'compensation', status = 'pending',
        customer_step = 'not_required', driver_step = 'pending', company_step = 'pending',
        customer_rollback = 'pending', driver_rollback = 'pending', company_rollback = 'pending',
    }
end

h.test('compensation succeeds once and increments stats after durable paid', function()
    local payments, ledger, calls = loadPayments({ ledger = compensationLedger() })
    h.eq(select(1, payments.PayCompensation(compensationRide)), true, 'first payout')
    h.eq(select(1, payments.PayCompensation(compensationRide)), true, 'replay')
    h.eq(count(calls, 'company_remove'), 1, 'company debits')
    h.eq(count(calls, 'driver_add'), 1, 'driver credits')
    h.eq(count(calls, 'stat'), 1, 'stat writes')
    h.eq(ledger.status, 'paid', 'status')
end)

h.test('compensation failure before company debit moves no money', function()
    local payments, _, calls = loadPayments({
        ledger = compensationLedger(), failTransition = 'company_step:processing',
    })
    h.eq(select(1, payments.PayCompensation(compensationRide)), false, 'result')
    h.eq(#calls, 0, 'calls')
end)

h.test('compensation failure after company debit is quarantined', function()
    local payments, ledger, calls = loadPayments({
        ledger = compensationLedger(), failTransition = 'company_step:applied',
    })
    h.eq(select(2, payments.PayCompensation(compensationRide)), 'needs_reconciliation', 'reason')
    h.eq(count(calls, 'company_remove'), 1, 'company debits')
    h.eq(ledger.status, 'needs_reconciliation', 'status')
end)

h.test('compensation driver failure rolls company back', function()
    local payments, ledger, calls = loadPayments({
        ledger = compensationLedger(), failOperation = 'driver_add',
    })
    h.eq(select(1, payments.PayCompensation(compensationRide)), false, 'result')
    h.eq(count(calls, 'company_add'), 1, 'company rollbacks')
    h.eq(count(calls, 'stat'), 0, 'stat writes')
    h.eq(ledger.status, 'rolled_back', 'status')
end)

h.test('compensation rollback failure is quarantined', function()
    local payments, ledger = loadPayments({
        ledger = compensationLedger(), failOperation = { driver_add = true, company_add = true },
    })
    h.eq(select(2, payments.PayCompensation(compensationRide)), 'needs_reconciliation', 'reason')
    h.eq(ledger.status, 'needs_reconciliation', 'status')
end)

h.test('compensation all-applied recovery only finalizes DB and stats', function()
    local ledger = compensationLedger()
    ledger.company_step, ledger.driver_step, ledger.status = 'applied', 'applied', 'needs_reconciliation'
    local payments, _, calls = loadPayments({ ledger = ledger, failPaid = true })
    h.eq(select(2, payments.PayCompensation(compensationRide)), 'needs_reconciliation', 'first reason')
    h.eq(select(1, payments.PayCompensation(compensationRide)), true, 'recovery')
    h.eq(count(calls, 'company_remove'), 0, 'company debits')
    h.eq(count(calls, 'driver_add'), 0, 'driver credits')
    h.eq(count(calls, 'stat'), 1, 'stat writes')
end)
