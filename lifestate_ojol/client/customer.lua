-- Customer-side ride helpers (Phase 3B/3C).
--
-- CfxLua exposes road/path nodes on the client only, so resolving a *usable*
-- pickup and destination has to happen here. This file therefore owns exactly
-- three things: reading the player's GTA waypoint, snapping coordinates to the
-- nearest drivable road node, and rendering the live driver marker. Everything
-- else (fare, validation, state) is server-side, and the server re-validates the
-- pickup this file proposes against the position it sees for the player - so a
-- modified client can never move its own pickup point across the map.
--
-- Snapping runs only when a request is prepared (or re-prepared after a driver
-- abandons the ride). Nothing here runs per frame.
--
-- Driver marker (Phase 3C): the SERVER streams the assigned driver's position
-- every ~2.5 s while a ride is active and stops by itself on any state change.
-- This file only draws/clears the blip - one blip, no polling, no loops.

local sharedConfig = require 'config.shared'

---Horizontal (map plane) distance - rooftop/interior pickups are judged on the
---plane so they snap to the street below rather than being rejected.
---@param a table
---@param b table
---@return number metres
local function horizontalDistance(a, b)
    local dx = (a.x or 0.0) - (b.x or 0.0)
    local dy = (a.y or 0.0) - (b.y or 0.0)
    return math.sqrt(dx * dx + dy * dy)
end

---Read the player's GTA map waypoint.
---@return vector3? coords, string? reason
local function readWaypoint()
    if not IsWaypointActive() then return nil, 'no_waypoint' end

    local blip = GetFirstBlipInfoId(8) -- 8 = waypoint blip sprite
    if not blip or blip == 0 or not DoesBlipExist(blip) then return nil, 'no_waypoint' end

    local coords = GetBlipInfoIdCoord(blip)
    if not coords then return nil, 'no_waypoint' end

    if coords.x == 0.0 and coords.y == 0.0 then return nil, 'no_waypoint' end

    return coords
end

---Nearest drivable road node.
---nodeType 0 is "any road node", which includes the dirt and gravel tracks we
---want to accept. A node is by definition something the game's own traffic path
---system drives on, so rooftops and interiors (which have no vehicle nodes)
---resolve to the street underneath them.
---@param x number
---@param y number
---@param z number
---@return table? node, number? heading
local function snapToRoad(x, y, z)
    local first, second = GetClosestVehicleNodeWithHeading(x, y, z, 0, 3.0, 0)

    -- CfxLua surfaces the native's out-parameters as return values. Both
    -- possible orderings are handled so a wrong assumption can never silently
    -- place a pickup somewhere else.
    local node, heading
    if type(first) == 'vector3' then
        node, heading = first, second
    elseif type(second) == 'vector3' then
        node, heading = second, first
    end

    if not node then return nil end
    if type(heading) ~= 'number' then heading = nil end

    return node, heading
end

---Ground height for a coordinate that only has x/y (a waypoint blip).
---@param x number
---@param y number
---@return number z
local function groundHeightAt(x, y)
    local found, groundZ = GetGroundZFor_3dCoord(x, y, 1000.0, false)

    if found and type(groundZ) == 'number' then
        return groundZ
    end

    return 0.0
end

-- Live driver marker -----------------------------------------------------------

local driverBlip = nil

local function clearDriverBlip()
    if driverBlip and DoesBlipExist(driverBlip) then RemoveBlip(driverBlip) end
    driverBlip = nil
end

---Server-pushed driver position (~every 2.5 s, only while a ride is active).
---One blip, moved in place - never a stack of markers.
RegisterNetEvent('lifestate_ojol:client:driverLocation', function(coords)
    if type(coords) ~= 'table' or not coords.x or not coords.y then return end

    if not driverBlip or not DoesBlipExist(driverBlip) then
        driverBlip = AddBlipForCoord(coords.x + 0.0, coords.y + 0.0, (coords.z or 0.0) + 0.0)
        SetBlipSprite(driverBlip, sharedConfig.blipSpriteDriver or 1)
        SetBlipColour(driverBlip, sharedConfig.blipColourDriver or 2)
        SetBlipScale(driverBlip, 0.85)
        SetBlipAsShortRange(driverBlip, false)

        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName('Driver Ojol')
        EndTextCommandSetBlipName(driverBlip)
    else
        SetBlipCoords(driverBlip, coords.x + 0.0, coords.y + 0.0, (coords.z or 0.0) + 0.0)
    end
end)

---The ride state changed: terminal/absent rides clear the marker immediately.
RegisterNetEvent('lifestate_ojol:client:customerRideChanged', function(view)
    if not view or view.terminal or (view.status == 'SEARCHING' and not view.driver) then
        clearDriverBlip()
    end
end)

lib.callback.register('lifestate_ojol:client:getRoadPickup', function()
    local coords = GetEntityCoords(PlayerPedId())
    local node = snapToRoad(coords.x, coords.y, coords.z)
    if not node or horizontalDistance(node, coords) > sharedConfig.maxPickupSnapMeters then return nil end
    return { x = node.x + 0.0, y = node.y + 0.0, z = node.z + 0.0 }
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- No orphan blips when the resource goes away.
    clearDriverBlip()
end)

---Resolve the customer's current ride endpoints.
---Exposed to the NPWD customer app as a client export; a missing waypoint or an
---unreachable destination is reported as a reason string, never as an error.
---@return table payload
local function getSnappedRideLocations()
    local ped = PlayerPedId()
    local pickupCoords = GetEntityCoords(ped)

    local pickupNode, pickupHeading = snapToRoad(pickupCoords.x, pickupCoords.y, pickupCoords.z)

    local pickup
    if pickupNode and horizontalDistance(pickupNode, pickupCoords) <= sharedConfig.maxPickupSnapMeters then
        pickup = { x = pickupNode.x + 0.0, y = pickupNode.y + 0.0, z = pickupNode.z + 0.0 }
    else
        -- No usable road nearby (mid-air, deep interior, out at sea): keep the
        -- player's own position. The server accepts it because that is exactly
        -- where the player stands.
        pickup = { x = pickupCoords.x + 0.0, y = pickupCoords.y + 0.0, z = pickupCoords.z + 0.0 }
        pickupHeading = GetEntityHeading(ped)
    end

    local waypoint, waypointReason = readWaypoint()
    if not waypoint then return { success = false, reason = waypointReason } end

    local waypointZ = groundHeightAt(waypoint.x, waypoint.y)
    local destinationNode = snapToRoad(waypoint.x, waypoint.y, waypointZ)

    if not destinationNode or horizontalDistance(destinationNode, waypoint) > sharedConfig.maxDestinationSnapMeters then
        return { success = false, reason = 'destination_not_on_road' }
    end

    return {
        success = true,
        pickup = pickup,
        pickupHeading = pickupHeading or 0.0,
        destination = { x = destinationNode.x + 0.0, y = destinationNode.y + 0.0, z = destinationNode.z + 0.0 },
    }
end

exports('GetSnappedRideLocations', getSnappedRideLocations)
