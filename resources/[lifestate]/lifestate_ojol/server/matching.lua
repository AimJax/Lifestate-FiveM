-- Driver matching for the Ojol ride system (Phase 3B).
--
-- Ownership: search radius, per-driver offers, decline memory, the hidden
-- driver<->customer cooldown and the driver-facing ride view. Ride lifecycle
-- lives in server/rides.lua, which this module requires (never the other way
-- round) - all traffic in the other direction is server events.
--
-- Performance: matching only runs when something actually changes (a ride is
-- created / reopened, a tier expands, a driver becomes available, an offer is
-- answered). With no SEARCHING ride there are no timers and no work at all: the
-- per-tier timeout is cleared the moment a ride is assigned or closed.

local serverConfig = require 'config.server'
local drivers = require 'server.drivers'
local fares = require 'server.fares'
local rides = require 'server.rides'

local M = {}

M.DriverOffers = {}  -- [citizenid] = { [rideId] = true }  every ride offered to that driver
M.RideOffers = {}    -- [rideId]    = { [citizenid] = true }
M.RideDeclines = {}  -- [rideId]    = { [citizenid] = true }  survives a rematch
M.Cooldowns = {}     -- [driverCitizenid] = { [customerCitizenid] = expiresAtMs }
M.SearchState = {}   -- [rideId] = { tier = number, timer = handle|nil }

local RIDE_STATES = rides.STATES

-- Cooldowns ------------------------------------------------------------------

---Hidden 5-minute driver <-> customer cooldown after a driver cancels.
---@param driverCitizenid string
---@param customerCitizenid string
function M.SetPairCooldown(driverCitizenid, customerCitizenid)
    if not driverCitizenid or not customerCitizenid then return end

    local byCustomer = M.Cooldowns[driverCitizenid]
    if not byCustomer then
        byCustomer = {}
        M.Cooldowns[driverCitizenid] = byCustomer
    end

    byCustomer[customerCitizenid] = GetGameTimer() + (serverConfig.cancelPairCooldownSeconds * 1000)
end

---Is this driver still blocked from this customer? Expiry is evaluated lazily
---on access - there is deliberately no cleanup loop.
---@param driverCitizenid string
---@param customerCitizenid string
---@return boolean onCooldown
function M.IsOnCooldown(driverCitizenid, customerCitizenid)
    local byCustomer = M.Cooldowns[driverCitizenid]
    if not byCustomer then return false end

    local expiresAt = byCustomer[customerCitizenid]
    if not expiresAt then return false end

    if GetGameTimer() >= expiresAt then
        byCustomer[customerCitizenid] = nil
        if next(byCustomer) == nil then
            M.Cooldowns[driverCitizenid] = nil
        end
        return false
    end

    return true
end

-- Eligibility ----------------------------------------------------------------

