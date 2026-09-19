-- Admin job-management API for Ojol.
--
-- This is the only Ojol surface the generic admin menu reaches (through the
-- lifestate_jobs provider in server/jobsprovider.lua). Ojol is an INDEPENDENT
-- PROFESSION, so nothing here touches the player's Qbox primary job: a police
-- officer or a mechanic can also be a registered Ojol driver.
--
-- Trusted server-side callers only. The ADMIN's authorization is enforced by
-- lifestate_jobs before it calls these functions, and none of them is reachable
-- from a client.
--
--   RegisterDriver -> the existing server-authoritative registration path
--                     (drivers.RegisterDriver). No CEO proximity and no CEO
--                     authority: an admin Give is not a promotion, so it never
--                     assigns CEO. A fired historical driver is reactivated with
--                     history, ratings and statistics preserved.
--   RemoveDriver   -> the existing soft-deactivation path (drivers.FireDriver):
--                     authorization, the work bike, pending offers/rides and the
--                     Driver app are all revoked. Works regardless of distance.
--   GetState       -> the generic state snapshot the admin menu renders.
--   AssignCEO      -> the trusted CEO path (drivers.AssignCEO); the single-CEO
--                     invariant stays owned there, and this is the only way an
--                     admin Give can reach the CEO rank.
--
-- Kept free of resource-lifecycle wiring (no events, no timers) so the whole
-- module is directly testable against the real driver registry.

local drivers = require 'server.drivers'

local M = {}

local function notify(src, message, notifyType)
    exports.qbx_core:Notify(src, message, notifyType)
end

---Admin registration: the existing server-authoritative registration path.
---@param citizenid string
---@param reason string
---@return boolean success, string? outcomeOrReason 'registered' | 'reactivated'
function M.RegisterDriver(citizenid, reason)
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'invalid_target' end

    local ok, outcome = drivers.RegisterDriver(citizenid, 'admin')
    if not ok then return false, outcome end

    print(('[ojol] admin registration: %s (%s, reason: %s)'):format(citizenid, outcome, tostring(reason)))

    local src = drivers.SourceByCitizenid[citizenid]
    if src then
        notify(src, 'Kamu sekarang terdaftar sebagai driver Ojol.', 'success')

        -- Live refresh: the dispatcher unlocks and the Driver app becomes eligible
        -- without a reconnect (registration and reactivation share this path).
        TriggerClientEvent('lifestate_ojol:client:driverStateChanged', src,
            drivers.GetDriverStateSnapshot(citizenid))
        TriggerClientEvent('lifestate_ojol:client:phoneAppsChanged', src)
    end

    return true, outcome
end

---Admin removal: the existing firing/deactivation semantics.
---Soft deactivation only (history, ratings, statistics preserved); the
---driverFired chain revokes authorization, the work bike, pending offers/rides and
---the Driver app. An active CEO is refused here on purpose: the single-CEO
---invariant is owned by drivers.FireDriver, so the CEO has to be reassigned first.
---@param citizenid string
---@param reason string
---@return boolean success, string? outcomeOrReason
function M.RemoveDriver(citizenid, reason)
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'invalid_target' end

    local ok, outcome = drivers.FireDriver(citizenid)
    if not ok then return false, outcome end

    print(('[ojol] admin removal: %s (reason: %s)'):format(citizenid, tostring(reason)))

    local src = drivers.SourceByCitizenid[citizenid]
    if src then
        -- The client mirror is revoked by FireDriver (driverRevoked) and the phone
        -- apps are refreshed by the driverFired handler in server/phoneapps.lua;
        -- this push keeps a still-open admin view consistent.
        TriggerClientEvent('lifestate_ojol:client:driverStateChanged', src,
            drivers.GetDriverStateSnapshot(citizenid))
    end

    return true, 'removed'
end

---Admin state snapshot (View Player Jobs). Read-only and generic in shape:
---standard flags plus provider-specific details the menu renders as-is.
---@param citizenid string
---@return table state
function M.GetState(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return { registered = false } end

    local driver = drivers.GetOjolDriver(citizenid)
    local snapshot = drivers.GetDriverStateSnapshot(citizenid)

    local details = {}
    if driver then
        details[#details + 1] = {
            label = 'Record',
            value = driver.active == true and 'active' or 'inactive (fired)',
        }

        if driver.registeredBy then
            details[#details + 1] = { label = 'Registered by', value = tostring(driver.registeredBy) }
        end

        if driver.registeredAt then
            details[#details + 1] = {
                label = 'Registered at',
                value = type(driver.registeredAt) == 'number'
                    and os.date('%Y-%m-%d %H:%M:%S', driver.registeredAt)
                    or tostring(driver.registeredAt),
            }
        end
    end

    return {
        registered = snapshot.registered,
        active = snapshot.active,
        online = snapshot.online,
        busy = snapshot.busy,
        rank = snapshot.rank,
        rating = snapshot.rating,
        details = details,
    }
end

---Assign CEO to a citizenid. Admin-controlled, never callable by a CEO.
---Creates the record if missing and reactivates it if the driver was previously
---fired; history is preserved either way.
---@param citizenid string
---@param reason string
---@return boolean success, string? error
function M.AssignCEO(citizenid, reason)
    local ok, err = drivers.AssignCEO(citizenid, 'admin')
    if not ok then return false, err end

    print(('[ojol] CEO assigned to %s (reason: %s)'):format(citizenid, tostring(reason)))

    local src = drivers.SourceByCitizenid[citizenid]
    if src then
        notify(src, 'Kamu sekarang CEO Ojol.', 'success')
        TriggerClientEvent('lifestate_ojol:client:driverStateChanged', src,
            drivers.GetDriverStateSnapshot(citizenid))
    end

    return true
end

return M
