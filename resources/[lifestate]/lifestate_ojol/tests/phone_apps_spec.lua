-- Lifestate App Store (server/phoneapps.lua).
--
-- The module is exercised directly. Its two host dependencies (MariaDB access and
-- the driver registry) are replaced by stubs, as is NPWD's config file: the specs
-- assert WHICH file is read and WHAT the module does with it, never that Lua can
-- parse JSON. The properties that matter are:
--
--   * an Ojol app is on the home screen only when it is INSTALLED and ELIGIBLE,
--   * losing eligibility (fired) hides it immediately, even before the persistent
--     uninstall lands,
--   * neither npwd/config.json nor a stale install row can reintroduce the old
--     "everyone has both Ojol apps" behaviour,
--   * the App Store itself is always present,
--   * install state is per character and survives independent of session,
--   * the DB is not queried on every visibility check.

local h = require 'tests.harness'

local STORE = 'npwd_lifestate_app_store'
local OJOL_CUSTOMER = 'npwd_lifestate_ojol_customer'
local OJOL_DRIVER = 'npwd_lifestate_ojol'

-- NPWD built-ins: compiled into the phone UI, hidden through `disabledApps`.
local MATCHMAKER = 'MATCH'
local IRC = 'DARKCHAT'
local SOCIAL = 'TWITTER'
local MARKETPLACE = 'MARKETPLACE'

local BUILTINS = { MATCHMAKER, IRC, SOCIAL, MARKETPLACE }

