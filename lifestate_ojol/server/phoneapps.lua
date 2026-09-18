-- Lifestate App Store: per-character app install state.
--
-- The Ojol apps must behave like DOWNLOADABLE apps, not like features that every
-- player has. Two separate facts drive what a player sees:
--
--   1. INSTALLED  - persistent, per character, stored in `lifestate_phone_apps`.
--   2. ELIGIBLE   - a server-side predicate (the Driver app additionally requires
--                   an active Ojol driver registration).
--
-- An app is on the home screen when it is installed AND currently eligible. The
-- App Store itself is always present.
--
-- That list is turned into NPWD's own resource config here, because NPWD decides
-- the home screen from `config.apps` (see client/phoneapps.lua for the bridge and
-- the version-specific reasoning). The client never chooses what it may see.
--
-- Nothing is "downloaded": every FiveM resource stays loaded. Install state only
-- controls registration/visibility inside the phone.

local db = require 'server.database'
local drivers = require 'server.drivers'

local M = {}

---App ids are resource names: NPWD loads `https://cfx-nui-<id>/web/dist/remoteEntry.js`.
M.APP_STORE = 'npwd_lifestate_app_store'
M.APP_OJOL_CUSTOMER = 'npwd_lifestate_ojol_customer'
M.APP_OJOL_DRIVER = 'npwd_lifestate_ojol'

---Apps this resource owns. They are always stripped out of NPWD's static `apps`
---list and re-added per character, so config.json can never re-preinstall them.
---@type table<string, boolean>
M.MANAGED_APPS = {
    [M.APP_OJOL_CUSTOMER] = true,
    [M.APP_OJOL_DRIVER] = true,
}

---What the App Store lists. `driverOnly` is evaluated server-side only; the UI
---receives the resolved `eligible` flag, never the predicate.
M.CATALOG = {
    {
        id = M.APP_OJOL_CUSTOMER,
        name = 'Ojol',
        description = 'Pesan transportasi Ojol',
        requiresDriver = false,
    },
    {
        id = M.APP_OJOL_DRIVER,
        name = 'Ojol Driver',
        description = 'Aplikasi kerja driver Ojol',
        requiresDriver = true,
    },
}

---Install/uninstall anti-spam (single player spamming the store).
local ACTION_COOLDOWN_MS = 500
local lastAction = {} -- [citizenid] = timestamp

---Installed app sets, so opening the phone does not re-query MariaDB each time.
---Invalidated on write and when the character's session ends.
local installedCache = {} -- [citizenid] = table<appId, boolean>

---NPWD's own config file, read once per resource start. It is static on disk, and
---re-sending it verbatim (only `apps` changed) keeps every other NPWD setting the
---admin configured - the phone UI replaces its whole config atom with this object.
local cachedNpwdConfig = nil

---@return table|nil config
local function readNpwdConfig()
    if cachedNpwdConfig then return cachedNpwdConfig end

    local raw = LoadResourceFile('npwd', 'config.json')
    if not raw then
        print('[ojol:phoneapps] npwd/config.json is unreadable; app visibility cannot be applied')
        return nil
    end

    local ok, parsed = pcall(json.decode, raw)
    if not ok or type(parsed) ~= 'table' then
        print(('[ojol:phoneapps] npwd/config.json is not valid JSON: %s'):format(tostring(parsed)))
        return nil
    end

    cachedNpwdConfig = parsed
    return cachedNpwdConfig
end

---Drop the cached NPWD config so the next read picks the file up again.
---Called when the npwd resource (re)starts: an admin editing config.json and
---restarting the phone must not be served from our memory.
function M.InvalidateNpwdConfig()
    cachedNpwdConfig = nil
end

AddEventHandler('onServerResourceStart', function(resourceName)
    if resourceName ~= 'npwd' then return end
    M.InvalidateNpwdConfig()
end)

