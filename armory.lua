-- armory: snapshots each character into armory_db for wow.stru.ci.
-- The game writes SavedVariables on /reload and logout; a watcher outside the
-- game uploads the file. Nothing here talks to the network.

local SCHEMA = 1
local LEGACY_TREES = { 1187, 1188, 1189 } -- professions, adventure, progression (Constants.LegacyConsts)
local LEGACY_CURRENCY = 4225

local f = CreateFrame("Frame")
local pending, dirty = false, false

-- plain copies a value into something SavedVariables can hold: numbers,
-- strings, booleans and tables of those. Functions and userdata are dropped.
local function plain(v, depth)
	local t = type(v)
	if t == "number" or t == "string" or t == "boolean" then return v end
	if t ~= "table" or (depth or 0) > 6 then return nil end
	local out = {}
	for k, x in pairs(v) do
		if type(k) == "number" or type(k) == "string" then
			out[k] = plain(x, (depth or 0) + 1)
		end
	end
	return out
end

local function try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c, d, e, g, h = pcall(fn, ...)
	if ok then return a, b, c, d, e, g, h end
end

local function hex(c)
	if type(c) ~= "table" or not c.r then return nil end
	return string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

-- tooltip turns C_TooltipInfo data into { {l, lc, r, rc}, ... }.
local function tooltip(data)
	if not data or not data.lines then return nil end
	local lines = {}
	for _, line in ipairs(data.lines) do
		if line.leftText or line.rightText then
			lines[#lines + 1] = {
				l = line.leftText, lc = hex(line.leftColor),
				r = line.rightText, rc = hex(line.rightColor),
			}
		end
	end
	return lines
end

local function equipment()
	local slots = {}
	for slot = 0, 19 do
		local link = GetInventoryItemLink("player", slot)
		if link then
			slots[slot] = {
				link = link,
				id = GetInventoryItemID("player", slot),
				icon = GetInventoryItemTexture("player", slot),
				quality = GetInventoryItemQuality("player", slot),
				durability = { try(GetInventoryItemDurability, slot) },
				tooltip = tooltip(try(C_TooltipInfo.GetInventoryItem, "player", slot)),
			}
		end
	end
	return slots
end

-- stats runs the character sheet's own stat functions against a hidden frame,
-- so labels, values and hidden rows match what the game shows.
local statFrame
local function stats()
	if not (PAPERDOLL_STATCATEGORIES and PAPERDOLL_STATINFO) then return nil end
	if not statFrame then
		statFrame = CreateFrame("Frame")
		statFrame:Hide()
		statFrame.Label = statFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		statFrame.Value = statFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		statFrame.Background = statFrame:CreateTexture()
	end
	local out = {}
	for _, cat in ipairs(PAPERDOLL_STATCATEGORIES) do
		local rows = {}
		local stats = cat.unit == "player" and cat.stats or {} -- skip the pet pane
		for _, stat in ipairs(stats) do
			local info = PAPERDOLL_STATINFO[stat.stat]
			local show = info and (not stat.showFunc or try(stat.showFunc))
			if show then
				statFrame.Label:SetText("")
				statFrame.Value:SetText("")
				statFrame.numericValue = nil
				if pcall(info.updateFunc, statFrame, "player") and (statFrame.Value:GetText() or "") ~= ""
					and (not stat.hideAt or stat.hideAt ~= statFrame.numericValue) then
					rows[#rows + 1] = {
						key = stat.stat,
						label = (statFrame.Label:GetText() or ""):gsub(":$", ""),
						value = statFrame.Value:GetText(),
						number = statFrame.numericValue,
					}
				end
				statFrame:Hide() -- some updateFuncs Show() the frame
			end
		end
		if #rows > 0 then out[#out + 1] = { name = cat.categoryName, stats = rows } end
	end
	return out
end

