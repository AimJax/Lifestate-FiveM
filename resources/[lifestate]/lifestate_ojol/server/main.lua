local sharedConfig = require 'config.shared'
local serverConfig = require 'config.server'
local db = require 'server.database'
local drivers = require 'server.drivers'
local company = require 'server.company'
local bikes = require 'server.vehicles'
-- rides.lua first: matching.lua requires it (rides never requires matching).
local rides = require 'server.rides'
local matching = require 'server.matching'
local payments = require 'server.payments'
local roadsnap = require 'server.roadsnap'
local phoneapps = require 'server.phoneapps'
local adminapi = require 'server.adminapi'
local jobsprovider = require 'server.jobsprovider'

-- Validation helpers --------------------------------------------------------

---Server-side proximity check using the real player peds.
---@param srcA number
---@param srcB number
---@param maxDistance number
---@return boolean
local function arePlayersNear(srcA, srcB, maxDistance)
    local pedA = GetPlayerPed(srcA)
    local pedB = GetPlayerPed(srcB)
    if not pedA or pedA == 0 or not pedB or pedB == 0 then return false end

    local coordA = GetEntityCoords(pedA)
    local coordB = GetEntityCoords(pedB)
    if not coordA or not coordB then return false end

    return #(coordA - coordB) <= maxDistance
end

---Manager-command rate limit (anti-spam for registration/fire/promotions).
local lastManagerAction = {}
local MANAGER_ACTION_COOLDOWN_MS = 1000

local function isManagerActionSpammy(src)
    local now = GetGameTimer()
    local last = lastManagerAction[src]
    if last and (now - last) < MANAGER_ACTION_COOLDOWN_MS then return true end

    lastManagerAction[src] = now
    return false
end

---Resolve a target source from a command argument with server-side existence check.
---@param targetSrcArg any
---@return number? targetSrc
local function resolveTargetSource(targetSrcArg)
    local targetSrc = tonumber(targetSrcArg)
    if not targetSrc or not GetPlayerName(targetSrc) then return nil end
    return targetSrc
end

-- Callbacks -----------------------------------------------------------------

---Driver state snapshot for the NPWD driver app.
lib.callback.register('lifestate_ojol:server:getDriverState', function(source)
    local citizenid = drivers.GetCitizenidBySource(source)
    if not citizenid then
        return {
            registered = false, active = false, online = false, busy = false,
            rank = nil, profilePhoto = nil, rating = nil,
        }
    end

    return drivers.GetDriverStateSnapshot(citizenid)
end)

---Clock in / out (MULAI NARIK / SELESAI NARIK).
---Clock-out while busy stays allowed here for now; the future ride system will
---forbid it at this boundary once ride state exists.
lib.callback.register('lifestate_ojol:server:setDriverDuty', function(source, desiredState)
    if type(desiredState) ~= 'boolean' then
        return { success = false, reason = 'invalid_state' }
    end

    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then
        return { success = false, reason = 'not_registered' }
    end

    local ok, reason = drivers.SetDriverOnline(citizenid, desiredState)
    if not ok then
        return { success = false, reason = reason }
    end

    -- Keep the owning game client's authorization mirror in sync (bike gating).
    TriggerClientEvent('lifestate_ojol:client:dutyChanged', source, desiredState)

    -- Let the ride system hand this driver work (or take pending offers away).
    TriggerEvent('lifestate_ojol:server:driverAvailabilityChanged', citizenid, desiredState)

    local snapshot = drivers.GetDriverStateSnapshot(citizenid)
    snapshot.success = true
    return snapshot
end)

