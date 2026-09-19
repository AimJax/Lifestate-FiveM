local M = { passed = 0, failed = 0 }
function M.eq(actual, expected, message)
    if actual ~= expected then error(('%s: expected %s, got %s'):format(message or 'assertion', tostring(expected), tostring(actual)), 2) end
end
function M.ok(value, message) if not value then error(message or 'expected truthy value', 2) end end
function M.test(name, fn)
    local ok, err = pcall(fn)
    if ok then M.passed = M.passed + 1; print('PASS ' .. name)
    else M.failed = M.failed + 1; print(('FAIL %s\n  %s'):format(name, tostring(err))) end
end
function M.finish()
    print(('%d passed, %d failed'):format(M.passed, M.failed))
    if M.failed > 0 then os.exit(1) end
end
return M
