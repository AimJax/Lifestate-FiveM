local db = require 'server.database'

local M = {}

local function dbBoolean(value)
    return value == true or value == 1 or value == '1'
end

-- Runtime state ------------------------------------------------------------
-- Database = persistence. These tables = live state. Never persisted per tick.

M.RegisteredDrivers = {} -- [citizenid] = { citizenid, rank, active, profilePhoto, registeredBy, registeredAt }
M.OnlineDrivers = {}     -- [citizenid] = true while clocked in (registered + online)
M.BusyDrivers = {}       -- [citizenid] = true while an accepted ride is active (Phase 3B+)
M.CitizenidBySource = {} -- [source] = citizenid, connection-scoped mapping for cleanup
M.SourceByCitizenid = {} -- [citizenid] = source

local RANKS = { 'driver', 'senior_driver', 'supervisor', 'ceo' }
local CEO_MANAGEABLE = { driver = true, senior_driver = true, supervisor = true }
local CEO_PROMOTABLE = { driver = 'senior_driver', senior_driver = 'supervisor' }
local CEO_DEMOTABLE = { supervisor = 'senior_driver', senior_driver = 'driver' }

local function isValidRank(rank)
    for i = 1, #RANKS do
        if RANKS[i] == rank then return true end
    end
    return false
end

local function buildRuntimeDriver(row)
    return {
        citizenid = row.citizenid,
        rank = row.rank,
        active = dbBoolean(row.active),
        profilePhoto = row.profile_photo,
        registeredBy = row.registered_by,
        registeredAt = row.registered_at,
    }
end

---Load all registrations from the database once. Called on resource start/restart.
---Inactive (fired) records are cached too: they carry the history needed for a
---safe rehire and are never treated as authorization (see IsRegisteredDriver).
function M.LoadDrivers()
    M.RegisteredDrivers = {}
    local rows = db.FetchAllDrivers()

    for i = 1, #rows do
        local row = rows[i]
        M.RegisteredDrivers[row.citizenid] = buildRuntimeDriver(row)
    end
end

---Count cached records by state (startup logging only).
---@return number active, number total
function M.CountDrivers()
    local active, total = 0, 0
    for _, driver in pairs(M.RegisteredDrivers) do
        total = total + 1
        if driver.active == true then active = active + 1 end
    end
    return active, total
end

-- Core helpers -------------------------------------------------------------

---@param citizenid string
---@return table? runtime driver record
function M.GetOjolDriver(citizenid)
    return citizenid and M.RegisteredDrivers[citizenid] or nil
end

function M.IsRegisteredDriver(citizenid)
    local driver = M.GetOjolDriver(citizenid)
    return driver ~= nil and driver.active == true
end

function M.IsDriverOnline(citizenid)
    return M.OnlineDrivers[citizenid] == true
end

function M.IsDriverBusy(citizenid)
    return M.BusyDrivers[citizenid] == true
end

function M.IsCEO(citizenid)
    local driver = M.GetOjolDriver(citizenid)
    return driver ~= nil and driver.active == true and driver.rank == 'ceo'
end

---Active CEO requirement for management actions: must be an active CEO record.
function M.IsActingCEO(citizenid)
    return M.IsCEO(citizenid)
end

---Resolve (and cache) the citizenid behind a live connection source.
---@param source number
---@return string? citizenid
function M.GetCitizenidBySource(source)
    local cached = M.CitizenidBySource[source]
    if cached then return cached end

    local player = exports.qbx_core:GetPlayer(source)
    if not player then return nil end

    M.CitizenidBySource[source] = player.PlayerData.citizenid
    M.SourceByCitizenid[player.PlayerData.citizenid] = source
    return player.PlayerData.citizenid
end

---Force-fresh resolve from qbx_core (bypasses the connection cache).
function M.ResolveCitizenid(source)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return nil end

    local citizenid = player.PlayerData.citizenid
    M.CitizenidBySource[source] = citizenid
    M.SourceByCitizenid[citizenid] = source
    return citizenid
end