---Bike spawn (Pangkalan LAJU). Requires registered + active + online.
---The Qbox primary job is NOT used as authorization anymore.
---Duplicate protection is server-authoritative AND serialized: the whole
---critical section runs under a per-driver spawn lock, so even two requests in
---the same tick can never both create a bike.
lib.callback.register('lifestate_ojol:server:spawnBike', function(source, model)
    local citizenid = drivers.GetCitizenidBySource(source)
    if not citizenid then
        print('[lifestate_ojol:server:spawnBike] rejected: no_player')
        return nil
    end

    if not drivers.IsRegisteredDriver(citizenid) then
        print('[lifestate_ojol:server:spawnBike] rejected: not_registered')
        return nil
    end

    if not drivers.IsDriverOnline(citizenid) then
        print('[lifestate_ojol:server:spawnBike] rejected: offline')
        return nil
    end

    local allowed = false
    for i = 1, #serverConfig.allowedVehicles do
        if serverConfig.allowedVehicles[i].model == model then
            allowed = true
            break
        end
    end

    if not allowed then
        print('[lifestate_ojol:server:spawnBike] rejected: model_not_allowed')
        return nil
    end

    -- Serialize concurrent requests for the same driver.
    if not bikes.AcquireSpawnLock(citizenid) then
        print(('[lifestate_ojol:server:spawnBike] rejected: spawn_in_progress (%s)'):format(citizenid))
        return nil
    end

    -- The lock must be released on every path, including a Lua error, so the
    -- rest of the critical section runs inside pcall.
    local ok, netId = pcall(function()
        -- Re-check inside the lock: one valid work bike per driver (stale entries
        -- for lost vehicles are cleared in place).
        if bikes.HasValidBike(citizenid) then
            print(('[lifestate_ojol:server:spawnBike] rejected: bike_already_active (%s)'):format(citizenid))
            return nil
        end

        local spawnedNetId = qbx.spawnVehicle({ model = model, spawnSource = sharedConfig.vehicleSpawnLocation, warp = true })
        if not spawnedNetId or spawnedNetId == 0 then
            print('[lifestate_ojol:server:spawnBike] rejected: spawn_failed')
            return nil
        end

        local veh = NetworkGetEntityFromNetworkId(spawnedNetId)
        if not veh or veh == 0 then
            -- Single deferred resolve (not a polling loop) so ownership can be stamped.
            Wait(0)
            veh = NetworkGetEntityFromNetworkId(spawnedNetId)
        end

        if not veh or veh == 0 then
            print('[lifestate_ojol:server:spawnBike] rejected: spawn_failed')
            return nil
        end

        local plate = locale('info.bus_plate') .. tostring(math.random(1000, 9999))
        SetVehicleNumberPlateText(veh, plate)
        TriggerClientEvent('vehiclekeys:client:SetOwner', source, plate)

        bikes.Track(citizenid, spawnedNetId)

        return spawnedNetId
    end)

    bikes.ReleaseSpawnLock(citizenid)

    if not ok then
        print(('[lifestate_ojol:server:spawnBike] error for %s: %s'):format(citizenid, tostring(netId)))
        return nil
    end

    return netId
end)

-- Ride system callbacks (Phase 3B) ------------------------------------------
-- Every ride action is validated server-side; the client only ever supplies a
-- payment method, a proposed pickup point and a destination.

local RIDE_ACTION_COOLDOWNS = {
    create = serverConfig.createRideCooldownMs,
    accept = serverConfig.acceptRideCooldownMs,
    cancel = serverConfig.cancelRideCooldownMs,
    trip = serverConfig.tripActionCooldownMs,
    rate = serverConfig.tripActionCooldownMs,
    payment = serverConfig.tripActionCooldownMs,
}

local lastRideAction = {} -- [source] = { [action] = timestamp }

---Lightweight anti-spam for ride actions.
---@param src number
---@param action string
---@return boolean spammy
local function isRideActionSpammy(src, action)
    local entry = lastRideAction[src]
    if not entry then
        entry = {}
        lastRideAction[src] = entry
    end

    local now = GetGameTimer()
    local last = entry[action]
    entry[action] = now

    return last ~= nil and (now - last) < RIDE_ACTION_COOLDOWNS[action]
