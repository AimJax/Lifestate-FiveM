local M = {}

-- Authoritative runtime tracking: at most ONE valid Ojol work bike per driver.
-- Keyed by persistent identity (citizenid), never by connection source.
-- Database is irrelevant here: these are live world objects.
M.ActiveDriverVehicles = {} -- [citizenid] = netId

-- Per-driver spawn lock. Spawning is not atomic on its own: two requests that
-- arrive in the same server tick would both pass the "no valid bike" check
-- before either has tracked its vehicle. Holding an explicit lock across
-- check -> spawn -> track makes a second concurrent request impossible.
M.SpawningDrivers = {} -- [citizenid] = true while a spawn is in flight

---Take the spawn lock for a driver.
---@param citizenid string
---@return boolean acquired @false when a spawn is already in flight
function M.AcquireSpawnLock(citizenid)
    if M.SpawningDrivers[citizenid] then return false end

    M.SpawningDrivers[citizenid] = true
    return true
end

---Release the spawn lock. Must run on success, failure and error paths.
---@param citizenid string
function M.ReleaseSpawnLock(citizenid)
    M.SpawningDrivers[citizenid] = nil
end

-- Entity state bag written at spawn time. This is what makes ownership survive a
-- resource restart without persisting anything to the database: the bag travels
-- with the entity, so a one-shot startup scan can re-adopt orphaned bikes.
local OWNER_STATE_KEY = 'ojolBikeOwner'

---Resolve a tracked network id to a live entity handle.
---@param netId number|nil
---@return number? veh
local function resolveVehicle(netId)
    if type(netId) ~= 'number' or netId == 0 then return nil end

    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end

    return veh
end

---Server-side validity check. The server has no IsEntityDead / IsVehicleDriveable
---natives, so engine + body health are the authoritative "destroyed" signals.
---@param veh number
---@return boolean
local function isVehicleUsable(veh)
    if not DoesEntityExist(veh) then return false end
    if GetVehicleEngineHealth(veh) <= 0.0 then return false end
    if GetVehicleBodyHealth(veh) <= 0.0 then return false end
    return true
end

---Does this driver already own a valid Ojol bike?
---Stale tracking (entity deleted or destroyed) is cleared here so the driver may
---receive a replacement - this is the "vehicle loss where detectable" path.
---@param citizenid string
---@return boolean hasValidBike, number? netId
function M.HasValidBike(citizenid)
    local netId = M.ActiveDriverVehicles[citizenid]
    if not netId then return false, nil end

    local veh = resolveVehicle(netId)
    if not veh or not isVehicleUsable(veh) then
        M.ActiveDriverVehicles[citizenid] = nil
        return false, nil
    end

    return true, netId
end

---Track a freshly spawned bike and stamp ownership onto the entity.
---@param citizenid string
---@param netId number
function M.Track(citizenid, netId)
    M.ActiveDriverVehicles[citizenid] = netId

    local veh = resolveVehicle(netId)
    if veh then
        Entity(veh).state:set(OWNER_STATE_KEY, citizenid, true)
    end
end

---Release tracking for a driver.
---@param citizenid string
---@param deleteEntity boolean @true to remove the company bike from the world
---@return boolean released @true when a tracked bike was dropped
function M.Release(citizenid, deleteEntity)
    local netId = M.ActiveDriverVehicles[citizenid]
    M.ActiveDriverVehicles[citizenid] = nil

    if not netId then return false end

    local veh = resolveVehicle(netId)
    if not veh then return true end

    Entity(veh).state:set(OWNER_STATE_KEY, nil, true)
    if deleteEntity then
        DeleteEntity(veh)
    end

    return true
end

---Connection cleanup: never leave a stale spawn lock behind, and drop tracking
---for bikes that are gone. A bike that is still alive keeps its owner entry on
---purpose: the vehicle really is still out in the world, so dropping the entry
---would let the driver spawn a second bike after reconnecting.
---@param citizenid string
function M.HandlePlayerDropped(citizenid)
    M.ReleaseSpawnLock(citizenid)

    if M.ActiveDriverVehicles[citizenid] then
        M.HasValidBike(citizenid) -- clears the entry when the vehicle is gone
    end
end

---Re-adopt bikes that survived a resource restart.
---One-shot world scan at startup (never a loop): reads the ownership state bag
---written by Track(). The bike already tracked is always the one kept; extras for
---the same driver are destroyed, so the "one valid bike per driver" invariant is
---re-established without ever deleting the bike a driver is riding.
---@return number restored, number duplicatesRemoved
function M.RestoreFromWorld()
    local restored, duplicatesRemoved = 0, 0

    local vehicles = GetAllVehicles()
    for i = 1, #vehicles do
        local veh = vehicles[i]
        if DoesEntityExist(veh) and isVehicleUsable(veh) then
            local owner = Entity(veh).state[OWNER_STATE_KEY]
            if type(owner) == 'string' and owner ~= '' then
                -- Keep the bike we already track and destroy extras, so a scan
                -- can never orphan (or delete) the bike a driver is riding.
                local tracked = resolveVehicle(M.ActiveDriverVehicles[owner])
                if tracked and tracked ~= veh then
                    DeleteEntity(veh)
                    duplicatesRemoved = duplicatesRemoved + 1
                elseif not tracked then
                    M.ActiveDriverVehicles[owner] = NetworkGetNetworkIdFromEntity(veh)
                    restored = restored + 1
                end
            end
        end
    end

    return restored, duplicatesRemoved
end

-- Fired drivers lose the company bike immediately (authorization revoked).
AddEventHandler('lifestate_ojol:server:driverFired', function(citizenid)
    M.Release(citizenid, true)
end)

return M
