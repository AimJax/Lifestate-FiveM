local h = require 'tests.harness'

local values = {
    { 1, true }, { 0, false }, { true, true }, { false, false },
    { '1', true }, { '0', false }, { nil, false },
}

for i = 1, #values do
    local input, expected = values[i][1], values[i][2]
    h.test(('driver active hydration: %s'):format(tostring(input)), function()
        package.loaded['server.drivers'] = nil
        package.loaded['server.database'] = nil
        package.preload['server.database'] = function()
            return {
                FetchAllDrivers = function()
                    return {{ citizenid = 'hydration-' .. i, rank = 'driver', active = input }}
                end,
            }
        end
        local drivers = require 'server.drivers'
        drivers.LoadDrivers()
        h.eq(drivers.RegisteredDrivers['hydration-' .. i].active, expected, 'active flag')
    end)
end

