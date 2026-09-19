-- Server-side grid spatial index for Ojol scalability hardening.
--
-- Pure Lua: no CFX natives, no database, no network traffic. Each entry lives
-- in exactly one cell, so insert/remove/move are O(1) and a radius query only
-- inspects the cells intersecting the search circle.
--
-- The index is a CANDIDATE FILTER, never an authority: callers must still run
-- their exact eligibility checks (distance included) on every candidate.
-- Gameplay values (tiers, radii, timing) live in config.server and are read by
-- the callers, never here.

local M = {}

---Default cell edge in metres. Justified in the scale report: equal to the
---smallest search tier (2 km), so the common tier-1 query touches at most a
---3x3 cell neighbourhood while a driver at 40 m/s crosses a cell only every
---~50 position refreshes.
M.DefaultCellSize = 2000

---@param cellSize number|nil edge length in metres
---@return table index
function M.New(cellSize)
    cellSize = tonumber(cellSize) or M.DefaultCellSize
    if cellSize <= 0 then cellSize = M.DefaultCellSize end

    local index = {
        cellSize = cellSize,
        cells = {},     -- [cellKey] = { [id] = true }
        positions = {}, -- [id] = { x, y }
        count = 0,
    }

    ---@param x number
---@param y number
    ---@return string
    local function cellKey(x, y)
        return math.floor(x / cellSize) .. ':' .. math.floor(y / cellSize)
    end

    index.CellKey = cellKey

    ---Insert or reposition an entry. Re-inserting an existing id moves it and
    ---never duplicates it.
    ---@param id string
    ---@param x number
    ---@param y number
    function index:Insert(id, x, y)
        if id == nil or type(x) ~= 'number' or type(y) ~= 'number' then return false end

        local key = cellKey(x, y)
        local previous = self.positions[id]
        if previous then
            local previousKey = cellKey(previous.x, previous.y)
            if previousKey == key then
                previous.x, previous.y = x, y
                return true
            end
            local bucket = self.cells[previousKey]
            if bucket then
                bucket[id] = nil
                if next(bucket) == nil then self.cells[previousKey] = nil end
            end
        else
            self.count = self.count + 1
        end

        local bucket = self.cells[key]
        if not bucket then
            bucket = {}
            self.cells[key] = bucket
        end
        bucket[id] = true
        self.positions[id] = { x = x, y = y }
        return true
    end

    ---@param id string
    function index:Remove(id)
        local previous = self.positions[id]
        if not previous then return false end

        local key = cellKey(previous.x, previous.y)
        local bucket = self.cells[key]
        if bucket then
            bucket[id] = nil
            if next(bucket) == nil then self.cells[key] = nil end
        end

        self.positions[id] = nil
        self.count = self.count - 1
        return true
    end

    ---Candidate ids whose stored position is within `radius` metres of
    ---(x, y), exact-distance filtered. Each id appears at most once.
    ---@param x number
    ---@param y number
    ---@param radius number metres
    ---@return table ids array
    function index:Query(x, y, radius)
        local found = {}
        if type(x) ~= 'number' or type(y) ~= 'number' or type(radius) ~= 'number' or radius < 0 then
            return found
        end

        local minCx, maxCx = math.floor((x - radius) / cellSize), math.floor((x + radius) / cellSize)
        local minCy, maxCy = math.floor((y - radius) / cellSize), math.floor((y + radius) / cellSize)

        for cx = minCx, maxCx do
            for cy = minCy, maxCy do
                local bucket = self.cells[cx .. ':' .. cy]
                if bucket then
                    for id in pairs(bucket) do
                        local pos = self.positions[id]
                        if pos then
                            local dx, dy = pos.x - x, pos.y - y
                            if dx * dx + dy * dy <= radius * radius then
                                found[#found + 1] = id
                            end
                        end
                    end
                end
            end
        end

        return found
    end

    ---@return number entries currently indexed
    function index:Count()
        return self.count
    end

    return index
end

return M
