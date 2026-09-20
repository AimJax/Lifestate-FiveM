-- Ojol's registration into the generic Lifestate job registry (lifestate_jobs).
--
-- Ojol is an INDEPENDENT PROFESSION: it never touches the player's Qbox primary
-- job, so a police officer or a mechanic can also be a registered Ojol driver.
-- This module is the only Ojol-specific piece the admin menu ever sees.
--
-- EXTERNAL PROVIDER CONTRACT - metadata only. A Lua closure does not survive the
-- real resource boundary as a callable function (CfxLua encodes it as a `funcref`,
-- which is how a live server rejected this provider with `give_not_function`), so the
-- definition below carries the NAMES of the trusted Ojol server exports instead.
-- lifestate_jobs calls them as:
--
--   give    -> exports.lifestate_ojol:adminRegisterDriver(target, options)
--              the existing server-authoritative registration path
--              (drivers.RegisterDriver): history/statistics preserved on rehire,
--              NO CEO proximity and NO CEO authority - this is an ADMIN operation.
--   remove  -> exports.lifestate_ojol:adminRemoveDriver(target, options), the
--              existing soft-deactivation path (drivers.FireDriver), which already
--              revokes authorization, the work bike, pending offers/rides and the
--              Driver app.
--   inspect -> exports.lifestate_ojol:getDriverAdminState(target)
--   setCeo  -> exports.lifestate_ojol:assignCEO(target, options), the existing
--              trusted CEO path. Ordinary Give never touches the CEO rank: the
--              single-CEO invariant stays owned by drivers.AssignCEO.
--
-- Ownership is resolved by lifestate_jobs from the invoking resource, so this
-- definition declares no owner (and could not get away with claiming one), and the
-- entry is dropped from the registry automatically when this resource stops.
--
-- The only wording that has to travel as data is the refusal message for removing
-- an active CEO (`messages` below).

local M = {}

M.PROVIDER_ID = 'ojol'
M.REGISTRY_RESOURCE = 'lifestate_jobs'

---Backoff for a registry that is not up YET (load order, or a restart in flight).
---Structural rejections are never retried - see M.IsRetryable.
M.RETRY_DELAYS_MS = { 500, 1000, 2000, 5000 }

---@return JobProviderDefinition
local function definition()
    return {
        id = M.PROVIDER_ID,
        label = 'Mitra LAJU',
        type = 'profession',
        order = 10,

        -- Ranks are not admin-assignable through Give/Remove: every rank below CEO
        -- stays a CEO-management concern, and CEO is the dedicated action below.
        grades = nil,

        operations = {
            give = 'adminRegisterDriver',
            remove = 'adminRemoveDriver',
            inspect = 'getDriverAdminState',
        },

        messages = {
            cannot_fire_ceo = 'This player is the active LAJU CEO. Reassign the CEO first '
                .. '(Advanced Provider Actions -> Set CEO LAJU), then remove.',
        },

        actions = {
            {
                id = 'setCeo',
                label = 'Set CEO LAJU',
                description = 'Assign the LAJU CEO rank (the previous CEO is demoted to driver).',
                confirm = true,
                export = 'assignCEO',
            },
        },
    }
end

---Registration failures that mean "the registry is not reachable yet" and are worth
---a bounded retry. Everything else (a rejected definition, an id conflict, a
---missing owner) is structural: retrying it can never succeed and would only spam
---the console, so it is logged once and dropped.
---@param outcome string?
---@return boolean retryable
function M.IsRetryable(outcome)
    return outcome == 'registry_unavailable'
end

---Register (or re-register) this provider with the generic registry.
---@return boolean registered
---@return string? outcomeOrReason
function M.Register()
    if GetResourceState(M.REGISTRY_RESOURCE) ~= 'started' then
        return false, 'registry_unavailable'
    end

    local called, ok, outcome = pcall(function()
        return exports[M.REGISTRY_RESOURCE]:RegisterProvider(definition())
    end)

    if not called then
        -- Mid-restart the export can still be missing; that is a dependency problem,
        -- not a definition problem.
        print(('[ojol] job provider registration could not reach %s: %s'):format(
            M.REGISTRY_RESOURCE, tostring(ok)))
        return false, 'registry_unavailable'
    end

    if not ok then
        print(('[ojol] job provider rejected: %s'):format(tostring(outcome)))
        return false, outcome
    end

    print(('[ojol] job provider %s %s in %s'):format(M.PROVIDER_ID, tostring(outcome), M.REGISTRY_RESOURCE))
    return true, outcome
end

---Register, retrying with a bounded backoff ONLY while the registry is not reachable
---yet (load order, or a restart in flight). A structural rejection is never retried:
---retrying a rejected definition can only spam the console.
---@return boolean registered, string? outcomeOrReason
function M.RegisterWithRetry()
    local registered, outcome = M.Register()
    if registered or not M.IsRetryable(outcome) then return registered, outcome end

    for i = 1, #M.RETRY_DELAYS_MS do
        Wait(M.RETRY_DELAYS_MS[i])

        registered, outcome = M.Register()
        if registered or not M.IsRetryable(outcome) then return registered, outcome end
    end

    print(('[ojol] job provider not registered: %s never became available '
        .. '(job management will run without LAJU)'):format(M.REGISTRY_RESOURCE))

    return false, 'registry_unavailable'
end

---Wire the provider: register now, retry with a small backoff only while the
---registry is unavailable, and re-register whenever it restarts (its registry is
---in-memory, and the re-registration goes through the same bounded retry in case its
---exports are not published yet).
function M.Start()
    local registered, outcome = M.Register()

    if not registered and M.IsRetryable(outcome) then
        CreateThread(M.RegisterWithRetry)
    end

    AddEventHandler('onServerResourceStart', function(resourceName)
        if resourceName ~= M.REGISTRY_RESOURCE then return end

        CreateThread(M.RegisterWithRetry)
    end)
end

return M
