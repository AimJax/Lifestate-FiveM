-- Driver-side ride rendering (Phase 3B/3C).
--
-- The server is the only source of truth for offers and rides; this file just
-- renders the pushed views (notifications + GPS) and cleans up after itself.
-- Closing the phone never changes ride state, because state does not live here.
--
-- Blip lifecycle (Phase 3C):
--   DRIVER_ENROUTE / DRIVER_ARRIVED -> one route to the PICKUP
--   PASSENGER_ONBOARD / ENROUTE_DESTINATION -> one route to the DESTINATION
--   terminal / no ride -> everything cleared
-- Exactly one blip exists at any time; switching legs reuses it.

local sharedConfig = require 'config.shared'

local rideBlip = nil
local activeRideId = nil
local activeLeg = nil -- 'pickup' | 'destination' | nil

local TERMINAL_MESSAGES = {
    CANCELLED_CUSTOMER = 'Penumpang membatalkan order.',
    CANCELLED_DRIVER = 'Order dibatalkan.',
    COMPLETED = 'Order selesai.',
    FAILED = 'Order gagal.',
}

local function clearBlip(blip)
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
end

---Remove the ride blip (idempotent).
local function clearRideBlips()
    clearBlip(rideBlip)
    rideBlip = nil
    activeRideId = nil
    activeLeg = nil
end

---Draw (or retarget) the single route blip. Reusing the existing blip is what
---keeps routes from stacking up when the leg switches.
---@param coords table
---@param name string
---@param sprite number
---@param colour number
local function showRoute(coords, name, sprite, colour)
    if rideBlip and DoesBlipExist(rideBlip) then
        -- Retarget in place: no duplicate blips on leg switch.
        SetBlipCoords(rideBlip, coords.x, coords.y, coords.z)
    else
        rideBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
        SetBlipAsShortRange(rideBlip, false)
    end

    activeLeg = name

    SetBlipSprite(rideBlip, sprite)
    SetBlipColour(rideBlip, colour)
    SetBlipScale(rideBlip, 0.9)
    SetBlipRoute(rideBlip, true)
    SetBlipRouteColour(rideBlip, colour)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(name)
    EndTextCommandSetBlipName(rideBlip)
end

local function showPickupRoute(ride)
    showRoute(ride.pickup, 'Jemput Penumpang', sharedConfig.blipSpritePickup, sharedConfig.blipColourPickup)
end

local function showDestinationRoute(ride)
    showRoute(ride.destination, 'Tujuan Perjalanan', sharedConfig.blipSpriteDestination, sharedConfig.blipColourDestination)
end

-- Events (pushed by the server) -------------------------------------------------

---A new order offer, or nil when the offer was withdrawn (taken by another
---driver, declined elsewhere, or the search ended).
RegisterNetEvent('lifestate_ojol:client:driverOfferChanged', function(offer)
    if not offer then return end

    lib.notify({
        title = 'Ojol',
        description = ('ORDER BARU - %s'):format(tostring(offer.customerName or 'Penumpang')),
        type = 'inform',
    })
end)

---The assigned ride changed. Terminal views clear the GPS; a new ride draws it.
RegisterNetEvent('lifestate_ojol:client:driverRideChanged', function(ride)
    if not ride or ride.terminal then
        local wasActive = activeRideId ~= nil
        clearRideBlips()

        if wasActive and ride then
            lib.notify({
                title = 'Ojol',
                description = TERMINAL_MESSAGES[ride.status] or 'Order berakhir.',
                type = 'inform',
            })
        end
        return
    end

    local isNewRide = activeRideId ~= ride.rideId
    if isNewRide then
        activeRideId = ride.rideId
        lib.notify({
            title = 'Ojol',
            description = 'Order diterima. Jemput penumpang di titik jemput.',
            type = 'success',
        })
    end

    if ride.status == 'PASSENGER_ONBOARD' or ride.status == 'ENROUTE_DESTINATION' then
        -- Passenger leg: pickup blip is replaced by the destination route.
        if activeLeg ~= 'destination' then
            lib.notify({
                title = 'Ojol',
                description = 'Penumpang sudah naik. Antar ke tujuan.',
                type = 'success',
            })
        end
        showDestinationRoute(ride)
    elseif ride.status == 'DRIVER_ARRIVED' and activeLeg ~= 'pickup' then
        showPickupRoute(ride)
    else
        showPickupRoute(ride)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- Never leave a route running for a resource that is no longer loaded.
    clearRideBlips()
end)
