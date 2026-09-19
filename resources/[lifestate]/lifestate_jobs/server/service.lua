-- Generic job-management service.
--
-- The admin UI never talks to a job: it talks to this module, which resolves the
-- target server-side, authorizes EVERY read and mutation, dispatches to the
-- provider registered for the requested job id and audits the result.
--
-- Nothing here knows a concrete job id, which is what lets a future job (or a
-- whole new job type) be added with a single provider registration.

local registry = require 'server.registry'
local config = require 'config.server'

local M = {}

-- Outcomes that mean "understood, and the state already is what the admin asked
-- for". They are reported as success (inform) rather than as an error, so a
-- repeated Give/Remove stays safe and self-explanatory.
local SAFE_NOOP = {
    already_registered = true,
    unchanged = true,
    not_registered = true,
}

local function gradeSuffix(detail)
    local label = detail and detail.gradeLabel
    return label and (' (%s)'):format(label) or ''
end

---Success messages, assembled per target/job so no job name is hardcoded here.
local OUTCOMES = {
    registered = function(target, job)
        return ('%s is now registered as %s.'):format(target.name, job.label)
    end,
    reactivated = function(target, job)
        return ('%s was reactivated as %s (previous history and statistics preserved).'):format(target.name, job.label)
    end,
    already_registered = function(target, job)
        return ('%s is already an active %s — nothing changed.'):format(target.name, job.label)
    end,
    assigned = function(target, job, detail)
        return ('%s now works as %s%s.'):format(target.name, job.label, gradeSuffix(detail))
    end,
    removed = function(target, job)
        return ('%s no longer has %s.'):format(target.name, job.label)
    end,
    not_registered = function(target, job)
        return ('%s is not registered as %s — nothing changed.'):format(target.name, job.label)
    end,
    unchanged = function(target, job)
        return ('%s already has %s — nothing changed.'):format(target.name, job.label)
    end,
}

---Failure messages. A provider may still override its own wording by returning
---`detail.message` (that is how job-specific refusals stay readable).
local FAILURE_MESSAGES = {
    invalid_source = 'Invalid admin source.',
    no_perms = "You don't have permission to manage jobs.",
    not_optin = 'You are not opted in for admin duty. (/optin to toggle)',
    invalid_request = 'Invalid job request.',
    invalid_action = 'Unknown job action.',
    invalid_job = 'Unknown job or profession.',
    invalid_grade = 'That grade does not exist for this job.',
    invalid_target = 'Player not found (invalid or offline server ID).',
    unsupported_action = 'This job provider does not support that action.',
    provider_error = 'The job provider failed to complete the request.',
    database_error = 'The job backend could not save the change.',
}

---@param reason string
---@return table result
function M.Failure(reason)
    return {
        ok = false,
        changed = false,
        outcome = reason,
        message = FAILURE_MESSAGES[reason] or ('The job request failed (%s).'):format(tostring(reason)),
    }
end

---@param source number
---@return boolean ok, string? reason
local function isOptin(source)
    local ok, optedIn = pcall(function() return exports.qbx_core:IsOptin(source) end)
    return ok and optedIn == true
end

---Authorize an admin request. Called by every entry point; the menu being
---visible on a client proves nothing.
---@param source number
---@return boolean ok, string? reason
function M.Authorize(source)
    if type(source) ~= 'number' or source <= 0 then return false, 'invalid_source' end
    if not IsPlayerAceAllowed(source, config.perm) then return false, 'no_perms' end
    if config.requireOptin and not isOptin(source) then return false, 'not_optin' end

    return true
end

---Resolve a client-supplied target id into a server-verified player.
---The admin's own server id is a valid target: the menu deliberately does not
---require a second player or proximity.
---@param targetArg any
---@return JobProviderTarget? target
---@return string? reason
function M.ResolveTarget(targetArg)
    local targetSource = tonumber(targetArg)
    if not targetSource or targetSource <= 0 or targetSource % 1 ~= 0 then return nil, 'invalid_target' end

    local serverName = GetPlayerName(targetSource)
    if not serverName then return nil, 'invalid_target' end

    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(targetSource) end)
    if not ok or not player or not player.PlayerData then return nil, 'invalid_target' end

    local data = player.PlayerData
    local charinfo = data.charinfo or {}
    local charName = ('%s %s'):format(tostring(charinfo.firstname or ''), tostring(charinfo.lastname or ''))
        :gsub('^%s+', ''):gsub('%s+$', '')

    return {
        source = targetSource,
        citizenid = data.citizenid,
        name = charName ~= '' and charName or serverName,
        serverName = serverName,
        -- Framework context, read once here so providers never re-fetch the
        -- player (and never trust a client-supplied snapshot).
        primaryJob = data.job,
        jobs = data.jobs,
    }