end

---Fare quote for the Ojol customer app. Read-only: nothing is created here.
lib.callback.register('lifestate_ojol:server:getRideQuote', function(source, payload)
    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'invalid_customer' } end
    if type(payload) ~= 'table' then return { success = false, reason = 'invalid_request' } end

    local ok, quoteOrReason = rides.BuildCustomerQuote(citizenid, payload.pickup, payload.destination)
    if not ok then return { success = false, reason = quoteOrReason } end

    -- The app shows the customer's balances; they come from the server, never
    -- from the client.
    local player = exports.qbx_core:GetPlayer(source)
    local money = player and player.PlayerData and player.PlayerData.money or {}
    quoteOrReason.balances = {
        cash = tonumber(money.cash) or 0,
        bank = tonumber(money.bank) or 0,
    }

    return { success = true, data = quoteOrReason }
end)

---Create a ride request. The client proposes a pickup + destination and picks a
---payment method; pickup validation, distance, fare and the balance check are
---all recomputed server-side.
lib.callback.register('lifestate_ojol:server:createRideRequest', function(source, payload)
    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'invalid_customer' } end
    if isRideActionSpammy(source, 'create') then return { success = false, reason = 'too_fast' } end
    if type(payload) ~= 'table' then return { success = false, reason = 'invalid_request' } end

    local ok, rideOrReason = rides.CreateRide(citizenid, payload.pickup, payload.destination, payload.paymentMethod)
    if not ok then return { success = false, reason = rideOrReason } end

    return { success = true, data = rides.GetCustomerView(citizenid) }
end)

---Customer cancels the current request or ride (always free for the customer).
lib.callback.register('lifestate_ojol:server:cancelCustomerRide', function(source)
    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'invalid_customer' } end
    if isRideActionSpammy(source, 'cancel') then return { success = false, reason = 'too_fast' } end

    local ok, reason = rides.CustomerCancel(citizenid)
    if not ok then return { success = false, reason = reason } end

    return { success = true, data = nil }
end)

---Customer app state. Reconstructed from server truth whenever the app reopens.
lib.callback.register('lifestate_ojol:server:getCustomerRideState', function(source)
    local citizenid = drivers.GetCitizenidBySource(source)
    if not citizenid then return nil end

    return rides.GetCustomerView(citizenid)
end)

---Driver app state: availability, pending offer and the active ride leg.
lib.callback.register('lifestate_ojol:server:getDriverRideState', function(source)
    return matching.GetDriverView(source)
end)

---Accept an offer. The first valid acceptance wins; the assignment itself is
---atomic (see rides.TryAcceptRide).
lib.callback.register('lifestate_ojol:server:acceptRideOffer', function(source, rideId)
    if isRideActionSpammy(source, 'accept') then return { success = false, reason = 'too_fast' } end

    local ok, reason = matching.AcceptOffer(source, rideId)
    if not ok then return { success = false, reason = reason } end

    return { success = true, data = matching.GetDriverView(source) }
end)

---Decline an offer. Only this driver stops seeing it; no cooldown is created.
lib.callback.register('lifestate_ojol:server:rejectRideOffer', function(source, rideId)
    local ok = matching.RejectOffer(source, rideId)
    return { success = ok, reason = ok and nil or 'no_offer' }
end)

---Driver cancels an accepted ride. Before pickup the customer's request reopens
---unchanged; after pickup it reopens recalculated. This is the only voluntary
---cancellation path, so it is the only one that records a cancel statistic or
---creates the hidden pair cooldown.
lib.callback.register('lifestate_ojol:server:cancelDriverRide', function(source)
    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'not_registered' } end
    if isRideActionSpammy(source, 'cancel') then return { success = false, reason = 'too_fast' } end

    local ok, reason = rides.DriverCancel(citizenid, rides.VOLUNTARY_CANCEL_ORIGIN)
    if not ok then return { success = false, reason = reason } end

    return { success = true, data = matching.GetDriverView(source) }