---The four built-ins a fresh character must not see on the home screen.
---Self-contained on purpose: the spec's `has` helper is declared further down.
---@param config table
---@return string[] hidden
local function hiddenBuiltins(config)
    local set = {}
    local list = config.disabledApps
    if type(list) == 'table' then
        for i = 1, #list do set[list[i]] = true end
    end

    local hidden = {}
    for i = 1, #BUILTINS do
        if set[BUILTINS[i]] then hidden[#hidden + 1] = BUILTINS[i] end
    end
    return hidden
end

local CHARACTER = 'citizen-a'
local OTHER_CHARACTER = 'citizen-b'

-- Stub host state -------------------------------------------------------------

local dbState = {
    writes = {},
    reads = 0,
    rows = {}, -- [citizenid] = { [appId] = true }
    writeFails = false,
}

-- Kept as two long-lived tables and cleared in place: the stubbed module captures
-- the table references, so reassigning them would silently detach the stub from
-- what the spec populates.
local driverState = {
    registered = {},
    sources = {},
}

local function clear(t)
    for key in pairs(t) do t[key] = nil end
end

local host = {
    clock = 0,
    fileReads = {},
    parsedConfig = nil,
    clientEvents = {},
    threads = {},
    handlers = {},
}

package.preload['server.database'] = function()
    return {
        FetchInstalledApps = function(citizenid)
            dbState.reads = dbState.reads + 1
            local set = {}
            for appId in pairs(dbState.rows[citizenid] or {}) do set[appId] = true end
            return set
        end,
        SetPhoneAppInstalled = function(citizenid, appId, installed)
            if dbState.writeFails then return false end

            dbState.writes[#dbState.writes + 1] = { citizenid = citizenid, appId = appId, installed = installed }

            dbState.rows[citizenid] = dbState.rows[citizenid] or {}
            dbState.rows[citizenid][appId] = installed and true or nil
            return true
        end,
    }
end

package.preload['server.drivers'] = function()
    return {
        SourceByCitizenid = driverState.sources,
        IsRegisteredDriver = function(citizenid)
            return driverState.registered[citizenid] == true
        end,
    }
end

-- Host primitives must exist before the module loads: it registers its
-- driverFired handler at load time.
LoadResourceFile = function(resourceName, fileName)
    host.fileReads[#host.fileReads + 1] = { resource = resourceName, file = fileName }
    return '{}'
end

json = {
    decode = function()
        return host.parsedConfig
    end,
}

GetGameTimer = function() return host.clock end

TriggerClientEvent = function(eventName, target, ...)
    host.clientEvents[#host.clientEvents + 1] = { event = eventName, target = target, args = { ... } }
end

AddEventHandler = function(eventName, fn)
    host.handlers[eventName] = fn
end

RegisterNetEvent = function(eventName, fn)
    host.handlers[eventName] = fn
end

CreateThread = function(fn)
    host.threads[#host.threads + 1] = fn
end

---Run (and clear) every thread handed to CreateThread.
local function runThreads()
    local pending = host.threads
    host.threads = {}

    for _, fn in ipairs(pending) do
        fn()
    end
end

package.preload['server.phoneapps'] = nil
package.loaded['server.database'] = nil
package.loaded['server.drivers'] = nil
package.loaded['server.phoneapps'] = nil

local phoneapps = require 'server.phoneapps'

---Fresh host state per test.
local function reset()
    dbState.writes = {}
    dbState.reads = 0
    dbState.rows = {}
    dbState.writeFails = false

    clear(driverState.registered)
    clear(driverState.sources)

    -- Clock only moves forward: the module's install rate limiter is real state,
    -- so a fresh test must start outside the previous test's cooldown.
    host.clock = host.clock + 60000
    host.fileReads = {}

    -- The module caches NPWD's config per resource start; invalidating is what the
    -- npwd restart hook does, and it is what makes each test see its own file.
    phoneapps.InvalidateNpwdConfig()
    host.clientEvents = {}
    host.threads = {}
    host.parsedConfig = {
        general = { defaultLanguage = 'en' },
        apps = { 'npwd_qbx_mail', 'npwd_qbx_garages', STORE },
        disabledApps = { 'BROWSER' },
    }

    phoneapps.Forget(CHARACTER)
    phoneapps.Forget(OTHER_CHARACTER)
end

---@param set table<string, boolean>
---@param appId string
---@return boolean
local function has(set, appId)
    for i = 1, #set do
        if set[i] == appId then return true end
    end
    return false
end

-- Preinstall regression --------------------------------------------------------

h.test('a fresh character sees only the App Store (never the Ojol apps)', function()
    reset()

    local config = phoneapps.BuildNpwdConfig(CHARACTER)

    h.eq(has(config.apps, OJOL_CUSTOMER), false, 'customer app absent')
    h.eq(has(config.apps, OJOL_DRIVER), false, 'driver app absent')
    h.eq(has(config.apps, STORE), true, 'store always present')
    h.eq(has(config.apps, 'npwd_qbx_mail'), true, 'unrelated apps preserved')
    h.eq(config.general.defaultLanguage, 'en', 'the rest of the NPWD config is preserved')
end)

h.test('a fresh character has every optional built-in disabled', function()
    reset()

    local config = phoneapps.BuildNpwdConfig(CHARACTER)

    h.eq(#hiddenBuiltins(config), 4, 'all four built-ins hidden')
    for i = 1, #BUILTINS do
        h.eq(has(config.apps, BUILTINS[i]), false, 'built-ins never go through `apps`')
    end
end)

h.test('a built-in is written to disabledApps, an external app to apps', function()
    reset()

    -- Every built-in installs for everyone; the Driver app also needs registration.
    h.eq(phoneapps.Install(CHARACTER, MATCHMAKER), true, 'Matchmaker installable by anyone')

    local config = phoneapps.BuildNpwdConfig(CHARACTER)

    h.eq(has(config.disabledApps, MATCHMAKER), false, 'installed built-in is no longer disabled')
    h.eq(has(config.disabledApps, IRC), true, 'the others stay disabled')
    h.eq(#hiddenBuiltins(config), 3, 'exactly three left hidden')
    h.eq(has(config.apps, MATCHMAKER), false, 'never registered as an external app')
end)

h.test('an admin disabled app is preserved, but managed ids are ours', function()
    reset()
    host.parsedConfig.disabledApps = { 'BROWSER', MATCHMAKER }

    local config = phoneapps.BuildNpwdConfig(CHARACTER)

    h.eq(has(config.disabledApps, 'BROWSER'), true, "the admin's own choice survives")
    h.eq(has(config.disabledApps, MATCHMAKER), true,
        'owned id stays disabled until installed, even if config.json said otherwise')

    h.eq(phoneapps.Install(CHARACTER, MATCHMAKER), true, 'install')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).disabledApps, MATCHMAKER), false,
        'our install state wins over config.json')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).disabledApps, 'BROWSER'), true, 'browser untouched')
end)

h.test('no install row means the built-in disappears (no auto-seeding)', function()
    reset()

    -- A character that had every built-in before the store existed: no rows exist,
    -- so every built-in is hidden instead of silently retained.
    local config = phoneapps.BuildNpwdConfig(CHARACTER)

    for i = 1, #BUILTINS do
        h.eq(has(config.disabledApps, BUILTINS[i]), true, 'hidden: ' .. BUILTINS[i])
    end
end)

h.test('a built-in install is per character and survives a restart', function()
    reset()
    phoneapps.Install(CHARACTER, SOCIAL)
    phoneapps.Forget(CHARACTER)
    dbState.rows[CHARACTER] = { [SOCIAL] = true }

    h.eq(phoneapps.IsVisible(CHARACTER, SOCIAL), true, 'visible for its owner')
    h.eq(phoneapps.IsVisible(OTHER_CHARACTER, SOCIAL), false, 'not for anyone else')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).disabledApps, SOCIAL), false, 'enabled after reload')
    h.eq(has(phoneapps.BuildNpwdConfig(OTHER_CHARACTER).disabledApps, SOCIAL), true, 'still hidden for others')
