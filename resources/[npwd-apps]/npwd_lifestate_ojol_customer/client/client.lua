lib.locale()

print('[NPWD OJOL CUSTOMER] client loaded')

-- Bridge for the Ojol customer app. The app is only a view: the ride lives on
-- the lifestate_ojol server, so closing the phone never cancels anything.
--
-- Waypoint reading and road snapping happen inside lifestate_ojol (client
-- export) because the road-node natives only exist on the game client. Fares,
-- pickup validation and ride state are always computed server-side.

---Ask lifestate_ojol for the customer's current ride endpoints.
---@return table payload
local function resolveLocations()
    local ok, payload = pcall(function()
        return exports.lifestate_ojol:GetSnappedRideLocations()
    end)

    if not ok or type(payload) ~= 'table' then
        return { success = false, reason = 'unavailable' }
    end

    return payload
end

---Fare preview for the current waypoint. Creates nothing.
RegisterNUICallback('npwd:lifestate_ojol_customer:preview', function(_, cb)
    local locations = resolveLocations()
    if not locations.success then
        cb({ status = 'ok', data = { success = false, reason = locations.reason } })
        return
    end

    local ok, result = pcall(lib.callback.await, 'lifestate_ojol:server:getRideQuote', false, {
        pickup = locations.pickup,
        destination = locations.destination,
    })

    if not ok then
        cb({ status = 'error', data = { reason = 'callback_failed' } })
        return
    end

    cb({ status = 'ok', data = result })
end)

---Confirm the order. The waypoint is re-read here so the locked fare always
---matches what the customer sees at the moment of ordering.
RegisterNUICallback('npwd:lifestate_ojol_customer:request', function(data, cb)
    local locations = resolveLocations()
    if not locations.success then
        cb({ status = 'ok', data = { success = false, reason = locations.reason } })
        return
    end

    local ok, result = pcall(lib.callback.await, 'lifestate_ojol:server:createRideRequest', false, {
        pickup = locations.pickup,
        destination = locations.destination,
        paymentMethod = data and data.paymentMethod,
    })

    if not ok then
        cb({ status = 'error', data = { reason = 'callback_failed' } })
        return
    end

    cb({ status = 'ok', data = result })
end)

---Current ride state from the server (server truth, never client memory).
RegisterNUICallback('npwd:lifestate_ojol_customer:state', function(_, cb)
    local ok, result = pcall(lib.callback.await, 'lifestate_ojol:server:getCustomerRideState', false)
    if not ok then
        cb({ status = 'error', data = { reason = 'callback_failed' } })
        return
    end

    cb({ status = 'ok', data = result })
end)

RegisterNUICallback('npwd:lifestate_ojol_customer:cancel', function(_, cb)
    local ok, result = pcall(lib.callback.await, 'lifestate_ojol:server:cancelCustomerRide', false)
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

---Switch the payment method (cash <-> bank) on a live ride. The locked fare
---never changes; the server re-checks that the new method can cover it.
RegisterNUICallback('npwd:lifestate_ojol_customer:changePayment', function(data, cb)
    local ok, result = pcall(lib.callback.await, 'lifestate_ojol:server:changePaymentMethod', false,
        { method = data and data.method })
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

---Submit the 1..5 rating for a completed ride (once, ride owner only).
RegisterNUICallback('npwd:lifestate_ojol_customer:rate', function(data, cb)
    local ok, result = pcall(lib.callback.await, 'lifestate_ojol:server:submitRating', false,
        { rideId = data and data.rideId, rating = data and data.rating })
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

-- Server-pushed ride changes (driver found, driver cancelled, order closed).

---Pull the authoritative ride state (including ratings for completed rides)
---and hand it to the NUI.
local function pushRideState()
    local ok, view = pcall(lib.callback.await, 'lifestate_ojol:server:getCustomerRideState', false)
    if not ok then return end

    exports.npwd:sendNPWDMessage('npwd_lifestate_ojol_customer', 'rideState', view)
end

RegisterNetEvent('lifestate_ojol:client:customerRideChanged', function(view)
    if type(view) == 'table' and view.driver then
        exports.npwd:createNotification({
            notisId = 'ojol:driverfound',
            appId = 'npwd_lifestate_ojol_customer',
            content = ('Driver ditemukan: %s'):format(tostring(view.driver.name or 'Mitra LAJU')),
            keepOpen = false,
            duration = 8000,
            path = '/npwd_lifestate_ojol_customer',
        })
    end

    CreateThread(pushRideState)
end)
