-- NodeSight's spots: where herbs, ore and chests were found, remembered for good
-- (NodeSightDB.spots, shared by your characters). Herbs and ore grow back in the same
-- places, so every scan teaches NodeSight a little more of each zone. Nothing uses the
-- spots yet: they are only collected here.
--
-- A spot: { x, y (0-1 on its map), kind, names = { [name] = times seen }, seen, empty
-- (times a whole scan looked there and found nothing), at (the server's time it was last
-- counted), cave (named in gray: on another level), rough (its place isn't measured yet) }.
--
-- Sections: Spots, After a scan.

local ADDON_NAME, ns = ...

local ipairs = ipairs

local MERGE = 12 -- yards: a find this close to a spot of its kind is that spot
local AGAIN = 240 -- seconds before a spot counts again (a node takes longer than that to grow back)
local INSIDE = 0.85 -- of the minimap's radius: only spots well inside it count as empty
local KINDS = { herbs = true, ore = true, treasure = true } -- (not rares: they walk)

---------------------------------------------------------------------------
-- Spots
---------------------------------------------------------------------------
-- A map's spots (made on first use).
local function List(map)
    if type(NodeSightDB.spots) ~= "table" then NodeSightDB.spots = {} end
    local list = NodeSightDB.spots[map]
    if type(list) ~= "table" then
        list = {}
        NodeSightDB.spots[map] = list
    end
    return list
end

-- The nearest spot of a kind within MERGE yards of x, y; nil if none.
local function Nearest(list, kind, x, y, width, height)
    local best, nearest = nil, MERGE * MERGE
    for _, spot in ipairs(list) do
        if spot.kind == kind then
            local dx, dy = (spot.x - x) * width, (spot.y - y) * height
            local far = dx * dx + dy * dy
            if far <= nearest then best, nearest = spot, far end
        end
    end
    return best
end

-- For other files: a map's spots, or nil.
function ns.Spots(map)
    local all = type(NodeSightDB) == "table" and NodeSightDB.spots
    return type(all) == "table" and all[map] or nil
end

---------------------------------------------------------------------------
-- After a scan
---------------------------------------------------------------------------
-- Each symbol a scan found is a spot seen; after a whole scan, a spot of the finder's kind
-- well inside the minimap with no symbol on it was empty.
local function Record()
    if type(NodeSightDB) ~= "table" then return end
    local now = GetServerTime()
    local touched = {} -- spots with a symbol on them this scan
    for _, marker in ipairs(ns.Markers()) do
        local map, x, y = marker.map, marker.mx, marker.my
        if KINDS[marker.kind] and map and x and y and not marker.far then
            local width, height = C_Map.GetMapWorldSize(map)
            if width and height and width > 0 and height > 0 then
                local list = List(map)
                local spot = Nearest(list, marker.kind, x, y, width, height)
                if marker.held or marker.missed then
                    -- (the other finder's, or not found this once: neither seen nor empty)
                    if spot then touched[spot] = true end
                else
                    if not spot then
                        spot = { x = x, y = y, kind = marker.kind, names = {}, seen = 0, empty = 0, at = 0, rough = marker.rough or nil }
                        list[#list + 1] = spot
                    elseif not marker.rough then
                        if spot.rough then
                            spot.x, spot.y, spot.rough = x, y, nil
                        else -- the average of its measured places (the last ten weigh the most)
                            local n = math.min(spot.seen, 9)
                            spot.x, spot.y = (spot.x * n + x) / (n + 1), (spot.y * n + y) / (n + 1)
                        end
                    end
                    touched[spot] = true
                    if spot.seen == 0 or now - spot.at >= AGAIN then
                        spot.seen, spot.at = spot.seen + 1, now
                        spot.names[marker.name] = (spot.names[marker.name] or 0) + 1
                        if marker.dim then spot.cave = true end
                    end
                end
            end
        end
    end
    -- Empty spots: only after a whole scan (not an edge scan), with one finder on.
    local last, edge = ns.KeyLast()
    if edge or type(last) ~= "table" or not last.map or not last.radius or issecretvalue(last.radius) then return end
    local finder = ns.Finders()
    if finder ~= "herbs" and finder ~= "ore" then return end
    local list = ns.Spots(last.map)
    local width, height = C_Map.GetMapWorldSize(last.map)
    if not list or not width or not height then return end
    local reach = (last.radius * INSIDE) ^ 2
    for _, spot in ipairs(list) do
        if spot.kind == finder and not touched[spot] and not spot.cave and now - spot.at >= AGAIN then
            local dx, dy = (spot.x - last.x) * width, (spot.y - last.y) * height
            if dx * dx + dy * dy <= reach then spot.empty, spot.at = spot.empty + 1, now end
        end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    if ns.db == ns.defaults then return end -- (NodeSight is waiting for a game restart)
    if NodeSightAPI and NodeSightAPI.RegisterCallback then
        NodeSightAPI.RegisterCallback(function() Record() end)
    end
end)
