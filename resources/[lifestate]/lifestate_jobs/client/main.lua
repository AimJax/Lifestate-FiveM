-- Job Management admin section (client).
--
-- Everything the menu shows comes from the server-side job registry: this file
-- knows the SHAPE of a provider and the three generic operations (give / remove /
-- inspect) plus optional provider actions, never a concrete job. A future job is
-- therefore a server-side registration, not a change here.
--
-- The menu is registered in this resource's own ox_lib state (exactly like the
-- other qbx_adminmenu sections) and opened through a server relay, so the only
-- thing the admin menu itself carries is the option that triggers that relay.

local MenuIndexes = {}

-- Forward declarations: the flows below reference each other.
local showJobsMenu, showPlayerJobs, mutate, startAdvanced

local TYPE_LABELS = {
    profession = 'Independent profession',
    framework_job = 'Primary framework job',
}

local function typeLabel(providerType)
    return TYPE_LABELS[providerType] or tostring(providerType)
end

local function notify(message, kind)
    exports.qbx_core:Notify(message or 'Done.', kind or 'inform')
end

local function backToAdminMenu()
    TriggerServerEvent('lifestate_jobs:server:backToAdminMenu')
end

---Escape closes, Backspace walks back one level (nil = the admin menu itself).
local function onCloseTo(parentId)
    return function(keyPressed)
        if keyPressed ~= 'Backspace' then
            lib.hideMenu(false)
            return
        end

        if parentId then
            lib.showMenu(parentId, MenuIndexes[parentId])
        else
            backToAdminMenu()
        end
    end
end

local function showMenu(id, title, options, onSelect, onClose)
    lib.registerMenu({
        id = id,
        title = title,
        position = 'top-right',
        onClose = onClose,
        onSelected = function(selected) MenuIndexes[id] = selected end,
        options = options,
    }, onSelect)

    lib.showMenu(id, MenuIndexes[id])
end

---Ask for a server id. The admin's own id is valid on purpose: the server
---validates the target, not the menu.
local function askPlayerId(title, label)
    local input = lib.inputDialog(title, {
        { type = 'number', label = label or 'Player Server ID', min = 1, required = true },
    })

    if not input or not input[1] then return nil end

    local targetId = tonumber(input[1])
    if not targetId or targetId < 1 or targetId % 1 ~= 0 then return nil end

    return targetId
end

