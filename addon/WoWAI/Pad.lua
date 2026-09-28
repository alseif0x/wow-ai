-- WoWAIPad: drive the WoW AI window with a gamepad.
--
-- The Forever client turns controller buttons into ordinary binding keys (PAD1,
-- PADDUP, ...) and its gamepad UI works by putting override bindings on them.
-- Gamepad mode does the same with a frame of its own: while it is on, priority
-- override bindings send those keys to WoWAIPadButton, and turning it off clears
-- them, so the game's own gamepad bindings are back untouched. Nothing here calls
-- into Blizzard's gamepad code (that is what tainted it for other addons).
--
--   A  talk (hold while speaking, or tap and speak)   B  back / leave gamepad mode
--   X  apply the proposed actions                      Y  menu: model, agent, quick phrases...
--   d-pad up/down  scroll          d-pad left/right  previous / next chat
--   LB / RB  page up / down        Start  leave gamepad mode
--
-- Bindings can't change in combat, so the mode ends when combat starts. To get
-- into it with the controller, /ai macros makes an "IA Mando" macro for an
-- action bar slot; a key binding (Esc > Options > Keybindings > WoW AI) works too.

local Pad = {}
_G.WoWAIPad = Pad

_G.BINDING_HEADER_WOWAI = "WoW AI"
_G.BINDING_NAME_WOWAI_TOGGLE = "Show / hide the window"
_G.BINDING_NAME_WOWAI_PAD = "Gamepad mode on / off"
_G.BINDING_NAME_WOWAI_TALK = "Talk (hold while speaking)"

local L = function(en, es) return WoWAI.L and WoWAI.L(en, es) or en end

local KEYS = {
	"PAD1", "PAD2", "PAD3", "PAD4",
	"PADDUP", "PADDDOWN", "PADDLEFT", "PADDRIGHT",
	"PADLSHOULDER", "PADRSHOULDER", "PADFORWARD",
}

local HOLD_SECONDS = 0.6 -- a longer A press is push-to-talk: releasing it stops listening

local owner = CreateFrame("Frame", "WoWAIPadOwner", UIParent)
local button = CreateFrame("Button", "WoWAIPadButton", UIParent)
button:SetSize(1, 1)
button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
button:RegisterForClicks("AnyDown", "AnyUp")

local active = false
local legend
local talkDownAt
local confirmAt -- when X was first pressed on actions JEV flagged

local QUICK_DEFAULT = {
	"¿Qué hago ahora?",
	"Resume mis misiones y dime cuál me conviene",
	"¿Qué pieza de equipo debería mejorar?",
	"Ordena las bolsas",
	"Vende la chatarra",
	"Siguiente parada",
}

local function Phrases()
	local db = _G.WoWAIDB
	local s = db and db.settings
	if s and type(s.phrases) == "table" and #s.phrases > 0 then return s.phrases end
	return QUICK_DEFAULT
end

