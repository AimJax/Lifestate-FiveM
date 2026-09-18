local db = require 'server.database'

local M = {}

---Load the company balance once (startup / after external DB edits).
function M.RefreshCompanyBalance()
    return db.FetchCompanyBalance()
end

---Get the Ojol company balance (organization-owned, integer Rupiah).
---@return number
function M.GetCompanyBalance()
    return db.FetchCompanyBalance()
end

---Add company funds. Only server code may call this; amounts are integer Rupiah.
---Phase 3A foundation: no ride fares are processed yet.
---@param amount number positive integer
---@param reason string audit reason (reserved for future ledger)
---@param rideId string|number|nil reserved for future ride ledger
---@return boolean success
function M.AddCompanyFunds(amount, reason, rideId)
    if type(amount) ~= 'number' or math.floor(amount) ~= amount or amount <= 0 then
        print(('[ojol] AddCompanyFunds rejected: invalid amount %s (%s)'):format(tostring(amount), tostring(reason)))
        return false
    end

    local ok = db.AdjustCompanyBalance(amount, reason, rideId)
    if not ok then return false end

    return true
end

---Subtract company funds (cancellation compensation). The company balance is a
---SIGNED value by design: an owed Rp5.000 is paid even when the account is
---temporarily negative (operational debt). Money is never taken from a customer
---to cover it.
---@param amount number positive integer
---@param reason string audit reason
---@param rideId string|number|nil reserved for future ride ledger
---@return boolean success
function M.RemoveCompanyFunds(amount, reason, rideId)
    if type(amount) ~= 'number' or math.floor(amount) ~= amount or amount <= 0 then
        print(('[ojol] RemoveCompanyFunds rejected: invalid amount %s (%s)'):format(tostring(amount), tostring(reason)))
        return false
    end

    if db.FetchCompanyBalance() < amount then
        -- Going negative is allowed (signed balance migration, Phase 3C): keep
        -- going but surface the debt so it is visible in the server log.
        print(('[ojol] company balance going negative: -%d (%s)'):format(amount, tostring(reason)))
    end

    local ok = db.AdjustCompanyBalance(-amount, reason, rideId)
    if not ok then return false end

    return true
end

---Apply the 10% platform fee split. Returns the driver and company shares.
---Integers only: 90% driver / 10% company, company takes the rounding remainder so
---the two shares always sum to the original fare.
---@param fare number integer Rupiah
---@return number driverShare, number companyShare
function M.SplitFare(fare)
    if type(fare) ~= 'number' or math.floor(fare) ~= fare or fare <= 0 then
        return 0, 0
    end

    local companyShare = math.floor(fare * 0.1 + 0.5)
    local driverShare = fare - companyShare
    return driverShare, companyShare
end

return M
