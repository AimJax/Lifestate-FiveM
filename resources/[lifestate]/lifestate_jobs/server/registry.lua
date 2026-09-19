-- Generic job/profession provider registry.
--
-- This module knows NOTHING about any concrete job. It validates, stores and
-- hands back provider definitions, which is what keeps the admin menu from ever
-- growing a per-job code path:
--
--     ADMIN UI -> generic job service -> provider definition -> job backend
--
-- Two rules matter for the admin menu's stability:
--
--   * a malformed definition is REJECTED with a reason instead of raising, and
--   * a definition is only replaced by its own owner (idempotent re-registration
--     after a restart), so one resource can never hijack another's provider id.
--
-- Isolation of provider CALLS (pcall around give/remove/inspect) belongs to
-- server/service.lua, so a throwing provider cannot break the menu either.

local M = {}

---@class JobProviderGrade
---@field level number
---@field label string
---@field payment number?

---@class JobProviderTarget Resolved server-side; providers never see raw client input.
---@field source number live server id
---@field citizenid string
---@field name string character display name
---@field serverName string FiveM player name
---@field primaryJob table? framework primary job (Qbox PlayerData.job)
---@field jobs table? framework job memberships (Qbox PlayerData.jobs)

---@class JobProviderAction
---@field id string
---@field label string
---@field description string?
---@field confirm boolean? ask the admin to confirm before running
---@field handler fun(target: JobProviderTarget, options: table?, ctx: table?): boolean, string?, table?

---@class JobProviderDefinition
---@field id string unique provider id
---@field label string display name
---@field type string 'profession' | 'framework_job' | future types
---@field resource string? owning resource (diagnostics); defaults to the caller
---@field order number? sort hint, lower first (default 100)
---@field grades JobProviderGrade[]|fun(): JobProviderGrade[]? optional
---@field give fun(target, options): boolean, string?, table? optional
---@field remove fun(target, options): boolean, string?, table? optional
---@field inspect fun(target): table? optional
---@field actions JobProviderAction[]? optional

local providers = {}
local sortedIds

local function isNonEmptyString(value)
    return type(value) == 'string' and value ~= ''
end

---@param def JobProviderDefinition
---@return boolean ok, string? reason
local function validate(def)
    if type(def) ~= 'table' then return false, 'definition_not_table' end
    if not isNonEmptyString(def.id) then return false, 'missing_id' end
    if not isNonEmptyString(def.label) then return false, 'missing_label' end
    if not isNonEmptyString(def.type) then return false, 'missing_type' end

    if def.give ~= nil and type(def.give) ~= 'function' then return false, 'give_not_function' end
    if def.remove ~= nil and type(def.remove) ~= 'function' then return false, 'remove_not_function' end
    if def.inspect ~= nil and type(def.inspect) ~= 'function' then return false, 'inspect_not_function' end
    if def.grades ~= nil and type(def.grades) ~= 'table' and type(def.grades) ~= 'function' then
        return false, 'grades_not_table_or_function'
    end
    if def.give == nil and def.remove == nil then return false, 'no_mutation_handler' end
    if def.order ~= nil and type(def.order) ~= 'number' then return false, 'order_not_number' end

    if def.actions ~= nil then
        if type(def.actions) ~= 'table' then return false, 'actions_not_table' end

        for i = 1, #def.actions do
            local action = def.actions[i]
            if type(action) ~= 'table'
                or not isNonEmptyString(action.id)
                or not isNonEmptyString(action.label)
                or type(action.handler) ~= 'function' then
                return false, ('invalid_action_%s'):format(i)
            end
        end
    end

    return true
end

---@param def JobProviderDefinition
---@return JobProviderDefinition
local function normalize(def)
    local resource = def.resource
    if not isNonEmptyString(resource) then resource = GetInvokingResource() or 'unknown' end

    return {
        id = def.id,
        label = def.label,
        type = def.type,
        resource = resource,
        order = def.order or 100,
        grades = def.grades,
        give = def.give,
        remove = def.remove,
        inspect = def.inspect,
        actions = def.actions or {},
    }
end

---Register (or replace) a provider definition.
---Re-registering the same id from the same resource is an idempotent update, so a
---resource restart or a lazy re-sync cannot create duplicates.
---@param def JobProviderDefinition
---@param opts table? { overwrite = boolean } force an update across resources
---@return boolean ok, string outcomeOrReason
function M.Register(def, opts)
    local valid, reason = validate(def)
    if not valid then
        print(('[lifestate_jobs] provider rejected (%s)'):format(tostring(reason)))
        return false, reason
    end

    local normalized = normalize(def)
    local existing = providers[normalized.id]

    if existing and existing.resource ~= normalized.resource and not (opts and opts.overwrite) then
        print(('[lifestate_jobs] provider id conflict: %s is owned by %s, %s tried to register it'):format(
            normalized.id, tostring(existing.resource), tostring(normalized.resource)))
        return false, 'id_conflict'
    end

    providers[normalized.id] = normalized
    sortedIds = nil

    return true, existing and 'updated' or 'registered'
end

---@param id string
---@return boolean ok, string? reason
function M.Unregister(id)
    if not isNonEmptyString(id) then return false, 'invalid_id' end
    if not providers[id] then return false, 'not_registered' end

    providers[id] = nil
    sortedIds = nil
    return true
end

---@param id string
---@return JobProviderDefinition?
function M.Get(id)
    return providers[id]
end

---@return number
function M.Count()
    local total = 0
    for _ in pairs(providers) do total = total + 1 end
    return total
end
---Provider ids in admin-menu order (order hint, then label).
---@return string[]
local function orderedIds()
    if sortedIds then return sortedIds end

    local list = {}
    for id in pairs(providers) do list[#list + 1] = id end

    table.sort(list, function(a, b)
        local left, right = providers[a], providers[b]
        if left.order ~= right.order then return left.order < right.order end
        return left.label < right.label
    end)

    sortedIds = list
    return list
end

---@return JobProviderDefinition[]
function M.List()
    local ids = orderedIds()
    local list = {}

    for i = 1, #ids do
        list[i] = providers[ids[i]]
    end

    return list
end

---@param providerType string
---@return JobProviderDefinition[]
function M.ByType(providerType)
    local ids = orderedIds()
    local list = {}

    for i = 1, #ids do
        local provider = providers[ids[i]]
        if provider.type == providerType then list[#list + 1] = provider end
    end

    return list
end

---Resolve a provider's grades (static table or lazy function) without raising.
---@param provider JobProviderDefinition
---@return JobProviderGrade[]? grades, string? reason
function M.ResolveGrades(provider)
    local grades = provider.grades
    if grades == nil then return nil end

    if type(grades) == 'function' then
        local ok, result = pcall(grades)
        if not ok then
            print(('[lifestate_jobs] provider %s could not resolve grades: %s'):format(provider.id, tostring(result)))
            return nil, 'grades_error'
        end

        grades = result
    end

    if type(grades) ~= 'table' then return nil, 'grades_invalid' end

    local list = {}
    for i = 1, #grades do
        local grade = grades[i]
        local level = type(grade) == 'table' and tonumber(grade.level) or nil

        if level then
            list[#list + 1] = {
                level = level,
                label = type(grade.label) == 'string' and grade.label or ('grade %s'):format(level),
                payment = type(grade.payment) == 'number' and grade.payment or nil,
            }
        end
    end

    if #list == 0 then return nil, 'grades_invalid' end

    table.sort(list, function(a, b) return a.level < b.level end)
    return list
end

---Forget every provider (tests / hot reload).
function M.Reset()
    providers = {}
    sortedIds = nil
end

return M

