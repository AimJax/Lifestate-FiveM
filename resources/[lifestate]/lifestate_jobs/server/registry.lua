-- Generic job/profession provider registry.
--
-- This module knows NOTHING about any concrete job. It validates, stores and
-- hands back provider definitions, which is what keeps the admin menu from ever
-- growing a per-job code path:
--
--     ADMIN UI -> generic job service -> provider definition -> job backend
--
-- Three rules matter for the admin menu's stability:
--
--   * a malformed definition is REJECTED with a reason instead of raising,
--   * OWNERSHIP IS AN EXPLICIT PARAMETER (`Register(def, owner)`), never read from
--     the definition, so no caller can declare itself the owner of another
--     resource's provider id (server/providerapi.lua resolves the real owner from
--     GetInvokingResource() at the export boundary and passes it in), and
--   * a definition is only replaced by its own owner (idempotent re-registration
--     after a restart), so one resource can never hijack another's provider id.
--     There is no overwrite flag - cross-resource takeover does not exist.
--
-- Cleanup is ownership-driven too: `UnregisterByResource` drops every provider a
-- stopped resource owned, so the registry can never keep calling into a resource
-- that is gone.
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
---@field resource string? IGNORED on input: the registry overwrites it with the
---                    owner it was given (diagnostics / cleanup only)
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

---Copy a definition, forcing the owner. `def.resource` is deliberately dropped:
---ownership comes from the caller (the export boundary) and nowhere else.
---@param def JobProviderDefinition
---@param owner string
---@return JobProviderDefinition
local function normalize(def, owner)
    return {
        id = def.id,
        label = def.label,
        type = def.type,
        resource = owner,
        order = def.order or 100,
        grades = def.grades,
        give = def.give,
        remove = def.remove,
        inspect = def.inspect,
        actions = def.actions or {},
    }
end

---Register (or replace) a provider definition on behalf of `owner`.
---Re-registering the same id from the same owner is an idempotent update, so a
---resource restart or a lazy re-sync cannot create duplicates.
---@param def JobProviderDefinition
---@param owner string owning resource, resolved by the caller (never from `def`)
---@return boolean ok, string outcomeOrReason
function M.Register(def, owner)
    local valid, reason = validate(def)
    if not valid then
        print(('[lifestate_jobs] provider rejected (%s)'):format(tostring(reason)))
        return false, reason
    end

    if not isNonEmptyString(owner) then return false, 'owner_required' end

    local normalized = normalize(def, owner)
    local existing = providers[normalized.id]

    if existing and existing.resource ~= owner then
        print(('[lifestate_jobs] provider id conflict: %s is owned by %s, %s tried to register it'):format(
            normalized.id, tostring(existing.resource), owner))
        return false, 'id_conflict'
    end

    providers[normalized.id] = normalized
    sortedIds = nil

    return true, existing and 'updated' or 'registered'
end

---Remove a provider, but only for its owner.
---@param id string
---@param owner string owning resource, resolved by the caller
---@return boolean ok, string? reason
function M.Unregister(id, owner)
    if not isNonEmptyString(id) then return false, 'invalid_id' end
    if not isNonEmptyString(owner) then return false, 'owner_required' end
    if not providers[id] then return false, 'not_registered' end

    -- Only the owning resource may drop its provider: an unrelated resource must
    -- not be able to unregister (or silence) another resource's job.
    if providers[id].resource ~= owner then return false, 'owner_mismatch' end

    providers[id] = nil
    sortedIds = nil
    return true
end

---Drop every provider owned by a resource that is no longer running.
---Called from the onServerResourceStop handler, so a stopped provider can never
---leave a stale function reference behind.
---@param owner string
---@return number removed
function M.UnregisterByResource(owner)
    if not isNonEmptyString(owner) then return 0 end

    local removed = 0
    for id, provider in pairs(providers) do
        if provider.resource == owner then
            providers[id] = nil
            removed = removed + 1
        end
    end

    -- The ordered id cache is derived state: leaving it behind would keep handing
    -- the menu ids that no longer resolve.
    if removed > 0 then sortedIds = nil end

    return removed
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

