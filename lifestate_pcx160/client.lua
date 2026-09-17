-- PCX160 speed/torque taper
-- Standalone FiveM client script using GTA natives only.

local pcxModel = `pcx160`

local SPEED_115 = 31.944444

local function torqueMultiplier(speedKmh)
    if speedKmh < 80 then
        return 1.15

    elseif speedKmh < 100 then
        local t = (speedKmh - 80) / 20
        return 1.15 - (t * 0.37)
        -- 1.15 -> 0.78

    elseif speedKmh < 110 then
        local t = (speedKmh - 100) / 10
        return 0.78 - (t * 0.28)
        -- 0.78 -> 0.50

    elseif speedKmh < 115 then
        local t = (speedKmh - 110) / 5
        return 0.50 - (t * 0.35)
        -- 0.50 -> 0.15

    else
        return 0.00
    end
end

local lastPcxVeh = nil
local limiterActive = false

local function resetTorque(veh)
    if veh and DoesEntityExist(veh) then
        SetVehicleEngineTorqueMultiplier(veh, 1.0)
    end
end

local function capHorizontalVelocity(veh)
    local vx, vy, vz = table.unpack(GetEntityVelocity(veh))
    local horizontalSpeed = math.sqrt(vx * vx + vy * vy)

    if horizontalSpeed > SPEED_115 then
        local scale = SPEED_115 / horizontalSpeed
        SetEntityVelocity(veh, vx * scale, vy * scale, vz)
    end
end

print('[PCX160] limiter client loaded')

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)

        if veh == 0 then
            if lastPcxVeh then
                resetTorque(lastPcxVeh)
                lastPcxVeh = nil
            end
            if limiterActive then
                limiterActive = false
            end
            Wait(500)
            goto continue
        end

        if GetPedInVehicleSeat(veh, -1) ~= ped then
            if lastPcxVeh then
                resetTorque(lastPcxVeh)
                lastPcxVeh = nil
            end
            if limiterActive then
                limiterActive = false
            end
            Wait(500)
            goto continue
        end

        if GetEntityModel(veh) ~= pcxModel then
            if lastPcxVeh and lastPcxVeh ~= veh then
                resetTorque(lastPcxVeh)
                lastPcxVeh = nil
            end
            if limiterActive then
                limiterActive = false
            end
            Wait(500)
            goto continue
        end

        lastPcxVeh = veh

        if not limiterActive then
            limiterActive = true
            print('[PCX160] limiter active')
        end

        local speed = GetEntitySpeed(veh)
        local speedKmh = speed * 3.6

        local multiplier = torqueMultiplier(speedKmh)
        SetVehicleEngineTorqueMultiplier(veh, multiplier)

        capHorizontalVelocity(veh)

        Wait(0)

        ::continue::
    end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    if lastPcxVeh and DoesEntityExist(lastPcxVeh) then
        SetVehicleEngineTorqueMultiplier(lastPcxVeh, 1.0)
    end
end)