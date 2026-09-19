local h = require 'tests.harness'

local metadata
local alters

local function loadDatabase(column)
    metadata = column
    alters = {}
    MySQL = {
        query = { await = function(sql)
            if sql:find('ALTER TABLE') then alters[#alters + 1] = sql end
            return {}
        end },
        scalar = { await = function() return 1 end },
        single = { await = function(sql)
            if sql:find('information_schema%.COLUMNS') then return metadata end
            return nil
        end },
    }
    package.loaded['server.database'] = nil
    package.preload['server.database'] = nil
    return require 'server.database'
end

h.test('company balance migration skips ALTER when schema is current', function()
    local db = loadDatabase({ DATA_TYPE = 'bigint', COLUMN_TYPE = 'bigint(20)', IS_NULLABLE = 'NO', COLUMN_DEFAULT = '0' })
    db.EnsureSchema()
    h.eq(#alters, 0, 'ALTER count')
end)

h.test('company balance migration runs ALTER when schema is old', function()
    local db = loadDatabase({ DATA_TYPE = 'bigint', COLUMN_TYPE = 'bigint(20) unsigned', IS_NULLABLE = 'NO', COLUMN_DEFAULT = '0' })
    db.EnsureSchema()
    h.eq(#alters, 1, 'ALTER count')
    h.contains(alters[1], 'MODIFY `company_balance` BIGINT NOT NULL DEFAULT 0', 'signed definition')
end)
