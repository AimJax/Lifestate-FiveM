local config = require 'config.client'
local sharedConfig = require 'config.shared'
local dispatcher = require 'client.dispatcher'
local phoneApps = require 'client.phoneapps'

local busBlip = nil

local BikeData = {
    Active = false,
    Vehicle = nil,
    NetId = nil,
}

-- Driver state (server-authoritative mirror for UI gating; see OnPlayerLoaded)
local driverRegistered = false
local driverOnline = false

-- Functions -----------------------------------------------------------------

local function removeBusBlip()
    if not busBlip then return end
    RemoveBlip(busBlip)
    busBlip = nil
end

local function updateBlip()
    busBlip = AddBlipForCoord(sharedConfig.location.x, sharedConfig.location.y, sharedConfig.location.z)
    SetBlipSprite(busBlip, 513)
    SetBlipDisplay(busBlip, 4)
    SetBlipScale(busBlip, 0.6)
    SetBlipAsShortRange(busBlip, true)
    SetBlipColour(busBlip, 49)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName(locale('info.bus_depot'))
    EndTextCommandSetBlipName(busBlip)
end

local function isBikeDataVehicleInvalid()
    if not BikeData.Vehicle then
        return true
    end
    if not DoesEntityExist(BikeData.Vehicle) then
        return true
    end
    if IsEntityDead(BikeData.Vehicle) then
        return true
    end
    if GetVehicleEngineHealth(BikeData.Vehicle) <= 0.0 then
        return true
    end
    if not IsVehicleDriveable(BikeData.Vehicle, false) then
        return true
    end
    if GetEntitySubmergedLevel(BikeData.Vehicle) >= 0.8 then
        return true
    end
    return false
end

local function bikeGarage()
    local vehicleMenu = {}
    for _, v in pairs(config.allowedVehicles) do
        vehicleMenu[#vehicleMenu + 1] = {
            title = locale('info.bus'),
            event = "lifestate_ojol:client:TakeVehicle",
            args = v
        }
    end
    lib.registerContext({
        id = 'lifestate_ojol_open_garage_context_menu',
        title = locale('info.bus_header'),
        options = vehicleMenu
    })
    lib.showContext('lifestate_ojol_open_garage_context_menu')
end

---What "Ambil Motor" does once the dispatcher ped is interacted with. The ped
---itself (model, placement, invincibility, scenario, ox_target entry) is owned by
---client/dispatcher.lua; only the gameplay reaction lives here.
local function takeMotor()
    if not driverRegistered then
        lib.notify({
            title = 'Pangkalan Ojek',
            description = 'Kamu belum terdaftar sebagai driver Ojol.',
            type = 'error'
        })
        return
    end

    if not driverOnline then
        lib.notify({
            title = 'Pangkalan Ojek',
            description = 'Kamu belum online. Check-in melalui aplikasi Ojol terlebih dahulu.',
            type = 'error'
        })
        return
    end

    bikeGarage()
end

-- Events --------------------------------------------------------------------

RegisterNetEvent("lifestate_ojol:client:TakeVehicle", function(data)
    if not driverRegistered then
        lib.notify({
            title = 'Ojol',
            description = 'Kamu belum terdaftar sebagai driver Ojol.',
            type = 'error'
        })
        return
    end

    if not driverOnline then
        lib.notify({
            title = 'Ojol',
            description = 'Kamu belum online. Check-in melalui aplikasi Ojol terlebih dahulu.',
            type = 'error'
        })
        return
    end

    if BikeData.Active and not isBikeDataVehicleInvalid() then
        lib.notify({
            title = locale('info.bus_job'),
            description = locale('error.one_bus_active'),
            type = 'error'
        })
        return
    end

    if BikeData.Active and isBikeDataVehicleInvalid() then
        BikeData.Active = false
        BikeData.Vehicle = nil
        BikeData.NetId = nil
    end

    local netId = lib.callback.await('lifestate_ojol:server:spawnBike', false, data.model)
    Wait(300)
    if not netId or netId == 0 or not NetworkDoesEntityExistWithNetworkId(netId) then
        lib.notify({
            title = locale('info.bus_job'),
            description = locale('error.failed_to_spawn'),
            type = 'error'
        })
        return
    end

    local veh = NetToVeh(netId)
    if veh == 0 then
        lib.notify({
            title = locale('info.bus_job'),
            description = locale('error.failed_to_spawn'),
            type = 'error'
        })
        return
    end

    SetVehicleFuelLevel(veh, 100.0)
    SetVehicleEngineOn(veh, true, true, false)
    BikeData.Active = true
    BikeData.Vehicle = veh
    BikeData.NetId = netId
    lib.hideContext()

    -- Watchdog: release local tracking when the bike dies/drowns/disappears.
    -- Event-driven via lib.zones-free loop with a generous 2s interval; no per-frame work.
    CreateThread(function()
        while BikeData.Active and not isBikeDataVehicleInvalid() do
            Wait(2000)
        end

        if BikeData.Active then
            BikeData.Active = false
            BikeData.Vehicle = nil
            BikeData.NetId = nil
        end
    end)
end)

RegisterNetEvent('lifestate_ojol:client:driverRevoked', function()
    -- Fired (server) while online: revoke authorization immediately.
    driverRegistered = false
    driverOnline = false

    lib.notify({
        title = 'Ojol',
        description = 'Registrasi Ojol kamu dicabut.',
        type = 'error'
    })
end)

RegisterNetEvent('lifestate_ojol:client:dutyChanged', function(online)
    -- Server confirms a clock-in/out done through the NPWD app so the local
    -- authorization mirror never drifts from the server state.
    driverOnline = online == true
end)

RegisterNetEvent('lifestate_ojol:client:driverStateChanged', function(state)
    -- Registration/reactivation pushed by the server: a driver hired (or hired back)
    -- while already online gets dispatcher access without reconnecting.
    if type(state) ~= 'table' then return end
    driverRegistered = state.registered == true
    driverOnline = state.online == true
end)

-- Resource / player lifecycle -----------------------------------------------

---Refresh the local driver mirror from the server. Event-driven: only on load,
---resource restart and revocation - never polled.
local function refreshDriverState()
    local state = lib.callback.await('lifestate_ojol:server:getDriverState', false)
    if state then
        driverRegistered = state.registered == true
        driverOnline = state.online == true
    else
        driverRegistered = false
        driverOnline = false
    end
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    updateBlip()
    CreateThread(refreshDriverState)
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    CreateThread(refreshDriverState)
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    driverRegistered = false
    driverOnline = false
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- The dispatcher ped and its ox_target registration are owned by
    -- client/dispatcher.lua, which registers its own onResourceStop cleanup.
    removeBusBlip()
end)

-- Lifecycle wiring -----------------------------------------------------------

-- Exactly one dispatcher ped, re-created whenever it is missing, broken or was
-- created before the model could stream. See client/dispatcher.lua.
dispatcher.Start({ onSelect = takeMotor })

-- Phone app visibility (Ojol apps are installable, not preinstalled).
phoneApps.Start()