end)

h.test('uninstalling a built-in puts it back into disabledApps', function()
    reset()
    phoneapps.Install(CHARACTER, MARKETPLACE)
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).disabledApps, MARKETPLACE), false, 'enabled')
    host.clock = host.clock + 5000

    h.eq(phoneapps.Uninstall(CHARACTER, MARKETPLACE), true, 'uninstalled')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).disabledApps, MARKETPLACE), true, 'disabled again')
end)

h.test('managed ids cannot be re-preinstalled through npwd/config.json', function()
    reset()
    host.parsedConfig.apps = { 'npwd_qbx_mail', OJOL_CUSTOMER, OJOL_DRIVER, STORE, MATCHMAKER }

    local config = phoneapps.BuildNpwdConfig(CHARACTER)

    h.eq(has(config.apps, OJOL_CUSTOMER), false, 'customer app cannot come from config.json')
    h.eq(has(config.apps, OJOL_DRIVER), false, 'driver app cannot come from config.json')
    h.eq(has(config.apps, MATCHMAKER), false,
        'a built-in id in config.json would only make NPWD try to load a missing resource')
end)

h.test('the App Store is present even if config.json forgets it', function()
    reset()
    host.parsedConfig.apps = { 'npwd_qbx_mail' }

    local config = phoneapps.BuildNpwdConfig(CHARACTER)

    h.eq(has(config.apps, STORE), true, 'store injected')
end)

h.test('an unreadable NPWD config yields no config at all', function()
    reset()
    host.parsedConfig = nil

    h.eq(phoneapps.BuildNpwdConfig(CHARACTER), nil, 'nil, so the phone is left untouched')
    h.eq(host.fileReads[1].resource, 'npwd', 'reads NPWD own config')
    h.eq(host.fileReads[1].file, 'config.json', 'exact file name')
end)

-- Installing ------------------------------------------------------------------

h.test('anyone may install the customer app, and it then appears', function()
    reset()

    local ok, reason = phoneapps.Install(CHARACTER, OJOL_CUSTOMER)

    h.eq(ok, true, 'install allowed')
    h.eq(reason, nil, 'no reason')
    h.eq(dbState.writes[1].installed, true, 'persisted as installed')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).apps, OJOL_CUSTOMER), true, 'now visible')
end)

h.test('an unregistered player cannot install the Driver app (server-side)', function()
    reset()

    local ok, reason = phoneapps.Install(CHARACTER, OJOL_DRIVER)

    h.eq(ok, false, 'denied')
    h.eq(reason, 'driver_only', 'reason')
    h.eq(#dbState.writes, 0, 'nothing written')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).apps, OJOL_DRIVER), false, 'still absent')
end)

h.test('a registered driver may install and then see the Driver app', function()
    reset()
    driverState.registered[CHARACTER] = true

    local ok = phoneapps.Install(CHARACTER, OJOL_DRIVER)

    h.eq(ok, true, 'install allowed')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).apps, OJOL_DRIVER), true, 'visible')
end)

h.test('an unknown app id is refused', function()
    reset()

    local ok, reason = phoneapps.Install(CHARACTER, 'npwd_definitely_not_real')

    h.eq(ok, false, 'denied')
    h.eq(reason, 'unknown_app', 'reason')
end)

h.test('a failing write is reported instead of pretending to install', function()
    reset()
    dbState.writeFails = true

    local ok, reason = phoneapps.Install(CHARACTER, OJOL_CUSTOMER)

    h.eq(ok, false, 'failed')
    h.eq(reason, 'database_error', 'reason')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).apps, OJOL_CUSTOMER), false, 'not visible')
end)

