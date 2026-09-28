-- WoWAI: talk to local coding agents (Claude Code, Codex, Grok) from inside WoW,
-- without reloading.
--
-- The WoW sandbox has no network and no file reads at runtime. Two doors remain open:
--
--   OUT ("pixel" mode): pending messages are drawn as a strip of colored squares in
--        the top-left corner of the screen until the bridge acknowledges them.
--        bridge.js screen-captures that corner and decodes it. Nothing touches the game.
--   IN:  load-on-demand addons read their files from disk at the moment they load.
--        The bridge writes the latest replies for every chat into a pool of pre-made
--        slot addons (WoWAI_S001..S200); we load a fresh slot from a timer.
--        Each slot is single-use per session; a /reload frees them all.
--   Fallback ("reload" mode): SavedVariables + Inbox.lua, a ReloadUI() per step.
--
-- Chats: each chat is its own agent session (like a separate terminal) with its own
-- folder, agent, history and pending message. The bridge runs them in parallel.
-- Everything here is plain addon API. No automation, no memory reading.

local ADDON_NAME = ...
local WoWAI = {}
_G.WoWAI = WoWAI
local Codec = WoWAI_Codec

local DEFAULT_CWD = "" -- empty = the bridge's configured defaultCwd
local MAX_HISTORY = 200
local MAX_CHATS = 16

local SLOT_COUNT = 200
local SLOT_PREFIX = "WoWAI_S"
local ACT_MAX = 60 -- heartbeat files per message (act/NNN/01..60.wav)
local PRESENCE_MAX = 2000 -- presence/0001..2000.wav, one flipped by the bridge every 30 s
local STRIP_TRIES = 3 -- re-show an unacknowledged message this many times before falling back
local CELL, CELLS_PER_ROW, MAX_ROWS = 4, 200, 48
local STRIP_SECONDS = 40 -- max per message; it leaves the strip as soon as the bridge acknowledges
local POLL_SCHEDULE = { 5, 10, 16, 24, 34, 46, 60, 80, 100, 130, 160, 200, 240, 300 }
local POLL_TAIL = 60
local TICK_SECONDS = 2
local CONNECT_WAIT = 15 -- seconds the Connect button waits for the bridge before giving up
local IDLE_POLL_SECONDS = 600 -- without the sound channel, spend one slot this often while idle to check the bridge
local RS, US = "\30", "\31" -- record / unit separators in the strip payload

local db
local ui = {}
-- Transport state for this UI session. outbound[id] = { chat, cwd, flags, text, sentAt, acked }
local run = { outbound = {} }

-- Shared window backdrop. Declared up here because ShowCopy (rendering section)
-- uses it too: a later `local` would be invisible there and resolve to a nil global.
local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- The assistant bubble is labelled with the agent that wrote it (see AgentName).
local ROLE_STYLE = {
	user      = { label = "You",    color = { 0.49, 0.78, 1.00 }, bg = { 0.25, 0.45, 0.75, 0.16 } },
	assistant = { label = "AI",     color = { 1.00, 0.82, 0.25 }, bg = { 0.85, 0.70, 0.30, 0.10 } },
	system    = { label = "System", color = { 0.62, 0.62, 0.62 }, bg = { 0.50, 0.50, 0.50, 0.10 } },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ToHex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- Record fields use control characters as separators, so keep them out of the wire format.
local function Wire(s)
	local value = tostring(s or "")
	return (value:gsub("[\30\31]", " "))
end

-- EditBoxes do not render UI escape sequences, so just make pipes harmless.
local function Display(s)
	return (tostring(s or ""):gsub("|", "¦"))
end

-- Text added for game data, actions and the message queue follows the client's
-- language: Spanish on esES/esMX, English otherwise.
local IS_ES = ((GetLocale and GetLocale()) or ""):match("^es") ~= nil
local function L(en, es) return IS_ES and es or en end

local function Trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function FmtDur(sec)
	sec = math.floor(sec or 0)
	if sec < 60 then return sec .. "s" end
	if sec < 3600 then return math.floor(sec / 60) .. "m" .. string.format("%02d", sec % 60) .. "s" end
	return math.floor(sec / 3600) .. "h" .. string.format("%02d", math.floor(sec / 60) % 60) .. "m"
end

-- Last path component of a folder, for labels.
local function FolderName(cwd)
	local name = tostring(cwd or ""):gsub("[\\/]+$", ""):match("([^\\/]+)$")
	return name or ""
end

-- The folder a chat works in: its own, or the bridge's default (the folder the
-- bridge was started from), which the bridge reports in every slot file.
local function ChatFolder(c)
	if c and c.cwd ~= "" then return c.cwd end
	return run.bridgeCwd or ""
end

-- Agents are named by id as the bridge knows them ("claude", "codex", "grok");
-- the bridge lists the ones it has, and its default, in every slot file. A chat
-- with no agent of its own runs on the bridge's default.
-- "jev" marks a quick order the bridge answered itself: JEV (a decision model,
-- not a chat model) recognised it, and no agent ran.
local AGENT_NAMES = { claude = "Claude", codex = "Codex", grok = "Grok", jev = (((GetLocale and GetLocale()) or ""):match("^es") and "Orden rápida" or "Quick order") }

local function AgentName(id)
	id = tostring(id or "")
	if id == "" then return "AI" end
	return AGENT_NAMES[id] or (id:sub(1, 1):upper() .. id:sub(2))
end

local function ChatAgent(c)
	if c and c.agent and c.agent ~= "" then return c.agent end
	return run.bridgeAgent or ""
end

local function ChatAgentName(c)
	return AgentName(ChatAgent(c))
end

-- The name to show on a reply: the agent the bridge says wrote it, else the chat's.
local function ReplyAgentName(c, agent)
	if agent and agent ~= "" then return AgentName(agent) end
	return ChatAgentName(c)
end

-- The model a chat runs on: one of opencodex's (the bridge lists them in every
-- slot file), "auto" (JEV picks a tier per message), or empty = the agent's own
-- default from the bridge's config.
local function ChatModelName(c)
	local m = c and c.model or ""
	if m == "" then return L("default model", "modelo por defecto") end
	if m == "auto" then return L("auto (JEV picks)", "auto (JEV decide)") end
	return m
end

-- "gpt-6-sol" for a bubble label: the provider prefix only adds width.
local function ShortModel(m)
	m = tostring(m or "")
	return (m:gsub("^[%w-]+/", ""))
end

local function Contains(list, v)
	for _, x in ipairs(list or {}) do
		if x == v then return true end
	end
	return false
end

-- First few words of a message, as a chat title.
local function AutoTitle(text)
	local words = {}
	for w in tostring(text or ""):gmatch("%S+") do
		w = w:gsub("^[%p]+", ""):gsub("[%p]+$", "")
		if w ~= "" then
			table.insert(words, w)
			if #words >= 5 then break end
		end
	end
	local title = table.concat(words, " ")
	if #title > 24 then title = title:sub(1, 24):gsub("%s+%S*$", "") end
	if title == "" then return nil end
	return title:sub(1, 1):upper() .. title:sub(2)
end

local function NewId()
	return string.format("%x%04x", time() % 0xFFFFFF, math.random(0, 0xFFFF))
end

local function FindChat(id)
	for i, c in ipairs(db.chats) do
		if c.id == id then return c, i end
	end
end

local function ActiveChat()
	return FindChat(db.activeChat)
end

