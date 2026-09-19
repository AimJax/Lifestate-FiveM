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
local spatial = require 'server.spatial'

local M = {}

M.DriverOffers = {}  -- [citizenid] = { [rideId] = true }  every ride offered to that driver
M.RideOffers = {}    -- [rideId]    = { [citizenid] = true }
M.RideDeclines = {}  -- [rideId]    = { [citizenid] = true }  survives a rematch
M.Cooldowns = {}     -- [driverCitizenid] = { [customerCitizenid] = expiresAtMs }
M.SearchState = {}   -- [rideId] = { tier = number, timer = handle|nil }

-- SEARCHING rides by pickup cell (scalability hardening). Added on search
-- start (create/reopen, including recalculated pickups - the pickup is
-- assigned before the rideSearching event fires) and removed on assignment
-- or closure. refreshOffersForDriver queries this instead of every live ride.
M.RideGrid = spatial.New(serverConfig.spatialCellSizeMeters or spatial.DefaultCellSize)

-- Lightweight aggregate diagnostics. Counters are a few table increments per
-- sweep (effectively zero overhead); the periodic report only exists while
-- performanceDebug is enabled.
M.Diag = {
    sweeps = 0,
    candidates = 0,
    eligibilityChecks = 0,
    offers = 0,
    refreshQueries = 0,
    armed = false,
}

---Snapshot of the aggregate counters (tests/diagnostics).
---@return table
function M.GetStats()
    local online, searching, indexed = 0, 0, 0
    if drivers.OnlineDrivers then
        for _ in pairs(drivers.OnlineDrivers) do online = online + 1 end
    end
    for _ in pairs(M.SearchState) do searching = searching + 1 end
    if drivers.DriverGrid then indexed = drivers.DriverGrid:Count() end
    return {
        onlineDrivers = online,
        indexedDrivers = indexed,
        searchingRides = searching,
        indexedRides = M.RideGrid:Count(),
        sweeps = M.Diag.sweeps,
        candidates = M.Diag.candidates,
        eligibilityChecks = M.Diag.eligibilityChecks,
        offers = M.Diag.offers,
        refreshQueries = M.Diag.refreshQueries,
    }
end

local function maybeArmDiagnostics()
    if M.Diag.armed or not serverConfig.performanceDebug then return end
    M.Diag.armed = true

    local interval = tonumber(serverConfig.performanceDebugIntervalMs) or 45000
    if interval < 5000 then interval = 5000 end

    local function report()
        if not serverConfig.performanceDebug then
            M.Diag.armed = false
            return
        end

        local stats = M.GetStats()
        print(('[ojol] perf online=%d indexedDrivers=%d searching=%d indexedRides=%d sweeps=%d candidates=%d eligibility=%d offers=%d refreshQueries=%d')
            :format(stats.onlineDrivers, stats.indexedDrivers, stats.searchingRides,
                stats.indexedRides, stats.sweeps, stats.candidates,
                stats.eligibilityChecks, stats.offers, stats.refreshQueries))
        M.Diag.sweeps, M.Diag.candidates = 0, 0
        M.Diag.eligibilityChecks, M.Diag.offers, M.Diag.refreshQueries = 0, 0, 0

        SetTimeout(interval, report)
    end

    SetTimeout(interval, report)
end

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

---Widest configured search radius: bounds refreshOffersForDriver queries so a
---newly available driver only evaluates searches that could reach them.
---@return number metres
local function maxRadius()
    local tiers = serverConfig.searchRadiusTiers
    return tiers[#tiers]
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
    -- it (first valid acceptance wins). Candidates come from the driver spatial
    -- index - nearby drivers only - instead of every online driver, so a sweep
    -- costs O(nearby candidates) rather than O(onlineDrivers). The index is a
    -- filter only: isEligible re-checks everything, exact distance included.
    -- Sweeps only ever run while at least one ride is searching.
    local candidates
    if drivers.GetDriversNear then
        candidates = drivers.GetDriversNear(ride.pickup, radius) or {}
    else
        -- Legacy stub drivers in unit tests expose no spatial API.
        candidates = {}
        for citizenid in pairs(drivers.OnlineDrivers or {}) do
            candidates[#candidates + 1] = citizenid
        end
    end

    M.Diag.sweeps = M.Diag.sweeps + 1
    M.Diag.candidates = M.Diag.candidates + #candidates

    for i = 1, #candidates do
        local citizenid = candidates[i]
        if not byRide[citizenid] and not declines[citizenid] then
            M.Diag.eligibilityChecks = M.Diag.eligibilityChecks + 1
            if isEligible(ride, citizenid, radius) then
                M.Diag.offers = M.Diag.offers + 1
                offerRideTo(ride, citizenid)
            end
        end
    end
end

---Offer this driver every searching ride they can serve. Used when a driver
---becomes available (clock-in) or is freed by a finished order. Nearby
---searches only (ride pickup index bounded by the widest tier); each ride's
---own current tier radius still decides eligibility.
---@param citizenid string
local function refreshOffersForDriver(citizenid)
    local coords = drivers.GetPlayerCoordsByCitizenid
        and drivers.GetPlayerCoordsByCitizenid(citizenid) or nil
    if not coords then return end

    M.Diag.refreshQueries = M.Diag.refreshQueries + 1

    -- Ride pickups are stable, so this query stays exact (no halo); the
    -- driver's own position here is live, not indexed.
    local rideIds = M.RideGrid:Query(coords.x, coords.y, maxRadius())
    for i = 1, #rideIds do
        local ride = rides.GetRide and rides.GetRide(rideIds[i]) or nil
        if ride and ride.status == RIDE_STATES.SEARCHING then
            local declines = M.RideDeclines[ride.rideId] or {}
            local byDriver = M.DriverOffers[citizenid]
            -- Same radius rule a sweep would apply right now.
            if not declines[citizenid] and not (byDriver and byDriver[ride.rideId]) then
                M.Diag.eligibilityChecks = M.Diag.eligibilityChecks + 1
                if isEligible(ride, citizenid, currentRadius(ride.rideId)) then
                    M.Diag.offers = M.Diag.offers + 1
                    offerRideTo(ride, citizenid)
                end
            end
        end
    end
end

-- Exported for tests and for explicit availability triggers; the event above
-- is the production caller.
M.RefreshOffersForDriver = refreshOffersForDriver

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

    -- Index the pickup before sweeping so refreshOffersForDriver can find this
    -- search immediately. Reopens re-add (same id, possibly recalculated
    -- pickup - Insert moves the entry).
    if ride.pickup then
        M.RideGrid:Insert(ride.rideId, ride.pickup.x, ride.pickup.y)
    end
    maybeArmDiagnostics()

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

    M.RideGrid:Remove(rideId)

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
    M.RideGrid = spatial.New(serverConfig.spatialCellSizeMeters or spatial.DefaultCellSize)
    M.Diag.sweeps, M.Diag.candidates = 0, 0
    M.Diag.eligibilityChecks, M.Diag.offers, M.Diag.refreshQueries = 0, 0, 0
end

return M
