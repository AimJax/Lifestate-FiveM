-- Generic job/profession provider registry.
--
-- This module knows NOTHING about any concrete job. It validates, stores and
-- hands back provider definitions, which is what keeps the admin menu from ever
-- growing a per-job code path:
--
--     ADMIN UI -> generic service -> provider -> job backend
--
-- Rules that matter for the admin menu's stability:
--
--   * a malformed definition is REJECTED with a reason instead of raising,
--   * OWNERSHIP IS AN EXPLICIT PARAMETER (`Register(def, owner, mode)`), never read
--     from the definition, so no caller can claim another resource's provider id
--     (server/providerapi.lua resolves the real owner from GetInvokingResource() at
--     the export boundary and passes it in), and
--   * a definition is only replaced by its own owner (idempotent re-registration
--     after a restart). There is no overwrite flag - cross-resource takeover does
--     not exist.
--
-- Two explicit MODES, because an external resource and an in-resource provider are
-- genuinely different beasts:
--
--   * `internal` - the provider lives in THIS resource (the Qbox framework adapter
--     in server/frameworkjobs.lua). Its handlers are local Lua functions.
--   * `external` - the provider lives in ANOTHER resource and is reached through
--     the export boundary. A Lua closure does not survive that boundary as a
--     callable function: CfxLua encodes it as a `funcref` (msgpack EXT, see
--     citizen/scripting/lua/scheduler.lua), which is exactly how a real server
--     rejected Ojol with `give_not_function`. An external definition therefore
--     carries SERIALIZABLE METADATA ONLY: export NAMES, never functions.
--
-- Cleanup is ownership-driven: `UnregisterByResource` drops every provider a
-- stopped resource owned, so the registry can never keep calling into a resource
-- that is gone.

local M = {}

M.MODE_INTERNAL = 'internal'
M.MODE_EXTERNAL = 'external'

local MODES = { [M.MODE_INTERNAL] = true, [M.MODE_EXTERNAL] = true }

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
---@field handler fun(target: JobProviderTarget, options: table?, ctx: table?): boolean, string?, table? internal mode only
---@field export string? server export name on the owning resource, external mode only

---@class JobProviderDefinition
---@field id string unique provider id
---@field label string display name
---@field type string 'profession' | 'framework_job' | future types
---@field mode string 'internal' | 'external'; the registry is told, never guesses
---@field resource string? IGNORED on input: the registry overwrites it with the
---                    owner it was given (diagnostics / cleanup only)
---@field order number? sort hint, lower first (default 100)
---@field grades table|function? internal may use a lazy function, external must be data
---@field give fun(target, options): boolean, string?, table? internal mode only
---@field remove fun(target, options): boolean, string?, table? internal mode only
---@field inspect fun(target): table? internal mode only
---@field operations table? external mode: { give = 'exportName', remove = ..., inspect = ... }
---@field messages table? external mode: outcome name -> admin-facing message
---@field actions JobProviderAction[]? optional

local OPERATIONS = { 'give', 'remove', 'inspect' }

local providers = {}
local sortedIds

local function isNonEmptyString(value)
    return type(value) == 'string' and value ~= ''
end