---One readable line for a provider's state on a target. Purely shape-driven, so
---a new provider needs no change here.
local function stateLine(entry)
    if entry.failed then return 'unavailable (provider error)' end

    local state = entry.state
    if type(state) ~= 'table' or state.registered ~= true then return 'not registered' end

    local parts = {}
    if state.rank then parts[#parts + 1] = tostring(state.rank) end
    parts[#parts + 1] = 'registered'
    if state.online ~= nil then parts[#parts + 1] = state.online and 'online' or 'offline' end
    if state.busy ~= nil then parts[#parts + 1] = state.busy and 'busy' or 'not busy' end
    if type(state.rating) == 'number' then parts[#parts + 1] = ('rating %.1f'):format(state.rating) end

    return table.concat(parts, ' · ')
end
-- Generic operations ----------------------------------------------------------

---Run one mutation server-side, then show the resulting state. Nothing is
---optimistically assumed here: the state view comes from the server.
mutate = function(payload)
    local result = lib.callback.await('lifestate_jobs:server:mutate', false, payload)

    if not result then
        notify('The server did not answer the job request.', 'error')
        showJobsMenu()
        return
    end

    notify(result.message, result.ok and (result.changed and 'success' or 'inform') or 'error')

    if result.target and result.target.source then
        showPlayerJobs(result.target.source)
    else
        showJobsMenu()
    end
end

local function fetchCatalog()
    local catalog = lib.callback.await('lifestate_jobs:server:getCatalog', false)

    if not catalog or not catalog.ok then
        notify(catalog and catalog.message or 'Could not load the job catalog.', 'error')
        return nil
    end

    return catalog
end

local function showProviderList(providers, title, onPick, parentId)
    local options = {}

    for i = 1, #providers do
        local provider = providers[i]
        local gradeCount = provider.grades and #provider.grades or 0

        options[#options + 1] = {
            label = provider.label,
            description = ('%s · %s'):format(typeLabel(provider.type),
                gradeCount > 0 and ('%d grade(s)'):format(gradeCount) or 'no grades'),
            icon = 'fas fa-briefcase',
            args = { provider },
        }
    end

    showMenu('lifestate_jobs_provider_list', title, options, function(_, _, args)
        if type(args) ~= 'table' then return end
        onPick(args[1])
    end, onCloseTo(parentId))
end

---Provider picker. Above `categoryThreshold` entries the type becomes a level of
---its own, so hundreds of jobs stay navigable without one menu entry per job.
local function showProviderPicker(catalog, title, onPick, parentId)
    local providers = catalog.providers
    if not providers or #providers == 0 then
        notify('No job provider is registered.', 'error')
        return
    end

    local threshold = tonumber(catalog.categoryThreshold) or 25
    if #providers <= threshold then
        showProviderList(providers, title, onPick, parentId)
        return
    end

    local groups, order = {}, {}
    for i = 1, #providers do
        local providerType = providers[i].type
        if not groups[providerType] then
            groups[providerType] = {}
            order[#order + 1] = providerType
        end

        groups[providerType][#groups[providerType] + 1] = providers[i]
    end

    table.sort(order)

    local options = {}
    for i = 1, #order do
        options[#options + 1] = {
            label = ('%s (%d)'):format(typeLabel(order[i]), #groups[order[i]]),
            icon = 'fas fa-layer-group',
            args = { order[i] },
        }
    end

    showMenu('lifestate_jobs_provider_types', title, options, function(_, _, args)
        if type(args) ~= 'table' then return end
        showProviderList(groups[args[1]], title, onPick, 'lifestate_jobs_provider_types')
    end, onCloseTo(parentId))
end

local function showGradePicker(provider, targetId)
    local options = {}

    for i = 1, #provider.grades do
        local grade = provider.grades[i]
        options[#options + 1] = {
            label = ('%s — grade %s'):format(grade.label, grade.level),
            description = grade.payment and ('Payment: %d'):format(grade.payment) or nil,
            icon = 'fas fa-ranking-star',
            args = { grade.level },
        }
    end

    showMenu('lifestate_jobs_grade_picker', ('Give %s — player %d'):format(provider.label, targetId), options,
        function(_, _, args)
            if type(args) ~= 'table' then return end
            mutate({ action = 'give', jobId = provider.id, target = targetId, grade = args[1] })
        end, onCloseTo('lifestate_jobs_menu'))
end

local function startGive()
    local targetId = askPlayerId('Give Job / Profession', 'Player Server ID (your own id is allowed)')
    if not targetId then
        showJobsMenu()
        return
    end

    local catalog = fetchCatalog()
    if not catalog then return end

    showProviderPicker(catalog, ('Give job — player %d'):format(targetId), function(provider)
        if provider.grades and #provider.grades > 0 then
            showGradePicker(provider, targetId)
        else
            mutate({ action = 'give', jobId = provider.id, target = targetId })
        end
    end, 'lifestate_jobs_menu')
end

local function startRemove()
    local targetId = askPlayerId('Remove Job / Profession', 'Player Server ID (your own id is allowed)')
    if not targetId then
        showJobsMenu()
        return
    end

    local catalog = fetchCatalog()
    if not catalog then return end

    showProviderPicker(catalog, ('Remove job — player %d'):format(targetId), function(provider)
        mutate({ action = 'remove', jobId = provider.id, target = targetId })
    end, 'lifestate_jobs_menu')
end

local function startView()
    local targetId = askPlayerId('View Player Jobs', 'Player Server ID to inspect')
    if not targetId then
        showJobsMenu()
        return
    end

    showPlayerJobs(targetId)
end
-- The section itself ----------------------------------------------------------

showJobsMenu = function()
    local catalog = fetchCatalog()
    if not catalog then
        backToAdminMenu()
        return
    end

    local options = {
        {
            label = 'Give Job / Profession',
            description = ('Assign one of %d registered jobs/professions.'):format(catalog.total),
            icon = 'fas fa-plus',
            args = { 'give' },
        },
        {
            label = 'Remove Job / Profession',
            description = 'Deactivate or remove a job/profession from a player.',
            icon = 'fas fa-minus',
            args = { 'remove' },
        },
        {
            label = 'View Player Jobs',
            description = 'Primary job and every registered profession of a player.',
            icon = 'fas fa-magnifying-glass',
            args = { 'view' },
        },
    }

    if catalog.hasActions then
        options[#options + 1] = {
            label = 'Advanced Provider Actions',
            description = 'Provider-specific authority actions (for example setting an organization CEO).',
            icon = 'fas fa-user-shield',
            args = { 'advanced' },
        }
    end

    showMenu('lifestate_jobs_menu', 'Job Management', options, function(_, _, args)
        if type(args) ~= 'table' then return end
        if args[1] == 'give' then
            startGive()
        elseif args[1] == 'remove' then
            startRemove()
        elseif args[1] == 'view' then
            startView()
        elseif args[1] == 'advanced' then
            startAdvanced(catalog)
        end
    end, onCloseTo(nil))
end

---Read-only state view. Rendered entirely from the generic provider state shape,
---so a new job's state appears here without touching this file.
showPlayerJobs = function(targetId)
    local data = lib.callback.await('lifestate_jobs:server:getPlayerJobs', false, targetId)

    if not data or not data.ok then
        notify(data and data.message or 'Could not read the player job state.', 'error')
        showJobsMenu()
        return
    end

    local options = {}

    local function info(label, description)
        options[#options + 1] = {
            label = label,
            description = description,
            icon = 'fas fa-circle-info',
            close = false,
        }
    end

    local target = data.target or {}
    info(('Player %s'):format(tostring(target.source or targetId)),
        ('%s%s'):format(target.name or 'unknown', target.citizenid and (' · %s'):format(target.citizenid) or ''))

    local primary = data.primaryJob
    if primary then
        local grade = primary.gradeLabel
            and (' — %s%s'):format(primary.gradeLabel, primary.grade and (' (grade %s)'):format(primary.grade) or '')
            or ''
        info('Primary job', ('%s%s · %s'):format(primary.label, grade, primary.onDuty and 'on duty' or 'off duty'))
    else
        info('Primary job', 'unknown')
    end

    -- Registered providers first, so "does this player have X?" is one glance.
    local registered, others = {}, {}
    for i = 1, #(data.providers or {}) do
        local entry = data.providers[i]
        if entry.state and entry.state.registered == true then
            registered[#registered + 1] = entry
        else
            others[#others + 1] = entry
        end
    end

    if #registered > 0 then
        info('Registered jobs / professions', ('%d provider(s)'):format(#registered))
        for i = 1, #registered do
            local entry = registered[i]
            info(('    %s'):format(entry.label), stateLine(entry))

            for j = 1, #((entry.state and entry.state.details) or {}) do
                local detail = entry.state.details[j]
                info(('        %s'):format(tostring(detail.label)), tostring(detail.value))
            end
        end
    else
        info('Registered jobs / professions', 'none')
    end

    if data.listUnregisteredProfessions ~= false and #others > 0 then
        info('Other providers', 'not registered on this player')
        for i = 1, #others do
            info(('    %s'):format(others[i].label), stateLine(others[i]))
        end
    end

    options[#options + 1] = { label = 'Back', icon = 'fas fa-arrow-left', args = { 'back' } }

    showMenu('lifestate_jobs_player_state',
        ('Jobs — %s'):format(target.name or ('player ' .. tostring(targetId))), options,
        function(_, _, args)
            -- Informational rows carry no args: selecting one is a no-op.
            if type(args) ~= 'table' then return end
            if args[1] == 'back' then showJobsMenu() end
        end, onCloseTo('lifestate_jobs_menu'))
end
-- Provider-specific authority actions (optional per provider) -----------------

startAdvanced = function(catalog)
    local providers = {}

    for i = 1, #catalog.providers do
        local provider = catalog.providers[i]
        if provider.actions and #provider.actions > 0 then
            providers[#providers + 1] = provider
        end
    end

    if #providers == 0 then
        notify('No provider exposes advanced actions.', 'error')
        showJobsMenu()
        return
    end

    showProviderPicker({ providers = providers, categoryThreshold = catalog.categoryThreshold },
        'Advanced provider actions', function(provider)
            local options = {}

            for i = 1, #provider.actions do
                local action = provider.actions[i]
                options[#options + 1] = {
                    label = action.label,
                    description = action.description,
                    icon = 'fas fa-user-shield',
                    args = { action },
                }
            end

            showMenu('lifestate_jobs_provider_actions', ('%s — advanced'):format(provider.label), options,
                function(_, _, args)
                    if type(args) ~= 'table' or type(args[1]) ~= 'table' then return end
                    local action = args[1]

                    local targetId = askPlayerId(action.label, ('Player Server ID for "%s"'):format(action.label))
                    if not targetId then
                        showJobsMenu()
                        return
                    end

                    if action.confirm then
                        local confirmed = lib.alertDialog({
                            header = action.label,
                            content = ('Run "%s" for player %d?'):format(action.label, targetId),
                            centered = true,
                            cancel = true,
                            labels = { confirm = 'Confirm', cancel = 'Cancel' },
                        })

                        if confirmed ~= 'confirm' then
                            showJobsMenu()
                            return
                        end
                    end

                    mutate({ action = 'action', actionId = action.id, jobId = provider.id, target = targetId })
                end, onCloseTo('lifestate_jobs_menu'))
        end, 'lifestate_jobs_menu')
end

-- Entry point -----------------------------------------------------------------
-- Pushed by this resource's server only after it authorized the requesting admin,
-- so nothing here can be opened by a local trigger.

RegisterNetEvent('lifestate_jobs:client:openMenu', function()
    CreateThread(showJobsMenu)
end)