end

---@param target JobProviderTarget
---@return table
local function clientTarget(target)
    return {
        source = target.source,
        name = target.name,
        serverName = target.serverName,
        -- Internal identifier: only exposed when an admin explicitly enables it.
        citizenid = config.showCitizenId and target.citizenid or nil,
    }
end

---Run a provider handler in isolation: a broken provider must never break the
---admin menu, another provider or the request path.
---@param fn function
---@param target JobProviderTarget
---@param options table
---@param ctx table
---@return table result { ok, outcome, detail }
local function invoke(fn, target, options, ctx)
    local called, succeeded, outcome, detail = pcall(fn, target, options, ctx)

    if not called then
        print(('[lifestate_jobs] provider error: %s'):format(tostring(succeeded)))
        return { ok = false, outcome = 'provider_error' }
    end

    if type(succeeded) ~= 'boolean' then
        print(('[lifestate_jobs] provider returned no result: %s'):format(tostring(succeeded)))
        return { ok = false, outcome = 'provider_error' }
    end

    return {
        ok = succeeded,
        outcome = type(outcome) == 'string' and outcome or (succeeded and 'done' or 'failed'),
        detail = type(detail) == 'table' and detail or nil,
    }
end
---Everything the admin UI needs to render Give/Remove/Advanced, generated from
---the registry. A provider whose metadata fails to resolve still appears (without
---grades) instead of removing the whole list.
---@param source number
---@return table result
function M.GetCatalog(source)
    local authorized, reason = M.Authorize(source)
    if not authorized then return M.Failure(reason) end

    local providers, counts = {}, {}
    local hasActions = false

    for _, provider in ipairs(registry.List()) do
        local grades = registry.ResolveGrades(provider)
        local actions = {}

        for i = 1, #provider.actions do
            local action = provider.actions[i]
            actions[#actions + 1] = {
                id = action.id,
                label = action.label,
                description = action.description,
                confirm = action.confirm == true,
            }
        end

        if #actions > 0 then hasActions = true end

        providers[#providers + 1] = {
            id = provider.id,
            label = provider.label,
            type = provider.type,
            resource = config.audit.resource and provider.resource or nil,
            grades = grades,
            actions = actions,
        }

        counts[provider.type] = (counts[provider.type] or 0) + 1
    end

    return {
        ok = true,
        providers = providers,
        counts = counts,
        total = #providers,
        hasActions = hasActions,
        categoryThreshold = config.categoryThreshold,
        listUnregisteredProfessions = config.listUnregisteredProfessions,
        showCitizenId = config.showCitizenId,
    }
end

---Primary framework job of a target, in the display shape the UI uses.
---@param target JobProviderTarget
---@return table? primaryJob
local function primaryJobOf(target)
    local job = target.primaryJob
    if not job then return nil end

    local grade = job.grade or {}

    return {
        name = job.name,
        label = job.label or job.name,
        grade = tonumber(grade.level),
        gradeLabel = grade.name,
        onDuty = job.onduty == true,
    }
end

---View Player Jobs: framework primary job plus the state every provider reports.
---@param source number
---@param targetArg any
---@return table result
function M.Inspect(source, targetArg)
    local authorized, reason = M.Authorize(source)
    if not authorized then return M.Failure(reason) end

    local target, targetReason = M.ResolveTarget(targetArg)
    if not target then return M.Failure(targetReason) end

    local providers = {}
    for _, provider in ipairs(registry.List()) do
        local state, failed

        if provider.inspect then
            local ok, result = pcall(provider.inspect, target)
            if ok and type(result) == 'table' then
                state = result
            else
                failed = true
                if not ok then
                    print(('[lifestate_jobs] provider %s inspect failed: %s'):format(provider.id, tostring(result)))
                end
            end
        end

        providers[#providers + 1] = {
            id = provider.id,
            label = provider.label,
            type = provider.type,
            state = state,
            failed = failed == true,
        }
    end

    return {
        ok = true,
        target = clientTarget(target),
        primaryJob = primaryJobOf(target),
        providers = providers,
        listUnregisteredProfessions = config.listUnregisteredProfessions,
        showCitizenId = config.showCitizenId,
    }