local function Legend()
	local f = WoWAI.Frame()
	if not f then return end
	if not legend then
		legend = CreateFrame("Frame", nil, f, "BackdropTemplate")
		legend:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 2)
		legend:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, 2)
		legend:SetHeight(26)
		legend:SetBackdrop({
			bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		legend:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
		legend:SetBackdropBorderColor(1, 0.82, 0.25, 1)
		legend.text = legend:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		legend.text:SetPoint("CENTER")
		legend.text:SetText(L("A talk   B back   X apply   Y menu   D-pad up/down scroll, left/right chat   LB/RB page   Start exit",
			"A hablar   B atrás   X aplicar   Y menú   Cruceta arriba/abajo desplaza, izq./der. chat   LB/RB página   Start salir"))
	end
	return legend
end

local function Menu()
	local items = {
		{ value = "model", label = L("Model: ", "Modelo: ") .. WoWAI.ModelLabel() },
		{ value = "agent", label = L("Agent...", "Agente...") },
		{ value = "phrases", label = L("Quick phrases...", "Frases rápidas...") },
		{ value = "new", label = L("New chat", "Nuevo chat") },
	}
	if WoWAI.HasActions() then table.insert(items, { value = "discard", label = L("Discard the proposed actions", "Descartar las acciones propuestas") }) end
	table.insert(items, { value = "last", label = L("Show the last reply in full", "Ver la última respuesta completa") })
	table.insert(items, { value = "exit", label = L("Leave gamepad mode", "Salir del modo mando") })
	WoWAIPicker.Open(L("WoW AI menu", "Menú de WoW AI"), items, nil, function(v)
		if v == "model" then WoWAI.ModelPrompt()
		elseif v == "agent" then WoWAI.AgentPrompt()
		elseif v == "phrases" then
			local list = {}
			for _, p in ipairs(Phrases()) do table.insert(list, { value = p, label = p }) end
			WoWAIPicker.Open(L("Say to the AI", "Decir a la IA"), list, nil, function(p) WoWAI.Send(p) end)
		elseif v == "new" then WoWAI.NewChat()
		elseif v == "discard" then WoWAI.DiscardActions()
		elseif v == "last" then SlashCmdList["WOWAI"]("copy")
		elseif v == "exit" then Pad.Exit() end
	end)
end

-- One controller button (down = true on press, false on release).
local function Handle(key, down)
	local picker = WoWAIPicker and WoWAIPicker.IsOpen()
	if key == "PAD1" then
		if picker then if down then WoWAIPicker.Accept() end return end
		if down then
			talkDownAt = GetTime()
			WoWAI.Voice()
		elseif talkDownAt then
			if GetTime() - talkDownAt >= HOLD_SECONDS then WoWAI.VoiceStop() end
			talkDownAt = nil
		end
		return
	end
	if not down then return end
	if key == "PAD2" then
		if picker then WoWAIPicker.Close() else Pad.Exit() WoWAI.Minimize(true) end
	elseif key == "PAD3" then
		if picker then return end
		if WoWAI.HasActions() then
			-- Actions JEV flagged take a second press, so one tap can't apply them unseen.
			if WoWAI.HasWarnedActions() and (not confirmAt or GetTime() - confirmAt > 5) then
				confirmAt = GetTime()
				WoWAI.Note(L("Some proposed actions are marked (!): you may not have asked for them. Press X again within 5 s to apply them all, or Y > Discard.",
					"Hay acciones marcadas con (!): puede que no las hayas pedido. Pulsa X otra vez en 5 s para aplicarlas todas, o Y > Descartar."))
				return
			end
			confirmAt = nil
			WoWAI.ApplyActions()
		elseif WoWAI.IsPending() then WoWAI.Send("") -- check for the reply now
		else WoWAI.Note(L("Nothing to apply.", "No hay nada que aplicar.")) end
	elseif key == "PAD4" then
		if picker then WoWAIPicker.Close() else Menu() end
	elseif key == "PADDUP" then
		if picker then WoWAIPicker.Move(-1) else WoWAI.ScrollBy(-3) end
	elseif key == "PADDDOWN" then
		if picker then WoWAIPicker.Move(1) else WoWAI.ScrollBy(3) end
	elseif key == "PADDLEFT" then
		if picker then WoWAIPicker.Move(-8) else WoWAI.CycleChat(-1) end
	elseif key == "PADDRIGHT" then
		if picker then WoWAIPicker.Move(8) else WoWAI.CycleChat(1) end
	elseif key == "PADLSHOULDER" then
		if picker then WoWAIPicker.Move(-8) else WoWAI.ScrollBy(-10) end
	elseif key == "PADRSHOULDER" then
		if picker then WoWAIPicker.Move(8) else WoWAI.ScrollBy(10) end
	elseif key == "PADFORWARD" then
		Pad.Exit()
	end
end

button:SetScript("OnClick", function(_, key, down)
	if not active then return end
	-- Bindings deliver the press and the release; mouse-style clicks only "up".
	if down == nil then down = true end
	Handle(key, down)
end)

function Pad.IsActive() return active end

function Pad.Enter()
	if active then return end
	if InCombatLockdown() then
		WoWAI.Note(L("Gamepad mode can't start in combat.", "El modo mando no puede empezar en combate."))
		return
	end
	WoWAI.Toggle(true)
	for _, key in ipairs(KEYS) do
		SetOverrideBinding(owner, true, key, "CLICK WoWAIPadButton:" .. key)
	end
	active = true
	local lg = Legend()
	if lg then lg:Show() end
	local f = WoWAI.Frame()
	if f then f:SetBackdropBorderColor(1, 0.82, 0.25, 1) end
end

function Pad.Exit()
	if not active then return end
	active = false
	talkDownAt = nil
	if not InCombatLockdown() then ClearOverrideBindings(owner) end
	if legend then legend:Hide() end
	if WoWAIPicker then WoWAIPicker.Close() end
	local f = WoWAI.Frame()
	if f then f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1) end
end

function Pad.Toggle() if active then Pad.Exit() else Pad.Enter() end end

-- Key binding handler for "Talk" (Bindings.xml, runOnUp).
function Pad.TalkBinding(keystate)
	if keystate == "down" then
		talkDownAt = GetTime()
		WoWAI.Voice()
	elseif talkDownAt then
		if GetTime() - talkDownAt >= HOLD_SECONDS then WoWAI.VoiceStop() end
		talkDownAt = nil
	end
end

-- "IA Voz" and "IA Mando" account macros, for an action bar the controller reaches.
function Pad.MakeMacros()
	if InCombatLockdown() then
		WoWAI.Note(L("Macros can't be made in combat.", "No se pueden crear macros en combate."))
		return
	end
	local made = {}
	for _, m in ipairs({ { "IA Voz", "/ai voz" }, { "IA Mando", "/ai mando" } }) do
		if GetMacroIndexByName(m[1]) == 0 then
			local ok = pcall(CreateMacro, m[1], "INV_Misc_QuestionMark", m[2], false)
			if ok then table.insert(made, m[1]) end
		end
	end
	WoWAI.Note((#made > 0 and (L("Macros made: ", "Macros creadas: ") .. table.concat(made, ", ") .. ". ") or L("The macros already exist. ", "Las macros ya existen. "))
		.. L("Open the macros window (/macro), drag them onto an action bar your controller reaches.",
			"Abre la ventana de macros (/macro) y arrástralas a una barra de acción que alcances con el mando."))
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		-- Still allowed here, the moment before combat locks bindings.
		if active then
			Pad.Exit()
			print("|cff66ccff[WoW AI]|r " .. L("gamepad mode off for combat (/ai pad to go back)", "modo mando desactivado por el combate (/ai mando para volver)"))
		end
	elseif event == "PLAYER_LOGIN" then
		local f = WoWAI.Frame()
		-- Leaving the window (Esc, minimize) leaves gamepad mode too.
		if f then f:HookScript("OnHide", function() if active then Pad.Exit() end end) end
	end
end)
