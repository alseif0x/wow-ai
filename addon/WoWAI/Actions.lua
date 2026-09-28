-- WoWAI actions: what the agent may do in the game, from a ```wowact block (see
-- docs/ACTIONS.md). The bridge only passes on the ops below, with their
-- arguments checked. This file describes each one to the player in its own
-- words (quest, spell and item names looked up here, never taken from the
-- agent) and runs them one step at a time when the player clicks Apply, never in
-- combat. Nothing the agent writes is run as code: every op is a fixed function.

local M = {}
WoWAIActions = M

local D = WoWAIData -- GameData.lua loads first
local Try = D.Try
local unpack = unpack or table.unpack -- Lua 5.1 in game; 5.3 in the test VM

local ES = ((GetLocale and GetLocale()) or ""):match("^es") ~= nil
local function L(en, es) return ES and es or en end

local BankType = (Enum and Enum.BankType) or {}
local CHARACTER_BANK = BankType.Character or 0
local SELECTION = { [2] = true, [3] = true } -- Enum.TraitNodeType Selection, SubTreeSelection

-- Window each op needs open, and what to tell the player when it isn't.
local NEEDS = {
	sort_bank = "bank", deposit_reagents = "bank", deposit = "bank", withdraw = "bank",
	sell_junk = "merchant", sell_items = "merchant", train_all = "trainer",
}
local OPEN_HINT = {
	bank = L("open your bank and click Apply again", "abre el banco y vuelve a pulsar Aplicar"),
	merchant = L("talk to a vendor and click Apply again", "habla con un vendedor y vuelve a pulsar Aplicar"),
	trainer = L("open the trainer and click Apply again", "abre el instructor y vuelve a pulsar Aplicar"),
}

---------------------------------------------------------------------------
-- Names and descriptions
---------------------------------------------------------------------------

local function QuestName(id)
	local t = Try(C_QuestLog and C_QuestLog.GetTitleForQuestID, id)
	return (t and t ~= "") and ("[" .. t .. "]") or (L("quest ", "misión ") .. id)
end

local function SpellName(id)
	return Try(C_Spell and C_Spell.GetSpellName, id) or (L("spell ", "hechizo ") .. id)
end

local function ItemName(id)
	local n = D.ItemName(id)
	return n and ("[" .. n .. "]") or (L("item ", "objeto ") .. id)
end

local function SlotLabel(slot)
	if slot <= 12 then return L("main bar, button ", "barra principal, botón ") .. slot end
	local bar = math.floor((slot - 1) / 12) + 1
	return L("bar ", "barra ") .. bar .. L(", button ", ", botón ") .. ((slot - 1) % 12 + 1)
end

local function List(ids, namer, max)
	local out = {}
	for i, id in ipairs(ids or {}) do
		if i > (max or 6) then
			table.insert(out, L("and ", "y ") .. (#ids - (max or 6)) .. L(" more", " más"))
			break
		end
		table.insert(out, namer(id))
	end
	return table.concat(out, ", ")
end

local function NodeName(node, entry)
	local configID = D.TalentConfig()
	if not configID then return L("talent ", "talento ") .. node end
	local n = Try((C_Traits or {}).GetNodeInfo, configID, node)
	local e = entry or (type(n) == "table" and type(n.entryIDs) == "table" and n.entryIDs[1])
	return e and D.EntryName(configID, e) or (L("talent ", "talento ") .. node)
end

local DESCRIBE = {
	sort_bags = function() return L("Sort your bags", "Ordenar las bolsas") end,
	sort_bank = function() return L("Sort your bank", "Ordenar el banco") end,
	deposit_reagents = function() return L("Deposit all reagents in the bank", "Guardar todos los materiales en el banco") end,
	deposit = function(a) return L("Put in the bank: ", "Guardar en el banco: ") .. List(a.items, ItemName) end,
	withdraw = function(a) return L("Take from the bank: ", "Sacar del banco: ") .. List(a.items, ItemName) end,
	sell_junk = function() return L("Sell the gray items", "Vender los objetos grises") end,
	sell_items = function(a) return L("Sell: ", "Vender: ") .. List(a.items, ItemName, 10) end,
	equip = function(a) return L("Equip: ", "Equipar: ") .. List(a.items, ItemName) end,
	abandon_quests = function(a) return L("Abandon: ", "Abandonar: ") .. List(a.ids, QuestName, 10) end,
	track_quests = function(a)
		local parts = {}
		if #a.add > 0 then table.insert(parts, L("Track: ", "Seguir: ") .. List(a.add, QuestName)) end
		if #a.remove > 0 then table.insert(parts, L("Stop tracking: ", "Dejar de seguir: ") .. List(a.remove, QuestName)) end
		return table.concat(parts, "; ")
	end,
	place_action = function(a)
		local parts = {}
		for i, s in ipairs(a.slots) do
			if i > 8 then table.insert(parts, L("and ", "y ") .. (#a.slots - 8) .. L(" more", " más")) break end
			local what = s.spell and SpellName(s.spell) or s.item and ItemName(s.item) or (L("macro ", "macro ") .. tostring(s.macro))
			table.insert(parts, what .. " -> " .. SlotLabel(s.slot))
		end
		return L("Action bars: ", "Barras de acción: ") .. table.concat(parts, "; ")
	end,
	clear_actions = function(a) return L("Empty action slots: ", "Vaciar botones: ") .. List(a.slots, SlotLabel, 8) end,
	create_macro = function(a)
		return L("Macro \"", "Macro \"") .. a.name .. "\": " .. a.body:gsub("\n", " / ")
	end,
	learn_talents = function(a)
		local parts = {}
		for i, n in ipairs(a.nodes) do
			if i > 10 then table.insert(parts, L("and ", "y ") .. (#a.nodes - 10) .. L(" more", " más")) break end
			table.insert(parts, NodeName(n.node, n.entry) .. ((n.ranks or 1) > 1 and (" x" .. n.ranks) or ""))
		end
		return L("Learn talents: ", "Aprender talentos: ") .. table.concat(parts, ", ")
	end,
	train_all = function() return L("Learn everything the trainer offers", "Aprender todo lo que ofrece el instructor") end,
}

function M.Describe(a)
	local f = type(a) == "table" and DESCRIBE[a.op]
	if not f then return L("Unknown action ", "Acción desconocida ") .. tostring(type(a) == "table" and a.op) end
	local ok, text = pcall(f, a)
	return ok and text or (a.op .. " (" .. tostring(text) .. ")")
end

-- Only the ops this addon knows, the same set the bridge lets through.
function M.Known(a) return type(a) == "table" and DESCRIBE[a.op] ~= nil end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------

-- Each op turns into steps run one after another (a short wait between them
-- lets the server catch up) and a line in the report.
local PLAN = {}

local function Steps(o) o.steps = o.steps or {}; return o.steps end
local function Add(o, fn, wait) table.insert(Steps(o), { fn = fn, wait = wait or 0.15 }) end

-- A step that calls one game function: counts it as done unless it errors or
-- returns false.
local function Call(o, fn, ...)
	local args, n = { ... }, select("#", ...)
	if type(fn) ~= "function" then o.fail = o.fail + 1; o.err = L("not available in this client", "no disponible en este cliente"); return false end
	local ok, res = pcall(fn, unpack(args, 1, n))
	if not ok then o.fail = o.fail + 1; o.err = tostring(res); return false end
	if res == false then o.fail = o.fail + 1; return false end
	o.done = o.done + 1
	return true
end

local function MatchingSlots(containers, ids, filter)
	local want = {}
	for _, id in ipairs(ids or {}) do want[id] = true end
	local out = {}
	for _, s in ipairs(D.Slots(containers)) do
		if (not ids or want[s.info.itemID]) and (not filter or filter(s.info)) then table.insert(out, s) end
	end
	return out
end

local function UseEach(o, slots, bankType)
	for _, s in ipairs(slots) do
		Add(o, function() Call(o, C_Container and C_Container.UseContainerItem, s.bag, s.slot, nil, bankType) end, 0.25)
	end
	if #slots == 0 then o.err = L("none found", "no había ninguno") end
end

PLAN.sort_bags = function(_, o) Add(o, function() Call(o, C_Container and C_Container.SortBags) end, 0.5) end
PLAN.sort_bank = function(_, o)
	local C = C_Container or {}
	if C.SortBank then Add(o, function() Call(o, C.SortBank, CHARACTER_BANK) end, 0.5)
	else Add(o, function() Call(o, C.SortBankBags) end, 0.5) end
end
PLAN.deposit_reagents = function(_, o) Add(o, function() Call(o, C_Bank and C_Bank.AutoDepositItemsIntoBank, CHARACTER_BANK) end, 0.5) end
PLAN.deposit = function(a, o) UseEach(o, MatchingSlots(D.BAGS, a.items), CHARACTER_BANK) end
PLAN.withdraw = function(a, o) UseEach(o, MatchingSlots(D.BANK_TABS, a.items)) end
PLAN.sell_items = function(a, o) UseEach(o, MatchingSlots(D.BAGS, a.items, function(i) return not i.hasNoValue end)) end
PLAN.sell_junk = function(_, o)
	local sellAll = C_MerchantFrame and C_MerchantFrame.SellAllJunkItems
	if sellAll then Add(o, function() Call(o, sellAll) end, 0.5); return end
	UseEach(o, MatchingSlots(D.BAGS, nil, function(i) return i.quality == 0 and not i.hasNoValue end))
end
PLAN.equip = function(a, o)
	for _, id in ipairs(a.items) do Add(o, function() Call(o, C_Item and C_Item.EquipItemByName, id) end, 0.4) end
end

PLAN.abandon_quests = function(a, o)
	local Q = C_QuestLog or {}
	for _, id in ipairs(a.ids) do
		Add(o, function()
			if not Try(Q.GetLogIndexForQuestID, id) then o.fail = o.fail + 1; o.err = L("not in your quest log", "no está en tu diario"); return end
			if Call(o, Q.SetSelectedQuest, id) then
				o.done = o.done - 1 -- only the abandon itself counts
				if Call(o, Q.SetAbandonQuest) then o.done = o.done - 1; Call(o, Q.AbandonQuest) end
			end
		end, 0.35)
	end
end
PLAN.track_quests = function(a, o)
	local Q = C_QuestLog or {}
	for _, id in ipairs(a.add) do Add(o, function() Call(o, Q.AddQuestWatch, id) end) end
	for _, id in ipairs(a.remove) do Add(o, function() Call(o, Q.RemoveQuestWatch, id) end) end
end

local function PickupFor(s)
	if s.spell then return (C_Spell and C_Spell.PickupSpell) or PickupSpell, s.spell end
	if s.item then return (C_Item and C_Item.PickupItem) or PickupItem, s.item end
	return PickupMacro, s.macro
end

PLAN.place_action = function(a, o)
	for _, s in ipairs(a.slots) do
		Add(o, function()
			Try(ClearCursor)
			local pick, what = PickupFor(s)
			Try(pick, what)
			if not Try(GetCursorInfo) then
				o.fail = o.fail + 1
				o.err = L("couldn't pick up ", "no se pudo coger ") .. (s.spell and SpellName(s.spell) or s.item and ItemName(s.item) or tostring(s.macro)) .. L(" (not known?)", " (¿no lo tienes?)")
				return
			end
			Call(o, PlaceAction, s.slot)
			Try(ClearCursor)
		end, 0.1)
	end
end
PLAN.clear_actions = function(a, o)
	for _, slot in ipairs(a.slots) do
		Add(o, function() Try(ClearCursor); Call(o, PickupAction, slot); Try(ClearCursor) end, 0.1)
	end
end

local QUESTION_MARK = 134400
local function FindMacro(name)
	local global, perChar = Try(GetNumMacros)
	for i = 1, global or 0 do if Try(GetMacroInfo, i) == name then return i end end
	for i = 121, 120 + (perChar or 0) do if Try(GetMacroInfo, i) == name then return i end end
end
PLAN.create_macro = function(a, o)
	Add(o, function()
		local icon = a.icon or QUESTION_MARK
		local index = FindMacro(a.name)
		if index then
			if not pcall(EditMacro, index, a.name, icon, a.body) then Call(o, EditMacro, index, a.name, QUESTION_MARK, a.body)
			else o.done = o.done + 1 end
		else
			if not pcall(CreateMacro, a.name, icon, a.body, a.perCharacter) then Call(o, CreateMacro, a.name, QUESTION_MARK, a.body, a.perCharacter)
			else o.done = o.done + 1 end
		end
	end, 0.2)
end

PLAN.learn_talents = function(a, o)
	local T = C_Traits or {}
	local configID = D.TalentConfig()
	if not configID then o.err = L("no talent tree", "no hay árbol de talentos"); return end
	for _, n in ipairs(a.nodes) do
		Add(o, function()
			local info = Try(T.GetNodeInfo, configID, n.node)
			if type(info) ~= "table" then o.fail = o.fail + 1; o.err = L("unknown talent ", "talento desconocido ") .. n.node; return end
			if n.entry and SELECTION[info.type] then
				Call(o, T.SetSelection, configID, n.node, n.entry, false)
			else
				for _ = 1, n.ranks or 1 do
					if not Call(o, T.PurchaseRank, configID, n.node) then
						o.err = o.err or (NodeName(n.node) .. L(": can't take a point there yet", ": todavía no se puede poner un punto ahí"))
						break
					end
				end
			end
		end, 0.1)
	end
	Add(o, function()
		if o.done == 0 then return end
		local before = o.done
		if not Call(o, T.CommitConfig, configID) then o.err = o.err or L("the game refused to apply the tree", "el juego no aceptó aplicar el árbol") end
		o.done = before
	end, 0.5)
end

PLAN.train_all = function(_, o)
	for _ = 1, 40 do
		Add(o, function()
			if o.stop then return end
			local money = Try(GetMoney) or 0
			for i = 1, Try(GetNumTrainerServices) or 0 do
				local _, _, kind = Try(GetTrainerServiceInfo, i)
				local cost = Try(GetTrainerServiceCost, i) or 0
				if kind == "available" and cost <= money then
					Call(o, BuyTrainerService, i)
					return
				end
			end
			o.stop = true
		end, 0.4)
	end
end

local running

function M.IsRunning() return running ~= nil end

local function Summary(o)
	local line = o.label
	if o.done > 0 and o.fail == 0 and not o.err then return "OK  " .. line .. (o.done > 1 and (" (" .. o.done .. ")") or "") end
	if o.done > 0 then return "OK  " .. line .. " (" .. o.done .. L(" done", " hechas") .. (o.fail > 0 and (", " .. o.fail .. L(" failed", " fallidas")) or "") .. (o.err and ("; " .. o.err) or "") .. ")" end
	return L("NO  ", "NO  ") .. line .. (o.err and (": " .. o.err) or "")
end

local function Finish(r)
	running = nil
	local lines = {}
	for _, o in ipairs(r.ops) do table.insert(lines, Summary(o)) end
	for _, p in ipairs(r.waiting) do table.insert(lines, "...  " .. M.Describe(p.action) .. ": " .. OPEN_HINT[p.need]) end
	if r.blocked then table.insert(lines, L("The game blocked: ", "El juego bloqueó: ") .. r.blocked) end
	if r.aborted then table.insert(lines, r.aborted) end
	local pending = {}
	for _, a in ipairs(r.retry) do table.insert(pending, a) end
	for _, p in ipairs(r.waiting) do table.insert(pending, p.action) end
	if r.done then r.done(lines, pending) end
end

local function NextStep()
	local r = running
	if not r then return end
	if InCombatLockdown() then
		r.aborted = L("Stopped: you entered combat. Click Apply again later for the rest.", "Parado: has entrado en combate. Vuelve a pulsar Aplicar después para el resto.")
		-- Whatever didn't run (or only partly) stays pending for another Apply.
		for i = r.opIndex, #r.ops do
			r.ops[i].err = r.ops[i].err or L("not finished (combat)", "sin terminar (combate)")
			if r.ops[i].action then table.insert(r.retry, r.ops[i].action) end
		end
		return Finish(r)
	end
	local o = r.ops[r.opIndex]
	while o and r.stepIndex >= #(o.steps or {}) do
		r.opIndex, r.stepIndex = r.opIndex + 1, 0
		o = r.ops[r.opIndex]
	end
	if not o then return Finish(r) end
	r.stepIndex = r.stepIndex + 1
	local step = o.steps[r.stepIndex]
	local ok, err = pcall(step.fn)
	if not ok then o.fail = o.fail + 1; o.err = tostring(err) end
	C_Timer.After(step.wait or 0.15, NextStep)
end

-- Run a list of actions. done(lines, pending) gets a line per action and the
-- actions that are waiting for a window (bank, vendor, trainer) to be opened.
function M.Run(actions, done)
	if running then return false, L("Already applying actions.", "Ya se están aplicando acciones.") end
	if InCombatLockdown() then return false, L("Not possible in combat.", "No se puede en combate.") end
	local r = { ops = {}, waiting = {}, retry = {}, opIndex = 1, stepIndex = 0, done = done }
	for _, a in ipairs(actions or {}) do
		local need = NEEDS[a.op]
		if not M.Known(a) then
			table.insert(r.ops, { label = M.Describe(a), done = 0, fail = 0, err = L("unknown", "desconocida") })
		elseif need and not D.IsOpen(need) then
			table.insert(r.waiting, { action = a, need = need })
		else
			local o = { label = M.Describe(a), done = 0, fail = 0, action = a }
			local ok, err = pcall(PLAN[a.op], a, o)
			if not ok then o.err = tostring(err) end
			table.insert(r.ops, o)
		end
	end
	running = r
	NextStep()
	return true
end

-- A protected call blocked mid-run is reported with the rest.
local watch = CreateFrame("Frame")
pcall(watch.RegisterEvent, watch, "ADDON_ACTION_BLOCKED")
pcall(watch.RegisterEvent, watch, "ADDON_ACTION_FORBIDDEN")
watch:SetScript("OnEvent", function(_, _, addon, func)
	if running and addon == "WoWAI" then running.blocked = tostring(func) end
end)
