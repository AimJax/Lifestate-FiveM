-- Qbox primary-job adapter.
--
-- The registry stays framework-agnostic; this module turns whatever qbx_core
-- currently knows into providers, using only APIs that exist in this installed
-- Qbox:
--
--   * GetJobs() / GetJob(name)             - discovery (includes runtime CreateJob)
--   * SetJob(source, name, grade)          - validated set; handles the primary job
--                                            replace + save + client update
--   * RemovePlayerFromJob(citizenid, name) - drop a non-primary membership
--
-- Providers are re-synced against qbx_core on every catalog/inspect request, so a
-- job added or removed at runtime appears or disappears with no code change.
-- Nothing here writes player state client-side, and no unsupported call is made.

local registry = require 'server.registry'
local config = require 'config.server'

local M = {}

---Provider id prefix, so a framework job can never collide with a hand-registered
---profession id ('ojol' and 'qbx:police' are separate providers).
M.PREFIX = 'qbx:'
M.TYPE = 'framework_job'

local function describeError(err)
    if type(err) == 'table' then return tostring(err.message or err.code or 'unknown error') end
    if err == nil then return 'unknown error' end
    return tostring(err)
end

---@param job table?
---@return JobProviderGrade[]?
local function gradeList(job)
    local grades = job and job.grades
    if type(grades) ~= 'table' then return nil end

    local list = {}
    for level, grade in pairs(grades) do
        local numeric = tonumber(level)
        if numeric and type(grade) == 'table' then
            list[#list + 1] = {
                level = numeric,
                label = type(grade.name) == 'string' and grade.name or ('grade %s'):format(numeric),
                payment = type(grade.payment) == 'number' and grade.payment or nil,
            }
        end
    end

    if #list == 0 then return nil end

    table.sort(list, function(a, b) return a.level < b.level end)
    return list
end

---@param name string
---@return boolean
local function isOffered(name)
    local framework = config.frameworkJobs
    if not framework.enabled then return false end
    if name == config.defaultJob then return false end
    if framework.blacklist and framework.blacklist[name] then return false end
    if framework.whitelist and not framework.whitelist[name] then return false end

    return true
end

---@param name string qbx_core job name
---@param job table qbx_core job definition (used for the display label)
---@return JobProviderDefinition
local function definition(name, job)
    local providerId = M.PREFIX .. name

    return {
        id = providerId,
        label = job.label or name,
        type = M.TYPE,
        resource = 'qbx_core',
        order = 200,

        -- Resolved lazily and live, so a runtime grade change is picked up without
        -- re-registering the provider.
        grades = function()
            return gradeList(exports.qbx_core:GetJob(name))
        end,

        give = function(target, options)
            local live = exports.qbx_core:GetJob(name)
            if not live or type(live.grades) ~= 'table' then return false, 'invalid_job' end

            local grade = tonumber(options and options.grade) or 0
            if not live.grades[grade] then return false, 'invalid_grade' end

            local current = target.primaryJob
            if current and current.name == name and current.grade and current.grade.level == grade then
                return true, 'unchanged'
            end

            local succeeded, err = exports.qbx_core:SetJob(target.source, name, grade)
            if not succeeded then
                return false, 'database_error', {
                    message = ('Qbox could not set %s (grade %s): %s'):format(
                        live.label or name, grade, describeError(err)),
                }
            end

            return true, 'assigned', { gradeLabel = live.grades[grade].name }
        end,

        remove = function(target)
            local held = target.jobs and target.jobs[name]
            local isPrimary = target.primaryJob and target.primaryJob.name == name

            if held == nil and not isPrimary then return true, 'not_registered' end

            if isPrimary then
                -- The primary job is replaced through the framework API, which is
                -- what keeps Qbox employment logic (membership removal, save,
                -- client update) intact.
                if not exports.qbx_core:GetJob(config.defaultJob) then return false, 'invalid_job' end

                local succeeded, err = exports.qbx_core:SetJob(target.source, config.defaultJob, 0)
                if not succeeded then
                    return false, 'database_error', {
                        message = ('Qbox could not move the player to %s: %s'):format(
                            config.defaultJob, describeError(err)),
                    }
                end

                return true, 'removed'
            end

            local succeeded, err = exports.qbx_core:RemovePlayerFromJob(target.citizenid, name)
            if not succeeded then
                return false, 'database_error', {
                    message = ('Qbox could not remove the %s membership: %s'):format(name, describeError(err)),
                }
            end

            return true, 'removed'
        end,

        inspect = function(target)
            local live = exports.qbx_core:GetJob(name)
            local grade = target.jobs and target.jobs[name]
            local isPrimary = target.primaryJob and target.primaryJob.name == name
            local gradeDef = (grade ~= nil and live and live.grades) and live.grades[grade] or nil

            return {
                registered = grade ~= nil or isPrimary == true,
                active = isPrimary == true,
                rank = gradeDef and gradeDef.name or nil,
                grade = grade,
                gradeLabel = gradeDef and gradeDef.name or nil,
                details = {
                    { label = 'Primary job', value = isPrimary and 'yes' or 'no' },
                },
            }
        end,
    }
end
---Re-scan qbx_core's job table and make the registry match it.
---@return number added
function M.Sync()
    if not config.frameworkJobs.enabled then return 0 end
    if GetResourceState('qbx_core') ~= 'started' then return 0 end

    local called, jobs = pcall(function() return exports.qbx_core:GetJobs() end)
    if not called or type(jobs) ~= 'table' then
        print(('[lifestate_jobs] framework job sync skipped: %s'):format(tostring(jobs)))
        return 0
    end

    local offered, added = {}, 0

    for name, job in pairs(jobs) do
        if type(name) == 'string' and type(job) == 'table' and isOffered(name) then
            local registered, outcome = registry.Register(definition(name, job))

            if registered then
                offered[M.PREFIX .. name] = true
                if outcome == 'registered' then added = added + 1 end
            end
        end
    end

    -- Drop providers whose job no longer exists in qbx_core (runtime RemoveJob) or
    -- that a config change just excluded.
    for _, provider in ipairs(registry.List()) do
        local isFrameworkJob = provider.resource == 'qbx_core' and provider.id:sub(1, #M.PREFIX) == M.PREFIX
        if isFrameworkJob and not offered[provider.id] then
            registry.Unregister(provider.id)
        end
    end

    return added
end

---Provider id of a framework job (the inverse of jobNameOf).
---@param name string
---@return string
function M.ProviderId(name)
    return M.PREFIX .. name
end

---Wire the adapter: initial sync, then a re-sync whenever qbx_core restarts
---(its job table is recreated from scratch, so our providers must follow).
function M.Start()
    M.Sync()

    AddEventHandler('onServerResourceStart', function(resourceName)
        if resourceName ~= 'qbx_core' then return end
        CreateThread(M.Sync)
    end)
end

return M