end)

-- In-trip driver actions (Phase 3C). Every action re-validates ownership, ride
-- state and real server-side ped proximity inside rides.lua.

---SAYA SUDAH SAMPAI: DRIVER_ENROUTE -> DRIVER_ARRIVED.
lib.callback.register('lifestate_ojol:server:driverArrived', function(source, rideId)
    if isRideActionSpammy(source, 'trip') then return { success = false, reason = 'too_fast' } end

    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'not_registered' } end

    local ok, reason = rides.DriverArrived(citizenid, rideId)
    if not ok then return { success = false, reason = reason } end

    return { success = true, data = matching.GetDriverView(source) }
end)

---PENUMPANG SUDAH NAIK: DRIVER_ARRIVED -> PASSENGER_ONBOARD -> ENROUTE_DESTINATION.
lib.callback.register('lifestate_ojol:server:passengerBoarded', function(source, rideId)
    if isRideActionSpammy(source, 'trip') then return { success = false, reason = 'too_fast' } end

    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'not_registered' } end

    local ok, reason = rides.PassengerBoarded(citizenid, rideId)
    if not ok then return { success = false, reason = reason } end

    return { success = true, data = matching.GetDriverView(source) }
end)

---SELESAIKAN PERJALANAN: ENROUTE_DESTINATION -> payment -> COMPLETED.
---An unpaid ride never completes; insufficient funds keep the ride pending.
lib.callback.register('lifestate_ojol:server:completeRide', function(source, rideId)
    if isRideActionSpammy(source, 'trip') then return { success = false, reason = 'too_fast' } end

    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'not_registered' } end

    local ok, reason = rides.TryCompleteRide(citizenid, rideId)
    if not ok then return { success = false, reason = reason } end

    return { success = true, data = matching.GetDriverView(source) }
end)

---Customer switches cash <-> bank while the ride is alive (not while searching).
---The locked fare never changes; only coverage of the SAME fare is re-checked.
lib.callback.register('lifestate_ojol:server:changePaymentMethod', function(source, payload)
    if isRideActionSpammy(source, 'payment') then return { success = false, reason = 'too_fast' } end

    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'invalid_customer' } end
    if type(payload) ~= 'table' then return { success = false, reason = 'invalid_request' } end

    local ok, reason = rides.CustomerChangePayment(citizenid, payload.method)
    if not ok then return { success = false, reason = reason } end

    return { success = true, data = rides.GetCustomerView(citizenid) }
end)

---Submit a rating for a completed ride (1..5, once, ride owner only).
lib.callback.register('lifestate_ojol:server:submitRating', function(source, payload)
    if isRideActionSpammy(source, 'rate') then return { success = false, reason = 'too_fast' } end

    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'invalid_customer' } end
    if type(payload) ~= 'table' then return { success = false, reason = 'invalid_request' } end

    local ok, reason = rides.SubmitRating(citizenid, payload.rideId, tonumber(payload.rating))
    if not ok then return { success = false, reason = reason } end

    return { success = true, data = { rideId = payload.rideId, rating = payload.rating } }
end)

-- Lifestate App Store callbacks --------------------------------------------
-- Ojol apps are installable, never preinstalled. Install state is per character
-- and every request is re-validated here: the app id, the character behind the
-- source and driver eligibility all come from the server, never from the client.

---The full NPWD resource config with this character's `apps` list applied. The
---client forwards it to NPWD's own NUI message (see client/phoneapps.lua).
lib.callback.register('lifestate_ojol:server:getPhoneAppConfig', function(source)
    local citizenid = drivers.GetCitizenidBySource(source)
    if not citizenid then return nil end

    return phoneapps.BuildNpwdConfig(citizenid)
end)

