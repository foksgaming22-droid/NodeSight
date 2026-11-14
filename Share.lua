-- Sharing: the places Collect.lua remembers are passed on to other NodeSight players, and
-- theirs come to you, over a hidden addon channel. No chat line is written. A message says
-- a map, a herb or ore, and places on that map; nothing else.
--
-- Messages (text, at most 255 bytes):
--   N:<map>:<node>:<place>,<place>,...   places of a node on a map (Collect.lua's numbers)
--   H:<map>:<count>                      "I know this many places on this map"
-- A place you gather for the first time is sent at once. Now and then each player says how
-- many places they know on the map they are on; whoever knows more sends theirs, after a
-- random wait, so not everyone answers at once.
--
-- Sections: Sending, Receiving, Taking turns, Loading.

local _, ns = ...

local ipairs, pairs = ipairs, pairs
local floor, random = math.floor, math.random

local PREFIX = "NodeSight"
local CHANNEL = "NodeSightShare"
local MAX_BYTES = 240 -- of a message (the game allows 255)
local SEND_WAIT = 2 -- seconds between two messages
local THROTTLE_WAIT = 15 -- seconds without sending after the game said "too fast"
local JOIN_WAIT = 30 -- seconds between tries to join the channel
local MAX_QUEUE = 300 -- messages waiting; more are dropped
local ANNOUNCE = 300 -- seconds between two "I know this many", plus up to a minute
local ANSWER_WAIT = { 5, 30 } -- seconds before answering one who knows less
local ANSWER_AGAIN = 600 -- seconds before a map's places are sent again
local MAX_RECEIVED = 3000 -- received places kept per map
local MAX_FAILS = 5 -- sends refused in a row before sharing rests
local REST = 300 -- seconds it rests

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local queue = {} -- messages waiting, oldest first
local nextSend, nextJoin, fails = 0, 0, 0
local stats = { sent = 0, heard = 0, refused = 0 } -- since login, for the status button
local own = {} -- message: when you sent it (the channel sends your own back to you)
local OWN_WAIT = 10 -- seconds a message that comes in counts as your own echo

local function On()
    return ns.db.collect and ns.db.share
end

local function Queue(message)
    if #queue < MAX_QUEUE then queue[#queue + 1] = message end
end

-- The channel's number, joining it if need be (nil until it is joined).
local function ChannelID()
    local id = GetChannelName(CHANNEL)
    if type(id) == "number" and id > 0 then return id end
    local now = GetTime()
    if now >= nextJoin then
        nextJoin = now + JOIN_WAIT
        pcall(JoinTemporaryChannel or JoinChannelByName, CHANNEL)
    end
    return nil
end

local function Locked()
    local locked = C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
    return issecretvalue(locked) or locked == true
end

-- Sends the oldest waiting message, if it is time.
local function SendNext()
    local now = GetTime()
    if now < nextSend or not queue[1] then return end
    nextSend = now + SEND_WAIT
    if Locked() then return end -- (dungeons and raids: later)
    local id = ChannelID()
    if not id then return end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, queue[1], "CHANNEL", id)
    local sent = Enum.SendAddonMessageResult
    if ok and (result == true or result == 0 or (sent and result == sent.Success)) then
        own[queue[1]] = now
        table.remove(queue, 1)
        fails = 0
        stats.sent = stats.sent + 1
    elseif ok and sent and (result == sent.AddonMessageThrottle or result == sent.ChannelThrottle) then
        nextSend = now + THROTTLE_WAIT -- too fast: the message stays, and is tried again later
    else
        -- Refused: the message is dropped; refused too often, everything waits a while.
        table.remove(queue, 1)
        fails = fails + 1
        stats.refused = stats.refused + 1
        if fails >= MAX_FAILS then
            fails = 0
            wipe(queue)
            nextSend = now + REST
        end
    end
end

-- The N messages for a node's places on a map.
local function QueuePlaces(map, key, places)
    local head = ("N:%d:%s:"):format(map, key)
    local line = head
    for _, place in ipairs(places) do
        local text = tostring(place)
        if #line + #text + 1 > MAX_BYTES and line ~= head then
            Queue(line)
            line = head
        end
        line = line .. (line == head and "" or ",") .. text
    end
    if line ~= head then Queue(line) end
end

-- Every place known on a map, your own and the received ones.
local function QueueMap(map)
    for pass = 1, 2 do
        local nodes = ns.Nodes(pass == 2)[map]
        for key, places in pairs(type(nodes) == "table" and nodes or {}) do
            if type(places) == "table" then QueuePlaces(map, key, places) end
        end
    end
end

-- How many places are known on a map.
local function MapCount(map)
    local count = 0
    for pass = 1, 2 do
        local nodes = ns.Nodes(pass == 2)[map]
        for _, places in pairs(type(nodes) == "table" and nodes or {}) do
            if type(places) == "table" then count = count + #places end
        end
    end
    return count
end

-- A place you just gathered for the first time (Collect.lua).
function ns.ShareNew(map, key, place)
    if On() then QueuePlaces(map, key, { place }) end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local PACK, UNITS = ns.NODE_PACK, ns.NODE_UNITS
