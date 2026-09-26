-- memory: records what happens to each character into armory_memory, for the
-- private archive (see the forever-memory repo). Read only: nothing here acts
-- on the game. The public armory only receives each worn item's first-seen time.

local _, ns = ...

local KEEP_DAYS = 30 -- rows older than this are dropped at login; armory-sync archives them long before
local POSITION_EVERY = 2 -- seconds between position samples while moving

local mem, char -- armory_memory and this character's part of it

local function now() return time() end

-- log appends one event row. Rows carry a sequence number unique per account
-- so the archive can pick up exactly the rows it hasn't seen.
local function log(event, row)
	if not char then return end
	row = row or {}
	mem.seq = (mem.seq or 0) + 1
	row.n, row.t, row.e = mem.seq, now(), event
	char.log[#char.log + 1] = row
end

-- Context: which interaction an item or money change belongs to. A frame
-- counts for two seconds after it closes, since bag updates arrive late.
local ctx = { open = {}, closed = {} }
local function setContext(name, isOpen)
	if isOpen then ctx.open[name] = true else ctx.open[name], ctx.closed[name] = nil, GetTime() end
end
local function context()
	for name in pairs(ctx.open) do return name end
	local best, at = nil, GetTime() - 2
	for name, t in pairs(ctx.closed) do
		if t > at then best, at = name, t end
	end
	return best
end

-- itemKey identifies an item for first-seen purposes: the item ID, plus the
-- random suffix for items like "of the Bear".
local function itemKey(link)
	local id, suffix = link:match("item:(%d+):[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:]*)")
	if not id then id = link:match("item:(%d+)") end
	if not id then return nil end
	if suffix and suffix ~= "" and suffix ~= "0" then return id .. ":" .. suffix end
	return id
end
ns.itemKey = itemKey

-- firstSeen returns when an item was first seen on this character.
function ns.firstSeen(link)
	local key = link and itemKey(link)
	return key and char and char.seen[key]
end

-- noteItem keeps an account-wide catalogue of every item seen, so the
-- archive can show names, icons and quality for any item ID.
local function noteItem(link)
	if not link or not mem then return end
	local id = tonumber(link:match("item:(%d+)"))
	if not id or (mem.items[id] and mem.items[id].icon) then return end
	local _, _, _, equipLoc, icon, classID, subclassID = C_Item.GetItemInfoInstant(id)
	local name = link:match("%[(.-)%]")
	mem.items[id] = {
		name = name ~= "" and name or (mem.items[id] and mem.items[id].name) or nil,
		icon = icon, q = tonumber(link:match("|cnIQ(%d)")), slot = equipLoc ~= "" and equipLoc or nil,
		class = classID, subclass = subclassID,
	}
end
ns.noteItem = noteItem

local function see(link)
	noteItem(link)
	local key = itemKey(link)
	if key and not char.seen[key] then char.seen[key] = now() end
	return key
end

-- Inventory: bags and worn items are scanned; the bank is remembered from
-- the last time it was open, so moving things into it isn't a loss.
local counts, links = nil, {}
local baselineUntil = 0 -- scans before this only set the baseline: bags load after login
local bankCounts = {}

local function scanContainer(bag, into)
	for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
		local info = C_Container.GetContainerItemInfo(bag, slot)
		if info and info.hyperlink then
			local key = see(info.hyperlink)
			if key then
				into[key] = (into[key] or 0) + (info.stackCount or 1)
				links[key] = info.hyperlink
			end
		end
	end
end

-- Container IDs from Enum.BagIndex in this client: keyring -1, backpack 0,
-- bags 1-4, reagent bag 5; bank -2 and bank tabs 6-14.
local CARRIED = { -1, 0, 1, 2, 3, 4, 5 }
local BANK = { -2, 6, 7, 8, 9, 10, 11, 12, 13, 14 }

local function scanBank()
	bankCounts = {}
	for _, bag in ipairs(BANK) do scanContainer(bag, bankCounts) end
end

local function scanInventory()
	local cur = {}
	for _, bag in ipairs(CARRIED) do scanContainer(bag, cur) end
	for slot = 0, 19 do
		local link = GetInventoryItemLink("player", slot)
		if link then
			local key = see(link)
			if key then cur[key] = (cur[key] or 0) + 1; links[key] = link end
		end
	end
	for key, n in pairs(bankCounts) do cur[key] = (cur[key] or 0) + n end
	if counts and GetTime() >= baselineUntil then
		local where = context()
		for key, n in pairs(cur) do
			local d = n - (counts[key] or 0)
			if d ~= 0 then log("item", { key = key, link = links[key], d = d, total = n, ctx = where }) end
		end
		for key, n in pairs(counts) do
			if not cur[key] then log("item", { key = key, link = links[key], d = -n, total = 0, ctx = where }) end
		end
	end
	counts = cur
end

-- Quest and gossip text is cached by ID, once per text, account-wide.
local function questText(field, text)
	local id = GetQuestID and GetQuestID()
	if not id or id == 0 then return end
	local q = mem.quests[id] or { title = GetTitleText and GetTitleText(), seen = now() }
	q[field] = text
	mem.quests[id] = q
	return id
end

local function npcID()
	local guid = UnitGUID("npc")
	return guid and tonumber(guid:match("%-(%d+)%-%x+$")), UnitName("npc")
end

local lastPos = {}
local function samplePosition()
	if not char then return end
	local map = C_Map.GetBestMapForUnit("player")
	local pos = map and C_Map.GetPlayerMapPosition(map, "player")
	if not pos then return end
	local x, y = pos:GetXY()
	if not x then return end
	x, y = math.floor(x * 10000 + .5) / 10000, math.floor(y * 10000 + .5) / 10000
	if lastPos.map == map and math.abs(lastPos.x - x) < .0005 and math.abs(lastPos.y - y) < .0005 then return end
	local facing = GetPlayerFacing and GetPlayerFacing()
	lastPos = { map = map, x = x, y = y }
	log("pos", { map = map, x = x, y = y, f = facing and math.floor(facing * 100 + .5) / 100 })
end

local money, xp, level
local f = CreateFrame("Frame")
local handlers = {}

function handlers.PLAYER_LOGIN()
	armory_memory = armory_memory or {}
	mem = armory_memory
	mem.schema = 1
	mem.characters = mem.characters or {}
	mem.quests = mem.quests or {}
	mem.gossip = mem.gossip or {}
	mem.items = mem.items or {}
	mem.players = mem.players or {}
	local guid = UnitGUID("player")
	mem.characters[guid] = mem.characters[guid] or { seen = {}, log = {} }
	char = mem.characters[guid]

	-- Drop rows the archive has certainly taken by now.
	local cutoff, kept = now() - KEEP_DAYS * 86400, {}
	for _, row in ipairs(char.log) do if row.t >= cutoff then kept[#kept + 1] = row end end
	char.log = kept

	if mem.nativeLogs ~= false then -- the plan's "never forget the native logs"
		if LoggingChat and not LoggingChat() then LoggingChat(true) end
		if LoggingCombat and not LoggingCombat() then LoggingCombat(true) end
		-- Positions and full unit info in combat log lines (Options > Network).
		if C_CVar and C_CVar.GetCVar("advancedCombatLogging") ~= "1" then C_CVar.SetCVar("advancedCombatLogging", "1") end
	end

	money, xp, level = GetMoney(), UnitXP("player"), UnitLevel("player")
	log("login", { level = level, money = money, xp = xp, zone = GetRealZoneText() })
	C_Timer.NewTicker(POSITION_EVERY, samplePosition)
end

function handlers.PLAYER_ENTERING_WORLD()
	baselineUntil = GetTime() + 5
	scanInventory()
	C_Timer.After(5, scanInventory)
end
function handlers.BAG_UPDATE_DELAYED() scanInventory() end
function handlers.PLAYER_LOGOUT() log("logout", { money = GetMoney(), zone = GetRealZoneText() }) end

function handlers.PLAYER_EQUIPMENT_CHANGED(slot)
	local link = GetInventoryItemLink("player", slot)
	if link then see(link) end
	log("equip", { slot = slot, link = link })
end

function handlers.PLAYER_MONEY()
	local m = GetMoney()
	if money and m ~= money then log("money", { d = m - money, total = m, ctx = context() }) end
	money = m
end

function handlers.PLAYER_XP_UPDATE()
	local x, l = UnitXP("player"), UnitLevel("player")
	if xp and l == level and x ~= xp then log("xp", { d = x - xp, cur = x, max = UnitXPMax("player") }) end
	xp, level = x, l
end

function handlers.PLAYER_LEVEL_UP(newLevel)
	log("level", { level = newLevel, zone = GetRealZoneText() })
	level, xp = newLevel, UnitXP("player")
end

function handlers.ZONE_CHANGED_NEW_AREA()
	log("zone", { zone = GetRealZoneText(), sub = GetSubZoneText(), map = C_Map.GetBestMapForUnit("player") })
end
function handlers.ZONE_CHANGED() log("subzone", { zone = GetRealZoneText(), sub = GetSubZoneText() }) end

function handlers.QUEST_ACCEPTED(questID)
	log("quest", { act = "accept", id = questID, title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID) })
end
function handlers.QUEST_TURNED_IN(questID, xpReward, moneyReward)
	local q = mem.quests[questID]
	log("quest", { act = "turnin", id = questID, title = q and q.title, xp = xpReward, money = moneyReward, choice = ns.questChoice })
	ns.questChoice = nil
end
function handlers.QUEST_REMOVED(questID) log("quest", { act = "remove", id = questID }) end

function handlers.QUEST_DETAIL()
	local id = questText("text", GetQuestText())
	if id then mem.quests[id].objective = GetObjectiveText() end
	setContext("quest", true)
end
function handlers.QUEST_PROGRESS() questText("progress", GetProgressText()); setContext("quest", true) end
function handlers.QUEST_COMPLETE()
	local id = questText("reward", GetRewardText())
	if id then
		local choices = {}
		for i = 1, GetNumQuestChoices() or 0 do
			choices[i] = GetQuestItemLink("choice", i)
			noteItem(choices[i])
		end
		mem.quests[id].choices = choices
	end
	setContext("quest", true)
end
function handlers.QUEST_FINISHED() setContext("quest", false) end

-- The quest log as it stands, with objective progress; each objective that
-- moves forward is also logged, so the archive can show how a quest went.
local lastObjectives = {}
local questLogPending = false
local function snapshotQuestLog()
	questLogPending = false
	local list = {}
	for i = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(i)
		if info and not info.isHeader and not info.isHidden and info.questID and info.questID > 0 then
			local id = info.questID
			local objectives = {}
			for j, o in ipairs(C_QuestLog.GetQuestObjectives(id) or {}) do
				objectives[j] = { text = o.text, have = o.numFulfilled, need = o.numRequired, done = o.finished }
				local key = id .. ":" .. j
				local before = lastObjectives[key]
				if before and o.numFulfilled and o.numFulfilled > before then
					log("objective", { id = id, i = j, have = o.numFulfilled, need = o.numRequired, text = o.text })
				end
				lastObjectives[key] = o.numFulfilled
			end
			local complete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(id)
			list[#list + 1] = { id = id, title = info.title, level = info.level, group = info.suggestedGroup,
				complete = complete or nil, objectives = objectives }
			if not mem.quests[id] then mem.quests[id] = { title = info.title, seen = now() } end
			mem.quests[id].level = info.level
		end
	end
	char.questlog = list
end
function handlers.QUEST_LOG_UPDATE()
	if questLogPending then return end
	questLogPending = true
	C_Timer.After(1, snapshotQuestLog)
end

-- Everyone met: full name (first + surname), class, race, level and guild,
-- keyed by the same GUID the combat log uses. Updated at most once a minute.
local function notePlayer(unit)
	if not mem or not UnitExists(unit) or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end
	local guid = UnitGUID(unit)
	if not guid then return end
	local p = mem.players[guid]
	if p and now() - (p.last or 0) < 60 then return end
	local name, surname = UnitName(unit)
	local _, classFile = UnitClass(unit)
	local race = UnitRace(unit)
	local guild = GetGuildInfo(unit)
	p = p or { first = now(), seen = 0 }
	p.name, p.surname, p.class, p.race = name, surname, classFile, race
	p.level = math.max(p.level or 0, UnitLevel(unit) or 0)
	p.guild = guild or p.guild
	p.faction = UnitFactionGroup(unit)
	p.last, p.seen = now(), (p.seen or 0) + 1
	mem.players[guid] = p
end
function handlers.UPDATE_MOUSEOVER_UNIT() notePlayer("mouseover") end
function handlers.PLAYER_TARGET_CHANGED() notePlayer("target") end
function handlers.NAME_PLATE_UNIT_ADDED(unit) notePlayer(unit) end

function handlers.GOSSIP_SHOW()
	local id, name = npcID()
	local text = C_GossipInfo.GetText()
	local options = {}
	for i, o in ipairs(C_GossipInfo.GetOptions() or {}) do options[i] = o.name end
	if text and text ~= "" then
		mem.gossip[(id or name or "?") .. ":" .. text] = { npc = id, name = name, text = text, options = options, seen = now() }
	end
	log("gossip", { npc = id, name = name })
	setContext("gossip", true)
end
function handlers.GOSSIP_CLOSED() setContext("gossip", false) end

for event, name in pairs({
	MERCHANT_SHOW = "merchant", MAIL_SHOW = "mail", TRADE_SHOW = "trade", LOOT_OPENED = "loot",
	AUCTION_HOUSE_SHOW = "auction", BANKFRAME_OPENED = "bank", TRAINER_SHOW = "trainer",
}) do
	handlers[event] = function()
		setContext(name, true)
		if name == "bank" then scanBank() end
		log("open", { what = name })
	end
end
for event, name in pairs({
	MERCHANT_CLOSED = "merchant", MAIL_CLOSED = "mail", TRADE_CLOSED = "trade", LOOT_CLOSED = "loot",
	AUCTION_HOUSE_CLOSED = "auction", BANKFRAME_CLOSED = "bank", TRAINER_CLOSED = "trainer",
}) do
	handlers[event] = function() setContext(name, false) end
end
function handlers.PLAYERBANKSLOTS_CHANGED() if ctx.open.bank then scanBank() end end

function handlers.PLAYER_DEAD() log("death", { zone = GetRealZoneText(), sub = GetSubZoneText() }) end
function handlers.PLAYER_ALIVE() log("alive") end
function handlers.PLAYER_UNGHOST() log("unghost") end

function handlers.GROUP_ROSTER_UPDATE()
	local members = {}
	for i = 1, GetNumGroupMembers() do
		local unit = IsInRaid() and ("raid" .. i) or (i == 1 and "player" or "party" .. (i - 1))
		notePlayer(unit)
		members[#members + 1] = GetUnitName(unit, true)
	end
	log("group", { members = members })
end

function handlers.TIME_PLAYED_MSG(total, thisLevel) log("played", { total = total, level = thisLevel }) end
function handlers.LEARNED_SPELL_IN_SKILL_LINE(spellID) log("spell", { id = spellID }) end

-- System lines worth keeping verbatim (they are also in the chat log).
for event, kind in pairs({
	CHAT_MSG_SKILL = "skill", CHAT_MSG_COMBAT_FACTION_CHANGE = "rep", CHAT_MSG_LOOT = "loot", CHAT_MSG_MONEY = "money",
}) do
	handlers[event] = function(text) log("msg", { kind = kind, text = text }) end
end

f:SetScript("OnEvent", function(_, event, ...)
	if event ~= "PLAYER_LOGIN" and not char then return end
	handlers[event](...)
end)
for event in pairs(handlers) do pcall(f.RegisterEvent, f, event) end

-- The reward chosen on turn-in is only visible as the argument to GetQuestReward.
if GetQuestReward then
	hooksecurefunc("GetQuestReward", function(choice)
		ns.questChoice = choice and choice > 0 and GetQuestItemLink("choice", choice) or nil
	end)
end
-- The gossip frame picks options by ID or by index, depending on the button.
local function pickedGossip(match)
	for i, o in ipairs(C_GossipInfo.GetOptions() or {}) do
		if match(i, o) then
			local id, name = npcID()
			log("gossip_pick", { npc = id, name = name, option = o.name })
			return
		end
	end
end
if C_GossipInfo and C_GossipInfo.SelectOption then
	hooksecurefunc(C_GossipInfo, "SelectOption", function(optionID)
		pickedGossip(function(_, o) return o.gossipOptionID == optionID end)
	end)
end
if C_GossipInfo and C_GossipInfo.SelectOptionByIndex then
	hooksecurefunc(C_GossipInfo, "SelectOptionByIndex", function(index)
		pickedGossip(function(_, o) return o.orderIndex == index end)
	end)
end