---Store contents: catalog + install state + eligibility. Read-only.
lib.callback.register('lifestate_ojol:server:getPhoneApps', function(source)
    local citizenid = drivers.GetCitizenidBySource(source)
    if not citizenid then return { success = false, reason = 'invalid_character' } end

    return { success = true, data = phoneapps.BuildStoreState(citizenid) }
end)

---Install an app. The App Store front-end never sends eligibility - only an id.
lib.callback.register('lifestate_ojol:server:installPhoneApp', function(source, appId)
    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'invalid_character' } end

    local ok, reason = phoneapps.Install(citizenid, appId)
    if not ok then return { success = false, reason = reason } end

    -- Home screen updates immediately; no reconnect, no server restart.
    TriggerClientEvent('lifestate_ojol:client:phoneAppsChanged', source)

    return { success = true, data = phoneapps.BuildStoreState(citizenid) }
end)

---Uninstall an app (the customer Ojol app stays optional, like any other).
lib.callback.register('lifestate_ojol:server:uninstallPhoneApp', function(source, appId)
    local citizenid = drivers.ResolveCitizenid(source)
    if not citizenid then return { success = false, reason = 'invalid_character' } end

    local ok, reason = phoneapps.Uninstall(citizenid, appId)
    if not ok then return { success = false, reason = reason } end

    TriggerClientEvent('lifestate_ojol:client:phoneAppsChanged', source)

    return { success = true, data = phoneapps.BuildStoreState(citizenid) }
end)

-- CEO management commands (temporary V1 commands, all server-authoritative) --

local function notify(src, message, notifyType)
    exports.qbx_core:Notify(src, message, notifyType)
end

---Shared handler for /daftarlaju and its backward-compatible alias.
---@param source number
---@param args table
local function registerDriverCommand(source, args)
    local src = source
    if src == 0 then return end -- console has no CEO record
    if isManagerActionSpammy(src) then return end

    local callerCitizenid = drivers.ResolveCitizenid(src)
    if not callerCitizenid or not drivers.IsActingCEO(callerCitizenid) then
        notify(src, 'Kamu bukan CEO LAJU.', 'error')
        return
    end

    local targetSrc = resolveTargetSource(args.serverId)
    if not targetSrc then
        notify(src, 'Target tidak ditemukan.', 'error')
        return
    end

    if targetSrc == src then
        notify(src, 'Kamu tidak bisa mendaftarkan dirimu sendiri.', 'error')
        return
    end

    local targetCitizenid = drivers.GetCitizenidBySource(targetSrc)
    if not targetCitizenid then
        notify(src, 'Target tidak ditemukan.', 'error')
        return
    end

    if not arePlayersNear(src, targetSrc, sharedConfig.maxRegistrationDistance) then
        notify(src, 'Target terlalu jauh. Dekati target (maksimal 3 meter).', 'error')
        return
    end

    local ok, reason = drivers.RegisterDriver(targetCitizenid, callerCitizenid)
    if not ok then
        local messages = {
            already_registered = 'Player ini sudah terdaftar sebagai Mitra LAJU.',
            invalid_target = 'Target tidak valid.',
            database_error = 'Gagal menyimpan data driver.',
        }
        notify(src, messages[reason] or 'Gagal mendaftarkan driver.', 'error')
        return
    end

    -- 'reactivated' = an inactive historical record was reused (stats preserved).
    notify(src, reason == 'reactivated'
        and 'Mitra LAJU diaktifkan kembali (riwayat tetap tersimpan).'
        or 'Mitra LAJU berhasil didaftarkan.', 'success')
    notify(targetSrc, 'Kamu sekarang terdaftar sebagai Mitra LAJU. Buka aplikasi LAJU Mitra di HP untuk clock in.', 'success')

    -- Push the fresh state so an already-online hiree unlocks the dispatcher
    -- without reconnecting (fire/rehire uses the same persistent identity).
    TriggerClientEvent('lifestate_ojol:client:driverStateChanged', targetSrc,
        drivers.GetDriverStateSnapshot(targetCitizenid))
end