---@param citizenid string
---@return table<string, boolean>
function M.GetInstalledApps(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return {} end

    local cached = installedCache[citizenid]
    if cached then return cached end

    local installed = db.FetchInstalledApps(citizenid)
    installedCache[citizenid] = installed
    return installed
end

---Drop a character's cached install set (session end / external change).
---@param citizenid string
function M.Forget(citizenid)
    installedCache[citizenid] = nil
end

---May this character install/use this app at all?
---This is the only place driver eligibility is decided; callers never pass a flag.
---@param citizenid string
---@param appId string
---@return boolean eligible, string? reason
function M.IsEligible(citizenid, appId)
    if appId == M.APP_OJOL_CUSTOMER then return true end

    if appId == M.APP_OJOL_DRIVER then
        if drivers.IsRegisteredDriver(citizenid) then return true end
        return false, 'driver_only'
    end

    return false, 'unknown_app'
end

---Is this app on the character's home screen right now?
---@param citizenid string
---@param appId string
---@return boolean visible
function M.IsVisible(citizenid, appId)
    if not M.GetInstalledApps(citizenid)[appId] then return false end
    return M.IsEligible(citizenid, appId)
end

---@param citizenid string
---@return boolean spammy
local function isSpammy(citizenid)
    local now = GetGameTimer()
    local last = lastAction[citizenid]
    lastAction[citizenid] = now
    return last ~= nil and (now - last) < ACTION_COOLDOWN_MS
end

---@param citizenid string
---@return boolean success, string? reason
function M.Install(citizenid, appId)
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'invalid_character' end
    if type(appId) ~= 'string' then return false, 'invalid_app' end
    if isSpammy(citizenid) then return false, 'too_fast' end

    local eligible, reason = M.IsEligible(citizenid, appId)
    if not eligible then return false, reason or 'not_eligible' end

    if not db.SetPhoneAppInstalled(citizenid, appId, true) then
        return false, 'database_error'
    end

    local installed = M.GetInstalledApps(citizenid)
    installed[appId] = true
    return true
end

---@param citizenid string
---@return boolean success, string? reason
function M.Uninstall(citizenid, appId)
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'invalid_character' end
    if type(appId) ~= 'string' then return false, 'invalid_app' end
    if isSpammy(citizenid) then return false, 'too_fast' end

    local eligible, reason = M.IsEligible(citizenid, appId)
    if not eligible then return false, reason or 'not_eligible' end

    if not db.SetPhoneAppInstalled(citizenid, appId, false) then
        return false, 'database_error'
    end

    local installed = M.GetInstalledApps(citizenid)
    installed[appId] = nil
    return true
end

---Revoke the Driver app when a driver is fired (or otherwise loses registration).
---The install is dropped rather than merely hidden, so a rehire restores the right
---to install - not the installation itself.
---@param citizenid string
---@return boolean changed
function M.RevokeDriverApp(citizenid)
    if not M.GetInstalledApps(citizenid)[M.APP_OJOL_DRIVER] then return false end

    local ok = db.SetPhoneAppInstalled(citizenid, M.APP_OJOL_DRIVER, false)
    if not ok then
        -- Fail closed anyway: eligibility is re-checked on every visibility pass, so
        -- the app still disappears even if the row could not be updated now.
        print(('[ojol:phoneapps] could not persist Driver app revocation for %s'):format(tostring(citizenid)))
    end

    installedCache[citizenid] = installedCache[citizenid] or {}
    installedCache[citizenid][M.APP_OJOL_DRIVER] = nil

    return true
end

---Store contents for one character: catalog + install state + eligibility.
---@param citizenid string
---@return table payload
function M.BuildStoreState(citizenid)
    local installed = M.GetInstalledApps(citizenid)
    local apps = {}

    for i = 1, #M.CATALOG do
        local entry = M.CATALOG[i]
        local eligible, reason = M.IsEligible(citizenid, entry.id)

        local view = {
            id = entry.id,
            name = entry.name,
            description = entry.description,
            installed = installed[entry.id] == true,
            eligible = eligible,
            -- Shown by the store; the UI never decides eligibility itself.
            requiresDriver = entry.requiresDriver == true,
        }

        -- Explicitly conditional: `eligible and nil or 'label'` would always take
        -- the label, because nil is falsy in Lua.
        if not eligible then
            view.reason = reason or 'not_eligible'
            view.lockLabel = 'Harus terdaftar sebagai driver Ojol'
        end

        apps[#apps + 1] = view
    end

    return {
        storeAppId = M.APP_STORE,
        apps = apps,
        driverRegistered = drivers.IsRegisteredDriver(citizenid),
    }
end

---NPWD's resource config with this character's `apps` list applied.
---Returns nil when NPWD's config cannot be read: the caller then leaves the phone
---untouched (the static config.json already contains no Ojol apps, so the safe
---state is "nothing extra visible").
---@param citizenid string
---@return table|nil config
function M.BuildNpwdConfig(citizenid)
    local base = readNpwdConfig()
    if not base then return nil end

    -- Shallow copy: the cached config must never be mutated per player.
    local config = {}
    for key, value in pairs(base) do
        config[key] = value
    end

    local apps = {}

    -- Keep every non-managed external app the admin configured (mail, garages, the
    -- App Store, ...), and drop the managed ids even if someone put them back into
    -- npwd/config.json - that was exactly how they ended up preinstalled.
    local baseApps = base.apps
    if type(baseApps) == 'table' then
        for i = 1, #baseApps do
            local appId = baseApps[i]
            if type(appId) == 'string' and not M.MANAGED_APPS[appId] then
                apps[#apps + 1] = appId
            end
        end
    end

    -- The App Store is permanently available.
    local hasStore = false
    for i = 1, #apps do
        if apps[i] == M.APP_STORE then hasStore = true end
    end
    if not hasStore then apps[#apps + 1] = M.APP_STORE end

    -- Installed + eligible apps only.
    for i = 1, #M.CATALOG do
        local appId = M.CATALOG[i].id
        if M.IsVisible(citizenid, appId) then
            apps[#apps + 1] = appId
        end
    end

    config.apps = apps
    return config
end

-- Driver revocation ---------------------------------------------------------

---Firing a driver revokes the Driver app immediately.
---Eligibility (drivers.IsRegisteredDriver) is already false by the time this
---event fires, so the app leaves the phone on the client push alone; the install
---row is then cleared so a rehire restores ELIGIBILITY, not the installation.
AddEventHandler('lifestate_ojol:server:driverFired', function(citizenid)
    if type(citizenid) ~= 'string' then return end

    local src = drivers.SourceByCitizenid[citizenid]
    if src then
        TriggerClientEvent('lifestate_ojol:client:phoneAppsChanged', src)
    end

    -- Persist outside the event: the write can yield, and nothing about the
    -- revocation depends on it having finished yet (eligibility is re-checked on
    -- every visibility pass).
    CreateThread(function() M.RevokeDriverApp(citizenid) end)
end)

return M
