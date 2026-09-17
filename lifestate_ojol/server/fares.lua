-- Fare + distance maths for the Ojol ride system.
-- Pure functions only: integer Rupiah out, no client input, no side effects.
-- Every value is deterministic so a preview and the locked fare can never differ.

local serverConfig = require 'config.server'
local company = require 'server.company'

local M = {}

---Euclidean map distance in metres between two vector-like points.
---@param from table|vector3
---@param to table|vector3
---@return number metres
function M.StraightLineMeters(from, to)
    local dx = (from.x or 0.0) - (to.x or 0.0)
    local dy = (from.y or 0.0) - (to.y or 0.0)
    local dz = (from.z or 0.0) - (to.z or 0.0)

    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

---Fare distance: map distance scaled by the configured road factor.
---FiveM cannot run road pathfinding server-side, so this is the documented,
---deterministic substitute. The driver's route choice never changes the fare.
---@param pickup table|vector3
---@param destination table|vector3
---@return number metres integer
function M.RouteDistanceMeters(pickup, destination)
    return math.floor(M.StraightLineMeters(pickup, destination) * serverConfig.roadDistanceMultiplier + 0.5)
end

---Fare = max(minimumFare, baseFare + round(perKilometer * km)).
---Integer Rupiah, nearest-Rupiah rounding, never negative.
---@param distanceMeters number
---@return number fare
function M.CalculateFare(distanceMeters)
    if type(distanceMeters) ~= 'number' or distanceMeters < 0 then
        return serverConfig.minimumFare
    end

    local distanceFare = math.floor(serverConfig.perKilometer * distanceMeters / 1000 + 0.5)
    local fare = serverConfig.baseFare + distanceFare

    if fare < serverConfig.minimumFare then
        return serverConfig.minimumFare
    end

    return fare
end

---Full locked quote for a ride. Delegates the 90/10 split to the company module
---so the fee rules exist in exactly one place.
---@param pickup table|vector3
---@param destination table|vector3
---@return table quote { distanceMeters, fare, driverPayout, companyFee }
function M.BuildQuote(pickup, destination)
    local distanceMeters = M.RouteDistanceMeters(pickup, destination)
    local fare = M.CalculateFare(distanceMeters)
    local driverPayout, companyFee = company.SplitFare(fare)

    return {
        distanceMeters = distanceMeters,
        fare = fare,
        driverPayout = driverPayout,
        companyFee = companyFee,
    }
end

---Format an integer Rupiah amount for user-facing text (no floating point).
---@param amount number
---@return string
function M.FormatRupiah(amount)
    local text = tostring(math.floor(tonumber(amount) or 0))
    local formatted = text:reverse():gsub('(%d%d%d)', '%1.')
    formatted = formatted:reverse()

    -- Drop a leading separator produced by exact multiples of 1000.
    if formatted:sub(1, 1) == '.' then
        formatted = formatted:sub(2)
    end

    return 'Rp' .. formatted
end

return M