lib.addCommand('daftarlaju', {
    help = 'CEO LAJU: daftarkan Mitra LAJU yang berada di dekatmu',
    params = {
        { name = 'serverId', help = 'Server ID target', type = 'playerId' },
    },
}, registerDriverCommand)

-- Backward-compatible alias: the exact same handler as /daftarlaju.
lib.addCommand('daftarojol', {
    help = 'Alias of /daftarlaju',
    params = {
        { name = 'serverId', help = 'Server ID target', type = 'playerId' },
    },
}, registerDriverCommand)

---Shared handler for /pecatlaju and its backward-compatible alias.
---@param source number
---@param args table
local function fireDriverCommand(source, args)
    local src = source
    if src == 0 then return end
    if isManagerActionSpammy(src) then return end

    local callerCitizenid = drivers.ResolveCitizenid(src)
    if not callerCitizenid or not drivers.IsActingCEO(callerCitizenid) then
        notify(src, 'Kamu bukan CEO LAJU.', 'error')
        return
    end

    local targetSrc = resolveTargetSource(args.serverId)
    if not targetSrc then
        notify(src, 'Target tidak ditemukan.', 'error')
        return
    end

    if targetSrc == src then
        notify(src, 'Kamu tidak bisa memecat dirimu sendiri.', 'error')
        return
    end

    -- V1 behavior: nearby preferred, enforced server-side.
    if not arePlayersNear(src, targetSrc, sharedConfig.maxRegistrationDistance) then
        notify(src, 'Target terlalu jauh. Dekati target (maksimal 3 meter).', 'error')
        return
    end

    local targetCitizenid = drivers.GetCitizenidBySource(targetSrc)
    if not targetCitizenid then
        notify(src, 'Target tidak ditemukan.', 'error')
        return
    end

    local ok, reason = drivers.FireDriver(targetCitizenid)
    if not ok then
        local messages = {
            not_registered = 'Player ini bukan Mitra LAJU terdaftar.',
            cannot_fire_ceo = 'Kamu tidak bisa memecat CEO.',
            database_error = 'Gagal menghapus data driver.',
        }
        notify(src, messages[reason] or 'Gagal memecat driver.', 'error')
        return
    end

    notify(src, 'Mitra LAJU berhasil dipecat.', 'success')
    notify(targetSrc, 'Kamu telah dipecat dari LAJU.', 'error')
end

lib.addCommand('pecatlaju', {
    help = 'CEO LAJU: pecat Mitra LAJU yang berada di dekatmu',
    params = {
        { name = 'serverId', help = 'Server ID target', type = 'playerId' },
    },
}, fireDriverCommand)

-- Backward-compatible alias: the exact same handler as /pecatlaju.
lib.addCommand('pecatojol', {
    help = 'Alias of /pecatlaju',
    params = {
        { name = 'serverId', help = 'Server ID target', type = 'playerId' },
    },
}, fireDriverCommand)

---Shared handler for /promotelaju and its backward-compatible alias.
---@param source number
---@param args table
local function promoteDriverCommand(source, args)
    local src = source
    if src == 0 then return end
    if isManagerActionSpammy(src) then return end

    local callerCitizenid = drivers.ResolveCitizenid(src)
    if not callerCitizenid or not drivers.IsActingCEO(callerCitizenid) then
        notify(src, 'Kamu bukan CEO LAJU.', 'error')
        return
    end

    local targetSrc = resolveTargetSource(args.serverId)
    if not targetSrc then
        notify(src, 'Target tidak ditemukan.', 'error')
        return
    end

    local targetCitizenid = drivers.GetCitizenidBySource(targetSrc)
    if not targetCitizenid then
        notify(src, 'Target tidak ditemukan.', 'error')
        return
    end

    local ok, reason, newRank = drivers.PromoteDriver(targetCitizenid)
    if not ok then
        local messages = {
            not_registered = 'Player ini bukan Mitra LAJU terdaftar.',
            cannot_promote = 'Driver ini tidak bisa dinaikkan ranknya lagi.',
            rank_not_manageable = 'Rank ini tidak bisa dikelola oleh CEO.',
            database_error = 'Gagal menyimpan perubahan rank.',
        }
        notify(src, messages[reason] or 'Gagal mempromosikan driver.', 'error')
        return
    end

    notify(src, ('Driver berhasil dipromosikan ke %s.'):format(newRank), 'success')
    notify(targetSrc, ('Rank LAJU kamu naik ke %s.'):format(newRank), 'success')
