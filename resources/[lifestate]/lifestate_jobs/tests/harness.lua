local M = { passed = 0, failed = 0 }

function M.eq(actual, expected, message)
    if actual ~= expected then
        error(('%s: expected %s, got %s'):format(message or 'assertion', tostring(expected), tostring(actual)), 2)
    end
end

function M.ok(value, message)
    if not value then
        error(('%s: expected a truthy value, got %s'):format(message or 'assertion', tostring(value)), 2)
    end
end

---Assert that a string contains a fragment.
function M.contains(haystack, needle, message)
    if type(haystack) ~= 'string' or not haystack:find(needle, 1, true) then
        error(('%s: expected %s to contain %s'):format(message or 'assertion', tostring(haystack), tostring(needle)), 2)
    end
end

---Assert that a string does NOT contain a fragment.
function M.absent(haystack, needle, message)
    if type(haystack) == 'string' and haystack:find(needle, 1, true) then
        error(('%s: expected %s to not contain %s'):format(message or 'assertion', haystack, needle), 2)
    end
end

function M.test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        M.passed = M.passed + 1
        print(('PASS %s'):format(name))
    else
        M.failed = M.failed + 1
        print(('FAIL %s\n  %s'):format(name, tostring(err)))
    end
end

---Emulate FiveM's `exports` proxy for one resource:
---   exports.res:fn(a)  -> fn(a)        (colon syntax, self stripped)
---   exports.res.fn(a)  -> fn(a)        (dot syntax)
function M.exportsProxy(target)
    local proxy
    proxy = setmetatable({}, {
        __index = function(_, key)
            local fn = target[key]
            if type(fn) ~= 'function' then return nil end

            return function(self, ...)
                if self == proxy then return fn(...) end
                return fn(self, ...)
            end
        end,
    })

    return proxy
end

---Forget a module (and its preload) so the next require reloads it.
function M.reload(...)
    local names = { ... }
    for i = 1, #names do
        package.loaded[names[i]] = nil
        package.preload[names[i]] = nil
    end
end

function M.finish()
    print(('%d passed, %d failed'):format(M.passed, M.failed))
    if M.failed > 0 then os.exit(1) end
end

return M
