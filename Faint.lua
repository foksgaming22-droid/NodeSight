-- NodeSight's faint symbols (Beta): the spots where herbs, ore and chests have been found
-- before (Spots.lua) show on the minimap as see-through symbols without a ring, with no scan
-- at all. "Something grows here at times", not "something is here now": a scan that finds
-- it puts the real symbol there. The arrow never points at a faint one.
--
-- Sections: Which spots, Drawing.

local ADDON_NAME, ns = ...

local ipairs = ipairs

local MAX = 30 -- faint symbols at once
local NEAR = 12 -- yards: a real symbol this close stands for the spot
local QUIET = 120 -- seconds a spot is at its faintest after a scan found it empty
local EMPTY = 0.6 -- of the opacity set: a spot a scan just found empty, or one that is mostly empty
-- The plain herb and ore symbols, for a name without a picture of its own (NodeSight.lua's ICONS).
local PLAIN = { herbs = "Professions_Tracking_Herb", ore = "Professions_Tracking_Ore" }

---------------------------------------------------------------------------
-- Which spots
---------------------------------------------------------------------------
-- The kinds whose finder is on now (Find Herbs, Find Minerals, Find Treasure): only those
-- have dots on the minimap, so only those get faint symbols. Asked for once a second.
local kinds, kindsAt = {}, 0
local function Kinds()
    local now = GetTime()
    if now < kindsAt then return kinds end
    kindsAt = now + 1
    kinds = {}
    if not (C_Minimap.GetNumTrackingTypes and C_Minimap.GetTrackingInfo) then return kinds end
    for index = 1, C_Minimap.GetNumTrackingTypes() do
        local info = C_Minimap.GetTrackingInfo(index)
        if type(info) == "table" and not issecretvalue(info) and not issecretvalue(info.spellID) and not issecretvalue(info.active)
            and info.active then
            local kind = ns.FINDERS[info.spellID]
            if kind == "herbs" or kind == "ore" or kind == "treasure" then kinds[kind] = true end
        end
    end
    return kinds
end

-- The name seen most often at a spot.
local function NameOf(spot)
    local best, most = nil, 0
    for name, times in pairs(spot.names) do
        if times > most then best, most = name, times end
    end
    return best
end

-- The spots to show now: on this map, of a kind tracked, inside the minimap's reach, not
-- under a real symbol. Worked out twice a second.
local shown, shownAt = {}, 0
local function Choose(map, x, y, width, height, radius)
    local now = GetTime()
    if now < shownAt and shown.map == map then return shown end
    shownAt = now + 0.5
    shown = { map = map }
    local list = ns.Spots(map)
    if not list then return shown end
    local tracked = Kinds()
    local reach = (radius * 1.5) ^ 2 -- (a square minimap's corners are further than its radius)
    local markers = ns.Markers()
    for _, spot in ipairs(list) do
        if tracked[spot.kind] and not spot.cave and type(spot.names) == "table" then
            local east, north = (spot.x - x) * width, (y - spot.y) * height
            if east * east + north * north <= reach then
                local real = false
                for _, marker in ipairs(markers) do
                    if marker.kind == spot.kind and marker.map == map and marker.mx
                        and ((marker.mx - spot.x) * width) ^ 2 + ((marker.my - spot.y) * height) ^ 2 <= NEAR * NEAR then
                        real = true
                        break
                    end
                end
                if not real then
                    shown[#shown + 1] = spot
                    if #shown >= MAX then break end
                end
            end
        end
    end
    return shown
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
-- On the symbols' own frame, under them: it goes where they go during a scan.
local icons = {}

local function Icon(i)
    local icon = icons[i]
    if icon then return icon end
    local frame = ns.MapFrame()
    local texture = frame:CreateTexture(nil, "ARTWORK")
    texture:SetSnapToPixelGrid(false)
    texture:SetTexelSnappingBias(0)
    texture:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- without the icon's border
    local mask = frame:CreateMaskTexture()
    mask:SetSnapToPixelGrid(false)
    mask:SetTexelSnappingBias(0)
    mask:SetAtlas(ns.CIRCLE)
    mask:SetAllPoints(texture)
    texture:AddMaskTexture(mask)
    icon = { texture = texture }
    icons[i] = icon
    return icon
end

local function HideFrom(first)
    for i = first, #icons do
        local icon = icons[i]
        if icon.shown then
            icon.shown = false
            icon.texture:Hide()
        end
    end
end

local function Draw()
    local db = ns.db
    local frame = ns.MapFrame()
    if not (db.faintSpots and db.mapIcons and frame) then return HideFrom(1) end
    local map, x, y, width, height = ns.MapPosition()
    local radius = C_Minimap.GetViewRadius()
    if not map or not radius or issecretvalue(radius) or radius <= 0 then return HideFrom(1) end
    local turning = C_CVar.GetCVar("rotateMinimap") == "1"
    local facing = turning and ns.PlayerFacing()
    if turning and not facing then return HideFrom(1) end
    local half = Minimap:GetWidth() / 2
    local quarters = ns.MinimapQuarters()
    local size = db.iconSize
    local solid = (tonumber(db.faintAlpha) or 80) / 100
    local used = 0
    for _, spot in ipairs(Choose(map, x, y, width, height, radius)) do
        local east, north = (spot.x - x) * width, (y - spot.y) * height
        local distance = math.sqrt(east * east + north * north) / radius * half
        local way = math.atan2(east, north)
        if turning then way = way + facing end
        local px, py = half + distance * math.sin(way), half + distance * math.cos(way)
        local inside = ns.InShape(px - half, py - half, half, quarters)
        local file = inside and ns.IconOf(NameOf(spot) or "", spot.kind)
        local plain = inside and not file and PLAIN[spot.kind]
        if file or plain then
            used = used + 1
            local icon = Icon(used)
            if icon.file ~= (file or plain) then
                icon.file = file or plain
                if file then
                    icon.texture:SetTexture(file)
                    icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- without the icon's border
                else
                    icon.texture:SetAtlas(plain)
                end
            end
            if icon.size ~= size then
                icon.size = size
                icon.texture:SetSize(size, size)
            end
            -- How often it was there when a scan looked: fainter the more often it was empty.
            -- One a scan just found empty is at its faintest: nothing there now, but it's a spot.
            local chance = spot.seen / math.max(1, spot.seen + (spot.empty or 0))
            local emptyAt = ns.SpotEmptyAt(spot)
            if emptyAt and GetTime() - emptyAt < QUIET then chance = 0 end
            local alpha = solid * math.max(EMPTY, chance)
            if icon.alpha ~= alpha then
                icon.alpha = alpha
                icon.texture:SetAlpha(alpha)
            end
            icon.texture:SetPoint("CENTER", frame, "BOTTOMLEFT", px, py)
            if not icon.shown then
                icon.shown = true
                icon.texture:Show()
            end
        end
    end
    HideFrom(used + 1)
    -- For the bug report: how many are drawn, said when it changes (at most every 10 seconds).
    local now = GetTime()
    if used ~= icons.said and now >= (icons.sayAt or 0) then
        icons.said, icons.sayAt = used, now + 10
        local list, tracked = ns.Spots(map), {}
        for kind in pairs(Kinds()) do tracked[#tracked + 1] = kind end
        ns.Log(("faint symbols: %d drawn, %d spots known on map %s, tracking %s"):format(used, list and #list or 0,
            tostring(map), tracked[1] and table.concat(tracked, "+") or "nothing"))
    end
end

local drawer = CreateFrame("Frame")
drawer:Hide()
drawer:SetScript("OnUpdate", function()
    local ok, err = pcall(Draw)
    if not ok then -- an error would repeat every frame: said once, and no faint symbols until a reload
        drawer:Hide()
        pcall(HideFrom, 1)
        ns.Log("error: faint symbols: " .. tostring(err):sub(1, 200))
    end
end)

-- The setting changed, or the settings are loaded: drawn every frame only while it's on.
function ns.RefreshFaint()
    shownAt, kindsAt = 0, 0
    local on = ns.db.faintSpots and ns.db ~= ns.defaults
    drawer:SetShown(on and true or false)
    if not on then pcall(HideFrom, 1) end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function() ns.RefreshFaint() end)