end

lib.addCommand('promotelaju', {
    help = 'CEO LAJU: naikkan rank Mitra LAJU (driver -> senior_driver -> supervisor)',
    params = {
        { name = 'serverId', help = 'Server ID target', type = 'playerId' },
    },
}, promoteDriverCommand)

-- Backward-compatible alias: the exact same handler as /promotelaju.
lib.addCommand('promoteojol', {
    help = 'Alias of /promotelaju',
    params = {
        { name = 'serverId', help = 'Server ID target', type = 'playerId' },
    },
}, promoteDriverCommand)

---Shared handler for /demotelaju and its backward-compatible alias.
---@param source number
---@param args table
local function demoteDriverCommand(source, args)
    local src = source
    if src == 0 then return end
    if isManagerActionSpammy(src) then return end

    local callerCitizenid = drivers.ResolveCitizenid(src)
    if not callerCitizenid or not drivers.IsActingCEO(callerCitizenid) then
        notify(src, 'Kamu bukan CEO LAJU.', 'error')
        return
    end

    local targetSrc = resolveTargetSource(args.serverId)
    if not targetSrc then
        notify(src, 'Target tidak ditemukan.', 'error')
        return
    end

    local targetCitizenid = drivers.GetCitizenidBySource(targetSrc)
    if not targetCitizenid then
        notify(src, 'Target tidak ditemukan.', 'error')
        return
    end

    local ok, reason, newRank = drivers.DemoteDriver(targetCitizenid)
    if not ok then
        local messages = {
            not_registered = 'Player ini bukan Mitra LAJU terdaftar.',
            cannot_demote = 'Driver ini tidak bisa diturunkan ranknya lagi.',
            rank_not_manageable = 'Rank ini tidak bisa dikelola oleh CEO.',
            database_error = 'Gagal menyimpan perubahan rank.',
        }
        notify(src, messages[reason] or 'Gagal mendemosi driver.', 'error')
        return
    end

    notify(src, ('Driver berhasil diturunkan ke %s.'):format(newRank), 'success')
    notify(targetSrc, ('Rank LAJU kamu turun ke %s.'):format(newRank), 'error')
end

lib.addCommand('demotelaju', {
    help = 'CEO LAJU: turunkan rank Mitra LAJU (supervisor -> senior_driver -> driver)',
    params = {
        { name = 'serverId', help = 'Server ID target', type = 'playerId' },
    },
}, demoteDriverCommand)

-- Backward-compatible alias: the exact same handler as /demotelaju.
lib.addCommand('demoteojol', {
    help = 'Alias of /demotelaju',
    params = {
        { name = 'serverId', help = 'Server ID target', type = 'playerId' },
    },
}, demoteDriverCommand)

-- Admin job-management API ----------------------------------------------------
-- The implementation lives in server/adminapi.lua (trusted server-only, called by
-- the generic admin Job Management section through lifestate_jobs). Ojol is an
-- independent profession, so none of these touches the player's Qbox primary job.
exports('assignCEO', adminapi.AssignCEO)
exports('adminRegisterDriver', adminapi.RegisterDriver)
exports('adminRemoveDriver', adminapi.RemoveDriver)
exports('getDriverAdminState', adminapi.GetState)

-- Lifecycle -----------------------------------------------------------------