h.test('install spam is rate limited', function()
    reset()

    h.eq(phoneapps.Install(CHARACTER, OJOL_CUSTOMER), true, 'first install')
    local ok, reason = phoneapps.Install(CHARACTER, OJOL_CUSTOMER)

    h.eq(ok, false, 'second refused')
    h.eq(reason, 'too_fast', 'reason')
    h.eq(#dbState.writes, 1, 'only one write')

    host.clock = host.clock + 5000
    h.eq(phoneapps.Install(CHARACTER, OJOL_CUSTOMER), true, 'allowed again later')
end)

h.test('install state is per character', function()
    reset()

    phoneapps.Install(CHARACTER, OJOL_CUSTOMER)

    h.eq(phoneapps.IsVisible(CHARACTER, OJOL_CUSTOMER), true, 'owner sees it')
    h.eq(phoneapps.IsVisible(OTHER_CHARACTER, OJOL_CUSTOMER), false, 'other character does not')
end)

h.test('a persistent install survives a resource restart', function()
    reset()
    dbState.rows[CHARACTER] = { [OJOL_CUSTOMER] = true }

    h.eq(phoneapps.IsVisible(CHARACTER, OJOL_CUSTOMER), true, 'loaded from storage')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).apps, OJOL_CUSTOMER), true, 'visible after reload')
end)

-- Uninstalling ----------------------------------------------------------------

h.test('uninstall removes the app from the home screen and from storage', function()
    reset()
    phoneapps.Install(CHARACTER, OJOL_CUSTOMER)
    host.clock = host.clock + 5000

    local ok = phoneapps.Uninstall(CHARACTER, OJOL_CUSTOMER)

    h.eq(ok, true, 'uninstalled')
    h.eq(dbState.writes[#dbState.writes].installed, false, 'persisted as uninstalled')
    h.eq(phoneapps.IsVisible(CHARACTER, OJOL_CUSTOMER), false, 'hidden')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).apps, OJOL_CUSTOMER), false, 'gone from the config')
end)