local function AddChat(name, cwd)
	if #db.chats >= MAX_CHATS then return nil end
	local current = ActiveChat()
	local c = {
		id = NewId(),
		name = name or ("Chat " .. (#db.chats + 1)),
		cwd = cwd or (current and current.cwd) or DEFAULT_CWD,
		agent = (current and current.agent) or "",
		model = (current and current.model) or "",
		history = {},
		unread = 0,
		created = time(),
	}
	table.insert(db.chats, c)
	return c
end

local function AnyPending()
	for _, c in ipairs(db.chats) do
		if c.pendingId then return true end
	end
	return false
end

local function InitDB()
	WoWAIDB = WoWAIDB or {}
	db = WoWAIDB
	db.settings = db.settings or {}
	local s = db.settings
	if s.autoRefresh == nil then s.autoRefresh = true end
	if s.signal == nil then s.signal = true end
	if s.context == nil then s.context = true end -- tell the agent about the character, zone, etc.
	if s.autoApply == nil then s.autoApply = true end -- clear orders run without the Apply click
	-- How much of each reply to print in the game chat. "summary" (the agent's
	-- closing TL;DR lines) replaced "full" as the default; an install that still
	-- has the old default saved moves over once, any other choice is kept.
	if not s.echoV2 then
		s.echoV2 = true
		if s.echo == "full" then s.echo = "summary" end
	end
	s.echo = s.echo or "summary"
	s.mode = s.mode or "pixel"
	s.interval = s.interval or 20
	s.cwd = s.cwd or DEFAULT_CWD
	s.width = s.width or 780
	s.height = s.height or 500
	db.lastSeq = db.lastSeq or 0
	-- Chats deleted in game that the bridge hasn't confirmed forgetting yet.
	db.forget = db.forget or {}
	-- Identifies this counter's lifetime. If the saved data is ever reset, a new
	-- session lets the bridge tell "message #1 again" from "message #1, already done".
	if not db.session then
		db.session = string.format("%x%04x%04x", time() % 0xFFFFFF, math.random(0, 0xFFFF), math.random(0, 0xFFFF))
	end
	if not db.chats then
		-- Migrate the single-chat layout into the first chat.
		db.chats = {}
		local c = {
			id = NewId(),
			name = "Chat 1",
			cwd = s.cwd,
			history = db.history or {},
			pendingId = db.pendingId,
			unread = db.unread or 0,
			draft = db.draft,
			created = time(),
		}
		table.insert(db.chats, c)
		db.activeChat = c.id
		db.history, db.pendingId, db.unread, db.draft = nil, nil, nil, nil
	end
	if #db.chats == 0 then AddChat() end
	if not FindChat(db.activeChat) then db.activeChat = db.chats[1].id end
	-- Chats from before agents had names: replies were stored with role "claude".
	for _, c in ipairs(db.chats) do
		c.agent = c.agent or ""
		c.model = c.model or ""
		for _, m in ipairs(c.history or {}) do
			if m.role == "claude" then m.role, m.agent = "assistant", m.agent or "claude" end
		end
	end
end

-- actions: game actions a reply proposed (Actions.lua), until applied or discarded.
local function AddHistory(chat, role, text, id, denied, agent, actions, model)
	table.insert(chat.history, { role = role, text = text, id = id, t = time(), denied = denied, agent = agent, actions = actions, model = model })
	while #chat.history > MAX_HISTORY do
		table.remove(chat.history, 1)
	end
end

local function SlotName(i)
	return string.format("%s%03d", SLOT_PREFIX, i)
end

local function SlotNumber(id)
	return ((id - 1) % SLOT_COUNT) + 1
end

---------------------------------------------------------------------------
-- Reload plumbing (fallback path)
---------------------------------------------------------------------------

local function SafeReload()
	if InCombatLockdown() then
		WoWAI.reloadAfterCombat = true
		if ui.status then
			ui.status:SetText("In combat - will reload as soon as it ends")
		end
		return
	end
	ReloadUI()
end

-- ReloadUI() only works from a hardware event (a keypress or click), never from
-- a timer. So the automatic reload piggybacks on the player's own next keypress
-- once the interval has elapsed. The key still reaches the game normally.
local keyCatcher = CreateFrame("Frame", "WoWAIKeyCatcher", UIParent)
keyCatcher:Hide()
keyCatcher:EnableKeyboard(true)
keyCatcher:SetScript("OnKeyDown", function(self, key)
	if db and AnyPending() and db.settings.autoRefresh
		and GetTime() >= (WoWAI.nextAutoRefresh or 0)
		and not InCombatLockdown() then
		self:Hide()
		ReloadUI()
	end
end)

-- Arm the keypress reload. In pixel mode this is only used once the slot pool
-- is exhausted (a reload frees every slot) or the slots are not installed.
function WoWAI.ArmAutoRefresh()
	keyCatcher:Hide()
	if not AnyPending() or not db.settings.autoRefresh then return end
	if db.settings.mode == "pixel" and not (run.slotsExhausted or run.slotsMissing or run.pixelFailed) then return end
	-- Propagation can't be changed in combat. Never show the catcher without it,
	-- or it would eat every keypress. PLAYER_REGEN_ENABLED re-arms after combat.
	if not keyCatcher.propagates then
		if InCombatLockdown() or not keyCatcher.SetPropagateKeyboardInput then return end
		keyCatcher:SetPropagateKeyboardInput(true)
		keyCatcher.propagates = true
	end
	WoWAI.nextAutoRefresh = GetTime() + db.settings.interval
	keyCatcher:Show()
end

---------------------------------------------------------------------------
-- Pixel strip (out)
---------------------------------------------------------------------------

local strip
local cellPool = {}

local function EnsureStrip()
	if strip then return strip end
	strip = CreateFrame("Frame", "WoWAIStrip", UIParent)
	strip:SetFrameStrata("TOOLTIP")
	strip:SetFrameLevel(10000)
	-- Scale so that one UI unit is exactly one physical pixel (see Blizzard's PixelUtil).
	local physH = 1080
	if GetPhysicalScreenSize then
		local _, h = GetPhysicalScreenSize()
		physH = h or physH
	end
	if strip.SetIgnoreParentScale then strip:SetIgnoreParentScale(true) end
	strip:SetScale(768 / physH)
	strip:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	strip:SetSize(CELLS_PER_ROW * CELL, MAX_ROWS * CELL)
	strip:Hide()
	return strip
end

local function HideStrip()
	if strip then strip:Hide() end
	run.stripShown = nil
end

local function ShowStrip(id, payload)
	local cells = Codec.Encode(id % 65536, payload)
	local s = EnsureStrip()
	local rows = math.ceil(#cells / CELLS_PER_ROW)
	local total = rows * CELLS_PER_ROW
	for i = 1, total do
		local t = cellPool[i]
		if not t then
			t = s:CreateTexture(nil, "OVERLAY")
			t:SetSize(CELL, CELL)
			local c = (i - 1) % CELLS_PER_ROW
			local r = math.floor((i - 1) / CELLS_PER_ROW)
			t:SetPoint("TOPLEFT", s, "TOPLEFT", c * CELL, -r * CELL)
			cellPool[i] = t
		end
		local cr, cg, cb = Codec.CellColor(cells[i] or 0)
		t:SetColorTexture(cr, cg, cb, 1)
		t:Show()
	end
	for i = total + 1, #cellPool do
		cellPool[i]:Hide()
	end
	s:Show()
	run.stripShown = true
end

-- Record: session, chat, id, cwd, flags, name, [context,] text. Several records
-- per frame. The context field is only present when the flags carry "c", so the
-- bridge can tell it from a separator inside the text.
local function RecordFor(id, rec)
	local flags = Wire(rec.flags)
	local fields = { Wire(db.session), Wire(rec.chat), tostring(id), Wire(rec.cwd), flags, Wire(rec.name) }
	if rec.ctx ~= nil then
		fields[5] = flags == "" and "c" or (flags .. ";c")
		table.insert(fields, Wire(rec.ctx))
	end
	table.insert(fields, Wire(rec.text))
	return table.concat(fields, US)
end

-- Redraw the strip from every outbound message the bridge hasn't acknowledged.
local function RefreshStrip()
	local ids = {}
	for id, rec in pairs(run.outbound) do
		if not rec.acked then table.insert(ids, id) end
	end
	if #ids == 0 then
		HideStrip()
		return
	end
	table.sort(ids)
	-- Newest first; drop the oldest if the frame would overflow.
	local parts, size, latest = {}, 0, ids[#ids]
	for i = #ids, 1, -1 do
		local r = RecordFor(ids[i], run.outbound[ids[i]])
		if size + #r + 1 > Codec.MAX_PAYLOAD then break end
		table.insert(parts, 1, r)
		size = size + #r + 1
	end
	ShowStrip(latest, table.concat(parts, RS))
end

---------------------------------------------------------------------------
-- Signals and slots (in)
---------------------------------------------------------------------------

-- Optional cheap poll: an empty .wav won't play, a valid one will. The bridge
-- fills sig/NNN.wav when reply NNN is ready. Self-disables if it misbehaves.
local signalAvailable = type(PlaySoundFile) == "function"
local signalStats = { checks = 0, hits = 0, lastHit = nil }

local function SoundValid(path)
	if not signalAvailable or not db.settings.signal then return false end
	signalStats.checks = signalStats.checks + 1
	local ok, willPlay, handle = pcall(PlaySoundFile, path, "Master")
	if not ok then
		signalAvailable = false
		signalStats.error = tostring(willPlay)
		return false
	end
	if willPlay and handle then pcall(StopSound, handle) end
	if willPlay then
		signalStats.hits = signalStats.hits + 1
		signalStats.lastHit = GetTime()
	end
	return willPlay and true or false
end

local function CheckSignal(kind, id)
	if run.signalUnreliable then return false end
	return SoundValid(string.format("Interface\\AddOns\\WoWAI\\%s\\%03d.wav", kind, SlotNumber(id)))
end

-- Heartbeat: the bridge flips act/NNN/kk.wav for the k-th action of message NNN.
local function ActPath(id, k)
	return string.format("Interface\\AddOns\\WoWAI\\act\\%03d\\%02d.wav", SlotNumber(id), k)
end

local function StartActivity(chat, id)
	local a = { next = 1, count = 0, startedAt = GetTime() }
	-- The bridge can't have written anything yet, so a valid first file means the
	-- client cached this slot number's files from an earlier use: don't trust them.
	if SoundValid(ActPath(id, 1)) then a.unreliable = true end
	run.act = run.act or {}
	run.act[chat.id] = a
end

-- Returns true if the counter moved.
local function PollActivity(chat)
	local a = run.act and run.act[chat.id]
	if not a or a.unreliable or not chat.pendingId then return false end
	local moved = false
	for _ = 1, 3 do
		if a.next > ACT_MAX then break end
		if not SoundValid(ActPath(chat.pendingId, a.next)) then break end
		a.count = a.count + 1
		a.next = a.next + 1
		a.last = GetTime()
		moved = true
	end
	return moved
end

-- Bridge presence. Evidence the bridge is alive comes from several places:
-- presence beats, acks, slot data (which carries the bridge's clock), replies.
local function NotedBridge(at)
	at = at or GetTime()
	if not run.bridgeSeen or at > run.bridgeSeen then run.bridgeSeen = at end
	run.pixelFailed = nil
end

local function PresencePath(k)
	return string.format("Interface\\AddOns\\WoWAI\\presence\\%04d.wav", k)
end

-- Valid presence files form a prefix 1..k, so a binary search finds the head.
local function FindPresenceHead()
	local lo, hi = 0, PRESENCE_MAX
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if SoundValid(PresencePath(mid)) then lo = mid else hi = mid - 1 end
	end
	return lo
end

local function PollPresence()
	if not signalAvailable or not db.settings.signal then return end
	run.presence = run.presence or { last = FindPresenceHead() }
	local p = run.presence
	for _ = 1, 3 do
		local k = (p.last % PRESENCE_MAX) + 1
		if not SoundValid(PresencePath(k)) then break end
		p.last = k
		p.beats = (p.beats or 0) + 1
		NotedBridge()
	end
end

-- Whether the 30-second presence beats can reach us at all. When they can't
-- (self-test failed, or signal checks turned off), the only evidence of the
-- bridge is a slot read: the idle poll below and the replies themselves.
local function PresenceWorks()
	return signalAvailable and db ~= nil and db.settings.signal
end

-- Returns state ("ok" | "stale" | "down" | "unknown"), a color and a description.
-- With presence beats the bridge is heard from every 30 s, so 90 s of silence is
-- suspicious. Without them the addon only hears from it every IDLE_POLL_SECONDS,
-- so the windows have to be wider or the light could never stay green between
-- messages and every reply would be followed by a Reconnect.
function WoWAI.BridgeState()
	local seen = run.bridgeSeen
	if not seen then
		return "unknown", 0.6, 0.6, 0.6, "Bridge: not seen yet this session"
	end
	local age = GetTime() - seen
	local okFor, staleFor = 90, 300
	if not PresenceWorks() then
		okFor, staleFor = IDLE_POLL_SECONDS + 120, IDLE_POLL_SECONDS * 2 + 120
	end
	if age < okFor then
		return "ok", 0.2, 0.9, 0.3, "Bridge: connected (seen " .. FmtDur(age) .. " ago)"
	elseif age < staleFor then
		return "stale", 0.95, 0.8, 0.2, "Bridge: last seen " .. FmtDur(age) .. " ago"
	end
	return "down", 0.9, 0.25, 0.25, "Bridge: not seen for " .. FmtDur(age) .. " - is the bridge running?"
end

-- Same icons the friends list uses for online / away / busy / offline.
local STATE_ICON = {
	ok = "Interface\\FriendsFrame\\StatusIcon-Online",
	stale = "Interface\\FriendsFrame\\StatusIcon-Away",
	down = "Interface\\FriendsFrame\\StatusIcon-DnD",
	unknown = "Interface\\FriendsFrame\\StatusIcon-Offline",
}

function WoWAI.UpdateDot()
	local state, _, _, _, tip = WoWAI.BridgeState()
	if run.pixelFailed then state = "down" end
	if not signalAvailable and signalStats.selftest then
		tip = tip .. "\n(sound-file channel unavailable: " .. signalStats.selftest .. "; using slot checks only)"
	end
	for _, dot in ipairs({ ui.dot, ui.miniDot }) do
		if dot then
			dot:SetTexture(STATE_ICON[state] or STATE_ICON.unknown)
			dot.tip = tip
		end
	end
end

-- Connected = the bridge has been seen recently. In pixel mode, sending needs this;
-- until then the Connect button takes the Send button's place. The reload
-- transport has no idea whether the bridge is there, so it never gates.
function WoWAI.IsConnected()
	if not db or db.settings.mode ~= "pixel" then return true end
	return WoWAI.BridgeState() == "ok" and not run.pixelFailed
end

-- Connect button: say hello to the bridge (it acks, refreshes the slots and
-- offers a restore), ignoring SayHello's throttle so a click always does something.
function WoWAI.Connect()
	if db.settings.mode ~= "pixel" then
		SafeReload()
		return
	end
	run.lastHelloAt = nil
	run.pixelFailed = nil
	run.connectFailed = nil
	run.connectingAt = GetTime()
	WoWAI.SayHello()
end

-- One word for the connection state, so Tick can tell when it changed.
local function ConnectionKey()
	if WoWAI.IsConnected() then return "ok" end
	if run.connectingAt then return "connecting" end
	if run.connectFailed then return "failed" end
	return WoWAI.BridgeState()
end

-- Called every tick: time out a Connect attempt, and redraw when the state flips
-- (light, button, status line, placeholder) without redrawing every tick.
function WoWAI.CheckConnection()
	if run.connectingAt then
		if WoWAI.IsConnected() then
			run.connectingAt, run.connectFailed = nil, nil
			-- A message typed while disconnected goes out now, without a second click,
			-- as long as the same chat is still in front and free.
			local queued = run.sendOnConnect
			run.sendOnConnect = nil
			local c = queued and ActiveChat()
			if c and c.id == queued.chat and not c.pendingId then
				if ui.input and Trim(ui.input:GetText() or "") == queued.text then ui.input:SetText("") end
				WoWAI.Send(queued.text, queued.allow)
			end
		elseif GetTime() - run.connectingAt > CONNECT_WAIT then
			run.connectingAt, run.connectFailed = nil, true
			run.sendOnConnect = nil -- the text is still in the box
		end
	elseif run.connectFailed and WoWAI.IsConnected() then
		run.connectFailed = nil
	end
	local key = ConnectionKey()
	if key ~= run.connKey then
		run.connKey = key
		WoWAI.Render()
	end
end

-- Swap Send and Connect depending on the state; part of UpdateStatus.
function WoWAI.UpdateConnect()
	if not ui.connect or not ui.send then return end
	local connected = WoWAI.IsConnected()
	ui.send:SetShown(connected)
	ui.connect:SetShown(not connected)
	if connected then return end
	if run.connectingAt then
		ui.connect:SetText("Connecting...")
		ui.connect:Disable()
	else
		ui.connect:SetText(WoWAI.BridgeState() == "stale" and "Reconnect" or "Connect")
		ui.connect:Enable()
	end
end

-- Prove the sound-file trick actually distinguishes empty from valid files on this
-- client before trusting it for presence, heartbeats and readiness signals.
local function SelfTestSignals()
	if not signalAvailable then
		signalStats.selftest = "PlaySoundFile missing"
		return
	end
	local emptyLooksValid = SoundValid("Interface\\AddOns\\WoWAI\\ctl\\empty.wav")
	local validLooksValid = SoundValid("Interface\\AddOns\\WoWAI\\ctl\\valid.wav")
	if emptyLooksValid then
		signalAvailable = false
		signalStats.selftest = "an empty file reports as playable"
	elseif not validLooksValid then
		signalAvailable = false
		signalStats.selftest = "a valid file reports as unplayable (files not indexed? restart WoW)"
	else
		signalStats.selftest = "passed"
	end
end

local function ActivityLine(chat)
	local a = run.act and run.act[chat.id]
	local now = GetTime()
	local started = (a and a.startedAt) or run.sentAt or now
	local s = "running " .. FmtDur(now - started)
	if a and not a.unreliable then
		s = s .. " - " .. a.count .. (a.count == 1 and " action" or " actions")
		if a.last then
			local quiet = now - a.last
			s = s .. ", last " .. FmtDur(quiet) .. " ago"
			if quiet > 120 then s = s .. " (quiet for a while - stuck? /wow-ai cancel)" end
		elseif now - started > 60 then
			s = s .. ", no activity seen yet"
		end
	end
	return s
end

local function FreeSlot()
	for i = 1, SLOT_COUNT do
		local name = SlotName(i)
		if not C_AddOns.IsAddOnLoaded(name) then
			return name
		end
	end
end

local function ScheduleNextPoll()
	local idx = (run.polls or 0) + 1
	local t = POLL_SCHEDULE[idx]
	if not t then
		t = POLL_SCHEDULE[#POLL_SCHEDULE] + POLL_TAIL * (idx - #POLL_SCHEDULE)
	end
	run.nextPollAt = (run.sentAt or GetTime()) + t
end

local Finish -- defined below

-- The bridge has read this record: whatever game context rode on it is now
-- what the bridge knows, so later messages only carry it again if it changes.
local function NoteAcked(rec)
	rec.acked = true
	if rec.ctx ~= nil then run.contextSent = rec.ctx end
end

local function MarkAcked(id)
	local rec = run.outbound[id]
	if rec and not rec.acked then
		NoteAcked(rec)
		RefreshStrip()
	end
	NotedBridge()
end

-- A voice message goes out empty; the bridge says what it heard, and that
-- replaces the "listening" placeholder in the transcript (and names the chat).
local VOICE_PREFIX = "[voz] "
local function NoteHeard(c, id, heard)
	if type(heard) ~= "string" or heard == "" then return end
	for i = #c.history, 1, -1 do
		local m = c.history[i]
		if m.id == id and m.role == "user" then
			if m.voice and m.text ~= VOICE_PREFIX .. heard then
				m.text = VOICE_PREFIX .. heard
				m.voice = nil
				if c.name:match("^Chat %d+$") then c.name = AutoTitle(heard) or c.name end
				WoWAI.RenderChatList()
			end
			return
		end
	end
end

-- Map commands a quick order (JEV) sends back: only these, whatever the bridge says.
local QUICK_MAP = { next = true, prev = true, stop = true, ore = true, herb = true }
local function RunQuickCommands(cmds)
	if type(cmds) ~= "table" or not WoWAIMap then return end
	for _, cmd in ipairs(cmds) do
		if type(cmd) == "string" and QUICK_MAP[cmd] then WoWAIMap.Command(cmd) end
	end
end

-- Dispatch a list of reply records to the chats waiting for them.
local function ApplyReplies(replies)
	local matched = false
	for _, r in ipairs(replies or {}) do
		local c = FindChat(r.chat)
		if c and c.pendingId and r.id == c.pendingId then
			matched = true
			MarkAcked(r.id)
			NoteHeard(c, r.id, r.heard)
			local denied = type(r.denied) == "table" and #r.denied > 0 and r.denied or nil
			if r.status == "done" then
				local actions = type(r.actions) == "table" and #r.actions > 0 and r.actions or nil
				local need = type(r.need) == "table" and #r.need > 0 and r.need or nil
				if r.prefetch and need then
					-- Not a reply: the bridge (JEV) saw the question needs this game data,
					-- so it goes out now and the question runs with it.
					c.pendingId = nil
					c.progress = nil
					if run.act then run.act[c.id] = nil end
					WoWAI.Render()
					C_Timer.After(0.2, function() WoWAI.SendGameData(c.id, need, true) end)
				else
					RunQuickCommands(r.cmds)
					Finish(c, "assistant", r.text or "", denied, r.agent, r.summary, actions, need, r.model, r.auto and actions ~= nil)
				end
			elseif r.status == "error" then
				Finish(c, "system", "Bridge error: " .. tostring(r.text), denied)
			elseif r.status == "working" then
				c.progress = r.text
			end
		end
	end
	return matched
end

-- The bridge keeps every chat's transcript. After the client wipes our saved data,
-- it sends them back once, addressed to our new session token.
local function ImportRestore(r)
	if type(r) ~= "table" or r.token ~= db.session or db.restored then return end
	db.restored = true
	local added = 0
	local current = ActiveChat()
	for _, rc in ipairs(r.chats or {}) do
		-- Skip chats deleted here that the bridge hasn't been told about yet.
		if type(rc) == "table" and rc.id and not FindChat(rc.id) and not db.forget[rc.id] and #db.chats < MAX_CHATS then
			local chat = {
				id = rc.id,
				name = (rc.name and rc.name ~= "") and rc.name or ("Chat " .. (#db.chats + 1)),
				cwd = rc.cwd or DEFAULT_CWD,
				agent = "",
				history = {},
				unread = 0,
				created = time(),
			}
			for _, m in ipairs(rc.messages or {}) do
				local role, agent = m.role, m.agent
				if role == "claude" then role, agent = "assistant", agent or "claude" end -- an older bridge's transcript
				if agent == "" then agent = nil end
				table.insert(chat.history, { role = role, text = m.text, id = m.id, t = m.t, agent = agent })
			end
			-- Keep the chat we're currently using last so it stays where it was.
			table.insert(db.chats, math.max(1, #db.chats), chat)
			added = added + 1
		end
	end
	run.restoring = nil
	if added > 0 then
		if current and #current.history <= 2 then
			for _, ch in ipairs(db.chats) do
				if ch ~= current and ch.name == current.name then current.name = "New chat" end
			end
		end
		AddHistory(current, "system", "Restored " .. added .. " chat(s) from the bridge after the game reset the saved data.")
		WoWAI.RenderChatList()
	end
end

local function TryLoadSlot(why)
	local name = FreeSlot()
	if not name then
		run.slotsExhausted = true
		WoWAI.ArmAutoRefresh()
		WoWAI.UpdateStatus()
		return
	end
	WoWAI_SlotData = nil
	local loaded, reason = C_AddOns.LoadAddOn(name)
	if not loaded then
		run.slotError = reason
		if reason == "MISSING" or reason == "DISABLED" then
			run.slotsMissing = true
			WoWAI.ArmAutoRefresh()
		end
		WoWAI.UpdateStatus()
		return
	end
	run.polls = (run.polls or 0) + 1
	ScheduleNextPoll()
	local data = WoWAI_SlotData
	if type(data) == "table" and type(data.now) == "number" then
		-- The bridge's clock and ours are the same machine; translate to GetTime().
		NotedBridge(GetTime() - (time() - data.now))
	end
	if type(data) == "table" and type(data.cwd) == "string" and data.cwd ~= "" then run.bridgeCwd = data.cwd end
	if type(data) == "table" then
		if type(data.agent) == "string" and data.agent ~= "" then run.bridgeAgent = data.agent end
		if type(data.agents) == "table" and #data.agents > 0 then run.bridgeAgents = data.agents end
		if type(data.models) == "table" then run.bridgeModels = data.models end
		if data.voice ~= nil then run.bridgeVoice = data.voice and true or false end
	end
	local matched = ApplyReplies(type(data) == "table" and data.replies or nil)
	if type(data) == "table" and data.restore then ImportRestore(data.restore) end
	if type(data) == "table" and data.map and WoWAIMap then WoWAIMap.Sync(data.map) end
	if why == "signal" and not matched then
		run.signalUnreliable = true
	end
	WoWAI.Render()
end

local function Tick()
	if not db then return end
	local now = GetTime()
	PollPresence()
	-- Without presence beats, the only evidence is a slot read; spend one every
	-- IDLE_POLL_SECONDS while idle so the light still reflects reality (and stays
	-- green while the bridge is up: BridgeState allows for this interval).
	if not PresenceWorks() and db.settings.mode == "pixel" and not AnyPending()
		and now - (run.lastIdlePoll or -1e9) >= IDLE_POLL_SECONDS then
		run.lastIdlePoll = now
		TryLoadSlot("idle")
	end
	WoWAI.UpdateDot()
	WoWAI.CheckConnection()
	if db.settings.mode ~= "pixel" then return end
	local changed = false
	if run.helloPollAt and now >= run.helloPollAt then
		run.helloPollAt = nil
		TryLoadSlot("hello")
		-- Whatever that slot held, the wait is over.
		if run.restoring then
			run.restoring = nil
			WoWAI.Render()
		end
	end
	if run.restoring and now - run.restoring > 25 then
		run.restoring = nil
		WoWAI.Render()
	end
	for id, rec in pairs(run.outbound) do
		if not rec.acked and CheckSignal("ack", id) then
			NoteAcked(rec)
			changed = true
			NotedBridge()
		end
		-- A hello only needs the bridge to have been seen; it never escalates.
		-- A forget is the same, but the bridge must have been seen a moment after
		-- the record went up, so it had a chance to read it.
		if (rec.hello or rec.forget or rec.control) and not rec.acked and run.bridgeSeen and run.bridgeSeen >= rec.sentAt + ((rec.forget or rec.control) and 2 or 0) then
			NoteAcked(rec)
			changed = true
		end
		if rec.acked then
			if rec.forget then db.forget[rec.forget] = nil end
			run.outbound[id] = nil
			changed = true
		elseif (rec.hello or rec.control) and now - rec.sentAt >= (rec.control and 8 or 20) then
			run.outbound[id] = nil
			changed = true
		elseif now - rec.sentAt >= STRIP_SECONDS then
			rec.tries = (rec.tries or 1) + 1
			if rec.tries <= STRIP_TRIES then
				-- Nobody picked it up: show it again.
				rec.sentAt = now
				changed = true
			elseif rec.forget then
				-- The bridge is away; db.forget keeps it for the next hello.
				run.outbound[id] = nil
				changed = true
			else
				-- Give up on pixels for this message; the reload path still has it.
				run.outbound[id] = nil
				run.pixelFailed = true
				changed = true
				WoWAI.ArmAutoRefresh()
			end
		end
	end
	if changed then
		RefreshStrip()
		WoWAI.UpdateStatus()
	end
	if not AnyPending() then return end
	local moved = false
	for _, c in ipairs(db.chats) do
		if c.pendingId and PollActivity(c) then moved = true end
	end
	if moved then WoWAI.Render() end
	for _, c in ipairs(db.chats) do
		if c.pendingId and CheckSignal("sig", c.pendingId) then
			TryLoadSlot("signal")
			return
		end
	end
	if run.nextPollAt and now >= run.nextPollAt then
		TryLoadSlot("schedule")
	end
end

-- Pull whatever bridge.js last wrote into Inbox.lua (the reload path).
local function ProcessInbox()
	local inbox = WoWAI_Inbox
	if type(inbox) ~= "table" then return end
	if type(inbox.cwd) == "string" and inbox.cwd ~= "" then run.bridgeCwd = inbox.cwd end
	if type(inbox.agent) == "string" and inbox.agent ~= "" then run.bridgeAgent = inbox.agent end
	if type(inbox.agents) == "table" and #inbox.agents > 0 then run.bridgeAgents = inbox.agents end
	if type(inbox.models) == "table" then run.bridgeModels = inbox.models end
	if inbox.voice ~= nil then run.bridgeVoice = inbox.voice and true or false end
	ApplyReplies(inbox.replies)
	if inbox.restore then ImportRestore(inbox.restore) end
	if inbox.map and WoWAIMap then WoWAIMap.Sync(inbox.map) end
end

-- Messages typed while a chat was waiting (chat.queue): the next one goes out as
-- soon as the chat is free. One that can't be sent (too long) is dropped with a
-- note and the next one is tried.
local QUEUE_MAX = 10
local function SendNextQueued(chat)
	while chat.queue and #chat.queue > 0 and not chat.pendingId and WoWAI.IsConnected() do
		local q = table.remove(chat.queue, 1)
		WoWAI.Send(q.text, q.allow, { chat = chat.id })
	end
	WoWAI.Render()
end

Finish = function(chat, role, text, denied, agent, summary, actions, need, model, auto)
	AddHistory(chat, role, text, chat.pendingId, denied, agent, actions, model ~= "" and model or nil)
	-- The bridge (JEV) judged these actions plainly asked for: apply them without
	-- the click, unless the player turned that off (/wow-ai autoapply off).
	if auto and actions and db.settings.autoApply ~= false then
		chat.history[#chat.history].auto = true
		local chatId = chat.id
		C_Timer.After(0.4, function() WoWAI.ApplyActions(chatId, true) end)
	end
	chat.pendingId = nil
	chat.progress = nil
	if run.act then run.act[chat.id] = nil end
	if db.activeChat == chat.id then run.userScrolled = nil end
	NotedBridge()
	local visible = ui.frame and ui.frame:IsShown() and db.activeChat == chat.id
	if not visible then
		chat.unread = (chat.unread or 0) + 1
	end
	if not AnyPending() then
		keyCatcher:Hide()
	end
	if visible and ui.input and chat.draft and chat.draft ~= "" then
		ui.input:SetText(chat.draft)
		chat.draft = nil
	end
	WoWAI.Render()
	WoWAI.Notify(chat, text, agent, summary)
	-- The agent asked for game data (```wowdata): answer with it on our own. The
	-- queue carries on after that exchange.
	if need then
		C_Timer.After(0.5, function() WoWAI.SendGameData(chat.id, need) end)
	elseif chat.queue and #chat.queue > 0 then
		-- A reply that waits for the player (Apply/Discard, Allow) pauses the queue, so
		-- the next reply doesn't bury its buttons.
		if actions or denied then
			AddHistory(chat, "system", L("Queue paused (" .. #chat.queue .. " waiting): apply or discard the actions, or allow, and it carries on. /wow-ai queue send to go on anyway.",
				"Cola en pausa (" .. #chat.queue .. " esperando): aplica o descarta las acciones, o da el permiso, y seguirá. /wow-ai cola seguir para seguir igualmente."))
			WoWAI.Render()
		else
			C_Timer.After(0.3, function() SendNextQueued(chat) end)
		end
	end
end

---------------------------------------------------------------------------
-- Game context and links
---------------------------------------------------------------------------

-- The agent only sees text, so two things about the game are spelled out for it:
-- who is asking (the character, where they are; sent with the hello and again
-- when it changes, and put into the agent's system prompt by the bridge), and
-- what the player shift-clicked into the message (item, spell and quest links
-- are meaningless markup to the agent; their tooltips are what the player sees).
-- Every game API here is optional: whatever the client lacks is left out.

local CONTEXT_MAX = 900 -- bytes of context per record; the strip has ~3.2 KB for everything
local LINK_LINES_MAX = 30 -- tooltip lines kept per link
local LINK_BYTES_MAX = 900 -- bytes kept per link

-- Call a game API that may not exist or may throw, and get its returns or nothing.
local function Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c, d, e, f, g = pcall(fn, ...)
	if ok then return a, b, c, d, e, f, g end
end

local function Money(copper)
	copper = tonumber(copper) or 0
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	if g > 0 then return g .. "g " .. s .. "s " .. c .. "c" end
	if s > 0 then return s .. "s " .. c .. "c" end
	return c .. "c"
end

-- A few lines about the game and the character, as the bridge will show them to the agent.
-- Profession and secondary skill lines by skill id (vanilla ids).
local PROFESSION_SKILL_IDS = {
	[164] = true, [165] = true, [171] = true, [182] = true, [186] = true, [197] = true, [202] = true,
	[333] = true, [393] = true, [129] = true, [185] = true, [356] = true,
}

-- The character's skill lines as { name, isHeader, rank, maxRank, skillID }.
-- Forever only has C_SkillInfo (one table per line); the classic globals
-- (multiple returns) are the fallback for other clients.
function WoWAI.SkillLines()
	local out = {}
	if C_SkillInfo and C_SkillInfo.GetNumSkillLines then
		local n = Try(C_SkillInfo.GetNumSkillLines)
		local seen = {}
		for i = 1, (type(n) == "number" and n or 0) do
			local sk = Try(C_SkillInfo.GetSkillLineInfo, i)
			-- Child lines (parentSkillLineID ~= 0) repeat their parent; Blizzard's
			-- skills frame skips them too.
			if type(sk) == "table" and type(sk.name) == "string" and (sk.parentSkillLineID or 0) == 0 then
				local key = sk.isHeader and ("h:" .. sk.name) or (sk.skillID or sk.name)
				if not seen[key] then
					seen[key] = true
					out[#out + 1] = { name = sk.name, isHeader = sk.isHeader, rank = sk.rank, maxRank = sk.maxRank, skillID = sk.skillID }
				end
			end
		end
		return out
	end
	local n = Try(GetNumSkillLines)
	for i = 1, (type(n) == "number" and n or 0) do
		local sname, isHeader, _, rank, _, _, maxRank = Try(GetSkillLineInfo, i)
		if type(sname) == "string" then
			out[#out + 1] = { name = sname, isHeader = isHeader and true or false, rank = rank, maxRank = maxRank }
		end
	end
	return out
end

function WoWAI.GameContext()
	local lines = {}
	local version, build, _, toc = Try(GetBuildInfo)
	toc = tonumber(toc)
	local game = "World of Warcraft"
	if toc and toc >= 16000 and toc < 20000 then game = "World of Warcraft: Forever" end
	local client = ""
	if version then
		client = " (client " .. tostring(version) .. (build and ("." .. tostring(build)) or "") .. (toc and (", interface " .. toc) or "") .. ")"
	end
	table.insert(lines, "Game: " .. game .. client)

	local name = Try(UnitName, "player")
	if name then
		local realm = Try(GetRealmName)
		local level = Try(UnitLevel, "player")
		local race = Try(UnitRace, "player")
		local class = Try(UnitClass, "player")
		local faction = Try(UnitFactionGroup, "player")
		local guild = Try(GetGuildInfo, "player")
		local who = "Character: " .. tostring(name) .. (realm and (" on " .. tostring(realm)) or "")
		local desc = {}
		if level then table.insert(desc, "level " .. tostring(level)) end
		if race then table.insert(desc, tostring(race)) end
		if class then table.insert(desc, tostring(class)) end
		if #desc > 0 then who = who .. ", " .. table.concat(desc, " ") end
		if faction then who = who .. " (" .. tostring(faction) .. ")" end
		if guild then who = who .. ", guild <" .. tostring(guild) .. ">" end
		table.insert(lines, who)
	end

	local zone = Try(GetZoneText)
	local sub = Try(GetSubZoneText)
	if zone and zone ~= "" then
		table.insert(lines, "Location: " .. zone .. ((sub and sub ~= "" and sub ~= zone) and (" - " .. sub) or ""))
	end

	-- Map coordinates, as the minimap shows them (0-100 across the current map;
	-- addons get no world x/y/z). Modern C_Map first, the vanilla call as fallback.
	local x, y, mapName
	local mapId = Try(C_Map and C_Map.GetBestMapForUnit, "player")
	if type(mapId) == "number" then
		local pos = Try(C_Map.GetPlayerMapPosition, mapId, "player")
		if type(pos) == "table" and type(pos.x) == "number" and type(pos.y) == "number" then x, y = pos.x, pos.y end
		local info = Try(C_Map.GetMapInfo, mapId)
		if type(info) == "table" and type(info.name) == "string" then mapName = info.name end
	end
	if not x then
		local px, py = Try(GetPlayerMapPosition, "player")
		if type(px) == "number" and type(py) == "number" then x, y = px, py end
	end
	if x and y and (x > 0 or y > 0) then
		local where = (mapName and mapName ~= zone) and (" on " .. mapName) or ""
		table.insert(lines, string.format("Position: %.1f, %.1f%s%s", x * 100, y * 100, where, mapId and (" (map " .. mapId .. ")") or ""))
	end

	local progress = {}
	local copper = Try(GetMoney)
	if copper then table.insert(progress, "Money: " .. Money(copper)) end
	local xp, xpMax = Try(UnitXP, "player"), Try(UnitXPMax, "player")
	if type(xp) == "number" and type(xpMax) == "number" and xpMax > 0 then
		table.insert(progress, "XP: " .. xp .. "/" .. xpMax)
	end
	if #progress > 0 then table.insert(lines, table.concat(progress, "; ")) end

	-- Classic-style talent tabs: name, icon, points spent.
	local tabs = Try(GetNumTalentTabs)
	if type(tabs) == "number" and tabs > 0 then
		local parts = {}
		for i = 1, tabs do
			local tname, _, points = Try(GetTalentTabInfo, i)
			if type(tname) == "string" and type(points) == "number" then
				table.insert(parts, tname .. " " .. points)
			end
		end
		if #parts > 0 then table.insert(lines, "Talents: " .. table.concat(parts, " / ")) end
	end

	-- Skill lines under the Professions and Secondary Skills headers.
	local header, parts = nil, {}
	local wanted = { [TRADE_SKILLS or "Professions"] = true, [SECONDARY_SKILLS or "Secondary Skills"] = true }
	for _, sk in ipairs(WoWAI.SkillLines()) do
		if sk.isHeader then
			header = sk.name
		elseif (header and wanted[header]) or PROFESSION_SKILL_IDS[sk.skillID] then
			table.insert(parts, sk.name .. (sk.rank and (" " .. tostring(sk.rank) .. (sk.maxRank and ("/" .. tostring(sk.maxRank)) or "")) or ""))
		end
	end
	if #parts > 0 then table.insert(lines, "Professions: " .. table.concat(parts, ", ")) end

	-- Quest log ids (what is accepted, and which are done), so route planning can
	-- skip pickups and turn-ins that no longer apply.
	local quests = {}
	local qn = Try(C_QuestLog and C_QuestLog.GetNumQuestLogEntries) or Try(GetNumQuestLogEntries)
	if type(qn) == "number" then
		for i = 1, math.min(qn, 40) do
			local id, header, complete
			local info = Try(C_QuestLog and C_QuestLog.GetInfo, i)
			if type(info) == "table" then
				id, header = info.questID, info.isHeader
				complete = Try(C_QuestLog.IsComplete, id)
			else
				local _, _, _, isHeader, _, isComplete, _, qid = Try(GetQuestLogTitle, i)
				id, header, complete = qid, isHeader, isComplete == 1 or isComplete == true
			end
			if not header and type(id) == "number" and id > 0 then
				table.insert(quests, tostring(id) .. (complete and "*" or ""))
			end
		end
	end
	if #quests > 0 then table.insert(lines, "Quest log (id, * = ready to turn in): " .. table.concat(quests, ",")) end

	local s = table.concat(lines, "\n"):gsub("[\30\31]", " ")
	if #s > CONTEXT_MAX then s = s:sub(1, CONTEXT_MAX) end
	return s
end

-- The context to put on the next record, or nil when the bridge already has
-- it (or it wouldn't fit next to this message; it goes with a later one).
-- "" when the setting is off, so the bridge drops what it had.
local function ContextToSend(room)
	local ctx = db.settings.context and WoWAI.GameContext() or ""
	if ctx == (run.contextSent or "") then return nil end
	if room and #ctx > room then return nil end
	return ctx
end

-- Read a link's tooltip off a hidden GameTooltip, one line per row.
local scanTip
local function TooltipLines(payload)
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "WoWAIScanTip", UIParent, "GameTooltipTemplate")
	end
	scanTip:SetOwner(UIParent, "ANCHOR_NONE")
	scanTip:ClearLines()
	local lines = {}
	if pcall(scanTip.SetHyperlink, scanTip, payload) then
		for i = 1, math.min(scanTip:NumLines() or 0, LINK_LINES_MAX) do
			local left = _G["WoWAIScanTipTextLeft" .. i]
			local right = _G["WoWAIScanTipTextRight" .. i]
			local l = Trim(tostring((left and left:GetText()) or ""))
			local r = Trim(tostring((right and right:IsShown() and right:GetText()) or ""))
			if r ~= "" then l = l .. "  " .. r end
			if l ~= "" then table.insert(lines, l) end
		end
	end
	scanTip:Hide()
	return lines
end

-- What a link is, in words: "item 2140 (Uncommon)", "spell 1978", "quest 176".
local function DescribeLink(payload)
	local kind, id = payload:match("^(%a+):(%d+)")
	if not kind then return payload:match("^(%a+)") or "link" end
	local s = kind .. " " .. id
	if kind == "item" then
		local _, _, quality = Try((C_Item and C_Item.GetItemInfo) or GetItemInfo, payload)
		local desc = type(quality) == "number" and _G["ITEM_QUALITY" .. quality .. "_DESC"]
		if desc then s = s .. " (" .. desc .. ")" end
	end
	return s
end

-- Turn the links in a message into text the agent can use: each becomes [Name]
-- in place, and a block at the end lists what the tooltip says about it.
-- Returns the new text and the number of links found.
function WoWAI.ExpandLinks(text)
	local links, seen = {}, {}
	local function Take(payload, name)
		if not seen[payload] then
			seen[payload] = true
			table.insert(links, { payload = payload, name = name })
		end
		return "[" .. name .. "]"
	end
	-- Coloured links first (|cAARRGGBB|H...|h[Name]|h|r), then bare ones.
	local out = text:gsub("|c%x%x%x%x%x%x%x%x|H([^|]+)|h%[([^%]]*)%]|h|r", Take)
	out = out:gsub("|H([^|]+)|h%[([^%]]*)%]|h", Take)
	if #links == 0 then return text, 0 end
	local blocks = {}
	for _, l in ipairs(links) do
		local head = "[" .. l.name .. "] " .. DescribeLink(l.payload)
		local body = table.concat(TooltipLines(l.payload), "\n  ")
		local block = body ~= "" and (head .. "\n  " .. body) or head
		if #block > LINK_BYTES_MAX then block = block:sub(1, LINK_BYTES_MAX) .. "..." end
		table.insert(blocks, block)
	end
	return out .. "\n\n--- Linked from the game ---\n" .. table.concat(blocks, "\n"), #links
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- The agent and model a chat's records carry ("agent=codex;model=gpt-6-sol").
local function ChatTokens(c)
	local tokens = {}
	if c.agent and c.agent ~= "" then table.insert(tokens, "agent=" .. c.agent) end
	if c.model and c.model ~= "" then table.insert(tokens, "model=" .. c.model) end
	return tokens
end

-- allow: optional list of permission rules to grant before this message runs.
-- opts.chat: send in that chat instead of the active one; opts.display: what the
-- transcript shows instead of the text (the game data the addon sends on its own);
-- opts.data: this is such a send, not something the player typed; opts.voice: a
-- voice message: the text is empty and the bridge listens on the microphone.
function WoWAI.Send(text, allow, opts)
	opts = opts or {}
	local c = opts.chat and FindChat(opts.chat) or ActiveChat()
	if not c then return end
	text = Trim(text or "")
	if c.pendingId and opts.voice then
		AddHistory(c, "system", L("This chat is still waiting for a reply. Speak once it arrives, or switch to another chat.",
			"Este chat todavía espera una respuesta. Habla cuando llegue, o cambia a otro chat."))
		WoWAI.Render()
		return
	end
	if c.pendingId then
		if opts.data then return end -- the chat moved on; the agent can ask again
		-- Typing while waiting queues the message: it goes out after the reply.
		if text ~= "" then
			c.queue = c.queue or {}
			if #c.queue >= QUEUE_MAX then
				AddHistory(c, "system", L("The queue is full (" .. QUEUE_MAX .. " messages). Wait for a reply, or /wow-ai queue clear.",
					"La cola está llena (" .. QUEUE_MAX .. " mensajes). Espera a una respuesta, o /wow-ai cola vaciar."))
			else
				table.insert(c.queue, { text = text, allow = allow })
			end
			WoWAI.Render()
			return
		end
		-- Enter on an empty box while waiting: check for the reply.
		if db.settings.mode == "pixel" and not (run.slotsExhausted or run.slotsMissing) then
			TryLoadSlot("manual")
		else
			SafeReload()
		end
		return
	end
	if text == "" and not opts.voice then return end
	if opts.voice and not WoWAI.IsConnected() then
		AddHistory(c, "system", L("Voice needs the bridge: it is not connected. Connect first.", "La voz necesita el puente y no está conectado. Conecta primero."))
		if not run.connectingAt then WoWAI.Connect() end
		WoWAI.Render()
		return
	end
	if opts.voice and run.bridgeVoice == false then
		AddHistory(c, "system", L("The bridge has no voice set up (see docs/VOICE.md).", "El puente no tiene la voz instalada (mira docs/VOICE.md)."))
		WoWAI.Render()
		return
	end
	if not WoWAI.IsConnected() and opts.data then
		AddHistory(c, "system", "The agent asked for game data, but the bridge is not connected. Connect and ask again.")
		WoWAI.Render()
		return
	end
	if not WoWAI.IsConnected() then
		-- Not connected: the message stays in the box and we try to connect;
		-- CheckConnection sends it the moment the light turns green. If the bridge
		-- never answers, the text is still in the box for a later try.
		if ui.input then ui.input:SetText(text) end
		run.sendOnConnect = { chat = c.id, text = text, allow = allow }
		if not run.connectingAt then WoWAI.Connect() end
		WoWAI.Toggle(true)
		return
	end
	-- Shift-clicked links become [Name] plus their tooltip, which is what the agent can read.
	local links
	text, links = WoWAI.ExpandLinks(text)
	-- How the actions the player applied since the last message went ("[actions] ..."),
	-- so the agent knows what happened in the game.
	local shown = opts.display or text
	if opts.voice then shown = VOICE_PREFIX .. L("listening...", "escuchando...") end
	if c.actionReport then text = c.actionReport .. (text ~= "" and ("\n\n" .. text) or "") end
	local limit = Codec.MAX_PAYLOAD - 300
	if #text > limit then
		AddHistory(c, "system", "That message is too long for one send (" .. #text .. " chars, max ~" .. limit .. "). Split it up." .. (links > 0 and " Each linked item adds its tooltip to the message." or ""))
		WoWAI.Render()
		return
	end
	c.actionReport = nil
	-- Game data sent on the agent's request counts towards a small limit, reset by
	-- every message the player types (see WoWAI.SendGameData).
	if not opts.data then c.autoData = 0 end
	-- The game context rides along when the bridge doesn't have this version yet.
	local ctx = ContextToSend(limit - #text)

	db.lastSeq = db.lastSeq + 1
	local id = db.lastSeq
	local tokens = ChatTokens(c)
	if c.resetNext then table.insert(tokens, 1, "n") end
	if opts.voice then table.insert(tokens, "v") end
	local allowHex
	if type(allow) == "table" and #allow > 0 then
		table.insert(tokens, "allow=" .. table.concat(allow, ","))
		allowHex = ToHex(table.concat(allow, US))
	end
	local flags = table.concat(tokens, ";")
	local newSession = c.resetNext and true or nil
	c.resetNext = nil
	db.outbox = {
		id = id,
		session = db.session,
		chat = c.id,
		text = ToHex(text),
		cwd = ToHex(c.cwd),
		ctx = ctx and ToHex(ctx) or nil,
		agent = (c.agent and c.agent ~= "") and c.agent or nil,
		model = (c.model and c.model ~= "") and c.model or nil,
		allow = allowHex,
		newSession = newSession,
		t = time(),
	}
	c.pendingId = id
	c.draft = nil
	c.progress = nil
	AddHistory(c, opts.data and "system" or "user", shown, id)
	if opts.voice then c.history[#c.history].voice = true end
	run.userScrolled = nil
	-- A chat still carrying its default name takes its title from the first message
	-- you send (system notes like "/wow-ai cd" before it don't count).
	if c.name:match("^Chat %d+$") then
		local first = true
		for _, m in ipairs(c.history) do
			if m.role == "user" and m.id ~= id then first = false break end
		end
		if first and not opts.data and not opts.voice then c.name = AutoTitle(shown) or c.name end
	end
	db.settings.shown = true

	if db.settings.mode == "pixel" then
		run.outbound[id] = { chat = c.id, cwd = c.cwd, flags = flags, name = c.name, text = text, ctx = ctx, sentAt = GetTime() }
		run.sentAt = GetTime()
		run.polls = 0
		StartActivity(c, id)
		ScheduleNextPoll()
		RefreshStrip()
		WoWAI.Render()
	else
		SafeReload()
	end
end

-- Forget: a record with no text telling the bridge a chat was deleted, so it drops
-- the transcript (which a later restore would otherwise bring back) and the
-- agent session. db.forget keeps the id until the bridge acks, so a delete made
-- while the bridge was away is sent again with the next hello.
local function SendForget(chatId)
	if db.settings.mode ~= "pixel" then return end
	for _, rec in pairs(run.outbound) do
		if rec.forget == chatId and not rec.acked then return end
	end
	local info = db.forget[chatId] or {}
	db.lastSeq = db.lastSeq + 1
	run.outbound[db.lastSeq] = { chat = chatId, cwd = info.cwd or "", flags = "d", name = info.name or "", text = "", sentAt = GetTime(), forget = chatId }
	RefreshStrip()
end

local function ForgetOnBridge(c)
	if not c or not c.id then return end
	db.forget[c.id] = { name = c.name, cwd = c.cwd }
	SendForget(c.id)
end

-- Hello: a record with no text that just announces our session token. The bridge
-- acks it, offers a restore if our saved data is fresh, and refreshes the slots,
-- so the status light and any lost chats come back before the first message.
-- The game context always rides on it (empty when turned off), so the bridge's
-- copy is brought in line at every login and Connect.
function WoWAI.SayHello()
	if db.settings.mode ~= "pixel" then return end
	local now = GetTime()
	if run.lastHelloAt and now - run.lastHelloAt < 60 then return end
	run.lastHelloAt = now
	db.lastSeq = db.lastSeq + 1
	local c = ActiveChat()
	local ctx = db.settings.context and WoWAI.GameContext() or ""
	run.outbound[db.lastSeq] = { chat = c and c.id or "", cwd = c and c.cwd or "", flags = "h", name = c and c.name or "", text = "", ctx = ctx, sentAt = now, hello = true }
	run.helloPollAt = now + 5
	-- Deletions the bridge never confirmed ride along with the hello.
	for id in pairs(db.forget) do SendForget(id) end
	-- Fresh saved data: show "restoring" instead of an empty panel until we hear back.
	if not db.restored then
		local empty = true
		for _, ch in ipairs(db.chats) do
			if #ch.history > 0 then empty = false end
		end
		if empty then run.restoring = now end
	end
	RefreshStrip()
	WoWAI.Render()
end

-- Put the active chat's pending message back on the strip.
function WoWAI.Resend()
	local c = ActiveChat()
	if not c or not c.pendingId then return end
	local text
	for i = #c.history, 1, -1 do
		if c.history[i].id == c.pendingId and c.history[i].role == "user" then
			text = c.history[i].text
			break
		end
	end
	if not text then return end
	-- A voice message is not resent: the moment to speak has passed.
	if text:sub(1, #VOICE_PREFIX) == VOICE_PREFIX then return end
	run.outbound[c.pendingId] = { chat = c.id, cwd = c.cwd, flags = table.concat(ChatTokens(c), ";"), name = c.name, text = text, sentAt = GetTime() }
	run.sentAt = GetTime()
	run.polls = 0
	ScheduleNextPoll()
	RefreshStrip()
	WoWAI.UpdateStatus()
end

function WoWAI.SendFromInput()
	if not ui.input then return end
	local text = ui.input:GetText()
	ui.input:SetText("")
	ui.input:ClearFocus() -- hand the keyboard back to the game after sending
	WoWAI.Send(text)
end

-- Game data and actions (GameData.lua, Actions.lua, docs/ACTIONS.md).
local DATA_AUTO_MAX = 2 -- game data sends on the agent's request per message the player types

-- The agent asked for game data (a ```wowdata block): send it as the next message
-- of that chat, shown in the transcript as one line.
function WoWAI.SendGameData(chatId, need, prefetch)
	local c = FindChat(chatId)
	if not c or not WoWAIData or type(need) ~= "table" or #need == 0 then return end
	c.autoData = (c.autoData or 0) + 1
	if c.autoData > DATA_AUTO_MAX then
		AddHistory(c, "system", L("The agent asked for game data again; not sent this time. Type a message to carry on.",
			"La IA ha vuelto a pedir datos del juego; esta vez no se envían. Escribe un mensaje para seguir."))
		WoWAI.Render()
		return
	end
	local header = "[game data] " .. table.concat(need, ", ") .. "\n"
	-- Room for the header, and for the game context and an actions report riding along.
	local body = WoWAIData.Collect(need, Codec.MAX_PAYLOAD - 300 - #header - 500)
	WoWAI.Send(header .. body, nil, { chat = c.id, data = true,
		display = (prefetch and L("Game data the question needs (JEV), sent with it: ", "Datos del juego que necesita la pregunta (JEV), enviados con ella: ")
			or L("Game data sent to the agent: ", "Datos del juego enviados a la IA: ")) .. table.concat(need, ", ") })
end

-- The newest reply of a chat, when it proposes actions nobody applied or discarded yet.
local function PendingActions(c)
	for i = #c.history, 1, -1 do
		local m = c.history[i]
		if m.role == "assistant" then
			if type(m.actions) == "table" and #m.actions > 0 then return m, i end
			return nil
		end
	end
end

-- The Apply button (and /wow-ai apply): run the actions, note how it went in the
-- transcript and, with the next message, for the agent. Actions waiting for a
-- window (bank, vendor, trainer) stay on the reply for another Apply.
-- auto: applied without the click (a clear order, see Finish); in combat it
-- waits for combat to end, and actions that need a window wait for it to open.
function WoWAI.ApplyActions(chatId, auto)
	local c = (chatId and FindChat(chatId)) or ActiveChat()
	if not c or not WoWAIActions then return end
	local m = PendingActions(c)
	if not m then
		if not auto then
			AddHistory(c, "system", L("There are no proposed actions to apply.", "No hay acciones propuestas que aplicar."))
			WoWAI.Render()
		end
		return
	end
	if auto and InCombatLockdown() then
		if not m.combatNoted then
			m.combatNoted = true
			AddHistory(c, "system", L("A clear order, but you are in combat: it runs when combat ends (or click Apply then).",
				"Es una orden clara, pero estás en combate: se hará al salir del combate (o pulsa Aplicar entonces)."))
			WoWAI.Render()
		end
		return
	end
	if auto and WoWAIActions.IsRunning() then
		C_Timer.After(1, function() WoWAI.ApplyActions(chatId, true) end)
		return
	end
	local ok, err = WoWAIActions.Run(m.actions, function(lines, pending)
		m.actions = #pending > 0 and pending or nil
		local text = table.concat(lines, "\n")
		AddHistory(c, "system", (auto and L("Done without asking (a clear order):\n", "Hecho sin preguntar (era una orden clara):\n") or L("Actions:\n", "Acciones:\n")) .. text)
		c.actionReport = "[actions] " .. (text:gsub("\n", "; "))
		WoWAI.Render()
		-- With nothing left to apply, a paused queue carries on (with the report).
		if not m.actions then SendNextQueued(c) end
	end)
	if not ok then AddHistory(c, "system", err) end
	WoWAI.Render()
end

function WoWAI.DiscardActions(chatId)
	local c = (chatId and FindChat(chatId)) or ActiveChat()
	local m = c and PendingActions(c)
	if not m then return end
	m.actions = nil
	AddHistory(c, "system", L("Proposed actions discarded.", "Acciones propuestas descartadas."))
	c.actionReport = "[actions] the player discarded the proposed actions"
	WoWAI.Render()
	SendNextQueued(c)
end

-- The Allow button: grant the rules a reply asked for, then tell the agent to carry on.
function WoWAI.Allow(chatId, rules)
	local c = FindChat(chatId)
	if not c or c.pendingId or not rules or #rules == 0 then return end
	if db.activeChat ~= c.id then WoWAI.SwitchChat(c.id) end
	for _, m in ipairs(c.history) do m.denied = nil end
	AddHistory(c, "system", "Allowed: " .. table.concat(rules, ", "))
	WoWAI.Send("Those actions are allowed now. Continue from where you left off.", rules)
end

---------------------------------------------------------------------------
-- Chats
---------------------------------------------------------------------------

function WoWAI.SwitchChat(id)
	local c = FindChat(id)
	if not c then return end
	local prev = ActiveChat()
	if prev and prev ~= c and ui.input then
		local typed = Trim(ui.input:GetText() or "")
		prev.draft = typed ~= "" and typed or nil
	end
	db.activeChat = c.id
	c.unread = 0
	run.userScrolled = nil
	if ui.input then
		ui.input:SetText(c.draft or "")
		c.draft = nil
	end
	WoWAI.Render()
	WoWAI.RenderChatList()
end

function WoWAI.NewChat(name)
	local c = AddChat(name and name ~= "" and name or nil)
	if not c then
		local a = ActiveChat()
		AddHistory(a, "system", "Chat limit reached (" .. MAX_CHATS .. "). Delete one first with /wow-ai delete.")
		WoWAI.Render()
		return
	end
	WoWAI.SwitchChat(c.id)
	WoWAI.Toggle(true)
end

-- Folder this chat's agent works in. Empty (or "-" / "default") = the bridge's
-- default. Relative paths are resolved by the bridge against that default.
function WoWAI.SetFolder(rest, c)
	c = c or ActiveChat()
	if not c then return end
	rest = Trim(rest or "")
	if rest == "-" or rest == "default" then rest = "" end
	local base = run.bridgeCwd or "the bridge's default folder"
	if rest ~= "" then
		local changed = rest ~= c.cwd
		c.cwd = rest
		local absolute = rest:match("^%a:[\\/]") or rest:match("^[\\/~]")
		local note = absolute and "" or (" (relative to " .. base .. ")")
		AddHistory(c, "system", "cwd set to " .. rest .. note .. (changed and #c.history > 1 and ("; the next message starts a fresh " .. ChatAgentName(c) .. " session there") or ""))
	elseif c.cwd ~= "" then
		c.cwd = ""
		AddHistory(c, "system", "cwd reset to the bridge's default: " .. base)
	else
		AddHistory(c, "system", "cwd is the bridge's default: " .. base .. " (/wow-ai cd <folder>, or right-click the chat and pick Folder, to change)")
	end
	WoWAI.Render()
end

StaticPopupDialogs["WOWAI_FOLDER"] = {
	text = "Folder for this chat\n\nRelative to the bridge's folder (%s), ~, or a full path.\nEmpty = the bridge's default. Changing it starts a fresh agent session.",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = 1,
	editBoxWidth = 320,
	maxLetters = 250,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		if box then
			box:SetText(data and data.cwd or "")
			box:HighlightText()
			box:SetFocus()
		end
	end,
	OnAccept = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		local chat = data and FindChat(data.id)
		if chat and box then WoWAI.SetFolder(box:GetText(), chat) end
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		StaticPopupDialogs["WOWAI_FOLDER"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box)
		box:GetParent():Hide()
	end,
}

-- Folder dialog for a chat (the active one when no id is given).
function WoWAI.FolderPrompt(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWAI_FOLDER", run.bridgeCwd or "unknown until connected", nil, { id = c.id, cwd = c.cwd })
end

-- The agent this chat talks to, by id ("claude", "codex", "grok"). Empty (or
-- "-" / "default") = the bridge's default. The bridge starts a fresh session
-- when a chat changes agent, since a session belongs to the agent that made it.
local function AgentList()
	return run.bridgeAgents and table.concat(run.bridgeAgents, ", ") or "claude, codex, grok"
end

function WoWAI.SetAgent(rest, c)
	c = c or ActiveChat()
	if not c then return end
	rest = Trim(rest or ""):lower()
	if rest == "-" or rest == "default" then rest = "" end
	if rest ~= "" and run.bridgeAgents and not Contains(run.bridgeAgents, rest) then
		AddHistory(c, "system", "Unknown agent \"" .. rest .. "\". The bridge knows: " .. AgentList())
		WoWAI.Render()
		return
	end
	local changed = rest ~= (c.agent or "")
	c.agent = rest
	if rest ~= "" then
		AddHistory(c, "system", "agent set to " .. AgentName(rest) .. (changed and #c.history > 1 and "; the next message starts a fresh session with it" or ""))
	elseif changed then
		AddHistory(c, "system", "agent reset to the bridge's default: " .. (run.bridgeAgent and AgentName(run.bridgeAgent) or "unknown until connected"))
	else
		AddHistory(c, "system", "agent is the bridge's default: " .. (run.bridgeAgent and AgentName(run.bridgeAgent) or "unknown until connected") .. " (/wow-ai agent <name>, or right-click the chat and pick Agent, to change; agents: " .. AgentList() .. ")")
	end
	WoWAI.Render()
end

StaticPopupDialogs["WOWAI_AGENT"] = {
	text = "Agent for this chat\n\nOne of: %s.\nEmpty = the bridge's default (%s). Changing it starts a fresh session.",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = 1,
	editBoxWidth = 200,
	maxLetters = 32,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		if box then
			box:SetText(data and data.agent or "")
			box:HighlightText()
			box:SetFocus()
		end
	end,
	OnAccept = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		local chat = data and FindChat(data.id)
		if chat and box then WoWAI.SetAgent(box:GetText(), chat) end
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		StaticPopupDialogs["WOWAI_AGENT"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box)
		box:GetParent():Hide()
	end,
}

-- Agent picker for a chat (the active one when no id is given). A list of our
-- own (Picker.lua), which the gamepad can drive too; the old dialog stays as a
-- fallback. Blizzard's popups are what the gamepad UI trips over.
function WoWAI.AgentPrompt(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	if WoWAIPicker then
		local items = { { value = "", label = L("Bridge default", "El del puente") .. " (" .. (run.bridgeAgent and AgentName(run.bridgeAgent) or "?") .. ")" } }
		for _, a in ipairs(run.bridgeAgents or { "claude", "codex", "grok" }) do
			table.insert(items, { value = a, label = AgentName(a) })
		end
		WoWAIPicker.Open(L("Agent for ", "Agente para ") .. Display(c.name), items, c.agent or "", function(v) WoWAI.SetAgent(v, c) end)
		return
	end
	StaticPopup_Show("WOWAI_AGENT", AgentList(), run.bridgeAgent and AgentName(run.bridgeAgent) or "unknown until connected", { id = c.id, agent = c.agent or "" })
end

-- The model this chat runs on: one of the bridge's list (opencodex), "auto"
-- (JEV picks per message), or empty (the agent's configured default). The
-- session carries on: the next message just runs on the new model.
function WoWAI.SetModel(rest, c)
	c = c or ActiveChat()
	if not c then return end
	rest = Trim(rest or "")
	local low = rest:lower()
	if low == "-" or low == "default" or low == "defecto" then rest = "" end
	if low == "auto" then rest = "auto" end
	if rest == "" and low ~= "-" and low ~= "default" and low ~= "defecto" and c.model == "" then
		local list = run.bridgeModels and #run.bridgeModels > 0 and table.concat(run.bridgeModels, ", ")
			or L("unknown until the bridge answers (it reads them from opencodex)", "desconocidos hasta que responda el puente (los lee de opencodex)")
		AddHistory(c, "system", L("Model: ", "Modelo: ") .. ChatModelName(c) .. ". " .. L("Pick one with /ai model <name>, auto, or default. Models: ", "Elige con /ai modelo <nombre>, auto o defecto. Modelos: ") .. list)
		WoWAI.Render()
		return
	end
	if rest ~= "" and rest ~= "auto" and run.bridgeModels and #run.bridgeModels > 0 and not Contains(run.bridgeModels, rest) then
		-- A prefix is enough when it names one model: "opus-5-5", "luna--fast".
		local hit
		for _, m in ipairs(run.bridgeModels) do
			if m:lower():find(low, 1, true) then
				if hit then hit = nil break end
				hit = m
			end
		end
		if not hit then
			AddHistory(c, "system", L("Unknown model \"", "Modelo desconocido \"") .. rest .. "\". " .. L("Models: ", "Modelos: ") .. table.concat(run.bridgeModels, ", "))
			WoWAI.Render()
			return
		end
		rest = hit
	end
	c.model = rest
	AddHistory(c, "system", L("Model for this chat: ", "Modelo de este chat: ") .. ChatModelName(c))
	WoWAI.Render()
end

function WoWAI.ModelPrompt(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	if not WoWAIPicker then WoWAI.SetModel("", c) return end
	local items = {
		{ value = "", label = L("Default (the agent's own)", "Por defecto (el del agente)") },
		{ value = "auto", label = L("Auto: JEV (a decision AI) picks the model per message", "Auto: JEV (IA de decisiones) elige el modelo en cada mensaje") },
	}
	for _, m in ipairs(run.bridgeModels or {}) do table.insert(items, { value = m, label = m }) end
	if #items == 2 then
		table.insert(items, { value = nil, label = L("(no model list yet: is opencodex running?)", "(aún sin lista: ¿está opencodex en marcha?)") })
	end
	WoWAIPicker.Open(L("Model for ", "Modelo para ") .. Display(c.name), items, c.model or "", function(v) WoWAI.SetModel(v == "" and "default" or v, c) end)
end

-- Voice: ask the bridge to listen on the microphone for this chat. Hold-to-talk
-- sends VoiceStop on release, so a short phrase doesn't wait for the silence timer.
function WoWAI.Voice()
	local c = ActiveChat()
	if not c then return end
	WoWAI.Send("", nil, { voice = true })
end

function WoWAI.VoiceStop()
	if db.settings.mode ~= "pixel" then return end
	local c = ActiveChat()
	db.lastSeq = db.lastSeq + 1
	run.outbound[db.lastSeq] = { chat = c and c.id or "", cwd = "", flags = "vs", name = "", text = "", sentAt = GetTime(), control = true }
	RefreshStrip()
end

-- For Pad.lua and Picker.lua, which live in their own files.
function WoWAI.ActiveChat() return ActiveChat() end
function WoWAI.Chats() return db and db.chats or {} end
function WoWAI.Frame() return ui.frame end
function WoWAI.IsPending(c) c = c or ActiveChat() return c and c.pendingId ~= nil end
function WoWAI.HasActions(c) c = c or ActiveChat() return c and PendingActions(c) ~= nil end
-- Clear orders still waiting (for the end of combat, or a bank / vendor /
-- trainer window): try them again now.
function WoWAI.AutoApplyPending()
	if not db or db.settings.autoApply == false then return end
	for _, c in ipairs(db.chats) do
		local m = PendingActions(c)
		if m and m.auto and not c.pendingId then WoWAI.ApplyActions(c.id, true) end
	end
end

function WoWAI.HasWarnedActions(c)
	c = c or ActiveChat()
	local m = c and PendingActions(c)
	for _, a in ipairs(m and m.actions or {}) do if a.warn then return true end end
	return false
end
function WoWAI.Note(text) local c = ActiveChat() if c then AddHistory(c, "system", text) WoWAI.Render() end end
function WoWAI.ModelLabel(c) return ChatModelName(c or ActiveChat()) end
function WoWAI.L(en, es) return L(en, es) end

-- Scroll the transcript by `delta` lines' worth (negative = up), for the gamepad.
function WoWAI.ScrollBy(delta)
	local sf = ui.scroll
	if not sf then return end
	local max = sf:GetVerticalScrollRange() or 0
	local v = math.max(0, math.min(max, (sf:GetVerticalScroll() or 0) + delta * 40))
	sf:SetVerticalScroll(v)
	run.userScrolled = v < max - 2
end

-- Previous/next chat in the left panel's order, wrapping around.
function WoWAI.CycleChat(dir)
	local _, i = FindChat(db.activeChat)
	if not i or #db.chats < 2 then return end
	local n = ((i - 1 + dir) % #db.chats) + 1
	WoWAI.SwitchChat(db.chats[n].id)
end

StaticPopupDialogs["WOWAI_RENAME"] = {
	text = "Rename this chat",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = 1,
	maxLetters = 24,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		if box then
			box:SetText(data and data.name or "")
			box:HighlightText()
			box:SetFocus()
		end
	end,
	OnAccept = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		local chat = data and FindChat(data.id)
		local name = box and Trim(box:GetText() or "") or ""
		if chat and name ~= "" then
			chat.name = name:sub(1, 24)
			WoWAI.Render()
		end
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		StaticPopupDialogs["WOWAI_RENAME"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box)
		box:GetParent():Hide()
	end,
}

-- Rename dialog for a chat (the active one when no id is given).
function WoWAI.RenamePrompt(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWAI_RENAME", nil, nil, { id = c.id, name = c.name })
end
WoWAI.RenameActive = WoWAI.RenamePrompt

-- Delete a chat (the active one when no id is given). The last chat is cleared
-- and renamed instead of removed, so there is always one to type into. Either
-- way the bridge is told to forget it, so a restore won't bring it back.
function WoWAI.DeleteChat(id)
	local c, idx = nil, nil
	if id then c, idx = FindChat(id) end
	if not c then c, idx = ActiveChat() end
	if not c then return end
	ForgetOnBridge(c)
	if #db.chats == 1 then
		wipe(c.history)
		c.pendingId, c.progress, c.unread, c.draft = nil, nil, 0, nil
		c.name = "Chat 1"
		WoWAI.Render()
		WoWAI.RenderChatList()
		return
	end
	table.remove(db.chats, idx)
	if db.activeChat == c.id then
		WoWAI.SwitchChat(db.chats[math.min(idx, #db.chats)].id)
	else
		WoWAI.RenderChatList()
	end
end

-- The trash can on a chat row asks first; /wow-ai delete does not.
StaticPopupDialogs["WOWAI_DELETE"] = {
	text = "Delete chat \"%s\"?\n\nIts transcript goes away (the last chat is cleared instead of removed).",
	button1 = OKAY,
	button2 = CANCEL,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnAccept = function(dialog, data)
		if data then WoWAI.DeleteChat(data.id) end
	end,
}

function WoWAI.ConfirmDelete(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWAI_DELETE", Display(c.name), nil, { id = c.id })
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

function WoWAI.UpdateStatus()
	if not ui.status then return end
	local c = ActiveChat()
	local mode = db.settings.mode
	local s
	if c and c.pendingId then
		local id = c.pendingId
		local elapsed = run.sentAt and (GetTime() - run.sentAt) or 0
		local rec = run.outbound[id]
		if mode == "pixel" then
			if run.slotsMissing then
				s = "Reply slots not installed (run install-slots.js, restart WoW). Using reload instead: Enter or Refresh"
			elseif run.slotsExhausted then
				s = "Slot pool used up this session - next keypress reloads to free it"
			elseif run.pixelFailed then
				s = "Bridge didn't see #" .. id .. " after " .. STRIP_TRIES .. " tries - next keypress switches to the reload path (or /wow-ai reload)"
			elseif c.progress or (run.act and run.act[c.id] and run.act[c.id].count > 0) then
				s = ChatAgentName(c) .. " is working on #" .. id .. " - " .. ActivityLine(c)
			elseif rec and not rec.acked then
				s = "Sending #" .. id .. (rec.tries and rec.tries > 1 and (" (try " .. rec.tries .. "/" .. STRIP_TRIES .. ")") or "") .. "..."
				local state = WoWAI.BridgeState()
				if state == "down" then s = s .. " - bridge not seen lately, is the bridge running?" end
			else
				s = "Waiting for #" .. id .. " (checked " .. (run.polls or 0) .. "x)"
				if elapsed > 45 then
					s = s .. " - no sign of the bridge. Is the bridge running? /wow-ai resend"
				end
			end
		else
			s = "Waiting for reply #" .. id .. ". Enter or Refresh checks now"
			if db.settings.autoRefresh then
				s = s .. "; auto on next keypress after " .. db.settings.interval .. "s"
			end
		end
	elseif not WoWAI.IsConnected() then
		if run.connectingAt and run.sendOnConnect then
			s = "Connecting to the bridge... your message goes out as soon as it answers"
		elseif run.connectingAt then
			s = "Connecting to the bridge..."
		elseif run.connectFailed then
			s = "No answer from the bridge. Is it running (npm start)? Connect tries again"
		elseif WoWAI.BridgeState() == "stale" then
			s = "Bridge not seen for a while - click Reconnect"
		else
			s = "Not connected - start the bridge, then click Connect"
		end
	elseif c and c.draft and c.draft ~= "" then
		s = "Reply arrived. Your draft is back in the box - Enter to send it"
	elseif run.restoring then
		s = "Connecting to the bridge..."
	else
		s = "Ready"
	end
	ui.status:SetText(s)
	run.statusText = s
	WoWAI.UpdateDot()
	WoWAI.UpdateConnect()
	if ui.title then
		local t = c and Display(c.name) or "WoW AI"
		local folder = FolderName(ChatFolder(c))
		if folder ~= "" then t = t .. "  |cff888888" .. Display(folder) .. "|r" end
		if c and c.agent and c.agent ~= "" then t = t .. "  |cff888888" .. AgentName(c.agent) .. "|r" end
		if c and c.model and c.model ~= "" then t = t .. "  |cff888888" .. Display(ShortModel(ChatModelName(c))) .. "|r" end
		ui.title:SetText(t)
	end
	local cwdText
	if c and c.cwd ~= "" then
		cwdText = Display(c.cwd)
	elseif run.bridgeCwd then
		cwdText = Display(run.bridgeCwd) .. " (bridge default)"
	else
		cwdText = "(bridge default - start the bridge in a folder, or right-click the chat and pick Folder)"
	end
	local agentText
	if c and c.agent and c.agent ~= "" then
		agentText = AgentName(c.agent)
	elseif run.bridgeAgent then
		agentText = AgentName(run.bridgeAgent) .. " (bridge default)"
	else
		agentText = "(bridge default)"
	end
	ui.cwd:SetText("cwd: " .. cwdText .. "   agent: " .. agentText .. "   " .. L("model", "modelo") .. ": " .. Display(ChatModelName(c)) .. "   mode: " .. mode)
	if ui.modelBtn then ui.modelBtn:SetText(L("Model", "Modelo") .. ": " .. Display(ShortModel(ChatModelName(c)))) end
	if ui.talk then ui.talk:SetShown(run.bridgeVoice ~= false) end
	if ui.resend then ui.resend:SetShown(c and c.pendingId ~= nil and mode == "pixel") end
	if ui.refresh then ui.refresh:SetShown(mode ~= "pixel" or run.slotsExhausted or run.slotsMissing or run.pixelFailed or false) end
	WoWAI.UpdateMini()
end

-- One message bubble: accent bar, colored label, timestamp, wrapped body.
local function GetBubble(i)
	local b = ui.bubbles[i]
	if b then return b end
	b = CreateFrame("Frame", nil, ui.content)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.accent = b:CreateTexture(nil, "BORDER")
	b.accent:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	b.accent:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
	b.accent:SetWidth(3)
	b.who = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.who:SetPoint("TOPLEFT", b, "TOPLEFT", 10, -6)
	b.who:SetJustifyH("LEFT")
	b.when = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	b.when:SetPoint("TOPRIGHT", b, "TOPRIGHT", -8, -6)
	b.body = b:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	b.body:SetPoint("TOPLEFT", b.who, "BOTTOMLEFT", 0, -4)
	b.body:SetJustifyH("LEFT")
	b.body:SetJustifyV("TOP")
	b.body:SetWordWrap(true)
	b.body:SetNonSpaceWrap(true)
	b.allow = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
	b.allow:SetHeight(22)
	b.allow:SetPoint("TOPLEFT", b.body, "BOTTOMLEFT", 0, -6)
	b.allow:SetScript("OnClick", function(self)
		WoWAI.Allow(self.chatId, self.rules)
	end)
	b.allow:Hide()
	-- Apply / Discard for the actions a reply proposes (Actions.lua).
	b.apply = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
	b.apply:SetHeight(22)
	b.apply:SetScript("OnClick", function(self) WoWAI.ApplyActions(self.chatId) end)
	b.apply:Hide()
	b.discard = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
	b.discard:SetHeight(22)
	b.discard:SetPoint("LEFT", b.apply, "RIGHT", 6, 0)
	b.discard:SetText(L("Discard", "Descartar"))
	b.discard:SetWidth(100)
	b.discard:SetScript("OnClick", function(self) WoWAI.DiscardActions(self.chatId) end)
	b.discard:Hide()
	-- FontStrings can't be selected, so a click opens the message in the copy box.
	b:EnableMouse(true)
	b:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and self.text and self.text ~= "" then WoWAI.ShowCopy(self.text) end
	end)
	ui.bubbles[i] = b
	return b
end

function WoWAI.Render()
	local c = ActiveChat()
	if ui.content and c then
		local width = ui.scroll:GetWidth()
		if not width or width < 80 then width = 400 end
		ui.content:SetWidth(width)
		local y, n = 0, 0
		local function Place(role, text, when, dim, denied, agent, actions, model)
			n = n + 1
			local b = GetBubble(n)
			-- Proposed actions are listed in the addon's own words under the reply.
			if actions and WoWAIActions then
				local lines, warned = {}, false
				for _, a in ipairs(actions) do
					-- JEV's review (bridge) flags actions it doesn't think you asked for.
					if a.warn then warned = true end
					table.insert(lines, (a.warn and ("- (!) " .. L("not asked for? ", "¿no lo has pedido? ")) or "- ") .. WoWAIActions.Describe(a))
				end
				text = text .. "\n\n" .. L("Proposed actions (nothing happens until you click Apply):", "Acciones propuestas (no se hace nada hasta que pulses Aplicar):") .. "\n" .. table.concat(lines, "\n")
				if warned then
					text = text .. "\n" .. L("(!) JEV thinks you didn't ask for these. Check them before applying.", "(!) JEV cree que esto no lo has pedido. Revísalo antes de aplicar.")
				end
			end
			local st = ROLE_STYLE[role] or ROLE_STYLE.system
			b:SetWidth(width)
			b.bg:SetColorTexture(st.bg[1], st.bg[2], st.bg[3], st.bg[4])
			b.accent:SetColorTexture(st.color[1], st.color[2], st.color[3], 0.9)
			b.who:SetText(st == ROLE_STYLE.assistant and (ReplyAgentName(c, agent) .. ((model and model ~= "") and ("  |cff999999" .. Display(ShortModel(model)) .. "|r") or "")) or st.label)
			b.who:SetTextColor(st.color[1], st.color[2], st.color[3])
			b.when:SetText(when or "")
			b.body:SetWidth(width - 18)
			b.body:SetText(Display(text))
			if dim then
				b.body:SetTextColor(0.72, 0.72, 0.72)
			else
				b.body:SetTextColor(0.93, 0.93, 0.93)
			end
			local h = b.body:GetStringHeight()
			if not h or h < 1 then h = 14 end
			local extra = 0
			if denied then
				local label = "Allow " .. table.concat(denied, ", ") .. " & retry"
				b.allow:SetText(label)
				b.allow:SetWidth(math.min(width - 24, math.max(160, b.allow:GetFontString():GetStringWidth() + 30)))
				b.allow.chatId = c.id
				b.allow.rules = denied
				b.allow:Show()
				extra = 28
			else
				b.allow:Hide()
			end
			if actions then
				b.apply:ClearAllPoints()
				b.apply:SetPoint("TOPLEFT", b.body, "BOTTOMLEFT", 0, -6 - extra)
				b.apply:SetText(L("Apply", "Aplicar") .. " (" .. #actions .. ")")
				b.apply:SetWidth(120)
				b.apply.chatId = c.id
				b.discard.chatId = c.id
				local busy = WoWAIActions and WoWAIActions.IsRunning()
				b.apply:SetEnabled(not busy)
				b.apply:Show()
				b.discard:Show()
				extra = extra + 28
			else
				b.apply:Hide()
				b.discard:Hide()
			end
			b:SetHeight(6 + 12 + 4 + h + 8 + extra)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 0, -y)
			b.text = text
			b:Show()
			y = y + b:GetHeight() + 6
		end
		local last = #c.history
		-- Apply/Discard sit on the newest reply while it has actions left and the chat is idle.
		local _, actionsAt = PendingActions(c)
		if c.pendingId then actionsAt = nil end
		for i, m in ipairs(c.history) do
			-- The Allow button only makes sense on the newest reply, and only while idle.
			local denied = (i == last and not c.pendingId and type(m.denied) == "table" and #m.denied > 0) and m.denied or nil
			Place(m.role, m.text, m.t and date("%H:%M", m.t) or "", false, denied, m.agent, i == actionsAt and m.actions or nil, m.model)
		end
		if c.pendingId then
			local p = c.progress
			local head = "working... " .. ActivityLine(c)
			if run.statusText and run.statusText ~= "" then head = head .. "\n" .. run.statusText end
			Place("assistant", (p and p ~= "") and (head .. "\n\n" .. p) or head, "", true, nil, ChatAgent(c))
		elseif #c.history == 0 then
			if run.restoring then
				Place("system", "Connecting to the bridge and restoring your chats...", "", true)
			elseif not WoWAI.IsConnected() then
				Place("system", "Not connected to the bridge. Start it (npm start in the wow-ai folder, or wow-ai in your project), then click Connect below.", "", true)
			else
				Place("system", "Click the box below and type to start. Shift-click an item, spell or quest to link it into your message. /wow-ai help lists the commands; /ai <text> and /r work from the game chat too.", "", true)
			end
		end
		-- Messages waiting their turn (typed while this chat was busy).
		for i, q in ipairs(c.queue or {}) do
			Place("user", q.text, L("queued ", "en cola ") .. i, true)
		end
		for i = n + 1, #ui.bubbles do
			ui.bubbles[i]:Hide()
		end
		ui.content:SetHeight(math.max(y, 1))
		C_Timer.After(0.05, function()
			if ui.scroll and not run.userScrolled then
				ui.scroll:SetVerticalScroll(ui.scroll:GetVerticalScrollRange())
			end
		end)
	end
	WoWAI.UpdateStatus()
	WoWAI.RenderChatList()
end

-- Copy box (/wow-ai copy): a selectable EditBox with the last reply pre-highlighted for Ctrl+C.
function WoWAI.ShowCopy(text)
	if not ui.copy then
		local cf = CreateFrame("Frame", "WoWAICopy", UIParent, "BackdropTemplate")
		cf:SetSize(560, 320)
		cf:SetPoint("CENTER")
		cf:SetFrameStrata("FULLSCREEN_DIALOG")
		cf:SetMovable(true)
		cf:SetClampedToScreen(true)
		cf:EnableMouse(true)
		cf:RegisterForDrag("LeftButton")
		cf:SetScript("OnDragStart", cf.StartMoving)
		cf:SetScript("OnDragStop", cf.StopMovingOrSizing)
		cf:SetBackdrop(BACKDROP)
		cf:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
		cf:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
		tinsert(UISpecialFrames, "WoWAICopy")

		local t = cf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		t:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -12)
		t:SetText("Text is selected - press Ctrl+C, then Esc")

		local x = CreateFrame("Button", nil, cf, "UIPanelCloseButton")
		x:SetPoint("TOPRIGHT", cf, "TOPRIGHT", -4, -4)

		local sc = CreateFrame("ScrollFrame", "WoWAICopyScroll", cf, "UIPanelScrollFrameTemplate")
		sc:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -36)
		sc:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -32, 14)
		local eb = CreateFrame("EditBox", "WoWAICopyBox", sc)
		eb:SetMultiLine(true)
		eb:SetAutoFocus(false)
		eb:SetFontObject(ChatFontNormal)
		eb:SetMaxLetters(0)
		eb:SetSize(500, 260)
		eb:SetScript("OnEscapePressed", function() cf:Hide() end)
		sc:SetScrollChild(eb)
		sc:HookScript("OnSizeChanged", function(self, w) eb:SetWidth(w) end)
		ui.copy, ui.copyBox = cf, eb
	end
	ui.copyBox:SetText(text)
	ui.copy:Show()
	ui.copyBox:SetFocus()
	ui.copyBox:HighlightText()
end

function WoWAI.RenderChatList()
	if not ui.chatButtons then return end
	for i, btn in ipairs(ui.chatButtons) do
		local c = db.chats[i]
		if c then
			local label = Display(c.name)
			local folder = FolderName(ChatFolder(c))
			if folder ~= "" and folder:lower() ~= c.name:lower() then
				label = label .. " |cff888888" .. Display(folder) .. "|r"
			end
			if c.agent and c.agent ~= "" then
				label = label .. " |cff888888" .. AgentName(c.agent) .. "|r"
			end
			if c.pendingId then
				label = label .. " |cffffd100...|r"
			elseif (c.unread or 0) > 0 then
				label = label .. " |cff55ff55(" .. c.unread .. ")|r"
			end
			btn.label:SetText(label)
			btn.chatId = c.id
			btn.selected:SetShown(c.id == db.activeChat)
			btn:Show()
		else
			btn:Hide()
		end
	end
end

function WoWAI.UpdateMini()
	if not ui.miniBadge then return end
	local unread, working = 0, 0
	for _, c in ipairs(db.chats) do
		unread = unread + (c.unread or 0)
		if c.pendingId then working = working + 1 end
	end
	local t
	if working > 0 and unread > 0 then
		t = "|cff55ff55" .. unread .. " new|r |cffffd100" .. working .. " working|r"
	elseif working > 0 then
		t = "|cffffd100" .. (working == 1 and "working..." or (working .. " working...")) .. "|r"
	elseif unread > 0 then
		t = "|cff55ff55" .. unread .. (unread == 1 and " new reply" or " new replies") .. "|r"
	else
		t = "|cff999999idle|r"
	end
	ui.miniBadge:SetText(t)
	if ui.miniPulse then
		if unread > 0 then
			if not ui.miniPulse:IsPlaying() then ui.miniPulse:Play() end
		else
			ui.miniPulse:Stop()
			ui.miniBadge:SetAlpha(1)
		end
	end
end

local ECHO_DEFAULT = 4000 -- characters of a reply to print into the game chat ("/wow-ai echo <n>")

local function ChatLinks(chat)
	return "  |Hwowai:reply:" .. chat.id .. "|h|cff55ff55[reply]|r|h |Hwowai:open:" .. chat.id .. "|h|cff7ec8ff[open]|r|h"
end

local SUMMARY_LINES = 3 -- lines of the agent's TL;DR block printed in "summary" mode
local SUMMARY_FALLBACK_LINES = 2 -- lines of the reply shown when it came without one

-- Print a reply into the game chat: prefix on the first line, then the text line
-- by line up to the limit, then clickable links. `short` prints one preview line.
-- `summary` (the default) prints the TL;DR block the bridge split off the reply,
-- or the first lines of the reply when the agent didn't write one; the full text
-- is in the window, behind [open].
local function EchoToChat(chat, text, agent, summary)
	local mode = db.settings.echo
	if mode == "off" then return end
	local prefix = "|cff7ec8ff[" .. ReplyAgentName(chat, agent) .. " · " .. Display(chat.name) .. "]|r "
	local body = Display(text)
	if mode == "short" then
		local flat = (body:gsub("%s+", " "))
		if #flat > 200 then flat = flat:sub(1, 200) .. " ..." end
		print(prefix .. flat .. ChatLinks(chat))
		return
	end
	if mode == "summary" then
		local source, max = Display(summary or ""), SUMMARY_LINES
		if not source:match("%S") then source, max = body, SUMMARY_FALLBACK_LINES end
		local lines, total = {}, 0
		for line in (source .. "\n"):gmatch("(.-)\n") do
			if line:match("%S") then
				total = total + 1
				if total <= max then table.insert(lines, line) end
			end
		end
		for i, line in ipairs(lines) do
			print((i == 1 and prefix or "    ") .. line)
		end
		if total > max then
			print("    |cff888888... click [open] to read it all|r")
		end
		print("    " .. ChatLinks(chat):sub(3))
		return
	end
	local limit = tonumber(mode) or ECHO_DEFAULT
	local first, shown = true, 0
	for line in (body .. "\n"):gmatch("(.-)\n") do
		if line:match("%S") then
			if shown + #line > limit then
				print("    |cff888888... " .. (#body - shown) .. " more characters, click [open] to read it all|r")
				break
			end
			print((first and prefix or "    ") .. line)
			first = false
			shown = shown + #line
		end
	end
	print("    " .. ChatLinks(chat):sub(3))
end

-- A reply landed. Always play the sound and echo it to the game chat; if that
-- chat isn't on screen, also flash the screen text and light up the mini bar.
function WoWAI.Notify(chat, text, agent, summary)
	pcall(PlaySound, 3081)
	WoWAI.UpdateMini()
	-- Until a real whisper arrives, /r replies to this chat.
	run.lastMessenger = "agent"
	run.lastReplyChat = chat.id
	EchoToChat(chat, text, agent, summary)
	if ui.frame and ui.frame:IsShown() and db.activeChat == chat.id then return end
	if UIErrorsFrame then
		UIErrorsFrame:AddMessage(ReplyAgentName(chat, agent) .. " replied in " .. Display(chat.name), 0.5, 0.8, 1, 1)
	end
end

-- /r goes to the agent when it was the last one to message you, exactly like
-- whisper reply, and the box shows a "To Codex [chat]:" header while you type.
--
-- The chat type underneath is left alone (a custom type would leak into chat
-- settings); instead the box remembers an agent target, the header is repainted
-- over the game's own, and the send entry points are intercepted. Any other chat
-- type, Tab, Esc or a cleared box drops the target again.
local AGENT_R, AGENT_G, AGENT_B = 0.49, 0.78, 1.0

local function PaintAgentHeader(eb, chat)
	local header = _G[eb:GetName() .. "Header"]
	local suffix = _G[eb:GetName() .. "HeaderSuffix"]
	if not header then return end
	eb.agentPainting = true
	eb:UpdateHeader() -- lay out normally first, then repaint
	eb.agentPainting = nil
	header:SetWidth(0)
	header:SetText("To " .. ChatAgentName(chat) .. " [" .. Display(chat.name) .. "]: ")
	header:SetTextColor(AGENT_R, AGENT_G, AGENT_B)
	if suffix then suffix:Hide() end
	eb:SetTextInsets(15 + header:GetWidth(), 13, 0, 0)
	eb:SetTextColor(AGENT_R, AGENT_G, AGENT_B)
end

local function SendBoxToAgent(eb)
	local chat = FindChat(eb.agentTarget)
	local text = Trim(eb:GetText() or "")
	eb.agentTarget = nil
	eb:ClearChat()
	if chat and db.activeChat ~= chat.id then WoWAI.SwitchChat(chat.id) end
	if text ~= "" then
		WoWAI.Send(text)
	else
		WoWAI.Toggle(true)
		if ui.input then ui.input:SetFocus() end
	end
end

local function HookReplyCommand()
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local eb = _G["ChatFrame" .. i .. "EditBox"]
		if eb and eb.ProcessChatType and not eb.agentReplyHooked then
			eb.agentReplyHooked = true

			local origProcess = eb.ProcessChatType
			eb.ProcessChatType = function(self, msg, index, send, ...)
				if index ~= "REPLY" then
					self.agentTarget = nil
					return origProcess(self, msg, index, send, ...)
				end
				if not (db and run.lastMessenger == "agent") then
					return origProcess(self, msg, index, send, ...)
				end
				local chat = FindChat(run.lastReplyChat) or ActiveChat()
				if send == 1 then
					self:SetText(msg or "")
					self.agentTarget = chat and chat.id
					SendBoxToAgent(self)
					return true
				end
				self.agentTarget = chat and chat.id
				self:SetText(msg or "")
				if chat then PaintAgentHeader(self, chat) end
				return true
			end

			-- Enter arrives here; nothing below us ever sees an agent-targeted box.
			for _, name in ipairs({ "SendMessage", "SendText" }) do
				local orig = eb[name]
				if orig then
					eb[name] = function(self, ...)
						if self.agentTarget then
							SendBoxToAgent(self)
							return
						end
						return orig(self, ...)
					end
				end
			end

			-- Anything that repaints the header normally (Tab, /s, sticky reset) ends agent mode.
			hooksecurefunc(eb, "UpdateHeader", function(self)
				if not self.agentPainting then self.agentTarget = nil end
			end)
			hooksecurefunc(eb, "ClearChat", function(self)
				self.agentTarget = nil
			end)
		end
	end
end

-- Clicks on our [reply] / [open] links in the chat frame.
hooksecurefunc("SetItemRef", function(link)
	local action, chatId = tostring(link):match("^wowai:(%a+):(%w+)")
	if not action or not db then return end
	if FindChat(chatId) then WoWAI.SwitchChat(chatId) end
	WoWAI.Toggle(true)
	if action == "reply" and ui.input then ui.input:SetFocus() end
end)

-- Shift-clicking an item, spell, quest or name puts its link into the chat box
-- being typed in. Blizzard's insert function only knows its own boxes, so when
-- ours has the keyboard, take the link too. With no box focused the shift-click
-- keeps its normal meaning (splitting a stack, for one).
--
-- On this client (modern UI code, Blizzard_ChatFrameUtil) every shift-click
-- ends in ChatFrameUtil.InsertLink; ChatEdit_InsertLink is the older global
-- name, hooked only where the new one is missing so one click inserts once.
local function TakeLink(text)
	if text and text ~= "" and ui.input and ui.input:HasFocus() then
		ui.input:Insert(text)
	end
end
if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
	hooksecurefunc(ChatFrameUtil, "InsertLink", TakeLink)
elseif type(ChatEdit_InsertLink) == "function" then
	hooksecurefunc("ChatEdit_InsertLink", TakeLink)
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

local function MakeButton(parent, label, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(label)
	b:SetScript("OnClick", onClick)
	return b
end

local PANEL_W = 150

local function BuildUI()
	if ui.frame then return end
	local s = db.settings

	local f = CreateFrame("Frame", "WoWAIFrame", UIParent, "BackdropTemplate")
	ui.frame = f
	f:SetSize(s.width, s.height)
	if s.point then
		f:SetPoint(s.point, UIParent, s.relPoint or s.point, s.x or 0, s.y or 0)
	else
		f:SetPoint("CENTER")
	end
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:SetResizable(true)
	f:SetClampedToScreen(true)
	f:SetResizeBounds(560, 300)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		s.point, s.relPoint, s.x, s.y = point, relPoint, x, y
	end)
	f:SetBackdrop(BACKDROP)
	f:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
	f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	f:Hide()
	tinsert(UISpecialFrames, "WoWAIFrame")

	-- Status light: green = bridge seen recently, yellow = stale, red = gone.
	local function MakeDot(parent)
		local holder = CreateFrame("Frame", nil, parent)
		holder:SetSize(16, 16)
		local dot = holder:CreateTexture(nil, "OVERLAY")
		dot:SetAllPoints()
		dot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Offline")
		holder:EnableMouse(true)
		holder:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(dot.tip or "Bridge status", 0.9, 0.9, 0.9, 1, true)
			GameTooltip:Show()
		end)
		holder:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return holder, dot
	end

	local dotHolder, dot = MakeDot(f)
	dotHolder:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -16)
	ui.dot = dot

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("LEFT", dotHolder, "RIGHT", 6, 0)
	title:SetText("WoW AI")
	ui.title = title

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -34)
	status:SetPoint("RIGHT", f, "RIGHT", -60, 0)
	status:SetJustifyH("LEFT")
	ui.status = status

	-- Minimize button in the corner where a close X would be: this window is never
	-- closed from here, only collapsed to the mini bar (Esc does the same, see OnHide).
	-- The mini bar's own X is the one that hides everything.
	local mini
	if C_Texture and C_Texture.GetAtlasExists and C_Texture.GetAtlasExists("RedButton-MiniCondense") then
		-- Blizzard's own minimize button: the close button's chrome with a "condense" glyph.
		local ok, b = pcall(CreateFrame, "Button", nil, f, "UIPanelHideButtonNoScripts")
		if ok and b then mini = b end
	end
	if not mini then
		-- Older art: draw a dash on a plain button.
		mini = CreateFrame("Button", nil, f)
		mini:SetSize(24, 24)
		local dash = mini:CreateTexture(nil, "ARTWORK")
		dash:SetSize(10, 2)
		dash:SetPoint("CENTER", mini, "CENTER", 0, -3)
		dash:SetColorTexture(0.9, 0.9, 0.9, 1)
		local hl = mini:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.15)
	end
	mini:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
	mini:SetScript("OnClick", function() WoWAI.Minimize(true) end)
	mini:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Minimize to the small bar  (Esc)")
		GameTooltip:AddLine("The agent keeps working; the bar shows when a reply lands.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	mini:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Esc (via UISpecialFrames) just calls Hide(); treat that as a minimize unless
	-- we're hiding on purpose. Ignore hides caused by the whole UI going away.
	f:SetScript("OnHide", function()
		if ui.quitting then
			ui.quitting = nil
			return
		end
		if not db or not db.settings.shown or not UIParent:IsShown() then return end
		db.settings.minimized = true
		if ui.mini then ui.mini:Show() end
		WoWAI.UpdateMini()
	end)

	-- Left panel: chat list
	local panel = CreateFrame("Frame", nil, f, "BackdropTemplate")
	panel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -52)
	panel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 50)
	panel:SetWidth(PANEL_W)
	panel:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	panel:SetBackdropColor(0, 0, 0, 0.4)
	panel:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

	local newBtn = MakeButton(panel, "+ New chat", PANEL_W - 16, function() WoWAI.NewChat() end)
	newBtn:SetPoint("TOP", panel, "TOP", 0, -8)

	-- Per-chat menu: Rename, Folder and Agent, opened by right-clicking a chat
	-- row. A plain frame of our own rather than a Blizzard dropdown, so it looks
	-- the same on every client.
	local menu = CreateFrame("Frame", "WoWAIChatMenu", f, "BackdropTemplate")
	menu:SetSize(110, 5 * 20 + 12)
	menu:SetFrameStrata("TOOLTIP")
	menu:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	menu:SetBackdropColor(0.08, 0.08, 0.1, 0.97)
	menu:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	menu:EnableMouse(true)
	menu.title = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	menu.title:SetPoint("TOPLEFT", menu, "TOPLEFT", 10, -8)
	menu.title:SetPoint("RIGHT", menu, "RIGHT", -8, 0)
	menu.title:SetJustifyH("LEFT")
	menu.title:SetWordWrap(false)
	local function MenuItem(label, order, onClick)
		local it = CreateFrame("Button", nil, menu)
		it:SetSize(110 - 12, 20)
		it:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, -6 - order * 20)
		local hl = it:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.12)
		it.label = it:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		it.label:SetPoint("LEFT", it, "LEFT", 6, 0)
		it.label:SetText(label)
		it:SetScript("OnClick", function()
			menu:Hide()
			onClick(menu.chatId)
		end)
		return it
	end
	MenuItem("Rename...", 1, WoWAI.RenamePrompt)
	MenuItem("Folder...", 2, WoWAI.FolderPrompt)
	MenuItem("Agent...", 3, WoWAI.AgentPrompt)
	MenuItem(L("Model...", "Modelo..."), 4, WoWAI.ModelPrompt)
	-- Close once the mouse has wandered away from the menu and the row it came from.
	menu:SetScript("OnUpdate", function(self, dt)
		if not MouseIsOver then return end
		if MouseIsOver(self) or (self.owner and MouseIsOver(self.owner)) then
			self.away = 0
		else
			self.away = (self.away or 0) + dt
			if self.away > 0.5 then self:Hide() end
		end
	end)
	menu:Hide()
	ui.chatMenu = menu

	function WoWAI.ShowChatMenu(chatId, anchor)
		local c = FindChat(chatId)
		if not c then return end
		if menu:IsShown() and menu.chatId == chatId then
			menu:Hide()
			return
		end
		menu.chatId = chatId
		menu.owner = anchor
		menu.away = 0
		menu.title:SetText(Display(c.name))
		menu:ClearAllPoints()
		menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 8, 2)
		menu:Show()
	end

	ui.chatButtons = {}
	for i = 1, MAX_CHATS do
		local b = CreateFrame("Button", nil, panel)
		b:SetSize(PANEL_W - 16, 20)
		b:SetPoint("TOP", newBtn, "BOTTOM", 0, -6 - (i - 1) * 21)
		b.selected = b:CreateTexture(nil, "BACKGROUND")
		b.selected:SetAllPoints()
		b.selected:SetColorTexture(1, 1, 1, 0.12)
		b.selected:Hide()
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.08)

		-- Trash can: delete this chat (asks first). Blizzard's red delete button
		-- where the client has it, a plain X elsewhere.
		b.del = CreateFrame("Button", nil, b)
		b.del:SetSize(16, 16)
		b.del:SetPoint("RIGHT", b, "RIGHT", -2, 0)
		if C_Texture and C_Texture.GetAtlasExists and C_Texture.GetAtlasExists("128-RedButton-Delete") then
			b.del:SetNormalAtlas("128-RedButton-Delete")
			b.del:SetPushedAtlas("128-RedButton-Delete-Pressed")
			b.del:SetHighlightAtlas("128-RedButton-Delete-Highlight")
		else
			b.del:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
			b.del:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
		end
		b.del:SetAlpha(0.6)
		b.del:SetScript("OnClick", function() WoWAI.ConfirmDelete(b.chatId) end)
		b.del:SetScript("OnEnter", function(self)
			self:SetAlpha(1)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Delete this chat")
			GameTooltip:Show()
		end)
		b.del:SetScript("OnLeave", function(self)
			self:SetAlpha(0.6)
			GameTooltip:Hide()
		end)

		b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.label:SetPoint("LEFT", b, "LEFT", 6, 0)
		b.label:SetPoint("RIGHT", b.del, "LEFT", -4, 0)
		b.label:SetJustifyH("LEFT")
		b.label:SetWordWrap(false)
		-- Left-click switches to the chat; right-click opens its menu (Rename,
		-- Folder, Agent). A second right-click on the same row closes the menu again.
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				WoWAI.ShowChatMenu(self.chatId, self)
			else
				WoWAI.SwitchChat(self.chatId)
			end
		end)
		b:SetScript("OnDoubleClick", function(self)
			WoWAI.SwitchChat(self.chatId)
			WoWAI.RenamePrompt(self.chatId)
		end)
		b:Hide()
		ui.chatButtons[i] = b
	end

	-- Transcript: a scrolling stack of message bubbles
	local scroll = CreateFrame("ScrollFrame", "WoWAIScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", panel, "TOPRIGHT", 8, 0)
	scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 110)
	ui.scroll = scroll

	local content = CreateFrame("Frame", "WoWAIContent", scroll)
	content:SetSize(500, 1)
	scroll:SetScrollChild(content)
	ui.content = content
	ui.bubbles = {}
	scroll:HookScript("OnSizeChanged", function(self, w, h)
		if ui.frame:IsShown() then WoWAI.Render() end
	end)

	-- Input box, with Send docked at its right end like a messaging app.
	local SEND_W = 84
	local inputBg = CreateFrame("Frame", nil, f, "BackdropTemplate")
	inputBg:SetPoint("BOTTOMLEFT", panel, "BOTTOMRIGHT", 8, 0)
	inputBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14 - SEND_W - 6, 50)
	inputBg:SetHeight(54)
	inputBg:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	inputBg:SetBackdropColor(0, 0, 0, 0.6)
	inputBg:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

	local inScroll = CreateFrame("ScrollFrame", "WoWAIInputScroll", inputBg, "UIPanelScrollFrameTemplate")
	inScroll:SetPoint("TOPLEFT", inputBg, "TOPLEFT", 8, -6)
	inScroll:SetPoint("BOTTOMRIGHT", inputBg, "BOTTOMRIGHT", -24, 6)

	local input = CreateFrame("EditBox", "WoWAIInput", inScroll)
	input:SetMultiLine(true)
	input:SetAutoFocus(false)
	input:SetFontObject(ChatFontNormal)
	input:SetMaxLetters(0)
	input:SetSize(500, 40)
	input:SetScript("OnEnterPressed", function() WoWAI.SendFromInput() end)
	input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	inScroll:SetScrollChild(input)
	inScroll:HookScript("OnSizeChanged", function(self, w, h)
		input:SetWidth(w)
	end)
	inputBg:SetScript("OnMouseDown", function() input:SetFocus() end)
	ui.input = input

	-- Send sits to the right of the input box, vertically centred on it.
	local send = MakeButton(f, "Send", SEND_W, WoWAI.SendFromInput)
	send:SetHeight(30)
	send:SetPoint("LEFT", inputBg, "RIGHT", 6, 0)
	ui.send = send

	-- Connect stands in for Send until the bridge has been seen (see UpdateConnect).
	local connect = MakeButton(f, "Connect", SEND_W, WoWAI.Connect)
	connect:SetHeight(30)
	connect:SetPoint("LEFT", inputBg, "RIGHT", 6, 0)
	connect:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Connect to the bridge")
		GameTooltip:AddLine("The bridge must be running on this PC (npm start in wow-ai, or wow-ai in your project). The light turns green once it answers.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	connect:SetScript("OnLeave", function() GameTooltip:Hide() end)
	connect:Hide()
	ui.connect = connect

	-- Reload is the fallback transport's button; it sits apart on the right and
	-- only shows when a reload would do something (see UpdateStatus).
	local refresh = MakeButton(f, "Reload", 70, function() SafeReload() end)
	refresh:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 16)
	refresh:Hide()
	ui.refresh = refresh

	-- Bottom row: Clear, plus Resend while a message is in flight. Rename, Folder
	-- and Delete live on each chat row in the left panel.
	local clear = MakeButton(f, "Clear", 60, function()
		local c = ActiveChat()
		if c then wipe(c.history) end
		WoWAI.Render()
	end)
	clear:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 16)

	local resend = MakeButton(f, "Resend", 70, WoWAI.Resend)
	resend:SetPoint("LEFT", clear, "RIGHT", 6, 0)
	resend:Hide()
	ui.resend = resend

	-- Model picker and push-to-talk. Hold "Talk" while speaking (release stops
	-- listening at once); a click works too, the bridge stops on the silence.
	-- The model selector sits in the header, top right, like a chat app's model
	-- dropdown: it names the chat's model and opens the list (Picker.lua) on click.
	local modelBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
	modelBtn:SetSize(230, 24)
	modelBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -34, -10)
	modelBtn:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	modelBtn:SetBackdropColor(0.10, 0.10, 0.14, 0.95)
	modelBtn:SetBackdropBorderColor(1, 0.82, 0.25, 0.9)
	local mhl = modelBtn:CreateTexture(nil, "HIGHLIGHT")
	mhl:SetPoint("TOPLEFT", 3, -3)
	mhl:SetPoint("BOTTOMRIGHT", -3, 3)
	mhl:SetColorTexture(1, 0.82, 0.25, 0.15)
	local arrow = modelBtn:CreateTexture(nil, "OVERLAY")
	arrow:SetSize(14, 14)
	arrow:SetPoint("RIGHT", modelBtn, "RIGHT", -6, 0)
	arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
	local mtext = modelBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	mtext:SetPoint("LEFT", modelBtn, "LEFT", 8, 0)
	mtext:SetPoint("RIGHT", arrow, "LEFT", -4, 0)
	mtext:SetJustifyH("LEFT")
	mtext:SetWordWrap(false)
	function modelBtn:SetText(t) mtext:SetText(t) end
	modelBtn:SetScript("OnClick", function() WoWAI.ModelPrompt() end)
	modelBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText(L("Model for this chat", "Modelo de este chat"))
		GameTooltip:AddLine(L("Click to pick one from opencodex's list, or Auto (JEV picks per message).",
			"Pulsa para elegir uno de la lista de opencodex, o Auto (JEV elige en cada mensaje)."), 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	modelBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	ui.modelBtn = modelBtn
	status:SetPoint("RIGHT", modelBtn, "LEFT", -8, 0)
	title:SetPoint("RIGHT", modelBtn, "LEFT", -8, 0)
	title:SetJustifyH("LEFT")
	title:SetWordWrap(false)

	local talk = MakeButton(f, L("Talk", "Hablar"), 80, nil)
	talk:SetPoint("LEFT", resend, "RIGHT", 6, 0)
	talk:SetScript("OnMouseDown", function() talk.downAt = GetTime() WoWAI.Voice() end)
	talk:SetScript("OnMouseUp", function()
		-- A long press is push-to-talk; a quick click leaves it to the silence detector.
		if talk.downAt and GetTime() - talk.downAt > 0.6 then WoWAI.VoiceStop() end
		talk.downAt = nil
	end)
	talk:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L("Talk to the AI", "Habla con la IA"))
		GameTooltip:AddLine(L("The bridge listens on the PC's microphone: click and speak (it stops when you go quiet), or hold while you speak. /ai voice does the same, and A in gamepad mode (/ai pad).",
			"El puente escucha por el micrófono del PC: pulsa y habla (para solo cuando te callas), o mantenlo pulsado mientras hablas. /ai voz hace lo mismo, y A en el modo mando (/ai mando)."), 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	talk:SetScript("OnLeave", function() GameTooltip:Hide() end)
	ui.talk = talk

	-- A named, always-present button so a keybinding can click it (see /wow-ai bind).
	local hotkey = CreateFrame("Button", "WoWAIRefreshButton", UIParent)
	hotkey:SetSize(1, 1)
	hotkey:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
	hotkey:SetScript("OnClick", function()
		local c = ActiveChat()
		if c and c.pendingId then
			WoWAI.Send("")
		else
			WoWAI.Toggle()
		end
	end)

	local cwd = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	cwd:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 4)
	cwd:SetPoint("RIGHT", f, "RIGHT", -30, 0)
	cwd:SetJustifyH("LEFT")
	cwd:SetWordWrap(false)
	ui.cwd = cwd

	-- Resize grip
	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 5)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		s.width, s.height = f:GetSize()
	end)

	-- Mini bar: what the window collapses into. Click it to expand, drag to move.
	local m = CreateFrame("Frame", "WoWAIMini", UIParent, "BackdropTemplate")
	ui.mini = m
	m:SetSize(250, 30)
	if s.miniPoint then
		m:SetPoint(s.miniPoint, UIParent, s.miniRelPoint or s.miniPoint, s.miniX or 0, s.miniY or 0)
	else
		m:SetPoint("TOP", UIParent, "TOP", 0, -40)
	end
	m:SetFrameStrata("DIALOG")
	m:SetMovable(true)
	m:SetClampedToScreen(true)
	m:EnableMouse(true)
	m:RegisterForDrag("LeftButton")
	m:SetScript("OnDragStart", function(self)
		self.dragging = true
		self:StartMoving()
	end)
	m:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		s.miniPoint, s.miniRelPoint, s.miniX, s.miniY = point, relPoint, x, y
		C_Timer.After(0, function() self.dragging = nil end)
	end)
	m:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and not self.dragging then
			WoWAI.Minimize(false)
		end
	end)
	m:SetBackdrop(BACKDROP)
	m:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
	m:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	m:Hide()

	local miniDotHolder, miniDot = MakeDot(m)
	miniDotHolder:SetPoint("LEFT", m, "LEFT", 9, 0)
	ui.miniDot = miniDot

	local mlabel = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	mlabel:SetPoint("LEFT", miniDotHolder, "RIGHT", 6, 0)
	mlabel:SetText("WoW AI")

	local badge = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	badge:SetPoint("LEFT", mlabel, "RIGHT", 8, 0)
	badge:SetPoint("RIGHT", m, "RIGHT", -26, 0)
	badge:SetJustifyH("LEFT")
	badge:SetWordWrap(false)
	ui.miniBadge = badge

	local ok, pulse = pcall(function()
		local g = badge:CreateAnimationGroup()
		local a1 = g:CreateAnimation("Alpha")
		a1:SetFromAlpha(1)
		a1:SetToAlpha(0.25)
		a1:SetDuration(0.6)
		a1:SetOrder(1)
		local a2 = g:CreateAnimation("Alpha")
		a2:SetFromAlpha(0.25)
		a2:SetToAlpha(1)
		a2:SetDuration(0.6)
		a2:SetOrder(2)
		g:SetLooping("REPEAT")
		return g
	end)
	if ok then ui.miniPulse = pulse end

	local mclose = CreateFrame("Button", nil, m, "UIPanelCloseButton")
	mclose:SetSize(24, 24)
	mclose:SetPoint("RIGHT", m, "RIGHT", -2, 0)
	mclose:SetScript("OnClick", function() WoWAI.Toggle(false) end)
	mclose:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Quit: hide completely (/wow-ai brings it back)")
		GameTooltip:Show()
	end)
	mclose:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function WoWAI.Toggle(show)
	if not ui.frame then return end
	if show == nil then show = not ui.frame:IsShown() end
	if show then
		db.settings.minimized = false
		local c = ActiveChat()
		if c then c.unread = 0 end
	end
	if ui.mini then ui.mini:Hide() end
	if not show then ui.quitting = true end
	ui.frame:SetShown(show)
	ui.quitting = nil
	db.settings.shown = show
	if show then
		WoWAI.Render()
		-- No auto-focus: the game keeps the keyboard until you click the box.
		-- No automatic hello either: if the bridge hasn't been seen, the panel
		-- shows Connect in place of Send and waits for a click.
	end
	WoWAI.UpdateMini()
end

function WoWAI.Minimize(mini)
	if not ui.frame then return end
	if mini == nil then mini = not db.settings.minimized end
	if mini then
		db.settings.minimized = true
		db.settings.shown = true
		ui.frame:Hide() -- OnHide shows the mini bar
		if ui.mini and not ui.mini:IsShown() then ui.mini:Show() end
		WoWAI.UpdateMini()
	else
		WoWAI.Toggle(true)
	end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local HELP = table.concat({
	"/wow-ai                        toggle the window (/ai, /wowai and the old /wow-claude are the same command)",
	"/wow-ai mini                   collapse to the small bar (click the bar to expand)",
	"/wow-ai hide                   hide the window completely",
	"/ai <text>                         send <text> to the current chat straight from the game chat box (/wow-ai <text> too). A message that starts with a command word is still sent when the rest of the line doesn't fit that command",
	"/r <text>                          replies to the agent when it was the last to message you (else normal whisper reply)",
	"/wow-ai echo summary|full|short|off|<chars>   how much of each reply to print in the game chat (summary = the agent's closing TL;DR lines)",
	"/wow-ai longchat on|off        let the game chat box take 4000 characters (for long /ai messages)",
	"/wow-ai new [name]             start a new chat (its own agent session, like a new terminal)",
	"/wow-ai chat <n|name>          switch chats (or click one in the left panel)",
	"/wow-ai rename [name]          rename the current chat (no name = dialog; right-clicking the chat in the left panel offers it too)",
	"/wow-ai delete                 delete the current chat",
	"/wow-ai cd <folder>            folder this chat's agent works in (relative to the bridge's folder; no folder = back to default). Right-clicking the chat in the left panel and picking Folder does the same",
	"/wow-ai agent [name]           which agent this chat talks to: claude, codex or grok (no name = show; default = the bridge's). Right-clicking the chat and picking Agent does the same",
	"/wow-ai reset                  next message in this chat starts a fresh agent session",
	"/wow-ai context [on|off]       what the agent is told about your character and where you are (no argument = show it)",
	"/wow-ai map [...]              map layers the agent drew, the route navigator and herb/ore nodes (no argument = status and subcommands; /aimap is the same)",
	"/wow-ai mode pixel             no-reload transport (default)",
	"/wow-ai mode reload            fallback transport: a /reload per step",
	"/wow-ai resend                 show the strip again if the bridge missed it",
	"/wow-ai reload                 reload now (also frees the slot pool)",
	"/wow-ai cancel                 stop waiting on this chat's reply",
	"/wow-ai copy                   open the last reply in a selectable box for Ctrl+C",
	"/wow-ai bind <key>             hotkey: checks for a reply while waiting, else toggles the window",
	"/wow-ai auto on|off            reload-mode only: auto-reload on your next keypress after the interval",
	"/wow-ai signal on|off          the cheap sound-file readiness check (off if it spams errors)",
	"/wow-ai slots                  how many reply slots are still free this session",
	"/wow-ai diag                   transport diagnostics (is the cheap sound-file channel working?)",
	"/wow-ai clear                  clear this chat's transcript",
	"/wow-ai queue [clear|send]     messages typed while waiting go out one after another; show, empty or resume the queue (/wow-ai cola [vaciar|seguir])",
	"/wow-ai apply | aplicar        apply the actions the last reply proposes (same as its Apply button)",
	"/wow-ai discard | descartar    discard them",
	"/wow-ai data [kinds] | datos   show what the agent gets when it asks for game data: bags bank gear spells bars talents quests reputation macros",
	"/wow-ai model [name|auto|default] | modelo   the model this chat runs on (opencodex's list; auto = JEV picks per message). No name = pick from a list",
	"/wow-ai voice | voz            talk: the bridge listens on the PC's microphone and sends what you said (/wow-ai voice stop ends it early)",
	"/wow-ai pad [on|off] | mando   gamepad mode: the controller drives this window (A talk, B back, X apply, Y menu, d-pad scroll and chats)",
	"/wow-ai macros                 create the \"IA Voz\" and \"IA Mando\" macros, to put on a (gamepad) action bar",
	"/wow-ai autoapply [on|off] | autoaplicar   clear orders run without the Apply click (on by default); off = every action waits for Apply",
}, "\n")

-- What each subcommand accepts, so that free text which happens to start with
-- one of these words ("delete the unused imports", "help me with this macro")
-- is sent as a message instead of run as a command. 0 = no arguments, 1 = at
-- most one word, a table = one of those words, a function decides, true = anything.
local function OnOffOrNumber(rest)
	return rest == "" or rest == "on" or rest == "off" or tonumber(rest) ~= nil
end

local function ChatArgument(rest)
	if rest == "" or tonumber(rest) or not rest:find("%s") then return true end
	for _, ch in ipairs(db.chats) do
		if ch.name:lower() == rest:lower() then return true end
	end
	return false
end

-- /wow-ai data: only a list of known kinds (English or Spanish) makes it the
-- command; "/ai datos de mi personaje" is a message.
local DATA_WORDS = {
	bags = "bags", bank = "bank", gear = "gear", spells = "spells", bars = "bars", talents = "talents",
	quests = "quests", reputation = "reputation", macros = "macros",
	bolsas = "bags", banco = "bank", equipo = "gear", hechizos = "spells", barras = "bars",
	talentos = "talents", misiones = "quests", reputacion = "reputation",
}

local function DataKinds(rest)
	for w in rest:lower():gmatch("[^%s,]+") do
		if not DATA_WORDS[w] then return false end
	end
	return true
end

local COMMAND_ARGS = {
	mini = 0, min = 0, hide = 0, quit = 0, help = 0, clear = 0, delete = 0, reset = 0, copy = 0,
	cancel = 0, resend = 0, reload = 0, refresh = 0, slots = 0, diag = 0,
	context = { [""] = true, on = true, off = true }, ctx = { [""] = true, on = true, off = true },
	mode = { [""] = true, pixel = true, reload = true },
	signal = { [""] = true, on = true, off = true }, longchat = { [""] = true, on = true, off = true },
	auto = OnOffOrNumber,
	echo = function(rest) return rest == "" or rest == "summary" or rest == "full" or rest == "short" or rest == "off" or tonumber(rest) ~= nil end,
	bind = 1, agent = 1,
	chat = ChatArgument, chats = ChatArgument,
	cd = true, new = true, rename = true,
	map = true, -- /wow-ai map ...: Map.lua (layers, navigator, herb/ore nodes)
	apply = 0, aplicar = 0, discard = 0, descartar = 0,
	queue = { [""] = true, clear = true, send = true },
	cola = { [""] = true, vaciar = true, seguir = true, clear = true, send = true },
	data = DataKinds, datos = DataKinds,
	model = 1, modelo = 1,
	voice = { [""] = true, stop = true }, voz = { [""] = true, stop = true, para = true },
	pad = { [""] = true, on = true, off = true }, mando = { [""] = true, on = true, off = true },
	macros = 0,
	autoapply = { [""] = true, on = true, off = true }, autoaplicar = { [""] = true, on = true, off = true },
}

local function IsCommand(cmd, rest)
	local spec = COMMAND_ARGS[cmd]
	if spec == nil then return false end
	if spec == true then return true end
	if spec == 0 then return rest == "" end
	if spec == 1 then return not rest:find("%s") end
	if type(spec) == "table" then return spec[rest:lower()] == true end
	return spec(rest) == true
end

local function ApplyLongChat()
	local box = ChatFrame1EditBox
	if not box or not box.SetMaxLetters then return end
	box:SetMaxLetters(db.settings.longchat and 4000 or 255)
end

SLASH_WOWAI1 = "/wow-ai"
SLASH_WOWAI2 = "/wowai"
SLASH_WOWAI3 = "/wow-claude" -- the project's old name, kept so old habits and macros still work
SLASH_WOWAI4 = "/ai" -- the short form: /ai <text> sends, /ai agent codex and the rest work too
SLASH_WOWAI5 = "/ask"
SlashCmdList["WOWAI"] = function(msg)
	msg = Trim(msg or "")
	local cmd, rest = msg:match("^(%S+)%s*(.-)$")
	cmd = cmd and cmd:lower() or ""
	local s = db.settings
	local c = ActiveChat()

	-- Anything that isn't a command, or a command word followed by something it
	-- doesn't take, is a message for the agent.
	if cmd ~= "" and not IsCommand(cmd, rest) then
		WoWAI.Send(msg)
		return
	end
	if cmd == "" then
		WoWAI.Toggle()
	elseif cmd == "mini" or cmd == "min" then
		WoWAI.Minimize(true)
	elseif cmd == "new" then
		WoWAI.NewChat(rest)
	elseif cmd == "chat" or cmd == "chats" then
		local n = tonumber(rest)
		local target = n and db.chats[n]
		if not target and rest ~= "" then
			for _, ch in ipairs(db.chats) do
				if ch.name:lower() == rest:lower() then target = ch end
			end
		end
		if target then
			WoWAI.SwitchChat(target.id)
		else
			local lines = {}
			for i, ch in ipairs(db.chats) do
				table.insert(lines, i .. ". " .. ch.name .. (ch.id == db.activeChat and "  (current)" or "") .. (ch.pendingId and "  working" or "") .. ((ch.unread or 0) > 0 and ("  " .. ch.unread .. " new") or ""))
			end
			AddHistory(c, "system", "Chats:\n" .. table.concat(lines, "\n"))
			WoWAI.Render()
		end
		WoWAI.Toggle(true)
	elseif cmd == "rename" then
		if rest ~= "" then
			c.name = rest:sub(1, 24)
			WoWAI.Render()
		else
			WoWAI.RenameActive()
		end
		WoWAI.Toggle(true)
	elseif cmd == "delete" then
		WoWAI.DeleteChat()
	elseif cmd == "cd" then
		WoWAI.SetFolder(rest, c)
		WoWAI.Toggle(true)
	elseif cmd == "map" then
		if WoWAIMap then WoWAIMap.Command(rest) else print("|cff66ccff[WoW AI]|r the map module did not load") end
	elseif cmd == "agent" then
		WoWAI.SetAgent(rest, c)
		WoWAI.Toggle(true)
	elseif cmd == "reset" then
		c.resetNext = true
		local where = ChatFolder(c)
		AddHistory(c, "system", "Next message starts a fresh " .. ChatAgentName(c) .. " session" .. (where ~= "" and (" in " .. where) or ""))
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "context" or cmd == "ctx" then
		rest = rest:lower()
		if rest == "on" or rest == "off" then
			s.context = rest == "on"
			-- Make sure the next record carries the change, hello throttle or not.
			run.contextSent = nil
			run.lastHelloAt = nil
			if WoWAI.IsConnected() then WoWAI.SayHello() end
		end
		local ctx = WoWAI.GameContext()
		AddHistory(c, "system", (s.context
			and "Game context is ON: the agent is told this with each message (it goes into its system prompt, so unrelated projects are unaffected by anything but a few lines). /wow-ai context off to stop.\n\n"
			or "Game context is OFF: the agent is told nothing about the game. /wow-ai context on to send this:\n\n") .. ctx
			.. "\n\nTip: click the input box, then shift-click an item, spell or quest to link it into your message; the agent gets its tooltip.")
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "mode" then
		if rest == "pixel" or rest == "reload" then
			s.mode = rest
			AddHistory(c, "system", "mode set to " .. rest)
		else
			AddHistory(c, "system", "mode is " .. s.mode .. " (pixel or reload)")
		end
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "resend" then
		WoWAI.Resend()
	elseif cmd == "auto" then
		local n = tonumber(rest)
		if n then
			s.interval = math.max(5, math.floor(n))
			s.autoRefresh = true
		elseif rest == "on" then
			s.autoRefresh = true
		elseif rest == "off" then
			s.autoRefresh = false
		end
		WoWAI.UpdateStatus()
		WoWAI.ArmAutoRefresh()
	elseif cmd == "hide" or cmd == "quit" then
		WoWAI.Toggle(false)
	elseif cmd == "copy" then
		for i = #c.history, 1, -1 do
			if c.history[i].role == "assistant" then
				WoWAI.ShowCopy(c.history[i].text)
				break
			end
		end
	elseif cmd == "echo" then
		if rest == "summary" or rest == "full" or rest == "short" or rest == "off" then
			s.echo = rest
		elseif tonumber(rest) then
			s.echo = tostring(math.max(200, math.floor(tonumber(rest))))
		end
		AddHistory(c, "system", "replies in game chat: " .. s.echo .. " (summary = the agent's TL;DR lines, full = " .. ECHO_DEFAULT .. " chars, short, off, or a number of characters)")
		WoWAI.Render()
	elseif cmd == "longchat" then
		if rest == "on" then s.longchat = true elseif rest == "off" then s.longchat = false end
		ApplyLongChat()
		AddHistory(c, "system", "game chat box limit: " .. (s.longchat and "4000 characters (fine for /ai; real chat over 255 may be rejected by the server)" or "255 (default)"))
		WoWAI.Render()
	elseif cmd == "signal" then
		if rest == "on" then s.signal = true elseif rest == "off" then s.signal = false end
		AddHistory(c, "system", "signal check is " .. (s.signal and "on" or "off"))
		WoWAI.Render()
	elseif cmd == "slots" then
		local free = 0
		for i = 1, SLOT_COUNT do
			if not C_AddOns.IsAddOnLoaded(SlotName(i)) then free = free + 1 end
		end
		AddHistory(c, "system", free .. " of " .. SLOT_COUNT .. " reply slots free this session (a reload frees all)")
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "refresh" or cmd == "reload" then
		SafeReload()
	elseif cmd == "bind" then
		local key = rest:upper()
		if key ~= "" and not InCombatLockdown() then
			SetBinding(key, "CLICK WoWAIRefreshButton:LeftButton")
			SaveBindings(GetCurrentBindingSet())
			AddHistory(c, "system", key .. " is now bound: checks for a reply while waiting, otherwise toggles this window")
		end
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "diag" then
		local free = 0
		for i = 1, SLOT_COUNT do
			if not C_AddOns.IsAddOnLoaded(SlotName(i)) then free = free + 1 end
		end
		local lines = {
			"sound channel: " .. (signalAvailable and "usable" or "UNUSABLE") .. " (self-test: " .. tostring(signalStats.selftest) .. ")" .. (signalStats.error and (" error: " .. signalStats.error) or ""),
			"signal setting: " .. tostring(s.signal) .. ", marked unreliable this session: " .. tostring(run.signalUnreliable or false),
			"sound checks: " .. signalStats.checks .. ", valid hits: " .. signalStats.hits .. (signalStats.lastHit and (", last hit " .. FmtDur(GetTime() - signalStats.lastHit) .. " ago") or ""),
			"slot polls this session: " .. (run.polls or 0) .. ", free slots: " .. free .. "/" .. SLOT_COUNT,
			"presence: head at " .. tostring(run.presence and run.presence.last or "?") .. ", beats seen: " .. tostring(run.presence and run.presence.beats or 0),
			select(5, WoWAI.BridgeState()),
			"mode: " .. s.mode .. ", session token: " .. tostring(db.session),
		}
		for _, ch in ipairs(db.chats) do
			local a = run.act and run.act[ch.id]
			if ch.pendingId then
				table.insert(lines, ch.name .. ": pending #" .. ch.pendingId .. (a and (", heartbeat " .. (a.unreliable and "unreliable" or (a.count .. " beats"))) or ", no heartbeat state"))
			end
		end
		AddHistory(c, "system", "Diagnostics:\n" .. table.concat(lines, "\n"))
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "cancel" then
		if c.pendingId then
			AddHistory(c, "system", "Gave up waiting on #" .. c.pendingId)
			run.outbound[c.pendingId] = nil
			if run.act then run.act[c.id] = nil end
			c.pendingId = nil
			c.progress = nil
			RefreshStrip()
			if not AnyPending() then keyCatcher:Hide() end
			SendNextQueued(c) -- the queue goes on with the next message
		end
		WoWAI.Render()
	elseif cmd == "queue" or cmd == "cola" then
		rest = rest:lower()
		c.queue = c.queue or {}
		if rest == "clear" or rest == "vaciar" then
			local n = #c.queue
			c.queue = {}
			AddHistory(c, "system", L("Queue cleared (" .. n .. ").", "Cola vaciada (" .. n .. ")."))
		elseif rest == "send" or rest == "seguir" then
			if c.pendingId then
				AddHistory(c, "system", L("This chat is still waiting for a reply; the queue goes on after it.", "Este chat todavía espera una respuesta; la cola seguirá después."))
			else
				SendNextQueued(c)
			end
		else
			AddHistory(c, "system", #c.queue == 0
				and L("The queue is empty. What you type while a reply is on its way waits here and goes out after it.", "La cola está vacía. Lo que escribas mientras llega una respuesta espera aquí y se envía después.")
				or (L("Queued messages: ", "Mensajes en cola: ") .. #c.queue .. L(". /wow-ai queue clear empties it.", ". /wow-ai cola vaciar la vacía.")))
		end
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "apply" or cmd == "aplicar" then
		WoWAI.ApplyActions()
		WoWAI.Toggle(true)
	elseif cmd == "discard" or cmd == "descartar" then
		WoWAI.DiscardActions()
	elseif cmd == "data" or cmd == "datos" then
		if not WoWAIData then return end
		local kinds = {}
		for w in rest:lower():gmatch("[^%s,]+") do table.insert(kinds, DATA_WORDS[w]) end
		if #kinds == 0 then kinds = WoWAIData.KINDS end
		WoWAI.ShowCopy(WoWAIData.Collect(kinds, 60000))
	elseif cmd == "model" or cmd == "modelo" then
		if rest == "" then WoWAI.ModelPrompt() else WoWAI.SetModel(rest, c) end
		WoWAI.Toggle(true)
	elseif cmd == "voice" or cmd == "voz" then
		if rest == "stop" or rest == "para" then WoWAI.VoiceStop() else WoWAI.Toggle(true) WoWAI.Voice() end
	elseif cmd == "pad" or cmd == "mando" then
		if WoWAIPad then
			if rest == "on" then WoWAIPad.Enter() elseif rest == "off" then WoWAIPad.Exit() else WoWAIPad.Toggle() end
		end
	elseif cmd == "autoapply" or cmd == "autoaplicar" then
		if rest == "on" then s.autoApply = true elseif rest == "off" then s.autoApply = false end
		AddHistory(c, "system", s.autoApply
			and L("Clear orders run by themselves (JEV checks each action against what you asked; anything doubtful still waits for Apply). /wow-ai autoapply off to always ask.",
				"Las órdenes claras se hacen solas (JEV comprueba cada acción con lo que pediste; lo dudoso sigue esperando a Aplicar). /ai autoaplicar off para preguntar siempre.")
			or L("Every proposed action waits for Apply. /wow-ai autoapply on to let clear orders run by themselves.",
				"Todas las acciones esperan a Aplicar. /ai autoaplicar on para que las órdenes claras se hagan solas."))
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "macros" then
		if WoWAIPad then WoWAIPad.MakeMacros() end
	elseif cmd == "clear" then
		wipe(c.history)
		WoWAI.Render()
	elseif cmd == "help" then
		AddHistory(c, "system", HELP)
		WoWAI.Render()
		WoWAI.Toggle(true)
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("CHAT_MSG_WHISPER")
ev:RegisterEvent("CHAT_MSG_BN_WHISPER")
for _, e in ipairs({ "MERCHANT_SHOW", "BANKFRAME_OPENED", "TRAINER_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			InitDB()
		end
	elseif event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER" then
		-- A real person whispered: /r belongs to them again.
		run.lastMessenger = "player"
	elseif event == "PLAYER_LOGIN" then
		if not db then InitDB() end
		BuildUI()
		run = { outbound = {} }
		SelfTestSignals()
		ProcessInbox()
		if AnyPending() then
			-- Still waiting after a reload: resume polling with a fresh slot pool.
			run.sentAt = GetTime()
			run.polls = 0
			run.act = {}
			for _, ch in ipairs(db.chats) do
				if ch.pendingId then
					-- Beats already written stay valid, so the counter catches up on its own.
					run.act[ch.id] = { next = 1, count = 0, startedAt = GetTime() }
				end
			end
			ScheduleNextPoll()
		end
		local c = ActiveChat()
		if c and c.draft and c.draft ~= "" then
			ui.input:SetText(c.draft)
			if not c.pendingId then c.draft = nil end
		end
		WoWAI.Render()
		if db.settings.shown then
			if db.settings.minimized then
				WoWAI.Minimize(true)
			else
				WoWAI.Toggle(true)
			end
		end
		WoWAI.ArmAutoRefresh()
		WoWAI.UpdateDot()
		if db.settings.longchat then ApplyLongChat() end
		HookReplyCommand()
		C_Timer.NewTicker(TICK_SECONDS, Tick)
		C_Timer.After(3, WoWAI.SayHello)
	elseif event == "PLAYER_REGEN_ENABLED" then
		if WoWAI.reloadAfterCombat then
			WoWAI.reloadAfterCombat = nil
			ReloadUI()
		elseif db then
			WoWAI.ArmAutoRefresh()
			C_Timer.After(0.5, WoWAI.AutoApplyPending)
		end
	elseif event == "MERCHANT_SHOW" or event == "BANKFRAME_OPENED" or event == "TRAINER_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
		-- A clear order that was waiting for this window.
		C_Timer.After(0.8, WoWAI.AutoApplyPending)
	end
end)