local function onStartup()
    db.EnsureSchema()
    company.RefreshCompanyBalance()
    drivers.LoadDrivers()

    -- Server-internal spatial index refresh for online drivers (2 s cadence,
    -- ped reads only, no network traffic). Matching degrades to exact checks
    -- on live coordinates regardless, so this only affects candidate cost.
    drivers.StartPositionRefresh()

    -- Rides cannot survive a restart (their runtime state is gone), so any ride
    -- left non-terminal in the database is closed as FAILED.
    local failedRides = rides.RecoverOnStartup()

    -- Print the company balance INCLUDING any negative operational debt left by
    -- compensation so the state is visible at every restart.
    local companyBalance = company.GetCompanyBalance()

    -- Re-adopt Ojol bikes that survived a resource restart (one-shot world scan,
    -- never a loop) so the one-bike-per-driver invariant survives a restart
    -- without destroying a driver's in-use vehicle.
    local restored, duplicatesRemoved = bikes.RestoreFromWorld()

    local active, total = drivers.CountDrivers()
    print(('[ojol] foundation loaded: %d active / %d total driver record(s), %d bike(s) re-adopted, %d duplicate bike(s) removed, %d interrupted ride(s) closed, company balance %d%s'):format(
        active, total, restored, duplicatesRemoved, failedRides, companyBalance,
        companyBalance < 0 and ' (COMPANY IN DEBT - compensation payouts)' or ''))
end

AddEventHandler('onServerResourceStart', function(resName)
    if resName ~= GetCurrentResourceName() then return end
    onStartup()
end)

-- Job management -------------------------------------------------------------
-- The Ojol provider registers itself with the generic job registry, so the admin
-- menu (and the registry itself) never needs Ojol-specific code. Ojol stays an
-- independent profession: registering here does not touch the Qbox primary job.
jobsprovider.Start()

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    -- Warm the citizenid <-> source mapping as soon as characters are usable.
    if player and player.PlayerData then
        drivers.CitizenidBySource[player.PlayerData.source] = player.PlayerData.citizenid
        drivers.SourceByCitizenid[player.PlayerData.citizenid] = player.PlayerData.source
    end
end)

-- AddEventHandler (not RegisterNetEvent) so a client cannot spoof the drop event
-- and clear its own bike tracking.
AddEventHandler('playerDropped', function()
    local src = source
    local citizenid = drivers.CitizenidBySource[src]

    if citizenid then
        -- The connection is gone, so this player is not available for matching
        -- any more - drop availability before the ride system reacts to it.
        drivers.ClearOnlineState(citizenid)

        -- Finish any road-snap round trip aimed at this player first: the ride
        -- recovery waiting on it then closes out instead of sitting on its
        -- deadline, so nothing outlives the session.
        roadsnap.DropByCitizenid(citizenid)

        -- Ride cleanup runs before the source mapping is cleared: reopening a
        -- customer's request needs the dropping player's identity.
        rides.HandlePlayerDropped(citizenid)
    end

    -- Phone app install state is persistent, so only the per-session cache goes.
    if citizenid then phoneapps.Forget(citizenid) end

    drivers.CleanupSource(src)
    lastManagerAction[src] = nil
    lastRideAction[src] = nil

    if citizenid then
        -- Clears tracking for bikes that are gone; a still-valid bike stays owned
        -- so reconnecting cannot yield a second one.
        bikes.HandlePlayerDropped(citizenid)

        -- Take any pending offer away from the disconnected driver.
        TriggerEvent('lifestate_ojol:server:driverAvailabilityChanged', citizenid, false)
    end
end)

AddEventHandler('onResourceStop', function(resName)
    if resName ~= GetCurrentResourceName() then return end

    -- Never leave a tier timer pointing at a ride that no longer exists.
    matching.Shutdown()
    rides.ShutdownStreams()

    -- Drop every road-snap deadline timer; their coroutines go with the resource.
    roadsnap.Shutdown()
end)