h.test('a non-driver cannot uninstall by claiming to be one', function()
    reset()

    local ok, reason = phoneapps.Uninstall(CHARACTER, OJOL_DRIVER)

    h.eq(ok, false, 'denied')
    h.eq(reason, 'driver_only', 'reason')
    h.eq(#dbState.writes, 0, 'nothing written')
end)

-- Eligibility is not install state -------------------------------------------

h.test('firing a driver hides the Driver app even before the write lands', function()
    reset()
    driverState.registered[CHARACTER] = true
    phoneapps.Install(CHARACTER, OJOL_DRIVER)
    h.eq(phoneapps.IsVisible(CHARACTER, OJOL_DRIVER), true, 'visible while registered')

    -- Losing registration is the authorization boundary, exactly as FireDriver
    -- sets it, before any cleanup has had a chance to run.
    driverState.registered[CHARACTER] = nil

    h.eq(phoneapps.IsVisible(CHARACTER, OJOL_DRIVER), false, 'hidden immediately')
    h.eq(has(phoneapps.BuildNpwdConfig(CHARACTER).apps, OJOL_DRIVER), false, 'out of the config')
end)

h.test('the driverFired hook pushes a refresh and clears the install', function()
    reset()
    driverState.registered[CHARACTER] = true
    driverState.sources[CHARACTER] = 42
    phoneapps.Install(CHARACTER, OJOL_DRIVER)
    host.clientEvents = {}

    host.handlers['lifestate_ojol:server:driverFired'](CHARACTER)

    h.eq(#host.clientEvents, 1, 'client told to re-apply visibility')
    h.eq(host.clientEvents[1].event, 'lifestate_ojol:client:phoneAppsChanged', 'event name')
    h.eq(host.clientEvents[1].target, 42, 'pushed to the fired player only')

    -- The persistent clear runs off the event (it can yield).
    runThreads()
    h.eq(dbState.writes[#dbState.writes].appId, OJOL_DRIVER, 'driver app row touched')
    h.eq(dbState.writes[#dbState.writes].installed, false, 'persisted as uninstalled')
end)

h.test('the driverFired hook is harmless when nothing was installed', function()
    reset()

    host.handlers['lifestate_ojol:server:driverFired'](CHARACTER)

    h.eq(#dbState.writes, 0, 'no pointless write')
end)

h.test('reinstalling after a rehire needs eligibility again, not memory', function()
    reset()
    driverState.registered[CHARACTER] = true
    phoneapps.Install(CHARACTER, OJOL_DRIVER)
    driverState.registered[CHARACTER] = nil
    phoneapps.RevokeDriverApp(CHARACTER)

    -- Rehired: eligibility is back, but the install is NOT restored.
    driverState.registered[CHARACTER] = true
    h.eq(phoneapps.IsVisible(CHARACTER, OJOL_DRIVER), false, 'must be installed again manually')

    host.clock = host.clock + 5000
    h.eq(phoneapps.Install(CHARACTER, OJOL_DRIVER), true, 'can be installed again')
    h.eq(phoneapps.IsVisible(CHARACTER, OJOL_DRIVER), true, 'visible again')
end)

-- Store state -----------------------------------------------------------------

h.test('the store state reports install + eligibility and never a predicate', function()
    reset()
    driverState.registered[CHARACTER] = true
    phoneapps.Install(CHARACTER, OJOL_CUSTOMER)

    local state = phoneapps.BuildStoreState(CHARACTER)
    h.eq(state.storeAppId, STORE, 'store id')
    h.eq(state.driverRegistered, true, 'driver flag')
    h.eq(#state.apps, 6, 'catalog size: two Ojol apps + four NPWD built-ins')

    local customer, driver
    for _, entry in ipairs(state.apps) do
        if entry.id == OJOL_CUSTOMER then customer = entry end
        if entry.id == OJOL_DRIVER then driver = entry end
    end

    h.eq(customer.installed, true, 'customer installed')
    h.eq(customer.eligible, true, 'customer eligible')
    h.eq(driver.installed, false, 'driver not installed')
    h.eq(driver.eligible, true, 'driver eligible while registered')
    h.eq(driver.lockLabel, nil, 'no lock label when eligible')
end)

h.test('the store lists the built-ins as installable by everyone', function()
    reset()

    local state = phoneapps.BuildStoreState(CHARACTER)

    for i = 1, #BUILTINS do
        local found
        for _, entry in ipairs(state.apps) do
            if entry.id == BUILTINS[i] then found = entry end
        end

        h.eq(found ~= nil, true, 'listed: ' .. BUILTINS[i])
        h.eq(found.eligible, true, 'eligible: ' .. BUILTINS[i])
        h.eq(found.builtin, true, 'flagged as a built-in: ' .. BUILTINS[i])
        h.eq(found.installed, false, 'not preinstalled: ' .. BUILTINS[i])
    end
end)

h.test('the Ojol apps are not flagged as built-ins', function()
    reset()

    local state = phoneapps.BuildStoreState(CHARACTER)

    for _, entry in ipairs(state.apps) do
        if entry.id == OJOL_CUSTOMER or entry.id == OJOL_DRIVER then
            h.eq(entry.builtin, false, 'external: ' .. entry.id)
        end
    end
end)

h.test('the store state locks the Driver app for a non-driver', function()
    reset()

    local state = phoneapps.BuildStoreState(CHARACTER)
    local driver
    for _, entry in ipairs(state.apps) do
        if entry.id == OJOL_DRIVER then driver = entry end
    end

    h.eq(driver.eligible, false, 'not eligible')
    h.eq(driver.reason, 'driver_only', 'reason')
    h.eq(driver.lockLabel, 'Harus terdaftar sebagai Mitra LAJU', 'lock label')
    h.eq(state.driverRegistered, false, 'driver flag')
end)

h.test('the store catalog carries LAJU branding on stable app ids', function()
    reset()

    local state = phoneapps.BuildStoreState(CHARACTER)

    local customer, driver
    for _, entry in ipairs(state.apps) do
        if entry.id == OJOL_CUSTOMER then customer = entry end
        if entry.id == OJOL_DRIVER then driver = entry end
    end

    h.eq(customer.id, 'npwd_lifestate_ojol_customer', 'customer app id stable')
    h.eq(customer.name, 'LAJU', 'customer name')
    h.eq(customer.description, 'Pesan transportasi dengan LAJU', 'customer description')
    h.eq(driver.id, 'npwd_lifestate_ojol', 'driver app id stable')
    h.eq(driver.name, 'LAJU Mitra', 'driver name')
    h.eq(driver.description, 'Aplikasi kerja Mitra LAJU', 'driver description')
end)

-- Query economy ---------------------------------------------------------------

h.test('visibility checks do not re-query the database', function()
    reset()

    for _ = 1, 20 do
        phoneapps.BuildNpwdConfig(CHARACTER)
        phoneapps.BuildStoreState(CHARACTER)
    end

    h.eq(dbState.reads, 1, 'one read, then served from memory')
end)

h.test('forgetting a character forces the next read from storage', function()
    reset()
    phoneapps.BuildNpwdConfig(CHARACTER)
    phoneapps.Forget(CHARACTER)
    dbState.rows[CHARACTER] = { [OJOL_CUSTOMER] = true }
    phoneapps.BuildNpwdConfig(CHARACTER)

    h.eq(dbState.reads, 2, 're-read after the session ended')
    h.eq(phoneapps.IsVisible(CHARACTER, OJOL_CUSTOMER), true, 'fresh storage state wins')
end)

return true
