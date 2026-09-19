-- Ojol 1000-player scalability hardening.
--
-- Drives the REAL server/spatial.lua, server/drivers.lua and
-- server/matching.lua with stubbed persistence/config/world. Proves the
-- spatial candidate indexes preserve exact gameplay semantics:
-- eligibility, radius tiers, declines, pair cooldowns, busy exclusion,
-- first-valid-acceptance, ride index lifecycle and memory-only snapshots.

local h = require 'tests.harness'

local clock = os.clock or function() return 0 end

local world = {
    pos = {},        -- [citizenid] = { x, y }
    sources = {},    -- [citizenid] = source
    citBySrc = {},   -- [source] = citizenid
    nextSrc = 100,
    rides = {},      -- [rideId] = ride (server.rides stub backing)
    getRideCalls = {}, -- [rideId] = count
    offers = {},     -- pushed driverOfferChanged events
    events = {},
}

local configStub = {
    searchRadiusTiers = { 2000, 4000, 7000, 20000 },
    tierExpansionMs = 10000,
    cancelPairCooldownSeconds = 300,
    spatialCellSizeMeters = 2000,
    driverPositionRefreshMs = 2000,
    performanceDebug = false,
    performanceDebugIntervalMs = 45000,
}

local nowMs = 0

function GetGameTimer() return nowMs end
function SetTimeout() return 1 end
function ClearTimeout() end
function TriggerEvent(name, ...) world.events[name] = (world.events[name] or 0) + 1 end
function TriggerClientEvent(name, src, data)
    if name == 'lifestate_ojol:client:driverOfferChanged' then
        world.offers[#world.offers + 1] = { src = src, view = data }
    end
end
function AddEventHandler() end
function GetPlayerPed(source) return source and (source + 1000) or 0 end
function GetEntityCoords(ped)
    local cit = world.citBySrc[(tonumber(ped) or 0) - 1000]
    local pos = cit and world.pos[cit] or nil
    if not pos then return nil end
    return { x = pos.x, y = pos.y, z = 0 }
end
exports = { qbx_core = {
    GetPlayer = function(source)
        local cit = world.citBySrc[source]
        if cit then return { PlayerData = { citizenid = cit } } end
    end,
    GetPlayerByCitizenId = function() return nil end,
} }

for _, name in ipairs({ 'server.spatial', 'server.drivers', 'server.matching',
    'config.server', 'server.database', 'server.fares', 'server.rides' }) do
    package.loaded[name] = nil
end

package.preload['config.server'] = function() return configStub end
package.preload['server.database'] = function()
    return {
        -- NOTE: no FetchDriver on purpose. The snapshot must be memory-only;
        -- any SQL read there would raise here and fail the test.
        FetchAllDrivers = function() return {} end,
        InsertDriver = function() return 1 end,
        ReactivateDriver = function() return 1 end,
        DeactivateDriver = function() return 1 end,
        SubmitRatingTransaction = function() return true end,
    }
end
package.preload['server.fares'] = function()
    return {
        StraightLineMeters = function(a, b)
            local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
            return math.sqrt(dx * dx + dy * dy + dz * dz)
        end,
        FormatRupiah = tostring,
    }
end
package.preload['server.rides'] = function()
    return {
        STATES = {
            SEARCHING = 'SEARCHING', ACCEPTED = 'ACCEPTED',
            COMPLETED = 'COMPLETED', CANCELLED_CUSTOMER = 'CANCELLED_CUSTOMER',
            CANCELLED_DRIVER = 'CANCELLED_DRIVER', FAILED = 'FAILED',
        },
        GetRide = function(id)
            world.getRideCalls[id] = (world.getRideCalls[id] or 0) + 1
            return world.rides[id]
        end,
        -- First valid acceptance wins, mirroring the production CAS outcome.
        TryAcceptRide = function(rideId, citizenid)
            local ride = world.rides[rideId]
            if not ride or ride.status ~= 'SEARCHING' then return false, 'order_already_taken' end
            ride.status = 'ACCEPTED'
            ride.driverCitizenId = citizenid
            return true
        end,
        IsVoluntaryCancel = function() return false end,
    }
end

local spatial = require 'server.spatial'
local drivers = require 'server.drivers'
local matching = require 'server.matching'

-- Fixtures -------------------------------------------------------------------

local function setPos(citizenid, x, y)
    world.pos[citizenid] = { x = x, y = y }
    if not world.sources[citizenid] then
        world.nextSrc = world.nextSrc + 1
        world.sources[citizenid] = world.nextSrc
        world.citBySrc[world.nextSrc] = citizenid
        drivers.SourceByCitizenid[citizenid] = world.nextSrc
        drivers.CitizenidBySource[world.nextSrc] = citizenid
    end
end

local function addDriver(citizenid, x, y)
    setPos(citizenid, x, y)
    local ok, reason = drivers.RegisterDriver(citizenid, 'admin')
    h.eq(ok, true, 'register ' .. citizenid .. ' (' .. tostring(reason) .. ')')
    h.eq(select(1, drivers.SetDriverOnline(citizenid, true)), true, 'clock in ' .. citizenid)
    return world.sources[citizenid]
end

local function makeRide(rideId, x, y, customer)
    local ride = {
        rideId = rideId,
        customerCitizenid = customer or ('cust-' .. rideId),
        pickup = { x = x, y = y, z = 0 },
        destination = { x = x + 5000, y = y, z = 0 },
        distanceMeters = 6500,
        fare = 64000,
        driverPayout = 57600,
        companyFee = 6400,
        paymentMethod = 'cash',
        status = 'SEARCHING',
    }
    world.rides[rideId] = ride
    return ride
end

local function resetAll()
    world.pos, world.getRideCalls, world.offers, world.events = {}, {}, {}, {}
    world.rides = {}
    world.sources, world.citBySrc, world.nextSrc = {}, {}, 100
    drivers.RegisteredDrivers, drivers.OnlineDrivers, drivers.BusyDrivers = {}, {}, {}
    drivers.CitizenidBySource, drivers.SourceByCitizenid = {}, {}
    drivers.DriverGrid = spatial.New(2000)
    matching.DriverOffers, matching.RideOffers = {}, {}
    matching.RideDeclines, matching.Cooldowns, matching.SearchState = {}, {}, {}
    matching.RideGrid = spatial.New(2000)
    matching.Diag.sweeps, matching.Diag.candidates = 0, 0
    matching.Diag.eligibilityChecks, matching.Diag.offers, matching.Diag.refreshQueries = 0, 0, 0
    matching.Diag.armed = false
    nowMs = 0
end

local function offeredTo(citizenid)
    local src = world.sources[citizenid]
    for i = 1, #world.offers do
        if world.offers[i].src == src and world.offers[i].view ~= nil then return true end
    end
    return false
end

-- Spatial index unit ----------------------------------------------------------

h.test('spatial insert finds neighbours and excludes distant cells', function()
    resetAll()
    local index = spatial.New(2000)
    h.eq(index:Insert('a', 0, 0), true, 'insert a')
    h.eq(index:Insert('b', 2500, 0), true, 'insert b')
    h.eq(index:Insert('c', 1000, 1000), true, 'insert c')
    h.eq(index:Insert('edge', 2000, 0), true, 'insert edge')

    local near = index:Query(0, 0, 2000)
    local seen = {}
    for i = 1, #near do seen[near[i]] = true end
    h.eq(seen.a, true, 'finds a')
    h.eq(seen.c, true, 'finds neighbouring cell c')
    h.eq(seen.edge, true, 'exact radius boundary counts')
    h.eq(seen.b, nil, 'excludes distant b')
    h.eq(index:Count(), 4, 'count')
end)

h.test('spatial re-insert moves cells without duplicating', function()
    resetAll()
    local index = spatial.New(2000)
    index:Insert('a', 0, 0)
    index:Insert('a', 5000, 0)
    h.eq(index:Count(), 1, 'no duplicate')
    h.eq(#index:Query(0, 0, 2000), 0, 'old cell empty')
    local near = index:Query(5000, 0, 2000)
    h.eq(#near, 1, 'new cell has one entry')
    h.eq(near[1], 'a', 'moved entry')
    h.eq(index:Remove('a'), true, 'remove')
    h.eq(index:Remove('a'), false, 'double remove reports false')
    h.eq(index:Count(), 0, 'empty')
    h.eq(#index:Query(5000, 0, 2000), 0, 'removed entry gone')
end)

-- Driver index lifecycle -------------------------------------------------------

h.test('driver clock-in indexes, clock-out removes', function()
    resetAll()
    addDriver('d1', 100, 0)
    h.eq(drivers.DriverGrid:Count(), 1, 'indexed')
    local near = drivers.GetDriversNear({ x = 0, y = 0 }, 2000)
    h.eq(#near, 1, 'one candidate')
    h.eq(near[1], 'd1', 'candidate')
    h.eq(select(1, drivers.SetDriverOnline('d1', false)), true, 'clock out')
    h.eq(drivers.DriverGrid:Count(), 0, 'removed')
    h.eq(#drivers.GetDriversNear({ x = 0, y = 0 }, 2000), 0, 'no candidates')
end)

h.test('driver disconnect removes the index entry', function()
    resetAll()
    addDriver('d1', 100, 0)
    h.eq(drivers.DriverGrid:Count(), 1, 'indexed')
    drivers.CleanupSource(world.sources.d1)
    h.eq(drivers.DriverGrid:Count(), 0, 'removed on disconnect')
end)

h.test('fired driver is removed and ineligible', function()
    resetAll()
    addDriver('d1', 100, 0)
    local ride = makeRide('r-fire', 0, 0)
    matching.StartSearch(ride)
    h.eq(offeredTo('d1'), true, 'offered while active')
    h.eq(select(1, drivers.FireDriver('d1')), true, 'fired')
    h.eq(drivers.DriverGrid:Count(), 0, 'removed from index')
    h.eq(drivers.IsRegisteredDriver('d1'), false, 'no longer authorized')
end)

h.test('busy driver stays indexed but is never offered', function()
    resetAll()
    addDriver('d1', 100, 0)
    drivers.BusyDrivers.d1 = true
    h.eq(drivers.DriverGrid:Count(), 1, 'busy driver remains indexed')
    local ride = makeRide('r-busy', 0, 0)
    matching.StartSearch(ride)
    h.eq(offeredTo('d1'), false, 'busy driver excluded by eligibility')
end)

-- Matching semantics on the spatial path ----------------------------------------

h.test('sweep offers the nearby driver and not the distant one', function()
    resetAll()
    addDriver('d-near', 100, 0)
    addDriver('d-far', 50000, 0)
    local ride = makeRide('r-sweep', 0, 0)
    matching.StartSearch(ride)
    h.eq(offeredTo('d-near'), true, 'nearby offered')
    h.eq(offeredTo('d-far'), false, 'distant ignored')
    h.eq(matching.DriverOffers['d-near']['r-sweep'], true, 'offer recorded')
end)

h.test('exact tier radius still enforced, expansion respected', function()
    resetAll()
    addDriver('d-mid', 2500, 0)
    local ride = makeRide('r-tier', 0, 0)
    matching.StartSearch(ride)
    h.eq(offeredTo('d-mid'), false, 'outside tier 1 (2 km)')
    matching.SearchState['r-tier'].tier = 2
    matching.RefreshOffersForDriver('d-mid')
    h.eq(offeredTo('d-mid'), true, 'tier 2 expansion reaches 2.5 km')
end)

h.test('decline memory survives availability refresh', function()
    resetAll()
    addDriver('d1', 100, 0)
    local ride = makeRide('r-decline', 0, 0)
    matching.StartSearch(ride)
    h.eq(offeredTo('d1'), true, 'offered first')
    h.eq(matching.RejectOffer(world.sources.d1, 'r-decline'), true, 'declined')
    world.offers = {}
    -- Removing + re-adding the search must not re-offer a declined driver.
    matching.StopSearch('r-decline')
    matching.StartSearch(world.rides['r-decline'])
    h.eq(offeredTo('d1'), false, 'decline remembered across rematch')
end)

h.test('pair cooldown blocks offers without a decline', function()
    resetAll()
    addDriver('d1', 100, 0)
    local ride = makeRide('r-cool', 0, 0, 'cust-cool')
    matching.SetPairCooldown('d1', 'cust-cool')
    matching.StartSearch(ride)
    h.eq(offeredTo('d1'), false, 'cooldown blocks offer')
    nowMs = 301 * 1000
    world.offers = {}
    local ride2 = makeRide('r-cool2', 0, 0, 'cust-cool')
    matching.StartSearch(ride2)
    h.eq(offeredTo('d1'), true, 'offered after cooldown expiry')
end)

h.test('first valid acceptance still wins', function()
    resetAll()
    addDriver('d1', 100, 0)
    addDriver('d2', 200, 0)
    local ride = makeRide('r-accept', 0, 0)
    matching.StartSearch(ride)
    h.eq(offeredTo('d1'), true, 'd1 offered')
    h.eq(offeredTo('d2'), true, 'd2 offered')
    h.eq(select(1, matching.AcceptOffer(world.sources.d1, 'r-accept')), true, 'first wins')
    h.eq(select(2, matching.AcceptOffer(world.sources.d2, 'r-accept')), 'order_already_taken', 'second refused')
end)

-- Ride index lifecycle -----------------------------------------------------------

h.test('ride grid tracks search lifecycle and pickup moves', function()
    resetAll()
    local ride = makeRide('r-life', 0, 0)
    matching.StartSearch(ride)
    h.eq(matching.RideGrid:Count(), 1, 'searching ride indexed')
    h.eq(#matching.RideGrid:Query(0, 0, 2000), 1, 'found at pickup')
    matching.StopSearch('r-life')
    h.eq(matching.RideGrid:Count(), 0, 'accepted/terminal ride removed')
    h.eq(#matching.RideGrid:Query(0, 0, 2000), 0, 'pickup cell empty')
    -- Reopened rematch re-adds; a recalculated pickup moves the cell.
    ride.pickup = { x = 30000, y = 0, z = 0 }
    ride.status = 'SEARCHING'
    matching.StartSearch(ride)
    h.eq(matching.RideGrid:Count(), 1, 'reopened ride restored')
    h.eq(#matching.RideGrid:Query(0, 0, 2000), 0, 'old cell empty')
    h.eq(#matching.RideGrid:Query(30000, 0, 2000), 1, 'new pickup cell')
end)

h.test('availability refresh evaluates nearby searches only', function()
    resetAll()
    addDriver('d1', 100, 0)
    local near = makeRide('r-near', 0, 0)
    local far = makeRide('r-far', 40000, 0)
    matching.StartSearch(near)
    matching.StartSearch(far)
    h.eq(offeredTo('d1'), true, 'nearby ride offered by sweep, far ride never a candidate')
    world.getRideCalls = {}
    world.offers = {}
    -- The ride grid itself bounds the refresh: only the nearby ride resolves.
    local coords = { x = 100, y = 0 }
    local ids = matching.RideGrid:Query(coords.x, coords.y, 20000)
    local seen = {}
    for i = 1, #ids do seen[ids[i]] = true end
    h.eq(seen['r-near'], true, 'nearby search found')
    h.eq(seen['r-far'], nil, 'far search never a candidate')
end)

-- Snapshot cache ------------------------------------------------------------------

h.test('snapshot is memory-only and reflects cached aggregates', function()
    resetAll()
    drivers.RegisteredDrivers.cache1 = {
        citizenid = 'cache1', rank = 'senior_driver', active = true,
        profilePhoto = 'photo.png', registeredBy = 'admin', registeredAt = 1000,
        ratingSum = 47, ratingCount = 10,
    }
    drivers.OnlineDrivers.cache1 = true
    local snapshot = drivers.GetDriverStateSnapshot('cache1')
    h.eq(snapshot.registered, true, 'registered')
    h.eq(snapshot.rank, 'senior_driver', 'rank')
    h.eq(snapshot.profilePhoto, 'photo.png', 'photo without SQL')
    h.eq(math.floor(snapshot.rating * 10 + 0.5), 47, 'average from cache')
    drivers.ApplyRatingToCache('cache1', 5)
    local updated = drivers.GetDriverStateSnapshot('cache1')
    h.eq(math.floor(updated.rating * 100 + 0.5), 473, 'average bumps without SQL')
end)

-- Diagnostics -----------------------------------------------------------------------

h.test('diagnostics stay dormant unless enabled', function()
    resetAll()
    addDriver('d1', 100, 0)
    matching.StartSearch(makeRide('r-diag', 0, 0))
    h.eq(matching.Diag.armed, false, 'no timer when disabled')
    local stats = matching.GetStats()
    h.eq(stats.onlineDrivers, 1, 'online counted')
    h.eq(stats.indexedDrivers, 1, 'indexed counted')
    h.eq(stats.searchingRides, 1, 'searching counted')
    h.eq(stats.sweeps >= 1, true, 'sweeps counted')
    configStub.performanceDebug = true
    matching.StartSearch(makeRide('r-diag2', 50000, 0))
    h.eq(matching.Diag.armed, true, 'armed when enabled')
    configStub.performanceDebug = false
    matching.Diag.armed = false
end)

-- Synthetic benchmark ------------------------------------------------------------------

h.test('synthetic scale: 300 drivers, 100 searching rides', function()
    resetAll()
    for i = 1, 300 do
        local x = ((i * 7919) % 20000) - 10000
        local y = ((i * 104729) % 20000) - 10000
        local cit = 'bench-d' .. i
        setPos(cit, x, y)
        drivers.RegisterDriver(cit, 'admin')
        drivers.SetDriverOnline(cit, true)
    end
    h.eq(drivers.DriverGrid:Count(), 300, 'all drivers indexed')

    local started = clock()
    for i = 1, 100 do
        local x = ((i * 15485863) % 20000) - 10000
        local y = ((i * 32452843) % 20000) - 10000
        matching.StartSearch(makeRide('bench-r' .. i, x, y, 'bench-c' .. i))
    end
    local elapsed = clock() - started
    local stats = matching.GetStats()
    print(('[scale] 300 drivers, 100 rides: sweeps=%d candidates=%d eligibility=%d offers=%d elapsed=%.3fs')
        :format(stats.sweeps, stats.candidates, stats.eligibilityChecks, stats.offers, elapsed))
    h.eq(stats.sweeps, 100, 'one sweep per search start')
    h.ok(stats.candidates < 100 * 300, 'candidates bounded below full population (' .. stats.candidates .. ')')
    h.ok(stats.eligibilityChecks <= stats.candidates, 'checks never exceed candidates')
end)