-- tree snapshots one trait tree (a talent spec or a Legacy tree) under configID.
local function tree(configID, treeID)
	if not configID or not treeID then return nil end
	local out = { configID = configID, treeID = treeID, groups = {}, nodes = {} }

	local groupIDs = {}
	for _, g in ipairs(try(C_Traits.GetGroupDisplayInfoByTreeID, treeID) or {}) do
		out.groups[#out.groups + 1] = { id = g.groupID, name = g.displayName, icon = g.icon, order = g.orderIndex }
		groupIDs[#groupIDs + 1] = g.groupID
	end
	local spent = {}
	for _, gc in ipairs(try(C_Traits.GetGroupCurrencyInfo, configID, groupIDs) or {}) do
		spent[gc.traitNodeGroupID] = gc.currencyInfos and gc.currencyInfos[1] and gc.currencyInfos[1].spent
	end
	for _, g in ipairs(out.groups) do g.spent = spent[g.id] end
	out.currency = plain(try(C_Traits.GetTreeCurrencyInfo, configID, treeID, false))

	for _, nodeID in ipairs(try(C_Traits.GetTreeNodes, treeID) or {}) do
		local n = try(C_Traits.GetNodeInfo, configID, nodeID)
		if n and n.isVisible then
			local node = {
				id = nodeID, x = n.posX, y = n.posY, type = n.type, flags = n.flags,
				ranks = n.ranksPurchased, activeRank = n.activeRank, maxRanks = n.maxRanks,
				groups = plain(n.groupIDs), edges = {}, entries = {},
				activeEntry = n.activeEntry and n.activeEntry.entryID,
			}
			for _, e in ipairs(n.visibleEdges or {}) do
				node.edges[#node.edges + 1] = { to = e.targetNode, type = e.type, visualStyle = e.visualStyle }
			end
			for _, entryID in ipairs(n.entryIDs or {}) do
				local e = try(C_Traits.GetEntryInfo, configID, entryID) or {}
				local d = e.definitionID and try(C_Traits.GetDefinitionInfo, e.definitionID) or {}
				local s = d.spellID and try(C_Spell.GetSpellInfo, d.spellID) or {}
				local entry = {
					id = entryID, definitionID = e.definitionID, spellID = d.spellID,
					name = d.overrideName or s.name, icon = d.overrideIcon or s.iconID,
					maxRanks = e.maxRanks, ranks = {},
				}
				for rank = 1, math.max(e.maxRanks or 1, 1) do
					entry.ranks[rank] = tooltip(try(C_TooltipInfo.GetTraitEntry, entryID, rank))
				end
				node.entries[#node.entries + 1] = entry
			end
			out.nodes[#out.nodes + 1] = node
		end
	end
	return out
end

local function talents()
	local specInfo = C_SpecializationInfo
	local out = { active = try(specInfo.GetActiveSpecGroup), specs = {} }
	for group = 1, math.max(try(GetNumSpecGroups) or 1, 1) do
		local configID = try(specInfo.GetCombatConfigIDForSpecGroup, group)
		local config = configID and try(C_Traits.GetConfigInfo, configID)
		out.specs[group] = tree(configID, config and config.treeIDs and config.treeIDs[1])
	end
	return out
end

local function legacy()
	local out = { trees = {}, names = { LEGACY_TREE_PROFESSIONS, LEGACY_TREE_ADVENTURE, LEGACY_TREE_PROGRESSION } }
	for i, treeID in ipairs(LEGACY_TREES) do
		out.trees[i] = tree(try(C_Traits.GetConfigIDByTreeID, treeID), treeID)
	end
	out.maxPoints = try(C_Traits.GetMaxAvailableTraitCurrency, LEGACY_CURRENCY)
	return out
end

local function skills()
	local out = {}
	for i = 1, try(C_SkillInfo.GetNumSkillLines) or 0 do
		out[#out + 1] = plain(try(C_SkillInfo.GetSkillLineInfo, i))
	end
	return out
end

local function snapshot()
	pending = false
	if InCombatLockdown() then dirty = true return end
	dirty = false

	local guid = UnitGUID("player")
	local _, classFile, classID = UnitClass("player")
	local _, raceFile, raceID = UnitRace("player")
	local version, build, _, toc = GetBuildInfo()
	local guildName, guildRank = GetGuildInfo("player")
	local firstName, surname = UnitNameUnmodified("player")

	armory_db = armory_db or {}
	armory_db.schema = SCHEMA
	armory_db.characters = armory_db.characters or {}
	local c = {
		updated = time(),
		client = { version = version, build = build, toc = toc },
		-- Forever names are first name + surname; UnitName returns both.
		guid = guid, name = firstName, surname = surname, realm = GetRealmName(),
		displayName = NameUtil and try(NameUtil.FormatUnitNameForDisplay, "player") or nil,
		level = UnitLevel("player"),
		class = UnitClass("player"), classFile = classFile, classID = classID,
		race = UnitRace("player"), raceFile = raceFile, raceID = raceID,
		sex = UnitSex("player"), faction = UnitFactionGroup("player"),
		guild = guildName and { name = guildName, rank = guildRank } or nil,
		title = (try(GetCurrentTitle) or -1) > 0 and try(GetTitleName, GetCurrentTitle()) or nil,
		xp = { cur = UnitXP("player"), max = UnitXPMax("player"), rested = GetXPExhaustion() },
		money = GetMoney(),
		zone = GetRealZoneText(),
		equipment = equipment(),
		stats = stats(),
		talents = talents(),
		legacy = legacy(),
		skills = skills(),
	}
	armory_db.characters[guid] = c
end

-- schedule coalesces bursts of events (a gear swap fires several) into one snapshot.
local function schedule(delay)
	if pending then return end
	pending = true
	C_Timer.After(delay or 1, snapshot)
end

f:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_REGEN_ENABLED" then
		if dirty then schedule() end
	elseif event == "PLAYER_LOGOUT" then
		local c = armory_db and armory_db.characters and armory_db.characters[UnitGUID("player")]
		if c then c.money, c.zone, c.loggedOut = GetMoney(), GetRealZoneText(), time() end
	elseif event == "PLAYER_ENTERING_WORLD" then
		schedule(3) -- give the trait and tooltip caches a moment after loading
	else
		schedule()
	end
end)

for _, event in ipairs({
	"PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "PLAYER_REGEN_ENABLED",
	"PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP", "PLAYER_GUILD_UPDATE",
	"TRAIT_CONFIG_UPDATED", "ACTIVE_PLAYER_SPECIALIZATION_CHANGED", "PLAYER_TALENT_UPDATE",
	"SKILL_LINES_CHANGED", "KNOWN_TITLES_UPDATE",
}) do
	pcall(f.RegisterEvent, f, event) -- unknown events error in this client; skip them
end

SLASH_ARMORY1 = "/armory"
SlashCmdList.ARMORY = function()
	snapshot()
	local c = armory_db.characters[UnitGUID("player")]
	local nodes = 0
	for _, spec in pairs(c.talents.specs) do nodes = nodes + #spec.nodes end
	local slots = 0
	for _ in pairs(c.equipment) do slots = slots + 1 end
	print(string.format("|cff66ccffarmory|r %s: %d items, %d stat groups, %d talent nodes. /reload to save.",
		c.name, slots, #(c.stats or {}), nodes))
end
