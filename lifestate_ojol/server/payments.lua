local serverConfig = require 'config.server'
local db = require 'server.database'
local company = require 'server.company'

local M = { PaymentLocks = {} }

local function audit(rideId, step) return ('ojol-ride:%s:%s'):format(rideId, step) end
local function player(citizenid) return exports.qbx_core:GetPlayerByCitizenId(citizenid) end
local function ledgerId(rideId, action) return ('ride:%s:%s'):format(rideId, action) end

local function reconcile(rideId, id, step, why)
    pcall(db.MarkMoneyLedgerReconciliation, id, step, why)
    print(('[ojol] RECONCILIATION rideId=%s ledgerId=%s step=%s reason=%s')
        :format(tostring(rideId), tostring(id), tostring(step), tostring(why)))
end

local function transition(id, field, from, to)
    local ok, rows = pcall(db.TransitionMoneyLedgerStep, id, field, from, to)
    return ok and (rows or 0) > 0
end

local function fetch(id)
    local ok, row = pcall(db.FetchMoneyLedger, id)
    return ok and row or nil
end

local function hasProcessing(row)
    for _, field in ipairs({ 'customer_step', 'driver_step', 'company_step',
        'customer_rollback', 'driver_rollback', 'company_rollback' }) do
        if row[field] == 'processing' then return true, field end
    end
    return false
end

local function fareApplied(row)
    return row.customer_step == 'applied' and row.driver_step == 'applied' and row.company_step == 'applied'
end

local function finalizePaid(ride, row, movedNow)
    local ok, rows = pcall(db.MarkMoneyLedgerPaid, row.ledger_id)
    if ok and (rows or 0) > 0 then return true, nil, movedNow, true end
    local current = fetch(row.ledger_id)
    if current and current.status == 'paid' then return true, nil, false, false end
    reconcile(ride.rideId, row.ledger_id, 'paid_confirmation', 'database_finalize_failed')
    return false, 'needs_reconciliation', false, false
end

local function applyStep(ride, row, step, fn)
    local field = step .. '_step'
    if not transition(row.ledger_id, field, 'pending', 'processing') then return false, 'database_error' end
    if not fn() then
        pcall(db.MarkMoneyLedgerFailed, row.ledger_id, field, step .. '_failed')
        return false, step .. '_failed'
    end
    if not transition(row.ledger_id, field, 'processing', 'applied') then
        reconcile(ride.rideId, row.ledger_id, field, 'operation_applied_confirmation_failed')
        return false, 'needs_reconciliation'
    end
    row[field] = 'applied'
    return true
end

local function rollbackStep(ride, row, step, fn)
    local field = step .. '_rollback'
    if not transition(row.ledger_id, field, 'pending', 'processing') then
        reconcile(ride.rideId, row.ledger_id, field, 'rollback_intent_not_persisted')
        return false
    end
    if not fn() then
        reconcile(ride.rideId, row.ledger_id, field, 'rollback_operation_failed')
        return false
    end
    if not transition(row.ledger_id, field, 'processing', 'applied') then
        reconcile(ride.rideId, row.ledger_id, field, 'rollback_confirmation_failed')
        return false
    end
    return true
end

local function rollbackFare(ride, row)
    local customer, driver = player(ride.customerCitizenid), player(ride.driverCitizenId)
    if row.company_step == 'applied' and not rollbackStep(ride, row, 'company', function()
        return company.RemoveCompanyFunds(ride.companyFee, audit(ride.rideId, 'rollback-fee'), ride.rideId)
    end) then return false end
    if row.driver_step == 'applied' and not rollbackStep(ride, row, 'driver', function()
        return driver and driver.Functions.RemoveMoney(ride.paymentMethod, ride.driverPayout,
            audit(ride.rideId, 'rollback-payout')) or false
    end) then return false end
    if row.customer_step == 'applied' and not rollbackStep(ride, row, 'customer', function()
        return customer and customer.Functions.AddMoney(ride.paymentMethod, ride.fare,
            audit(ride.rideId, 'rollback-fare')) or false
    end) then return false end
    local ok, rows = pcall(db.MarkMoneyLedgerRolledBack, row.ledger_id)
    return ok and (rows or 0) > 0
end

function M.GetBalance(citizenid, method)
    local online = player(citizenid)
    local money = online and online.PlayerData and online.PlayerData.money
    return tonumber(money and money[method]) or 0
end