---Validate a definition for the mode it is being registered in.
---@param def JobProviderDefinition
---@param mode string
---@return boolean ok, string? reason
local function validate(def, mode)
    if type(def) ~= 'table' then return false, 'definition_not_table' end
    if not MODES[mode] then return false, 'invalid_mode' end
    if not isNonEmptyString(def.id) then return false, 'missing_id' end
    if not isNonEmptyString(def.label) then return false, 'missing_label' end
    if not isNonEmptyString(def.type) then return false, 'missing_type' end
    if def.order ~= nil and type(def.order) ~= 'number' then return false, 'order_not_number' end
    if def.grades ~= nil and type(def.grades) ~= 'table' and type(def.grades) ~= 'function' then
        return false, 'grades_not_table_or_function'
    end

    if def.messages ~= nil then
        if type(def.messages) ~= 'table' then return false, 'messages_not_table' end

        for key, value in pairs(def.messages) do
            if not isNonEmptyString(key) or not isNonEmptyString(value) then
                return false, 'messages_not_serializable'
            end
        end
    end

    if mode == M.MODE_EXTERNAL then
        -- A closure cannot cross the resource boundary as a function (it becomes a
        -- funcref). Catching the field here turns a live "give_not_function"
        -- mystery into a named, one-time rejection, and pointing the provider at
        -- `operations` instead is what actually makes the call work.
        if def.give ~= nil then return false, 'external_handler_not_serializable' end
        if def.remove ~= nil then return false, 'external_handler_not_serializable' end
        if def.inspect ~= nil then return false, 'external_handler_not_serializable' end
        if def.operations ~= nil and type(def.operations) ~= 'table' then return false, 'operations_not_table' end

        local operations = def.operations or {}
        for i = 1, #OPERATIONS do
            local name = operations[OPERATIONS[i]]
            if name ~= nil and not isNonEmptyString(name) then
                return false, ('operations_%s_not_export_name'):format(OPERATIONS[i])
            end
        end

        if operations.give == nil and operations.remove == nil then return false, 'no_mutation_handler' end
    else
        if def.give ~= nil and type(def.give) ~= 'function' then return false, 'give_not_function' end
        if def.remove ~= nil and type(def.remove) ~= 'function' then return false, 'remove_not_function' end
        if def.inspect ~= nil and type(def.inspect) ~= 'function' then return false, 'inspect_not_function' end
        if def.give == nil and def.remove == nil then return false, 'no_mutation_handler' end
        if def.operations ~= nil then return false, 'operations_not_supported_internal' end
    end

    if def.actions ~= nil then
        if type(def.actions) ~= 'table' then return false, 'actions_not_table' end

        for i = 1, #def.actions do
            local action = def.actions[i]
            local wellFormed = type(action) == 'table'
                and isNonEmptyString(action.id)
                and isNonEmptyString(action.label)

            if not wellFormed then return false, ('invalid_action_%s'):format(i) end

            if mode == M.MODE_EXTERNAL then
                if action.handler ~= nil then return false, 'external_action_handler_not_serializable' end
                if not isNonEmptyString(action.export) then return false, ('invalid_action_%s'):format(i) end
            elseif type(action.handler) ~= 'function' then
                return false, ('invalid_action_%s'):format(i)
            end
        end
    end

    return true
end

---@param def JobProviderDefinition
---@param mode string
---@return JobProviderAction[]
local function normalizeActions(def, mode)
    local list = {}
    local actions = def.actions or {}

    for i = 1, #actions do
        local action = actions[i]
        list[i] = {
            id = action.id,
            label = action.label,
            description = action.description,
            confirm = action.confirm == true,
            handler = mode == M.MODE_INTERNAL and action.handler or nil,
            export = mode == M.MODE_EXTERNAL and action.export or nil,
        }
    end

    return list
end

---Copy a definition, forcing the owner AND the mode. `def.resource` is deliberately
---dropped: ownership comes from the caller (the export boundary) and nowhere else.
---Fields that do not belong to the mode are stripped, so a stored provider can
---never be ambiguous about how it is invoked.
---@param def JobProviderDefinition
---@param owner string
---@param mode string
---@return JobProviderDefinition
local function normalize(def, owner, mode)
    return {
        id = def.id,
        label = def.label,
        type = def.type,
        mode = mode,
        resource = owner,
        order = def.order or 100,
        grades = def.grades,
        give = mode == M.MODE_INTERNAL and def.give or nil,
        remove = mode == M.MODE_INTERNAL and def.remove or nil,
        inspect = mode == M.MODE_INTERNAL and def.inspect or nil,
        operations = mode == M.MODE_EXTERNAL and {
            give = def.operations and def.operations.give or nil,
            remove = def.operations and def.operations.remove or nil,
            inspect = def.operations and def.operations.inspect or nil,
        } or nil,
        messages = def.messages,
        actions = normalizeActions(def, mode),
    }
end

---Register (or replace) a provider definition on behalf of `owner`.
---Re-registering the same id from the same owner is an idempotent update, so a
---resource restart or a lazy re-sync cannot create duplicates.
---@param def JobProviderDefinition
---@param owner string owning resource, resolved by the caller (never from `def`)
---@param mode string 'internal' | 'external'
---@return boolean ok, string outcomeOrReason
function M.Register(def, owner, mode)
    local valid, reason = validate(def, mode)
    if not valid then
        print(('[lifestate_jobs] provider rejected (%s)'):format(tostring(reason)))
        return false, reason
    end

    if not isNonEmptyString(owner) then return false, 'owner_required' end

    local normalized = normalize(def, owner, mode)
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
---leave a stale function reference - or a stale export name - behind.
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

---@param provider JobProviderDefinition
---@param actionId string
---@return JobProviderAction?
function M.FindAction(provider, actionId)
    for i = 1, #provider.actions do
        if provider.actions[i].id == actionId then return provider.actions[i] end
    end

    return nil
end

---Export name an external provider reaches for an operation ('give'/'remove'/'inspect').
---@param provider JobProviderDefinition
---@param operation string
---@return string? exportName
function M.OperationExport(provider, operation)
    if provider.mode ~= M.MODE_EXTERNAL or type(provider.operations) ~= 'table' then return nil end

    for i = 1, #OPERATIONS do
        if OPERATIONS[i] == operation then return provider.operations[OPERATIONS[i]] end
    end

    return nil
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
