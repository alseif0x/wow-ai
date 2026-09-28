-- WoWAIPicker: a small list to pick one value from (the chat's model, its agent,
-- a quick phrase, the gamepad menu). A frame of our own rather than a Blizzard
-- dropdown or StaticPopup: those go through the gamepad UI's popup handling,
-- which is what froze the client for addons on the Forever beta.
--
--   WoWAIPicker.Open(title, items, current, onPick)
--     items: { { value = "x", label = "X" }, ... }; an item with value == nil is
--     shown dimmed and can't be picked (a note). onPick(value) runs on a click,
--     Enter, or A on the gamepad (Pad.lua drives Move/Accept/Close).

local P = {}
_G.WoWAIPicker = P

local ROWS = 12
local ROW_H = 22
local WIDTH = 340

local frame, rows, title, hint
local state = { items = {}, sel = 1, top = 1, onPick = nil }

local function Build()
	if frame then return end
	frame = CreateFrame("Frame", "WoWAIPickerFrame", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, 44 + ROWS * ROW_H + 24)
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:EnableMouseWheel(true)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0.04, 0.04, 0.06, 0.97)
	frame:SetBackdropBorderColor(1, 0.82, 0.25, 1)
	frame:Hide()
	tinsert(UISpecialFrames, "WoWAIPickerFrame") -- Esc closes it

	title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -12)
	title:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
	title:SetJustifyH("LEFT")
	title:SetWordWrap(false)

	rows = {}
	for i = 1, ROWS do
		local b = CreateFrame("Button", nil, frame)
		b:SetSize(WIDTH - 20, ROW_H)
		b:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -34 - (i - 1) * ROW_H)
		b.sel = b:CreateTexture(nil, "BACKGROUND")
		b.sel:SetAllPoints()
		b.sel:SetColorTexture(1, 0.82, 0.25, 0.22)
		b.sel:Hide()
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.08)
		b.mark = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.mark:SetPoint("LEFT", b, "LEFT", 6, 0)
		b.mark:SetWidth(14)
		b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		b.label:SetPoint("LEFT", b.mark, "RIGHT", 2, 0)
		b.label:SetPoint("RIGHT", b, "RIGHT", -6, 0)
		b.label:SetJustifyH("LEFT")
		b.label:SetWordWrap(false)
		b:SetScript("OnClick", function(self)
			if self.index then
				state.sel = self.index
				P.Accept()
			end
		end)
		b:SetScript("OnEnter", function(self)
			if self.index then state.sel = self.index P.Render() end
		end)
		rows[i] = b
	end

	hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 10)
	hint:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
	hint:SetJustifyH("LEFT")

	frame:SetScript("OnMouseWheel", function(_, delta) P.Move(-delta) end)
	frame:SetScript("OnHide", function() state.onPick = nil end)
	-- Enter picks, arrow keys move, while the list is open and has the keyboard.
	frame:EnableKeyboard(true)
	frame:SetPropagateKeyboardInput(true)
	frame:SetScript("OnKeyDown", function(self, key)
		local eat = true
		if key == "UP" then P.Move(-1)
		elseif key == "DOWN" then P.Move(1)
		elseif key == "ENTER" then P.Accept()
		else eat = false end
		if not InCombatLockdown() then self:SetPropagateKeyboardInput(not eat) end
	end)
end

local function Pickable(i)
	local it = state.items[i]
	return it and it.value ~= nil
end

function P.Render()
	if not frame then return end
	local n = #state.items
	if state.sel < state.top then state.top = state.sel end
	if state.sel > state.top + ROWS - 1 then state.top = state.sel - ROWS + 1 end
	state.top = math.max(1, math.min(state.top, math.max(1, n - ROWS + 1)))
	for i = 1, ROWS do
		local b = rows[i]
		local idx = state.top + i - 1
		local it = state.items[idx]
		if it then
			b.index = it.value ~= nil and idx or nil
			b.label:SetText(it.label or tostring(it.value))
			if it.value == nil then b.label:SetTextColor(0.55, 0.55, 0.55) else b.label:SetTextColor(0.93, 0.93, 0.93) end
			b.mark:SetText(it.value ~= nil and it.value == state.current and ">" or "")
			b.sel:SetShown(idx == state.sel)
			b:Show()
		else
			b.index = nil
			b:Hide()
		end
	end
	local more = n > ROWS and (" (" .. state.sel .. "/" .. n .. ")") or ""
	hint:SetText(WoWAI.L("Click, or Enter / A to pick; Esc / B to close", "Clic, o Intro / A para elegir; Esc / B para cerrar") .. more)
end

-- title, items, the value now in use (marked), and what to call with the pick.
function P.Open(t, items, current, onPick)
	Build()
	state.items = items or {}
	state.current = current
	state.onPick = onPick
	state.sel, state.top = 1, 1
	for i, it in ipairs(state.items) do
		if it.value ~= nil and it.value == current then state.sel = i break end
	end
	if not Pickable(state.sel) then
		for i = 1, #state.items do if Pickable(i) then state.sel = i break end end
	end
	title:SetText(t or "")
	frame:ClearAllPoints()
	local main = WoWAI.Frame and WoWAI.Frame()
	if main and main:IsShown() then
		frame:SetPoint("CENTER", main, "CENTER", 0, 0)
	else
		frame:SetPoint("CENTER")
	end
	frame:Show()
	P.Render()
end

function P.IsOpen() return frame ~= nil and frame:IsShown() end

function P.Close() if frame then frame:Hide() end end

-- Move the highlight by `d` rows (skipping notes), clamped to the list.
function P.Move(d)
	if not P.IsOpen() or #state.items == 0 then return end
	local i = state.sel
	local step = d > 0 and 1 or -1
	for _ = 1, math.abs(d) do
		local j = i + step
		while state.items[j] and not Pickable(j) do j = j + step end
		if not state.items[j] then break end
		i = j
	end
	state.sel = i
	P.Render()
end

function P.Accept()
	if not P.IsOpen() or not Pickable(state.sel) then return end
	local it, cb = state.items[state.sel], state.onPick
	frame:Hide()
	if cb then cb(it.value) end
end
