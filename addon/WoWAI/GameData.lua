-- WoWAI game data: what the agent can ask for with a ```wowdata block (see
-- docs/ACTIONS.md): bags, bank, gear, spells, bars, talents, quests, reputation
-- and macros, as compact text for the next message of the chat.
--
-- Everything here only reads. The bank can only be read while it is open, so a
-- copy is kept (per character, WoWAIDataDB) every time the player opens it.
-- The open-window state (bank, merchant, trainer) lives here too, for Actions.lua.

local M = {}
WoWAIData = M

local KINDS = { "bags", "bank", "gear", "spells", "bars", "talents", "quests", "reputation", "macros" }
M.KINDS = KINDS

local ddb -- WoWAIDataDB: { bank = { t, lines, free, total } }
local open = {} -- bank / merchant / trainer = true while that window is open

-- Call a game API that may not exist or may throw, and get its returns or nothing
-- (up to 12: GetItemInfo's sell price is the 11th).
local function Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c, d, e, f, g, h, i, j, k, l = pcall(fn, ...)
	if ok then return a, b, c, d, e, f, g, h, i, j, k, l end
end
M.Try = Try

-- One value only: gsub also returns a count, which table.insert would take as a position.
local function Clean(s)
	return (tostring(s or ""):gsub("[\r\n\30\31|]", " "))
end

function M.IsOpen(what) return open[what] == true end

---------------------------------------------------------------------------
-- Containers
---------------------------------------------------------------------------

local BagIndex = (Enum and Enum.BagIndex) or {}
local BAGS = { 0, 1, 2, 3, 4, BagIndex.ReagentBag or 5 }
local BANK_TABS, ACCOUNT_TABS = {}, {}
for i = 1, 9 do
	BANK_TABS[i] = BagIndex["CharacterBankTab_" .. i] or (5 + i)
	ACCOUNT_TABS[i] = BagIndex["AccountBankTab_" .. i] or (14 + i)
end
M.BAGS, M.BANK_TABS, M.ACCOUNT_TABS = BAGS, BANK_TABS, ACCOUNT_TABS

local function NumSlots(bag)
	return Try(C_Container and C_Container.GetContainerNumSlots, bag) or 0
end

-- Slot info: { itemID, stackCount, quality, isLocked, hasNoValue, isBound, hyperlink }.
function M.SlotInfo(bag, slot)
	local info = Try(C_Container and C_Container.GetContainerItemInfo, bag, slot)
	if type(info) == "table" and info.itemID then return info end
	return nil
end

-- Every occupied slot of the given containers: { bag, slot, info }.
function M.Slots(containers)
	local out = {}
	for _, bag in ipairs(containers) do
		for slot = 1, NumSlots(bag) do
			local info = M.SlotInfo(bag, slot)
			if info then table.insert(out, { bag = bag, slot = slot, info = info }) end
		end
	end
	return out
end

local function ItemName(id)
	return Try(C_Item and C_Item.GetItemNameByID, id) or Try(GetItemInfo, id) or ("item " .. id)
end
M.ItemName = ItemName

-- One line per distinct item: "6948 Hearthstone x1 q1 Miscellaneous v0s".
local function ItemLines(containers)
	local byId, order, used, total = {}, {}, 0, 0
	for _, bag in ipairs(containers) do
		total = total + NumSlots(bag)
	end
	for _, s in ipairs(M.Slots(containers)) do
		used = used + 1
		local id = s.info.itemID
		local e = byId[id]
		if not e then
			e = { id = id, count = 0, quality = s.info.quality, bound = s.info.isBound, nosell = s.info.hasNoValue }
			byId[id] = e
			table.insert(order, e)
		end
		e.count = e.count + (s.info.stackCount or 1)
	end
	local lines = {}
	for _, e in ipairs(order) do
		local _, _, _, ilvl, _, itemType, _, _, equipLoc, _, price = Try(C_Item and C_Item.GetItemInfo or GetItemInfo, e.id)
		local parts = { tostring(e.id), Clean(ItemName(e.id)), "x" .. e.count }
		if e.quality then table.insert(parts, "q" .. e.quality) end
		if itemType then table.insert(parts, Clean(itemType)) end
		if equipLoc and equipLoc ~= "" and ilvl then table.insert(parts, "ilvl" .. ilvl) end
		if e.nosell then table.insert(parts, "nosell")
		elseif type(price) == "number" and price > 0 then table.insert(parts, "v" .. math.floor(price / 100) .. "s") end
		if e.bound then table.insert(parts, "bound") end
		table.insert(lines, table.concat(parts, " "))
	end
	return lines, total - used, total
end

local function BagsText()
	local lines, free, total = ItemLines(BAGS)
	return "## bags (" .. free .. " free of " .. total .. " slots; id name xcount quality type ilvl vendor-price)\n" .. table.concat(lines, "\n")
end

local function SnapshotBank()
	if not ddb then return end
	local tabs = {}
	for _, b in ipairs(BANK_TABS) do if NumSlots(b) > 0 then table.insert(tabs, b) end end
	if #tabs == 0 then return end
	local lines, free, total = ItemLines(tabs)
	local shared = {}
	for _, b in ipairs(ACCOUNT_TABS) do if NumSlots(b) > 0 then table.insert(shared, b) end end
	local sharedLines = #shared > 0 and ItemLines(shared) or nil
	ddb.bank = { t = time(), lines = lines, free = free, total = total, shared = sharedLines }
end

local function BankText()
	local b = ddb and ddb.bank
	if not b then return "## bank\n(unknown: the player has not opened the bank yet with this addon)" end
	local ago = math.floor((time() - (b.t or time())) / 60)
	local s = "## bank (" .. b.free .. " free of " .. b.total .. " slots; as of " .. ago .. " min ago" .. (open.bank and ", bank open now" or ", bank closed now") .. ")\n" .. table.concat(b.lines or {}, "\n")
	if b.shared and #b.shared > 0 then s = s .. "\n## warband bank\n" .. table.concat(b.shared, "\n") end
	return s
end

---------------------------------------------------------------------------
-- Gear, spells, bars, talents
---------------------------------------------------------------------------

local SLOTS = { "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrist", "Hands",
	"Finger1", "Finger2", "Trinket1", "Trinket2", "Back", "MainHand", "OffHand", "Ranged", "Tabard" }

local function GearText()
	local lines = {}
	for i, label in ipairs(SLOTS) do
		local link = Try(GetInventoryItemLink, "player", i)
		local id = Try(GetInventoryItemID, "player", i)
		if id then
			local ilvl = link and Try(C_Item and C_Item.GetDetailedItemLevelInfo, link)
			table.insert(lines, label .. ": " .. id .. " " .. Clean(ItemName(id)) .. (ilvl and (" ilvl" .. ilvl) or ""))
		end
	end
	return "## gear (slot: id name ilvl)\n" .. (#lines > 0 and table.concat(lines, "\n") or "(nothing equipped)")
end

local function SpellsText()
	local sb = C_SpellBook
	local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
	local SPELL = (Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell) or 1
	local lines = {}
	for line = 1, Try(sb and sb.GetNumSpellBookSkillLines) or 0 do
		local info = Try(sb.GetSpellBookSkillLineInfo, line)
		if type(info) == "table" and not info.shouldHide then
			local spells = {}
			for i = (info.itemIndexOffset or 0) + 1, (info.itemIndexOffset or 0) + (info.numSpellBookItems or 0) do
				local it = Try(sb.GetSpellBookItemInfo, i, bank)
				if type(it) == "table" and it.itemType == SPELL and it.spellID then
					local s = it.spellID .. " " .. Clean(it.name)
					if it.subName and it.subName ~= "" then s = s .. " (" .. Clean(it.subName) .. ")" end
					if it.isPassive then s = s .. " [passive]" end
					table.insert(spells, s)
				end
			end
			if #spells > 0 then table.insert(lines, Clean(info.name) .. ": " .. table.concat(spells, "; ")) end
		end
	end
	return "## spells (spellbook tab: id name; ...)\n" .. (#lines > 0 and table.concat(lines, "\n") or "(no spellbook data)")
end

local function MacroName(index)
	return (Try(GetMacroInfo, index))
end

local function BarsText()
	local lines = {}
	for slot = 1, 180 do
		if Try(HasAction, slot) then
			local kind, id = Try(GetActionInfo, slot)
			local name
			if kind == "spell" then name = Try(C_Spell and C_Spell.GetSpellName, id)
			elseif kind == "item" then name = ItemName(id)
			elseif kind == "macro" then name = MacroName(id) end
			table.insert(lines, slot .. " " .. tostring(kind) .. " " .. tostring(id) .. (name and (" " .. Clean(name)) or ""))
		end
	end
	return "## bars (slot type id name; slots 1-12 are the main bar, 13-24 its second page, 61-72 bottom left, 49-60 bottom right, 25-36 right, 37-48 right 2)\n" .. (#lines > 0 and table.concat(lines, "\n") or "(all empty)")
end

-- The active talent config: points left, then every visible node as
-- "node:entry name rank/max" with a mark for purchased and purchasable ones.
local function Traits() return C_Traits or {} end

function M.TalentConfig()
	local configID = Try(C_ClassTalents and C_ClassTalents.GetActiveConfigID)
	if not configID then return nil end
	local config = Try(Traits().GetConfigInfo, configID)
	if type(config) ~= "table" or type(config.treeIDs) ~= "table" then return nil end
	return configID, config.treeIDs
end

local function EntryName(configID, entryID)
	local entry = Try(Traits().GetEntryInfo, configID, entryID)
	local def = entry and entry.definitionID and Try(Traits().GetDefinitionInfo, entry.definitionID)
	if type(def) ~= "table" then return "entry " .. entryID end
	if def.overrideName and def.overrideName ~= "" then return def.overrideName end
	return (def.spellID and Try(C_Spell and C_Spell.GetSpellName, def.spellID)) or ("entry " .. entryID)
end
M.EntryName = EntryName

local function TalentsText()
	local configID, trees = M.TalentConfig()
	if not configID then return "## talents\n(no talent tree available)" end
	local lines = {}
	for _, treeID in ipairs(trees) do
		local currency = Try(Traits().GetTreeCurrencyInfo, configID, treeID, false)
		local points = {}
		for _, c in ipairs(type(currency) == "table" and currency or {}) do
			table.insert(points, tostring(c.quantity or 0) .. " left, " .. tostring(c.spent or 0) .. " spent")
		end
		table.insert(lines, "tree " .. treeID .. (#points > 0 and (": " .. table.concat(points, " / ")) or ""))
		for _, nodeID in ipairs(Try(Traits().GetTreeNodes, treeID) or {}) do
			local n = Try(Traits().GetNodeInfo, configID, nodeID)
			if type(n) == "table" and n.isVisible ~= false and type(n.entryIDs) == "table" and #n.entryIDs > 0 then
				local mark = (n.ranksPurchased or n.currentRank or 0) > 0 and "*" or ((n.canPurchaseRank and n.isAvailable) and "+" or "")
				local names = {}
				for _, e in ipairs(n.entryIDs) do
					local chosen = n.activeEntry and n.activeEntry.entryID == e and #n.entryIDs > 1
					table.insert(names, e .. " " .. Clean(EntryName(configID, e)) .. (chosen and " (chosen)" or ""))
				end
				table.insert(lines, mark .. nodeID .. ": " .. table.concat(names, " | ") .. " " .. (n.currentRank or 0) .. "/" .. (n.maxRanks or 1))
			end
		end
	end
	return "## talents (* = has points, + = can take a point now; node: entry name | entry name ... rank/max)\n" .. table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Quests, reputation, macros
---------------------------------------------------------------------------

local function QuestsText()
	local lines, zone = {}, nil
	local ql = C_QuestLog
	for i = 1, Try(ql and ql.GetNumQuestLogEntries) or 0 do
		local q = Try(ql.GetInfo, i)
		if type(q) == "table" then
			if q.isHeader then
				zone = q.title
			elseif q.questID and not q.isHidden then
				local state = ""
				if Try(ql.IsFailed, q.questID) then state = " [failed]"
				elseif Try(ql.IsComplete, q.questID) then state = " [ready to turn in]"
				else
					local objs = {}
					for _, o in ipairs(Try(ql.GetQuestObjectives, q.questID) or {}) do
						if o.text and o.text ~= "" and not o.finished then table.insert(objs, Clean(o.text)) end
					end
					if #objs > 0 then state = " [" .. table.concat(objs, "; ") .. "]" end
				end
				if Try(ql.IsQuestTrivial, q.questID) then state = state .. " [gray]" end
				table.insert(lines, q.questID .. " L" .. tostring(q.level or "?") .. " " .. Clean(q.title) .. (zone and (" (" .. Clean(zone) .. ")") or "") .. state)
			end
		end
	end
	return "## quests (id level title (zone) [state])\n" .. (#lines > 0 and table.concat(lines, "\n") or "(empty quest log)")
end

local function ReputationText()
	local lines = {}
	local rep = C_Reputation
	for i = 1, Try(rep and rep.GetNumFactions) or 0 do
		local f = Try(rep.GetFactionDataByIndex, i)
		if type(f) == "table" and f.name and (not f.isHeader or f.isHeaderWithRep) then
			local standing = _G["FACTION_STANDING_LABEL" .. tostring(f.reaction)] or tostring(f.reaction)
			local cur = (f.currentStanding or 0) - (f.currentReactionThreshold or 0)
			local span = (f.nextReactionThreshold or 0) - (f.currentReactionThreshold or 0)
			table.insert(lines, Clean(f.name) .. ": " .. Clean(standing) .. (span > 0 and (" " .. cur .. "/" .. span) or ""))
		end
	end
	return "## reputation\n" .. (#lines > 0 and table.concat(lines, "\n") or "(none)")
end

local function MacrosText()
	local lines = {}
	local global, perChar = Try(GetNumMacros)
	local function Add(i)
		local name, _, body = Try(GetMacroInfo, i)
		if name then table.insert(lines, i .. " " .. Clean(name) .. ": " .. Clean((body or ""):gsub("\n", " / ")):sub(1, 120)) end
	end
	for i = 1, global or 0 do Add(i) end
	for i = 1, perChar or 0 do Add(120 + i) end
	return "## macros (index name: body; 1-120 account-wide, 121+ this character)\n" .. (#lines > 0 and table.concat(lines, "\n") or "(none)")
end

local BUILDERS = {
	bags = BagsText, bank = BankText, gear = GearText, spells = SpellsText, bars = BarsText,
	talents = TalentsText, quests = QuestsText, reputation = ReputationText, macros = MacrosText,
}

-- The requested kinds as one block of text that fits in maxBytes: sections in
-- order, each cut short (with a note) when it doesn't fit whole.
function M.Collect(kinds, maxBytes)
	local parts, used = {}, 0
	for _, kind in ipairs(kinds or {}) do
		local build = BUILDERS[kind]
		local ok, text = pcall(build or function() return nil end)
		if not ok then text = "## " .. kind .. "\n(could not read: " .. Clean(text) .. ")" end
		if text then
			local room = maxBytes - used - 2
			if room < 60 then
				table.insert(parts, "## " .. kind .. " (left out: no room in this message; ask again for it alone)")
				used = used + 80
			else
				if #text > room then
					local cut = text:sub(1, room - 40)
					cut = cut:match("^(.*)\n") or cut
					text = cut .. "\n(... cut short: ask for " .. kind .. " alone to get the rest)"
				end
				table.insert(parts, text)
				used = used + #text + 2
			end
		end
	end
	return table.concat(parts, "\n\n")
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local INTERACT = (Enum and Enum.PlayerInteractionType) or {}
local interactKinds = { [INTERACT.Banker or 8] = "bank", [INTERACT.Merchant or 5] = "merchant", [INTERACT.Trainer or 7] = "trainer" }

local frame = CreateFrame("Frame")
for _, ev in ipairs({ "ADDON_LOADED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "BAG_UPDATE_DELAYED",
	"MERCHANT_SHOW", "MERCHANT_CLOSED", "TRAINER_SHOW", "TRAINER_CLOSED",
	"PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
	pcall(frame.RegisterEvent, frame, ev)
end
frame:SetScript("OnEvent", function(_, event, arg)
	if event == "ADDON_LOADED" then
		if arg == "WoWAI" then
			WoWAIDataDB = type(WoWAIDataDB) == "table" and WoWAIDataDB or {}
			ddb = WoWAIDataDB
		end
	elseif event == "BANKFRAME_OPENED" then
		open.bank = true
		C_Timer.After(0.5, SnapshotBank)
	elseif event == "BANKFRAME_CLOSED" then
		if open.bank then SnapshotBank() end
		open.bank = nil
	elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "BAG_UPDATE_DELAYED" then
		if open.bank then SnapshotBank() end
	elseif event == "MERCHANT_SHOW" then open.merchant = true
	elseif event == "MERCHANT_CLOSED" then open.merchant = nil
	elseif event == "TRAINER_SHOW" then open.trainer = true
	elseif event == "TRAINER_CLOSED" then open.trainer = nil
	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
		local what = interactKinds[arg]
		if what then
			local shown = event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW"
			if what == "bank" and not shown and open.bank then SnapshotBank() end
			open[what] = shown or nil
			if what == "bank" and shown then C_Timer.After(0.5, SnapshotBank) end
		end
	end
end)
