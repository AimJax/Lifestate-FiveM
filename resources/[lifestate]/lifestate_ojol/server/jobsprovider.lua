-- Ojol's registration into the generic Lifestate job registry (lifestate_jobs).
--
-- Ojol is an INDEPENDENT PROFESSION: it never touches the player's Qbox primary
-- job, so a police officer or a mechanic can also be a registered Ojol driver.
-- This module is the only Ojol-specific piece the admin menu ever sees, and it
-- exposes exactly that distinction through the generic provider contract:
--
--   give    -> the existing server-authoritative registration path
--              (drivers.RegisterDriver): history/statistics preserved on rehire,
--              NO CEO proximity and NO CEO authority - this is an ADMIN operation.
--   remove  -> the existing soft-deactivation path (drivers.FireDriver), which
--              already revokes authorization, the work bike, pending offers/rides
--              and the Driver app.
--   inspect -> the generic state shape the admin menu renders.
--   setCeo  -> the existing trusted exports.lifestate_ojol:assignCEO path.
--
-- Ordinary Give never assigns CEO: the single-CEO invariant stays owned by
-- drivers.AssignCEO.

local M = {}

M.PROVIDER_ID = 'ojol'
M.REGISTRY_RESOURCE = 'lifestate_jobs'
M.REASON = 'admin menu'

---@return JobProviderDefinition
local function definition()
    return {
        id = M.PROVIDER_ID,
        label = 'Ojol',
        type = 'profession',
        -- No `resource` field on purpose: lifestate_jobs records the real caller
        -- (GetInvokingResource) as the owner, so ownership cannot be declared - or
        -- claimed - from here. Ojol is also removed from the registry
        -- automatically when this resource stops.
        order = 10,

        -- Ranks are not admin-assignable through Give/Remove: every rank below CEO
        -- stays a CEO-management concern, and CEO is the dedicated action below.
        grades = nil,

        give = function(target)
            return exports.lifestate_ojol:adminRegisterDriver(target.citizenid, M.REASON)
        end,

        remove = function(target)
            local ok, outcome = exports.lifestate_ojol:adminRemoveDriver(target.citizenid, M.REASON)

            if not ok and outcome == 'cannot_fire_ceo' then
                return false, outcome, {
                    message = 'This player is the active Ojol CEO. Reassign the CEO first '
                        .. '(Advanced Provider Actions -> Set Ojol CEO), then remove.',
                }
            end

            return ok, outcome
        end,

        inspect = function(target)
            return exports.lifestate_ojol:getDriverAdminState(target.citizenid)
        end,

        actions = {
            {
                id = 'setCeo',
                label = 'Set Ojol CEO',
                description = 'Assign the Ojol CEO rank (the previous CEO is demoted to driver).',
                confirm = true,
                handler = function(target)
                    local ok, err = exports.lifestate_ojol:assignCEO(target.citizenid, M.REASON)

                    if not ok then
                        return false, err, {
                            message = ('Could not assign the Ojol CEO: %s'):format(tostring(err)),
                        }
                    end

                    return true, 'ceo_assigned', {
                        message = ('%s is now the Ojol CEO.'):format(target.name),
                    }
                end,
            },
        },
    }
end

---Register (or re-register) this provider with the generic registry.
---@return boolean registered
function M.Register()
    if GetResourceState(M.REGISTRY_RESOURCE) ~= 'started' then
        print(('[ojol] job provider not registered yet: %s is not running'):format(M.REGISTRY_RESOURCE))
        return false
    end

    local called, ok, outcome = pcall(function()
        return exports[M.REGISTRY_RESOURCE]:RegisterProvider(definition())
    end)

    if not called then
        print(('[ojol] job provider registration failed: %s'):format(tostring(ok)))
        return false
    end

    if not ok then
        print(('[ojol] job provider rejected: %s'):format(tostring(outcome)))
        return false
    end

    print(('[ojol] job provider %s %s in %s'):format(M.PROVIDER_ID, tostring(outcome), M.REGISTRY_RESOURCE))
    return true
end

---Wire the provider: register now, retry briefly if load order put us first, and
---re-register whenever the registry resource restarts (its registry is in-memory).
function M.Start()
    if not M.Register() then
        CreateThread(function()
            for _ = 1, 60 do
                Wait(500)
                if M.Register() then return end
            end
        end)
    end

    AddEventHandler('onServerResourceStart', function(resourceName)
        if resourceName ~= M.REGISTRY_RESOURCE then return end
        CreateThread(M.Register)
    end)
end

return M