end
---Server-side audit line for every mutation attempt (allowed or denied).
---Never logs identifiers, tokens or credentials.
---@param source number
---@param target JobProviderTarget?
---@param payload table?
---@param outcome string
function M.Audit(source, target, payload, outcome)
    local adminName = (type(source) == 'number' and source > 0 and GetPlayerName(source)) or 'console'
    local action = (payload and payload.action) or '-'
    if payload and payload.actionId then action = ('%s:%s'):format(action, payload.actionId) end

    local citizenid = ''
    if target and config.audit.citizenId and target.citizenid then
        citizenid = (' [%s]'):format(target.citizenid)
    end

    print(('[lifestate_jobs] audit: %s | admin %s (%s) | target %s (%s)%s | job %s | %s | grade %s | result %s'):format(
        os.date('%Y-%m-%d %H:%M:%S'),
        tostring(adminName), tostring(source),
        target and tostring(target.serverName) or '-',
        target and tostring(target.source) or '-',
        citizenid,
        tostring((payload and payload.jobId) or '-'),
        tostring(action),
        (payload and payload.grade ~= nil) and tostring(payload.grade) or '-',
        tostring(outcome)
    ))
end

---Give / Remove / provider action. Authorizes, resolves and audits on every path -
---including the refusals.
---@param source number
---@param payload table { action, jobId, target, grade?, actionId? }
---@return table result
function M.Mutate(source, payload)
    local authorized, authReason = M.Authorize(source)
    if not authorized then
        M.Audit(source, nil, type(payload) == 'table' and payload or nil, authReason)
        return M.Failure(authReason)
    end

    if type(payload) ~= 'table' then
        M.Audit(source, nil, nil, 'invalid_request')
        return M.Failure('invalid_request')
    end

    local action = payload.action
    if action ~= 'give' and action ~= 'remove' and action ~= 'action' then
        M.Audit(source, nil, payload, 'invalid_action')
        return M.Failure('invalid_action')
    end

    local provider = registry.Get(payload.jobId)
    if not provider then
        M.Audit(source, nil, payload, 'invalid_job')
        return M.Failure('invalid_job')
    end

    local target, targetReason = M.ResolveTarget(payload.target)
    if not target then
        M.Audit(source, nil, payload, targetReason)
        return M.Failure(targetReason)
    end

    local grade = tonumber(payload.grade)
    local outcome

    if action == 'give' then
        if not provider.give then
            M.Audit(source, target, payload, 'unsupported_action')
            return M.Failure('unsupported_action')
        end

        outcome = invoke(provider.give, target, { grade = grade, source = source }, { jobId = provider.id })
    elseif action == 'remove' then
        if not provider.remove then
            M.Audit(source, target, payload, 'unsupported_action')
            return M.Failure('unsupported_action')
        end

        outcome = invoke(provider.remove, target, { source = source }, { jobId = provider.id })
    else
        local handler
        for i = 1, #provider.actions do
            if provider.actions[i].id == payload.actionId then handler = provider.actions[i] end
        end

        if not handler then
            M.Audit(source, target, payload, 'invalid_action')
            return M.Failure('invalid_action')
        end

        outcome = invoke(handler.handler, target, {},
            { source = source, jobId = provider.id, actionId = payload.actionId })
    end

    -- A provider may report a "safe no-op" refusal (already registered, already
    -- absent). That is a successful request with no change, not an error.
    local safeNoop = SAFE_NOOP[outcome.outcome] == true
    local succeeded = outcome.ok or safeNoop

    local detailMessage = outcome.detail and outcome.detail.message
    local message

    if succeeded then
        local builder = OUTCOMES[outcome.outcome]
        message = detailMessage
            or (builder and builder(target, provider, outcome.detail))
            or ('%s updated for %s.'):format(provider.label, target.name)
    else
        message = detailMessage
            or FAILURE_MESSAGES[outcome.outcome]
            or ('The %s backend refused the request (%s).'):format(provider.label, tostring(outcome.outcome))
    end

    M.Audit(source, target, payload, outcome.outcome)

    return {
        ok = succeeded,
        changed = succeeded and not safeNoop,
        action = action,
        outcome = outcome.outcome,
        jobId = provider.id,
        jobLabel = provider.label,
        jobType = provider.type,
        grade = grade,
        target = clientTarget(target),
        message = message,
    }
end

---A denied entry point (forged client event, missing permission, not on duty).
---The attempt is audited; the player is told only when he is a real connection.
---@param source number
---@param reason string
function M.Denied(source, reason)
    M.Audit(source, nil, nil, reason)

    if type(source) == 'number' and source > 0 and GetPlayerName(source) then
        exports.qbx_core:Notify(source, M.Failure(reason).message, 'error')
    end
end

return M