local redraw = false -- the world map's marks are drawn again at the next turn

-- A map ID a message may name.
local function MapOf(text)
    local map = tonumber(text)
    if map and map == floor(map) and map > 0 and map < 100000 then return map end
end

local function ReceivedCount(map)
    local count = 0
    local nodes = ns.Nodes(true)[map]
    for _, places in pairs(type(nodes) == "table" and nodes or {}) do
        if type(places) == "table" then count = count + #places end
    end
    return count
end

-- N: places of a node. Only a herb or ore NodeSight knows by name, at places on the map.
local function GotPlaces(map, key, list)
    local kind = ns.NodeKind(key)
    if not map or (kind ~= "herbs" and kind ~= "ore") or key ~= ns.NodeKey(key) or #key > 40 then return end
    local room = MAX_RECEIVED - ReceivedCount(map)
    for text in list:gmatch("[^,]+") do
        if room <= 0 then return end
        local place = tonumber(text)
        if place and place == floor(place) and place >= 0 then
            local x, y = floor(place / PACK), place % PACK
            if x <= UNITS and y <= UNITS and ns.RememberNode(key, map, x, y, true) then
                room = room - 1
                redraw = true
            end
        end
    end
end

---------------------------------------------------------------------------
-- Taking turns
---------------------------------------------------------------------------
local nextAnnounce = 0
local answers = {} -- map: when its places are to be sent (the game's clock)
local answered = {} -- map: when they were last sent

local function Announce(map)
    local count = MapCount(map)
    if count > 0 then Queue(("H:%d:%d"):format(map, count)) end
end

-- H: someone says how many places they know on a map.
local function GotCount(map, theirs)
    if not map or not theirs then return end
    local mine = MapCount(map)
    local now = GetTime()
    if mine > theirs then
        -- You know more: yours are sent after a random wait, unless they were sent lately.
        if not answers[map] and now - (answered[map] or -ANSWER_AGAIN) >= ANSWER_AGAIN then
            answers[map] = now + random(ANSWER_WAIT[1], ANSWER_WAIT[2])
        end
    else
        answers[map] = nil -- they know as much as you, or more: no need to send yours
        if mine < theirs and mine > 0 and not queue[1] then Announce(map) end -- (so that they send theirs)
    end
end

local function PlayerMap()
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not issecretvalue(map) and type(map) == "number" then return map end
end

-- Once a second while sharing is on.
local function Turn()
    local now = GetTime()
    if redraw then
        redraw = false
        ns.RefreshNodePins()
    end
    for map, at in pairs(answers) do
        if now >= at then
            answers[map], answered[map] = nil, now
            QueueMap(map)
        end
    end
    if now >= nextAnnounce then
        nextAnnounce = now + ANNOUNCE + random(0, 60)
        local map = PlayerMap()
        if map and not queue[1] then Announce(map) end
    end
    SendNext()
end

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local passed, stopped = 0, false

frame:SetScript("OnEvent", function(_, _, prefix, text, channel)
    if prefix ~= PREFIX or channel ~= "CHANNEL" or type(text) ~= "string" or issecretvalue(text) then return end
    local sentAt = own[text]
    if sentAt then
        own[text] = nil
        if GetTime() - sentAt <= OWN_WAIT then return end -- your own, come back
    end
    stats.heard = stats.heard + 1
    local kind, map, rest = text:match("^(%u):(%d+):(.+)$")
    if kind == "N" then
        local key, list = rest:match("^([^:]+):([%d,]+)$")
        if key then GotPlaces(MapOf(map), key, list) end
    elseif kind == "H" then
        GotCount(MapOf(map), tonumber(rest))
    end
end)

local function OnUpdate(_, elapsed)
    passed = passed + elapsed
    if passed < 1 or stopped then return end
    passed = 0
    -- An error would repeat every second: reported once, and sharing stops until the next reload.
    if not xpcall(Turn, geterrorhandler()) then stopped = true end
end

-- For the settings' status button: how sharing is doing, in a sentence.
function ns.ShareStatus()
    if not On() then return "Sharing is off." end
    local id = GetChannelName(CHANNEL)
    local joined = type(id) == "number" and id > 0
    return ("Sharing is on, the channel is %s. Since login: %d messages sent, %d refused, %d waiting, %d heard from others. %d places from other players are remembered.")
        :format(joined and "joined" or "not joined yet", stats.sent, stats.refused, #queue, stats.heard, ns.NodeCount(true))
end

-- The Share or Collecting setting changed, or the settings were loaded.
function ns.UpdateShare()
    frame:UnregisterAllEvents()
    wipe(queue)
    wipe(answers)
    if On() then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        frame:RegisterEvent("CHAT_MSG_ADDON")
        -- The first join waits: joined before the game's own channels, ours would take their number.
        local now = GetTime()
        nextJoin, nextSend, nextAnnounce = now + 15, now + 20, now + 60 + random(0, 60)
        frame:SetScript("OnUpdate", OnUpdate)
    else
        frame:SetScript("OnUpdate", nil)
        local id = GetChannelName(CHANNEL)
        if type(id) == "number" and id > 0 then pcall(LeaveChannelByName, CHANNEL) end
    end
end
