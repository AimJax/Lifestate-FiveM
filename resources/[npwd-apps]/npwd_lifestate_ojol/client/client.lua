lib.locale()

print('[NPWD OJOL] client loaded')

-- Proxy NUI requests to the existing lifestate_ojol server backend.
-- Do NOT recreate duty or ride state here; lifestate_ojol is the source of truth.

---Forward a server answer to the NUI, normalising the callback contract.
---@param cb function
---@param request fun(): table|nil
local function forward(cb, request)
    local ok, result = pcall(request)
    if not ok then
        print(('[NPWD OJOL] request failed: %s'):format(tostring(result)))
        cb({ status = 'error', data = { reason = 'callback_failed' } })
        return
    end

    cb({ status = 'ok', data = result })
end

RegisterNUICallback('npwd:lifestate_ojol:getDriverState', function(_, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:getDriverState', false)
    end)
end)

RegisterNUICallback('npwd:lifestate_ojol:getDriverRideState', function(_, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:getDriverRideState', false)
    end)
end)

RegisterNUICallback('npwd:lifestate_ojol:setDriverDuty', function(data, cb)
    local ok, result = pcall(lib.callback.await, 'lifestate_ojol:server:setDriverDuty', false, data.desiredState)
    if not ok then
        cb({ status = 'error', data = { reason = 'callback_failed' } })
        return
    end

    if result and result.success then
        cb({ status = 'ok', data = result })
    else
        cb({ status = 'error', data = { reason = result and result.reason or 'unknown' } })
    end
end)

RegisterNUICallback('npwd:lifestate_ojol:acceptRideOffer', function(data, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:acceptRideOffer', false, data.rideId)
    end)
end)

RegisterNUICallback('npwd:lifestate_ojol:rejectRideOffer', function(data, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:rejectRideOffer', false, data.rideId)
    end)
end)

RegisterNUICallback('npwd:lifestate_ojol:cancelDriverRide', function(_, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:cancelDriverRide', false)
    end)
end)

-- Phase 3C in-trip actions. The server validates ownership, ride state and real
-- ped proximity for each; the app only sends the ride id.

RegisterNUICallback('npwd:lifestate_ojol:driverArrived', function(data, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:driverArrived', false, data.rideId)
    end)
end)

RegisterNUICallback('npwd:lifestate_ojol:passengerBoarded', function(data, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:passengerBoarded', false, data.rideId)
    end)
end)

RegisterNUICallback('npwd:lifestate_ojol:completeRide', function(data, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:completeRide', false, data.rideId)
    end)
end)

-- Push server-side ride changes into the app so the driver never has to poll.
-- The phone UI is only a view: closing it changes nothing on the server.

---Pull the authoritative driver view and hand it to the NUI.
local function pushRideState()
    local ok, view = pcall(lib.callback.await, 'lifestate_ojol:server:getDriverRideState', false)
    if not ok or not view then return end

    exports.npwd:sendNPWDMessage('npwd_lifestate_ojol', 'rideState', view)
end

RegisterNetEvent('lifestate_ojol:client:driverOfferChanged', function(offer)
    if offer then
        exports.npwd:createNotification({
            notisId = 'ojol:neworder',
            appId = 'npwd_lifestate_ojol',
            content = ('ORDER BARU: %s - %s'):format(tostring(offer.customerName or 'Penumpang'), tostring(offer.fareText or '')),
            keepOpen = false,
            duration = 8000,
            path = '/npwd_lifestate_ojol',
        })
    end

    CreateThread(pushRideState)
end)

RegisterNetEvent('lifestate_ojol:client:driverRideChanged', function()
    CreateThread(pushRideState)
end)

RegisterNetEvent('lifestate_ojol:client:driverStateChanged', function(state)
    if type(state) ~= 'table' then return end

    exports.npwd:sendNPWDMessage('npwd_lifestate_ojol', 'driverState', state)
    CreateThread(pushRideState)
end)