---Current search radius for a ride (tier 1 before the first expansion).
---@param rideId string
---@return number metres
local function currentRadius(rideId)
    local state = M.SearchState[rideId]
    local tiers = serverConfig.searchRadiusTiers
    local tier = state and state.tier or 1

    return tiers[tier] or tiers[#tiers]
end

---Driver-facing offer eligibility. Position comes from the server's view of the
---ped, never from the client.
---@param ride table
---@param citizenid string
---@param radius number|nil
---@return boolean eligible, number? distanceMeters
local function isEligible(ride, citizenid, radius)
    if not citizenid or citizenid == ride.customerCitizenid then return false end
    if not drivers.IsRegisteredDriver(citizenid) then return false end
    if not drivers.IsDriverOnline(citizenid) then return false end
    if drivers.IsDriverBusy(citizenid) then return false end
    if not drivers.SourceByCitizenid[citizenid] then return false end
    if M.IsOnCooldown(citizenid, ride.customerCitizenid) then return false end

    local coords = drivers.GetPlayerCoordsByCitizenid(citizenid)
    if not coords then return false end

    local distance = fares.StraightLineMeters(coords, ride.pickup)
    if radius and distance > radius then return false end

    return true, distance
end

-- Offers ---------------------------------------------------------------------

---Offer payload for the driver UI. No identifiers, no citizenid.
---@param ride table
---@param driverCitizenid string
---@return table
local function buildOfferView(ride, driverCitizenid)
    local coords = drivers.GetPlayerCoordsByCitizenid(driverCitizenid)
    local distanceToPickup = coords and fares.StraightLineMeters(coords, ride.pickup) or nil

    return {
        rideId = ride.rideId,
        customerName = drivers.GetDisplayName(ride.customerCitizenid),
        distanceToPickupMeters = distanceToPickup and math.floor(distanceToPickup + 0.5) or nil,
        rideDistanceMeters = ride.distanceMeters,
        fare = ride.fare,
        fareText = fares.FormatRupiah(ride.fare),
        driverPayout = ride.driverPayout,
        driverPayoutText = fares.FormatRupiah(ride.driverPayout),
        companyFee = ride.companyFee,
        paymentMethod = ride.paymentMethod,
    }
end

local function pushOffer(citizenid, offerView)
    local src = drivers.SourceByCitizenid[citizenid]
    if not src then return end

    TriggerClientEvent('lifestate_ojol:client:driverOfferChanged', src, offerView)
end

---Give a driver an offer for a ride.
---@param ride table
---@param citizenid string
local function offerRideTo(ride, citizenid)
    local byDriver = M.DriverOffers[citizenid]
    if not byDriver then
        byDriver = {}
        M.DriverOffers[citizenid] = byDriver
    end

    local byRide = M.RideOffers[ride.rideId]
    if not byRide then
        byRide = {}
        M.RideOffers[ride.rideId] = byRide
    end

    byDriver[ride.rideId] = true
    byRide[citizenid] = true

    pushOffer(citizenid, buildOfferView(ride, citizenid))
end

---Withdraw a single offer (accepted elsewhere, declined, driver no longer eligible).
---@param rideId string
---@param citizenid string
---@param pushState boolean
local function removeOffer(rideId, citizenid, pushState)
    local byDriver = M.DriverOffers[citizenid]
    if byDriver then
        byDriver[rideId] = nil
        if next(byDriver) == nil then
            M.DriverOffers[citizenid] = nil
        end
    end

    local byRide = M.RideOffers[rideId]
    if byRide then
        byRide[citizenid] = nil
    end

    if pushState then
        pushOffer(citizenid, nil)
    end
end

---Broadcast/refresh offers for a ride at its current tier, and prune drivers who
---stopped being eligible while the offer was out.
---@param ride table
local function sweep(ride)
    local state = M.SearchState[ride.rideId]
    if not state then return end

    local radius = currentRadius(ride.rideId)
    local byRide = M.RideOffers[ride.rideId]
    if not byRide then
        byRide = {}
        M.RideOffers[ride.rideId] = byRide
    end

    -- Collect first: removing keys during pairs() traversal is not safe.
    local stale = {}
    for citizenid in pairs(byRide) do
        if not isEligible(ride, citizenid, radius) then
            stale[#stale + 1] = citizenid
        end
    end

    for i = 1, #stale do
        removeOffer(ride.rideId, stale[i], true)
    end

    local declines = M.RideDeclines[ride.rideId] or {}

    -- Broadcast tier: every eligible driver gets the offer and races to accept
    -- it (first valid acceptance wins). Iterating the online map - never all
    -- players - keeps a sweep proportional to the drivers on duty, and sweeps
    -- only ever run while at least one ride is searching.
    for citizenid in pairs(drivers.OnlineDrivers) do
        if not byRide[citizenid] and not declines[citizenid] then
            if isEligible(ride, citizenid, radius) then
                offerRideTo(ride, citizenid)
            end
        end
    end
end

---Offer this driver every searching ride they can serve. Used when a driver
---becomes available (clock-in) or is freed by a finished order.
---@param citizenid string
local function refreshOffersForDriver(citizenid)
    for rideId, ride in pairs(rides.ActiveRides) do
        if ride.status == RIDE_STATES.SEARCHING then
            local declines = M.RideDeclines[rideId] or {}
            local byDriver = M.DriverOffers[citizenid]
            -- Same radius rule a sweep would apply right now.
            if not declines[citizenid] and not (byDriver and byDriver[rideId]) then
                if isEligible(ride, citizenid, currentRadius(rideId)) then
                    offerRideTo(ride, citizenid)
                end
            end
        end
    end
end

-- Search lifecycle -----------------------------------------------------------

---Expand the search radius while the ride is still unassigned. One timer per
---searching ride; it stops existing as soon as the ride is assigned or closed.
---@param ride table
local function scheduleExpansion(ride)
    local state = M.SearchState[ride.rideId]
    if not state or state.timer then return end
    if state.tier >= #serverConfig.searchRadiusTiers then return end

    state.timer = SetTimeout(serverConfig.tierExpansionMs, function()
        state.timer = nil

        local live = rides.GetRide(ride.rideId)
        if not live or live.status ~= RIDE_STATES.SEARCHING then
            M.StopSearch(ride.rideId)
            return
        end

        state.tier = state.tier + 1
        sweep(live)
        scheduleExpansion(live)
    end)
end

---Begin (or restart, after a driver abandoned the ride) the search for a ride.
---@param ride table
function M.StartSearch(ride)
    M.StopSearch(ride.rideId)

    M.SearchState[ride.rideId] = { tier = 1, timer = nil }
    M.RideOffers[ride.rideId] = M.RideOffers[ride.rideId] or {}

    sweep(ride)
    scheduleExpansion(ride)
end

---Stop searching: kill the tier timer and retract every outstanding offer.
---@param rideId string
function M.StopSearch(rideId)
    local state = M.SearchState[rideId]
    if state then
        if state.timer then ClearTimeout(state.timer) end
        M.SearchState[rideId] = nil
    end

    local byRide = M.RideOffers[rideId]
    if not byRide then return end

    local offered = {}
    for citizenid in pairs(byRide) do
        offered[#offered + 1] = citizenid
    end

    M.RideOffers[rideId] = nil

    for i = 1, #offered do
        removeOffer(rideId, offered[i], true)
    end
end

---Drop every offer held by a driver (fired, went offline, took a ride).
---@param citizenid string
function M.ClearDriverOffers(citizenid)
    local byDriver = M.DriverOffers[citizenid]
    if not byDriver then return end

    local pending = {}
    for rideId in pairs(byDriver) do
        pending[#pending + 1] = rideId
    end

    for i = 1, #pending do
        removeOffer(pending[i], citizenid, false)
    end

    M.DriverOffers[citizenid] = nil
    pushOffer(citizenid, nil)
end

-- Driver answers -------------------------------------------------------------

---Accept an offer. Eligibility is re-validated here (the authoritative rule) and
---the ride assignment itself is atomic inside rides.TryAcceptRide.
---@param source number
---@param rideId string
---@return boolean ok, string? reason
function M.AcceptOffer(source, rideId)
    if type(rideId) ~= 'string' then return false, 'invalid_ride' end

    local citizenid = drivers.GetCitizenidBySource(source)
    if not citizenid then return false, 'not_registered' end

    local ride = rides.GetRide(rideId)
    if not ride then return false, 'ride_not_found' end
    if ride.status ~= RIDE_STATES.SEARCHING then return false, 'order_already_taken' end

    local offered = M.DriverOffers[citizenid]
    if not offered or not offered[rideId] then return false, 'not_offered' end

    -- A driver may only accept a ride they could legitimately have been offered:
    -- online, registered, free, off cooldown, inside the current search tier.
    local eligible = isEligible(ride, citizenid, currentRadius(rideId))
    if not eligible then return false, 'not_eligible' end

    return rides.TryAcceptRide(rideId, citizenid)
end

---Decline an offer. Only this driver stops seeing it: the ride stays live for
---everyone else and no cooldown is created (that applies to cancelling after
---accepting).
---@param source number
---@param rideId string
---@return boolean ok
function M.RejectOffer(source, rideId)
    if type(rideId) ~= 'string' then return false end

    local citizenid = drivers.GetCitizenidBySource(source)
    if not citizenid then return false end

    local byDriver = M.DriverOffers[citizenid]
    if not byDriver or not byDriver[rideId] then return false end

    local declines = M.RideDeclines[rideId]
    if not declines then
        declines = {}
        M.RideDeclines[rideId] = declines
    end

    declines[citizenid] = true
    removeOffer(rideId, citizenid, true)

    return true
end

-- Views ----------------------------------------------------------------------

---Driver-facing state for the NPWD app: availability, pending offer and the
---active ride leg.
---@param citizenid string
---@return table
function M.BuildDriverView(citizenid)
    local view = {
        online = drivers.IsDriverOnline(citizenid),
        busy = drivers.IsDriverBusy(citizenid),
        offers = {},
        offer = nil,
        active = nil,
    }

    -- A driver can hold offers for several concurrent requests; the newest is
    -- also exposed as `offer` so a single-card UI stays trivial.
    local byDriver = M.DriverOffers[citizenid]
    if byDriver then
        for rideId in pairs(byDriver) do
            local ride = rides.GetRide(rideId)
            if ride and ride.status == RIDE_STATES.SEARCHING then
                view.offers[#view.offers + 1] = buildOfferView(ride, citizenid)
            end
        end

        table.sort(view.offers, function(a, b)
            return (a.rideId or '') > (b.rideId or '')
        end)
    end

    view.offer = view.offers[1]

    local activeRide = rides.GetDriverRide(citizenid)
    if activeRide then
        view.active = rides.BuildDriverRideView(activeRide)
    end

    return view
end

---@param source number
---@return table
function M.GetDriverView(source)
    local citizenid = drivers.GetCitizenidBySource(source)
    if not citizenid then
        return { online = false, busy = false, offers = {}, offer = nil, active = nil }
    end

    return M.BuildDriverView(citizenid)
end

-- Events from rides.lua ------------------------------------------------------

AddEventHandler('lifestate_ojol:server:rideSearching', function(ride)
    M.StartSearch(ride)
end)

AddEventHandler('lifestate_ojol:server:rideAssigned', function(ride)
    -- Retracts every offer for this ride, including the winner's own offer card.
    M.StopSearch(ride.rideId)
end)

AddEventHandler('lifestate_ojol:server:rideClosed', function(ride)
    M.StopSearch(ride.rideId)
    M.RideDeclines[ride.rideId] = nil
end)

---A driver became available or went offline. Online drivers may receive a ride
---they can already serve; offline drivers lose every pending offer.
AddEventHandler('lifestate_ojol:server:driverAvailabilityChanged', function(citizenid, online)
    if not citizenid then return end

    if online then
        refreshOffersForDriver(citizenid)
    else
        M.ClearDriverOffers(citizenid)
    end
end)

---Hidden pair cooldown after a driver *voluntarily* cancels a ride. The origin
---is re-checked here as well as in rides.lua, so a future caller (or a replay of
---this event) can never block a driver from a customer because of a disconnect,
---a firing or a server outage.
AddEventHandler('lifestate_ojol:server:driverCancelledRide', function(driverCitizenid, customerCitizenid, origin)
    if not rides.IsVoluntaryCancel(origin) then return end

    M.SetPairCooldown(driverCitizenid, customerCitizenid)
end)

AddEventHandler('lifestate_ojol:server:driverFired', function(citizenid)
    M.ClearDriverOffers(citizenid)
end)

-- Lifecycle ------------------------------------------------------------------

---Resource stop/restart: drop timers and offers so nothing references a dead
---ride. Live rides are closed as FAILED in the database on the next start.
function M.Shutdown()
    local rideIds = {}
    for rideId in pairs(M.SearchState) do
        rideIds[#rideIds + 1] = rideId
    end

    for i = 1, #rideIds do
        M.StopSearch(rideIds[i])
    end

    M.DriverOffers = {}
    M.RideOffers = {}
    M.RideDeclines = {}
    M.Cooldowns = {}
    M.SearchState = {}
end

return M
