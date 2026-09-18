lib.locale()

print('[NPWD APP STORE] client loaded')

-- Thin proxy: every decision (eligibility, install state, what the home screen
-- shows) belongs to the lifestate_ojol server. This resource only carries the
-- request across and hands the answer back to its NUI.

---Forward a server answer to the NUI, normalising the callback contract.
---@param cb function
---@param request fun(): table|nil
local function forward(cb, request)
    local ok, result = pcall(request)
    if not ok then
        print(('[NPWD APP STORE] request failed: %s'):format(tostring(result)))
        cb({ status = 'error', data = { reason = 'callback_failed' } })
        return
    end

    cb({ status = 'ok', data = result })
end

---Store contents for the current character.
RegisterNUICallback('npwd:lifestate_app_store:list', function(_, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:getPhoneApps', false)
    end)
end)

---Install one app. The NUI sends an id and nothing else; the server re-checks it.
RegisterNUICallback('npwd:lifestate_app_store:install', function(data, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:installPhoneApp', false,
            data and data.appId)
    end)
end)

RegisterNUICallback('npwd:lifestate_app_store:uninstall', function(data, cb)
    forward(cb, function()
        return lib.callback.await('lifestate_ojol:server:uninstallPhoneApp', false,
            data and data.appId)
    end)
end)
