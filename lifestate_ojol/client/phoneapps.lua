-- Per-character phone app visibility.
--
-- Ojol apps must behave like DOWNLOADABLE apps: nothing but the Lifestate App
-- Store is on the home screen until the character installs something. FiveM loads
-- every resource normally - "install" is only persistent per-character state, and
-- this module is the bridge that turns that state into what NPWD actually renders.
--
-- How NPWD 3.15.1-beta.2 decides the home screen (verified against this install's
-- dist bundles, not from documentation):
--
--   * The UI keeps the resource config in a Recoil atom (`resourceConfig`) and
--     renders the home grid from `config.apps` (external apps) + its built-in apps.
--   * The atom is populated by the UI itself fetching `npwd/config.json` once on
--     mount, and it can be replaced at runtime by a NUI message
--     `{ app = 'PHONE', method = 'npwd:setPhoneConfig', data = config }`.
--   * NPWD ships an export to send exactly such a message:
--     `exports.npwd:sendNPWDMessage(app, method, data)`.
--
-- So the bridge is: ask the server for the config file with a per-character `apps`
-- list, then hand it to NPWD's own export. That changes app *registration*, so an
-- uninstalled app is neither rendered nor routed - it is not CSS-hidden, and it is
-- not launchable, because its route does not exist. NPWD core is untouched.
--
-- The whole `apps` array is filtered server-side (server/phoneapps.lua), never
-- here: the client only forwards what it is given.

local M = {}

---NUI message envelope understood by NPWD's phone app handler.
M.NPWD_UI_APP = 'PHONE'
M.NPWD_UI_SET_CONFIG = 'npwd:setPhoneConfig'

---The phone-open signal NPWD emits locally. Used as a periodic safety net so a UI
---reload (which re-fetches npwd/config.json and would restore the unfiltered
---list) heals the next time the player looks at the phone.
local NPWD_PHONE_OPENED_EVENT = 'npwd:disableControlActions'

---Ignore duplicate phone-open signals inside this window.
local OPEN_DEBOUNCE_MS = 750

local started = false
local inFlight = false
local lastOpenRefresh = 0
local lastNpwdError = nil

---@param message string
local function log(message)
    print(('[lifestate_ojol:phoneapps] %s'):format(message))
end

---Ask the server for the NPWD config with this character's `apps` list.
---@return table|nil config
local function fetchConfig()
    local ok, config = pcall(lib.callback.await, 'lifestate_ojol:server:getPhoneAppConfig', false)
    if not ok then
        log('could not read the phone app config from the server')
        return nil
    end

    if type(config) ~= 'table' or type(config.apps) ~= 'table' then return nil end
    return config
end

---@param config table
---@return boolean sent
local function pushToNpwd(config)
    local ok, err = pcall(function()
        exports.npwd:sendNPWDMessage(M.NPWD_UI_APP, M.NPWD_UI_SET_CONFIG, config)
    end)

    if not ok then
        -- npwd starts after this resource, so a failure here is expected until the
        -- phone resource is up. Log the transition only.
        if lastNpwdError ~= tostring(err) then
            lastNpwdError = tostring(err)
            log(('npwd is not ready yet; app visibility will be re-applied (%s)'):format(tostring(err)))
        end
        return false
    end

    lastNpwdError = nil
    return true
end

---Re-apply this character's app visibility to NPWD.
---@param debounceMs number|nil skip if a refresh already ran this recently
---@return boolean applied
function M.Refresh(debounceMs)
    if inFlight then return false end

    if debounceMs then
        local now = GetGameTimer()
        if (now - lastOpenRefresh) < debounceMs then return false end
        lastOpenRefresh = now
    end

    inFlight = true
    local config = fetchConfig()
    local sent = config ~= nil and pushToNpwd(config)
    inFlight = false

    return sent
end

---Wire every trigger that can leave the home screen out of sync.
function M.Start()
    if started then return end
    started = true

    AddEventHandler('onResourceStart', function(resourceName)
        if resourceName ~= GetCurrentResourceName() then return end
        CreateThread(M.Refresh)
    end)

    -- Primary trigger: the character is in game and npwd has long finished
    -- fetching its own config, so our filtered list is the one that sticks.
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
        CreateThread(M.Refresh)
    end)

    -- npwd (re)started: its UI reloads npwd/config.json on mount, which would drop
    -- the per-character filter until we re-send it.
    AddEventHandler('onClientResourceStart', function(resourceName)
        if resourceName ~= 'npwd' then return end
        CreateThread(M.Refresh)
    end)

    -- Server-pushed change (install, uninstall, driver fired).
    RegisterNetEvent('lifestate_ojol:client:phoneAppsChanged', function()
        CreateThread(M.Refresh)
    end)

    -- Safety net: NPWD emits this when the phone is opened. Debounced, so opening
    -- the phone repeatedly costs one refresh, not one per keystroke.
    AddEventHandler(NPWD_PHONE_OPENED_EVENT, function(open)
        if open ~= true then return end
        CreateThread(function() M.Refresh(OPEN_DEBOUNCE_MS) end)
    end)
end

return M