function M.PayRide(ride)
    if not ride or not ride.rideId or not ride.driverCitizenId then return false, 'invalid_ride' end
    if M.PaymentLocks[ride.rideId] then return false, 'payment_in_progress', false end
    M.PaymentLocks[ride.rideId] = true

    local function run()
        local id = ledgerId(ride.rideId, 'fare')
        local ensured, row = pcall(db.EnsureMoneyLedger, id, ride, 'fare')
        if not ensured or not row then return false, 'database_error', false end
        if row.status == 'paid' then return true, nil, false end
        local processing, field = hasProcessing(row)
        if processing then
            reconcile(ride.rideId, id, field, 'ambiguous_processing_state')
            return false, 'needs_reconciliation', false
        end
        if fareApplied(row) then return finalizePaid(ride, row, false) end
        if row.status == 'needs_reconciliation' then return false, 'needs_reconciliation', false end

        local customer = player(ride.customerCitizenid)
        if not customer then return false, 'customer_offline', false end
        local ok, why = applyStep(ride, row, 'customer', function()
            return customer.Functions.RemoveMoney(ride.paymentMethod, ride.fare, audit(ride.rideId, 'fare'))
        end)
        if not ok then return false, why == 'customer_failed' and 'insufficient_funds' or why, false end

        local driver = player(ride.driverCitizenId)
        ok, why = applyStep(ride, row, 'driver', function()
            return driver and driver.Functions.AddMoney(ride.paymentMethod, ride.driverPayout,
                audit(ride.rideId, 'payout')) or false
        end)
        if not ok then
            if why ~= 'needs_reconciliation' and not rollbackFare(ride, row) then why = 'needs_reconciliation' end
            return false, why, false
        end

        ok, why = applyStep(ride, row, 'company', function()
            return company.AddCompanyFunds(ride.companyFee, audit(ride.rideId, 'fee'), ride.rideId)
        end)
        if not ok then
            if why ~= 'needs_reconciliation' and not rollbackFare(ride, row) then why = 'needs_reconciliation' end
            return false, why, false
        end
        return finalizePaid(ride, row, true)
    end

    local protected, ok, why, moved = xpcall(run, debug.traceback)
    M.PaymentLocks[ride.rideId] = nil
    if not protected then
        reconcile(ride.rideId, ledgerId(ride.rideId, 'fare'), 'exception', ok)
        return false, 'needs_reconciliation', false
    end
    return ok, why, moved
end

function M.ChangePaymentMethod(ride, method, customerCitizenid)
    if not ride or not ride.rideId then return false, 'invalid_ride' end
    if method ~= 'cash' and method ~= 'bank' then return false, 'invalid_payment' end
    if customerCitizenid ~= ride.customerCitizenid then return false, 'not_ride_owner' end
    if method == ride.paymentMethod then return true end
    if M.PaymentLocks[ride.rideId] then return false, 'payment_in_progress' end
    if M.GetBalance(customerCitizenid, method) < ride.fare then return false, 'insufficient_funds' end
    local ok, rows = pcall(db.UpdateRidePaymentMethod, ride.rideId, method)
    if not ok or (rows or 0) == 0 then return false, 'database_error' end
    ride.paymentMethod = method
    return true
end

local function creditCompensation(ride, amount)
    local online = player(ride.driverCitizenId)
    if online then return online.Functions.AddMoney('bank', amount, audit(ride.rideId, 'compensation')) end
    local ok, offline = pcall(function() return exports.qbx_core:GetOfflinePlayer(ride.driverCitizenId) end)
    return ok and offline and offline.Functions
        and offline.Functions.AddMoney('bank', amount, audit(ride.rideId, 'compensation')) or false
end

function M.PayCompensation(ride)
    if not ride or not ride.rideId or not ride.driverCitizenId then return false, 'invalid_ride' end
    if not ride.compensationEligible then return false, 'not_eligible' end
    local amount = serverConfig.cancelDriverCompensation
    if type(amount) ~= 'number' or amount <= 0 then return false, 'not_eligible' end

    local id = ledgerId(ride.rideId, 'compensation')
    local ensured, row = pcall(db.EnsureMoneyLedger, id, ride, 'compensation', amount)
    if not ensured or not row then return false, 'database_error', false end
    if row.status == 'paid' then return true, nil, false end
    local processing, field = hasProcessing(row)
    if processing then
        reconcile(ride.rideId, id, field, 'ambiguous_processing_state')
        return false, 'needs_reconciliation', false
    end
    if row.company_step == 'applied' and row.driver_step == 'applied' then
        local paid, paidWhy, _, finalizedNow = finalizePaid(ride, row, false)
        if paid and finalizedNow then
            pcall(db.IncrementDriverStat, ride.driverCitizenId, 'total_compensation', amount)
        end
        return paid, paidWhy, false
    end
    if row.status == 'needs_reconciliation' then return false, 'needs_reconciliation', false end

    local ok, why = applyStep(ride, row, 'company', function()
        return company.RemoveCompanyFunds(amount, audit(ride.rideId, 'compensation'), ride.rideId)
    end)
    if not ok then return false, why, false end
    ok, why = applyStep(ride, row, 'driver', function() return creditCompensation(ride, amount) end)
    if not ok then
        if why ~= 'needs_reconciliation' then
            local rolledBack = rollbackStep(ride, row, 'company', function()
                return company.AddCompanyFunds(amount, audit(ride.rideId, 'rollback-compensation'), ride.rideId)
            end)
            if rolledBack then
                pcall(db.MarkMoneyLedgerRolledBack, row.ledger_id)
            else
                why = 'needs_reconciliation'
            end
        end
        return false, why, false
    end

    local paid, paidWhy, paidNow, finalizedNow = finalizePaid(ride, row, true)
    if paid and finalizedNow then pcall(db.IncrementDriverStat, ride.driverCitizenId, 'total_compensation', amount) end
    return paid, paidWhy, paidNow
end

return M