---Character display name for player-facing UI. Never exposes identifiers.
---@param citizenid string
---@return string
function M.GetDisplayName(citizenid)
    local player = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    local charinfo = player and player.PlayerData and player.PlayerData.charinfo
    if not charinfo then return 'Pengguna Ojol' end

    local name = ('%s %s'):format(tostring(charinfo.firstname or ''), tostring(charinfo.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then return 'Pengguna Ojol' end

    return name
end

---Live ped position of a connected player, resolved from the persistent identity.
---Used by matching and by proximity validation; never cached across frames.
---@param citizenid string
---@return vector3? coords
function M.GetPlayerCoordsByCitizenid(citizenid)
    local src = citizenid and M.SourceByCitizenid[citizenid]
    if not src then return nil end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end

    return GetEntityCoords(ped)
end

-- Transitions ---------------------------------------------------------------

---Register a player as an Ojol driver (CEO action, server-authoritative).
---A previously fired driver keeps their persistent record: this reactivates the
---same row (same citizenid), preserving profile, registration and statistics.
---Rank resets to 'driver' on rehire; a CEO record is never lowered here.
---@param citizenid string
---@param registeredBy string
---@return boolean success, string? reasonOrOutcome 'registered' | 'reactivated' when successful
function M.RegisterDriver(citizenid, registeredBy)
    if not citizenid or citizenid == '' then return false, 'invalid_target' end

    local existing = M.GetOjolDriver(citizenid)
    if existing and existing.active == true then return false, 'already_registered' end

    local rank = (existing and existing.rank == 'ceo') and 'ceo' or 'driver'

    if existing then
        local ok, err = pcall(db.ReactivateDriver, citizenid, rank, registeredBy)
        if not ok then
            print(('[ojol] RegisterDriver reactivate DB error for %s: %s'):format(citizenid, tostring(err)))
            return false, 'database_error'
        end

        existing.active = true
        existing.rank = rank
        existing.registeredBy = registeredBy
        return true, 'reactivated'
    end

    local ok, err = pcall(db.InsertDriver, citizenid, rank, registeredBy)
    if not ok then
        print(('[ojol] RegisterDriver DB error for %s: %s'):format(citizenid, tostring(err)))
        return false, 'database_error'
    end

    M.RegisteredDrivers[citizenid] = {
        citizenid = citizenid,
        rank = rank,
        active = true,
        profilePhoto = nil,
        registeredBy = registeredBy,
        registeredAt = os.time(),
    }

    return true, 'registered'
end

---Fire a driver: soft deactivation only.
---The persistent record (profile, registration history, ratings, ride stats,
---earnings) is never deleted - only `active` is cleared.
---Runtime authorization is revoked immediately: online, busy/available and any
---tracked work bike. Fires an event so future ride/offer code can invalidate state.
---@param citizenid string
---@return boolean success, string? reason
function M.FireDriver(citizenid)
    local driver = M.GetOjolDriver(citizenid)
    if not driver or driver.active ~= true then return false, 'not_registered' end
    if driver.rank == 'ceo' then return false, 'cannot_fire_ceo' end

    local ok, err = pcall(db.DeactivateDriver, citizenid)
    if not ok then
        print(('[ojol] FireDriver DB error for %s: %s'):format(citizenid, tostring(err)))
        return false, 'database_error'
    end

    -- Soft deactivation: keep the record, drop every authorization flag.
    driver.active = false
    M.OnlineDrivers[citizenid] = nil
    M.BusyDrivers[citizenid] = nil
    -- The connection mapping (source <-> citizenid) is NOT authorization and is
    -- intentionally kept so the fired player still receives the revocation notice.

    -- Hook for future systems: pending ride offers / active ride cancellation.
    -- Phase 3B ride code must subscribe here to invalidate offers and rides.
    TriggerEvent('lifestate_ojol:server:driverFired', citizenid)

    local src = M.SourceByCitizenid[citizenid]
    if src then
        TriggerClientEvent('lifestate_ojol:client:driverRevoked', src)
    end

    return true
end

---Admin-only: assign the CEO rank, creating or reactivating the record if needed.
---Enforces the single-CEO invariant by demoting any previous CEO back to driver.
---Never reachable from a CEO-controlled command.
---@param citizenid string
---@param assignedBy string @who assigned it (e.g. 'admin')
---@return boolean success, string? reason
function M.AssignCEO(citizenid, assignedBy)
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'invalid_citizenid' end

    local target = M.GetOjolDriver(citizenid)
    local ok, err

    if not target then
        ok, err = pcall(db.InsertDriver, citizenid, 'ceo', assignedBy)
        if not ok then
            print(('[ojol] AssignCEO insert DB error for %s: %s'):format(citizenid, tostring(err)))
            return false, 'database_error'
        end

        M.RegisteredDrivers[citizenid] = {
            citizenid = citizenid,
            rank = 'ceo',
            active = true,
            profilePhoto = nil,
            registeredBy = assignedBy,
            registeredAt = os.time(),
        }
    elseif target.active ~= true then
        -- Admin intent is explicit: a fired driver can be reactivated as CEO.
        ok, err = pcall(db.ReactivateDriver, citizenid, 'ceo', assignedBy)
        if not ok then
            print(('[ojol] AssignCEO reactivate DB error for %s: %s'):format(citizenid, tostring(err)))
            return false, 'database_error'
        end

        target.active = true
        target.rank = 'ceo'
        target.registeredBy = assignedBy
    else
        ok, err = pcall(db.UpdateDriverFields, citizenid, { rank = 'ceo' })
        if not ok then
            print(('[ojol] AssignCEO rank DB error for %s: %s'):format(citizenid, tostring(err)))
            return false, 'database_error'
        end

        target.rank = 'ceo'
    end

    -- Single-CEO invariant: any other CEO is demoted back to driver.
    for otherCitizenid, otherDriver in pairs(M.RegisteredDrivers) do
        if otherCitizenid ~= citizenid and otherDriver.rank == 'ceo' then
            local demoted = pcall(db.UpdateDriverFields, otherCitizenid, { rank = 'driver' })
            if demoted then
                otherDriver.rank = 'driver'
                print(('[ojol] previous CEO %s demoted to driver'):format(otherCitizenid))
            end
        end
    end

    return true
end

---Change rank inside the CEO-manageable hierarchy. CEO rank itself is admin-only.
---@param citizenid string
---@param rank string
---@return boolean success, string? reason
function M.SetDriverRank(citizenid, rank)
    local driver = M.GetOjolDriver(citizenid)
    if not driver or driver.active ~= true then return false, 'not_registered' end
    if not isValidRank(rank) then return false, 'invalid_rank' end
    if rank == 'ceo' or not CEO_MANAGEABLE[rank] then return false, 'rank_not_manageable' end
    if not CEO_MANAGEABLE[driver.rank] then return false, 'rank_not_manageable' end

    local ok, err = pcall(db.UpdateDriverFields, citizenid, { rank = rank })
    if not ok then
        print(('[ojol] SetDriverRank DB error for %s: %s'):format(citizenid, tostring(err)))
        return false, 'database_error'
    end

    driver.rank = rank
    return true
end

---Promote one step: driver -> senior_driver -> supervisor. Never to CEO.
---@return boolean success, string? reason, string? newRank
function M.PromoteDriver(citizenid)
    local driver = M.GetOjolDriver(citizenid)
    if not driver or driver.active ~= true then return false, 'not_registered', nil end

    local nextRank = CEO_PROMOTABLE[driver.rank]
    if not nextRank then return false, 'cannot_promote', nil end

    local ok = M.SetDriverRank(citizenid, nextRank)
    if not ok then return false, 'database_error', nil end
    return true, nil, nextRank
end

---Demote one step: supervisor -> senior_driver -> driver.
---@return boolean success, string? reason, string? newRank
function M.DemoteDriver(citizenid)
    local driver = M.GetOjolDriver(citizenid)
    if not driver or driver.active ~= true then return false, 'not_registered', nil end

    local nextRank = CEO_DEMOTABLE[driver.rank]
    if not nextRank then return false, 'cannot_demote', nil end

    local ok = M.SetDriverRank(citizenid, nextRank)
    if not ok then return false, 'database_error', nil end
    return true, nil, nextRank
end

---Clock in / out. Runtime-only state; never written to the database.
---Clock-in requires registered + active + not busy.
---Clock-out requires registered and NOT busy: an active order must be finished or
---cancelled first (Phase 3B). The ride system is the only writer of BusyDrivers.
---@param citizenid string
---@param desired boolean
---@return boolean success, string? reason
function M.SetDriverOnline(citizenid, desired)
    local driver = M.GetOjolDriver(citizenid)
    if not driver or driver.active ~= true then return false, 'not_registered' end

    if desired then
        if M.IsDriverBusy(citizenid) then return false, 'busy' end
        M.OnlineDrivers[citizenid] = true
        return true
    end

    -- Busy guard: no clock-out while an accepted order is running.
    if M.IsDriverBusy(citizenid) then return false, 'busy_active_ride' end

    M.OnlineDrivers[citizenid] = nil
    return true
end

---Aggregate state snapshot for the driver app / client.
---@param citizenid string
---@return table
function M.GetDriverStateSnapshot(citizenid)
    local driver = M.GetOjolDriver(citizenid)
    local registered = driver ~= nil and driver.active == true

    local ratingSum = 0
    local ratingCount = 0
    local profilePhoto = nil

    if registered then
        -- Single indexed lookup for the persistent fields that are not cached
        -- (rating + profile). Preserved across fire/rehire.
        local row = db.FetchDriver(citizenid)
        if row then
            ratingSum = row.rating_sum or 0
            ratingCount = row.rating_count or 0
            profilePhoto = row.profile_photo
        end
    end

    return {
        registered = registered,
        active = registered,
        online = registered and M.IsDriverOnline(citizenid) or false,
        busy = M.IsDriverBusy(citizenid),
        rank = registered and driver.rank or nil,
        profilePhoto = registered and profilePhoto or nil,
        rating = ratingCount > 0 and (ratingSum / ratingCount) or nil,
    }
end

-- Connection lifecycle ------------------------------------------------------

---Connection teardown: mark a player unavailable without the busy guard.
---Used on disconnect, where nothing can be finished any more and the ride system
---must never offer a departed driver new work.
---@param citizenid string
function M.ClearOnlineState(citizenid)
    M.OnlineDrivers[citizenid] = nil
    M.BusyDrivers[citizenid] = nil
end

---Clear runtime mappings when a player drops. Persistent registration survives.
function M.CleanupSource(source)
    local citizenid = M.CitizenidBySource[source]
    if not citizenid then return end

    if M.SourceByCitizenid[citizenid] == source then
        M.SourceByCitizenid[citizenid] = nil
    end

    M.OnlineDrivers[citizenid] = nil
    M.BusyDrivers[citizenid] = nil
    M.CitizenidBySource[source] = nil
end

return M
