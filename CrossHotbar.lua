-- CrossHotbar Forever
-- FFXIV-style cross hotbar for World of Warcraft: Forever's gamepad UI.
-- Author: Bqlock  |  License: MIT (see LICENSE)
--
--   Bottom row:  LT bar | RT bar (dimmed until held)
--   Top row:     LT x2 flyout | base set | RT x2 flyout
--   Hold LT / RT / LT + RT     -> that set is active
--   Tap then hold LT or RT     -> the x2 flyout (face buttons) is active
--
-- Settings: /xhb, or hold LT + RT and press View.
-- LT, RT, LT + RT and the base D-pad share slots with Blizzard's gamepad
-- bar, so they bind through the normal spellbook / bag Bind flow.
-- Flyouts: open the spellbook or bags and drag spells / items onto them.

---------------------------------------------------------------------------
-- Layout measured from the native bar (reference screen 1449 px tall)
---------------------------------------------------------------------------
local REF_H = 1449
local REF = {
    centerY = 164,   -- center cluster, distance from bottom of screen
    square = 66,     -- D-pad button size
    round = 66,      -- face button size
    -- Up, Right, Down, Left, Y, B, A, X (offsets from cluster center)
    pos = {
        { -125, 40 }, { -48, 0 }, { -125, -40 }, { -202, 0 },
        {  125, 40 }, { 191, 0 }, {  125, -40 }, {   59, 0 },
    },
    indicatorY = -67, -- LT / RT badge under the center cluster
    badge = 36,
    flyX = 330,       -- flyout cluster offset from the center cluster
    flyY = 175,
}

local KEYS   = { "PADDUP", "PADDRIGHT", "PADDDOWN", "PADDLEFT", "PAD4", "PAD2", "PAD1", "PAD3" }
local LABELS = { "Up", "Rt", "Dn", "Lt", "Y", "B", "A", "X" }
local SETS = { "L", "R", "LR", "LL", "RR" }
local SET_NAMES = { L = "LT", R = "RT", LR = "LT + RT", LL = "LT x2", RR = "RT x2" }

local COLOR_DARK   = { 0.07, 0.05, 0.04, 0.95 }
local COLOR_BRONZE = { 0.58, 0.45, 0.25, 1 }
local COLOR_GLYPH  = { 0.62, 0.55, 0.42, 1 }
local CIRCLE_MASK  = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
CrossHotbarDB = CrossHotbarDB or {}

local DEFAULT_BASE = { L = 25, R = 37, LR = 49, LL = 61, RR = 13 }

local function LoadSettings()
    CrossHotbarDB.base = CrossHotbarDB.base or {}
    for k, v in pairs(DEFAULT_BASE) do
        if not CrossHotbarDB.base[k] then CrossHotbarDB.base[k] = v end
    end
    CrossHotbarDB.scale = CrossHotbarDB.scale or 1
    CrossHotbarDB.flyoutScale = CrossHotbarDB.flyoutScale or 0.7
    CrossHotbarDB.offsetX = CrossHotbarDB.offsetX or 0
    CrossHotbarDB.offsetY = CrossHotbarDB.offsetY or 0
    if CrossHotbarDB.showLabels == nil then CrossHotbarDB.showLabels = false end
    if CrossHotbarDB.showFlyouts == nil then CrossHotbarDB.showFlyouts = true end
    if CrossHotbarDB.nativeArt == nil then CrossHotbarDB.nativeArt = true end
    if CrossHotbarDB.hideNative == nil then CrossHotbarDB.hideNative = true end
    CrossHotbarDB.doubleTap = CrossHotbarDB.doubleTap or 0.3
    if not CrossHotbarDB.layoutV2 then
        CrossHotbarDB.flyoutScale = 0.5
        CrossHotbarDB.movePlayer = nil
        CrossHotbarDB.layoutV2 = true
    end
    CrossHotbarDB.dimAlpha = CrossHotbarDB.dimAlpha or 0.45
    CrossHotbarDB.point = nil -- old setting from earlier versions
    for _, k in ipairs({ "errors", "dump", "inspect", "maskInfo", "bindProbe", "bindProbeStats", "native", "inactiveAlpha" }) do
        CrossHotbarDB[k] = nil
    end
end

-- Slot for button i of a set: native-matched list if we have one, else contiguous
local function SlotFor(set, i)
    local list = CrossHotbarDB.slots and CrossHotbarDB.slots[set]
    if list and list[i] then return list[i] end
    if not CrossHotbarDB.base[set] then return 0 end
    return CrossHotbarDB.base[set] + i - 1
end

local debugMode = false
local editSet = "L"
local panel -- settings panel, created further down
local OpenConfig
local suspended = false -- true while spellbook / bags / etc. are open

---------------------------------------------------------------------------
-- Secure part: header, 8 active buttons, 2 trigger buttons
---------------------------------------------------------------------------
local header = CreateFrame("Frame", "XHB_Header", UIParent, "SecureHandlerStateTemplate")
header:SetAttribute("mode", "none")

local active = {}
for i = 1, 8 do
    local b = CreateFrame("Button", "XHB_Active" .. i, header, "SecureActionButtonTemplate")
    b:SetSize(1, 1)
    b:SetAlpha(0)
    b:EnableMouse(false)
    b:SetAttribute("type", "action")
    b:SetAttribute("action", DEFAULT_BASE.L + i - 1)
    b:RegisterForClicks("AnyDown")
    header:SetFrameRef("a" .. i, b)
    header:WrapScript(b, "OnClick",
        [[ owner:SetAttribute("used", true); return nil, true ]],
        [[
            local mode = owner:GetAttribute("mode")
            if mode == "LL" or mode == "RR" then
                local side = strsub(mode, 1, 1)
                if owner:GetAttribute("held" .. side) then
                    owner:RunAttribute("_apply", side)
                else
                    owner:RunAttribute("_apply", "none")
                end
            end
        ]])
    active[i] = b
end

header:Execute([[
    KEYS = newtable("PADDUP", "PADDRIGHT", "PADDDOWN", "PADDLEFT", "PAD4", "PAD2", "PAD1", "PAD3")
    ACTIVE = newtable()
    for i = 1, 8 do ACTIVE[i] = self:GetFrameRef("a" .. i) end
]])

-- Switch to a set (or "none") and bind the D-pad / face buttons to it
header:SetAttribute("_apply", [[
    local mode = ...
    self:ClearBindings()
    if mode ~= "none" then
        local first = (mode == "LL" or mode == "RR") and 5 or 1
        for i = first, 8 do
            ACTIVE[i]:SetAttribute("action", self:GetAttribute("slot-" .. mode .. "-" .. i))
            self:SetBindingClick(true, KEYS[i], "XHB_Active" .. i)
        end
        if mode == "LR" then
            self:SetBindingClick(true, "PADBACK", "XHB_ConfigButton")
        end
    end
    self:SetAttribute("mode", mode)
]])

local TRIGGER_SNIPPET = [[
    local side = self:GetAttribute("side")
    local other = (side == "L") and "R" or "L"
    if down then
        owner:SetAttribute("held" .. side, true)
        if owner:GetAttribute("held" .. other) then
            -- both triggers held
            owner:SetAttribute("used", true)
            owner:SetAttribute("armed", nil)
            owner:RunAttribute("_apply", "LR")
        else
            local mode = side
            if owner:GetAttribute("armed") == side then
                mode = side .. side -- double-tap: flyout set
            end
            owner:SetAttribute("armed", nil)
            owner:SetAttribute("used", nil)
            owner:RunAttribute("_apply", mode)
        end
    else
        if not owner:GetAttribute("held" .. side) then return end
        owner:SetAttribute("held" .. side, nil)
        if owner:GetAttribute("held" .. other) then
            owner:RunAttribute("_apply", other)
        else
            if owner:GetAttribute("mode") == side and not owner:GetAttribute("used") then
                owner:SetAttribute("armed", side) -- a quick tap arms the flyout
            end
            owner:RunAttribute("_apply", "none")
        end
    end
]]

local triggers = {}
for _, side in ipairs({ "L", "R" }) do
    local t = CreateFrame("Button", "XHB_Trigger" .. side, UIParent, "SecureActionButtonTemplate")
    t:SetSize(1, 1)
    t:SetAlpha(0)
    t:EnableMouse(false)
    t:SetAttribute("side", side)
    t:RegisterForClicks("AnyDown", "AnyUp")
    header:WrapScript(t, "OnClick", TRIGGER_SNIPPET)
    t:HookScript("OnClick", function(_, _, down)
        if debugMode then
            print(string.format("CrossHotbar: %sT %s", side, down and "pressed" or "released"))
        end
    end)
    triggers[side] = t
end

-- Opens settings when View is pressed while holding LT + RT
local configButton = CreateFrame("Button", "XHB_ConfigButton", UIParent)
configButton:SetScript("OnClick", function() if OpenConfig then OpenConfig() end end)

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------
local function Fill(tex, color)
    tex:SetColorTexture(color[1], color[2], color[3], color[4])
end

local function MakeCircle(tex, parent)
    if not parent.CreateMaskTexture then return end
    local m = parent:CreateMaskTexture()
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("CircleMask") then
        m:SetAtlas("CircleMask")
    else
        m:SetTexture("Interface\\Masks\\CircleMaskScalable", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    end
    m:SetAllPoints(tex)
    tex:AddMaskTexture(m)
end

local unit = 1 -- UI units per reference pixel, set in Layout()

local function SizeFrameParts(obj, s)
    obj.outer:SetSize(s, s)
    obj.rim:SetSize(s - 2 * unit * 2, s - 2 * unit * 2)
    obj.inner:SetSize(s - 2 * unit * 5, s - 2 * unit * 5)
end


---------------------------------------------------------------------------
-- Buttons and clusters
---------------------------------------------------------------------------
local function MakeButton(parent, i)
    local round = i > 4
    local b = CreateFrame("Button", nil, parent)
    b.index, b.round = i, round

    -- Fallback frame: dark edge, bronze rim, dark inside
    b.outer = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.rim   = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    b.inner = b:CreateTexture(nil, "BORDER")
    Fill(b.outer, COLOR_DARK)
    Fill(b.rim, COLOR_BRONZE)
    Fill(b.inner, COLOR_DARK)
    for _, t in ipairs({ b.outer, b.rim, b.inner }) do t:SetPoint("CENTER") end

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("CENTER")
    if round then
        -- zoom like native so the circle trims the icon's baked-in border
        b.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    else
        b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    if round then
        MakeCircle(b.outer, b)
        MakeCircle(b.rim, b)
        MakeCircle(b.inner, b)
        MakeCircle(b.icon, b)
    end

    b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cooldown:SetAllPoints(b.icon)
    if round and b.cooldown.SetSwipeTexture then
        b.cooldown:SetSwipeTexture(CIRCLE_MASK)
        if b.cooldown.SetUseCircularEdge then b.cooldown:SetUseCircularEdge(true) end
    end

    -- Text and glyphs sit above the cooldown swipe
    b.top = CreateFrame("Frame", nil, b)
    b.top:SetAllPoints()
    b.top:SetFrameLevel(b.cooldown:GetFrameLevel() + 2)

    -- Empty-slot glyph: arrow for D-pad, letter for face buttons
    if round then
        b.glyph = b.top:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        b.glyph:SetPoint("CENTER")
        b.glyph:SetText(LABELS[i])
        b.glyph:SetTextColor(COLOR_GLYPH[1], COLOR_GLYPH[2], COLOR_GLYPH[3])
    else
        b.glyph = b.top:CreateTexture(nil, "OVERLAY")
        b.glyph:SetPoint("CENTER")
        b.glyph:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
        b.glyph:SetVertexColor(COLOR_GLYPH[1], COLOR_GLYPH[2], COLOR_GLYPH[3])
        local rotation = ({ math.pi / 2, 0, -math.pi / 2, math.pi })[i]
        b.glyph:SetRotation(rotation)
    end

    b.count = b.top:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)

    b.hotkey = b.top:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
    b.hotkey:SetPoint("TOPRIGHT", b, "TOPRIGHT", -3, -3)
    b.hotkey:SetText(LABELS[i])
    b.hotkeyIcon = b.top:CreateTexture(nil, "OVERLAY")
    b.hotkeyIcon:SetPoint("TOPRIGHT", b, "TOPRIGHT", 4, 4)
    b.hotkeyIcon:Hide()

    -- Press flash and mouse-over highlight
    b.press = b.top:CreateTexture(nil, "OVERLAY")
    b.press:SetAllPoints(b.icon)
    b.press:SetColorTexture(1, 0.9, 0.6, 0.35)
    b.press:SetBlendMode("ADD")
    b.press:Hide()
    if round then MakeCircle(b.press, b.top) end

    b.hover = b.top:CreateTexture(nil, "HIGHLIGHT")
    b.hover:SetAllPoints(b.icon)
    b.hover:SetColorTexture(1, 1, 1, 0.15)
    b.hover:SetBlendMode("ADD")
    if round then MakeCircle(b.hover, b.top) end

    -- Drag spells on and off (out of combat)
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or not IsShiftKeyDown() then return end
        PickupAction(self.slot)
    end)
    b:SetScript("OnReceiveDrag", function(self)
        if InCombatLockdown() or not self.slot or self.slot < 1 then return end
        PlaceAction(self.slot)
    end)
    b:SetScript("OnMouseUp", function(self)
        if not InCombatLockdown() and GetCursorInfo() and self.slot and self.slot > 0 then PlaceAction(self.slot) end
    end)
    b:SetScript("OnEnter", function(self)
        if self.slot and HasAction(self.slot) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetAction(self.slot)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- glow while dragging a spell / item over the button: "this will accept it"
    b.dropGlow = b.top:CreateTexture(nil, "OVERLAY", nil, 6)
    b.dropGlow:SetBlendMode("ADD")
    b.dropGlow:SetPoint("CENTER")
    b.dropGlow:Hide()
    local function ShowDropGlow(self)
        if not GetCursorInfo() or not self.slot or self.slot < 1 or InCombatLockdown() then return end
        local atlas = self.round and "gamepad-actionbar-fx-circGlw" or "gamepad-actionbar-fx-squareGlw"
        if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
            self.dropGlow:SetAtlas(atlas)
            self.dropGlow:SetVertexColor(1, 1, 1, 1)
        else
            self.dropGlow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
            self.dropGlow:SetVertexColor(1, 0.85, 0.3, 1)
        end
        local w = self:GetWidth() * 1.35
        self.dropGlow:SetSize(w, w)
        self.dropGlow:Show()
    end
    local function HideDropGlow(self) self.dropGlow:Hide() end
    b:HookScript("OnEnter", ShowDropGlow)
    b:HookScript("OnLeave", HideDropGlow)
    b:HookScript("OnReceiveDrag", HideDropGlow)
    b:HookScript("OnMouseUp", HideDropGlow)
    b:HookScript("OnHide", HideDropGlow)

    return b
end

-- Blizzard's own gamepad action bar art (names read from the native bar)
local ATLAS_PREFIX = { [false] = "gamepad-actionbar-squareslot-", [true] = "gamepad-actionbar-circleslot-" }
local SLOT_ATLAS = {
    "gamepad-actionbar-squareslot-generic-dpadup-normal",
    "gamepad-actionbar-squareslot-generic-dpadright-normal",
    "gamepad-actionbar-squareslot-generic-dpaddown-normal",
    "gamepad-actionbar-squareslot-generic-dpadleft-normal",
    "gamepad-actionbar-circleslot-xbox-y-normal",
    "gamepad-actionbar-circleslot-xbox-b-normal",
    "gamepad-actionbar-circleslot-xbox-a-normal",
    "gamepad-actionbar-circleslot-xbox-x-normal",
}

local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function NativeAvailable()
    return HasAtlas("gamepad-actionbar-squareslot-border-normal")
        and HasAtlas("gamepad-actionbar-circleslot-border-normal")
end

-- Button styles: native (Blizzard gamepad art), classic, minimal, flat
local STYLES = { "native", "classic", "minimal", "flat" }
local STYLE_NAMES = { native = "Native", classic = "Classic", minimal = "Minimal", flat = "Flat" }

local function CurrentStyle()
    local st = CrossHotbarDB.style
    if not STYLE_NAMES[st] then st = (CrossHotbarDB.nativeArt == false) and "flat" or "native" end
    if st == "native" and not NativeAvailable() then st = "flat" end
    return st
end

local function ApplyArt(b)
    local s = b:GetWidth()
    local style = CurrentStyle()
    local useNative = style == "native"
    b.useNative = useNative
    b.outer:SetShown(not useNative)
    b.rim:SetShown(not useNative)
    b.inner:SetShown(not useNative)
    if b.cBorder then b.cBorder:Hide() end

    if not b.nShadow then
        b.nShadow = b:CreateTexture(nil, "BACKGROUND", nil, -1)
        b.nSlot   = b:CreateTexture(nil, "BACKGROUND", nil, 0)
        b.nBorder = b.top:CreateTexture(nil, "ARTWORK", nil, 0)
        b.nHover  = b.top:CreateTexture(nil, "HIGHLIGHT", nil, 0)
        b.nSelect = b.top:CreateTexture(nil, "OVERLAY", nil, 0)
        b.nSelect:SetBlendMode("ADD")
    end
    for _, t in ipairs({ b.nShadow, b.nSlot, b.nBorder, b.nHover, b.nSelect }) do t:SetShown(useNative) end
    b.hover:SetShown(not useNative)

    if not useNative then
        local u = unit
        if style == "classic" then
            Fill(b.outer, { 0, 0, 0, 0.9 })
            Fill(b.rim, { 1, 0.82, 0, 1 })
            Fill(b.inner, { 0.05, 0.04, 0.03, 1 })
            b.outer:SetSize(s, s)
            b.rim:SetSize(s - 2 * u * 1.5, s - 2 * u * 1.5)
            b.inner:SetSize(s - 2 * u * 5, s - 2 * u * 5)
            if not b.round then
                -- the old square action bar frame
                if not b.cBorder then
                    b.cBorder = b.top:CreateTexture(nil, "ARTWORK", nil, 0)
                    b.cBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
                    b.cBorder:SetPoint("CENTER")
                end
                b.cBorder:SetSize(s * 1.66, s * 1.66)
                b.cBorder:Show()
                b.rim:Hide()
            end
            local iconSize = s - 2 * u * 5
            b.icon:SetSize(iconSize, iconSize)
        elseif style == "minimal" then
            Fill(b.outer, { 0, 0, 0, 0.85 })
            b.outer:SetSize(s, s)
            b.rim:Hide()
            b.inner:Hide()
            local iconSize = s - 2 * u * 2.5
            b.icon:SetSize(iconSize, iconSize)
        else -- flat
            Fill(b.outer, COLOR_DARK)
            Fill(b.rim, COLOR_BRONZE)
            Fill(b.inner, COLOR_DARK)
            local iconSize = s - 2 * u * 6
            b.icon:SetSize(iconSize, iconSize)
        end
        return
    end

    local pre = ATLAS_PREFIX[b.round]
    b.nShadow:SetAtlas(pre .. "dropshadow")
    b.nShadow:ClearAllPoints()
    b.nShadow:SetPoint("CENTER")
    b.nShadow:SetSize(s * 1.25, s * 1.25)

    local slotAtlas = SLOT_ATLAS[b.index]
    b.hasSlotArt = HasAtlas(slotAtlas)
    if b.hasSlotArt then
        b.nSlot:SetAtlas(slotAtlas)
        b.nSlot:SetAllPoints()
    end
    b.nSlot:SetShown(b.hasSlotArt)

    b.nBorder:SetAtlas(pre .. "border-normal")
    b.nBorder:SetAllPoints()
    b.nHover:SetAtlas(pre .. "border-hover")
    b.nHover:SetAllPoints()
    b.nSelect:SetAtlas(pre .. "border-selected")
    b.nSelect:ClearAllPoints()
    b.nSelect:SetPoint("CENTER")
    b.nSelect:SetSize(s * 1.25, s * 1.25)
    b.nSelect:Hide()

    local iconSize = s * 26 / 32
    b.icon:SetSize(iconSize, iconSize)
end

local function SetPressed(b, pressed)
    if b.useNative then
        b.nBorder:SetAtlas(ATLAS_PREFIX[b.round] .. (pressed and "border-pressed" or "border-normal"))
    else
        b.press:SetShown(pressed)
    end
end

local clusters = {}

local function MakeCluster(key, title)
    local c = CreateFrame("Frame", "XHB_Cluster" .. key, UIParent)
    c:SetFrameStrata("HIGH")
    c.key = key
    c.buttons = {}
    for i = 1, 8 do c.buttons[i] = MakeButton(c, i) end
    c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.title:SetPoint("BOTTOM", c, "TOP", 0, 0)
    c.title:SetText("")
    c.title:Hide()

    -- faded backing like the native gamepad bar
    c.bgD = c:CreateTexture(nil, "BACKGROUND", nil, -8)
    c.bgF = c:CreateTexture(nil, "BACKGROUND", nil, -8)

    -- trigger icons under the group
    c.badge = CreateFrame("Frame", nil, c)
    c.badge.icons, c.badge.texts = {}, {}
    for k = 1, 2 do
        c.badge.icons[k] = c.badge:CreateTexture(nil, "OVERLAY")
        c.badge.texts[k] = c.badge:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    end
    c.badge.sep = c.badge:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.badge.sep:SetTextColor(1, 1, 1)
    c:Hide()
    return c
end

local TRIGGER_KEYS = {
    L = { "PADLTRIGGER" }, R = { "PADRTRIGGER" },
    LL = { "PADLTRIGGER", "PADLTRIGGER" }, RR = { "PADRTRIGGER", "PADRTRIGGER" },
    LR = { "PADLTRIGGER", "PADRTRIGGER" },
}
local TRIGGER_TEXT = { PADLTRIGGER = "LT", PADRTRIGGER = "RT" }

local function TriggerAtlas(key)
    local u = InputIconTextureSetUtility
    if u and u.GetNormalActiveInputIconButtonTexture then
        local ok, a = pcall(u.GetNormalActiveInputIconButtonTexture, key)
        if ok and type(a) == "string" and HasAtlas(a) then return a end
    end
    return nil
end

local function SetBadge(c, set)
    local bd = c.badge
    local keys = set and TRIGGER_KEYS[set]
    if not keys then bd:Hide() return end
    local sz = ((set == "LL" or set == "RR") and 44 or 72) * unit
    local gap = (set == "LR") and 26 * unit or 0
    local n = #keys
    for k = 1, 2 do
        local icon, text = bd.icons[k], bd.texts[k]
        icon:Hide(); text:Hide()
        local key = keys[k]
        if key then
            local x = (n == 1) and 0 or ((k == 1) and -(sz / 2 + gap) or (sz / 2 + gap))
            local atlas = TriggerAtlas(key)
            if atlas then
                icon:SetAtlas(atlas)
                icon:SetSize(sz, sz)
                icon:ClearAllPoints()
                icon:SetPoint("CENTER", bd, "CENTER", x, 0)
                icon:Show()
            else
                text:SetFont(STANDARD_TEXT_FONT, math.max(10, 26 * unit), "OUTLINE")
                text:SetText(TRIGGER_TEXT[key])
                text:ClearAllPoints()
                text:SetPoint("CENTER", bd, "CENTER", x, 0)
                text:Show()
            end
        end
    end
    bd.sep:SetFont(STANDARD_TEXT_FONT, math.max(12, 36 * unit), "OUTLINE")
    bd.sep:SetText(set == "LR" and "+" or "")
    bd.sep:ClearAllPoints()
    bd.sep:SetPoint("CENTER", bd, "CENTER", 0, 0)
    bd:Show()
end

-- Layout (FFXIV style):
--   top row:    LT x2 flyout | base set (or LT + RT while both held) | RT x2 flyout
--   bottom row: LT bar | RT bar, just above the XP bar
clusters.L  = MakeCluster("L", "LT")
clusters.R  = MakeCluster("R", "RT")
clusters.C  = MakeCluster("C", "")
clusters.LL = MakeCluster("LL", "LT x2")
clusters.RR = MakeCluster("RR", "RT x2")
-- flyouts only use the face buttons
clusters.LL.faceOnly = true
clusters.X  = MakeCluster("X", "") -- LT + RT, shown only as a drop target while dragging
clusters.RR.faceOnly = true

local LAYOUT = {
    bottomY = 135,  -- bottom row center, ref px above the screen bottom
    bottomX = 240,  -- LT / RT bars left and right of center
    bottomScale = 0.85,
    topY = 305,     -- top row center (flyouts and base set)
    centerScale = 0.55,
    flyX = 240,     -- flyouts sit right above the LT / RT bars
    flyY = 225,     -- lower than the base set so they clear the unit frames
}

local function LayoutCluster(c, scale, x, y)
    c:SetScale(scale)
    c:SetSize(500 * unit, 160 * unit)
    c:ClearAllPoints()
    c:SetPoint("CENTER", UIParent, "BOTTOM", x / scale, y / scale)
    for i, b in ipairs(c.buttons) do
        local s = (b.round and REF.round or REF.square) * unit
        b:SetSize(s, s)
        b:ClearAllPoints()
        if c.faceOnly then
            -- only Y/B/A/X, re-centered on the cluster
            b:SetShown(i > 4)
            b:SetPoint("CENTER", c, "CENTER", (REF.pos[i][1] - 125) * unit, REF.pos[i][2] * unit)
        else
            b:Show()
            b:SetPoint("CENTER", c, "CENTER", REF.pos[i][1] * unit, REF.pos[i][2] * unit)
        end
        SizeFrameParts(b, s)
        if b.round then
            b.glyph:SetFont(STANDARD_TEXT_FONT, math.max(10, 30 * unit), "OUTLINE")
        else
            b.glyph:SetSize(s * 0.42, s * 0.42)
        end
        ApplyArt(b)
    end
    c.title:SetFont(STANDARD_TEXT_FONT, math.max(10, 20 * unit), "OUTLINE")

    local BG_ATLAS = "gamepad-actionbar-focus-BG-section"
    local hasBG = HasAtlas(BG_ATLAS)
    local bg = c.bgD
    if hasBG then bg:SetAtlas(BG_ATLAS) end
    if c.faceOnly then
        bg:SetSize(400 * unit, 230 * unit)
    else
        bg:SetSize(730 * unit, 240 * unit)
    end
    bg:SetAlpha(1)
    bg:ClearAllPoints()
    bg:SetPoint("CENTER", c, "CENTER", 0, 0)
    bg:SetShown(hasBG)
    c.bgF:Hide()

    -- trigger icon: centered at the bottom, between D-pad and face buttons
    c.badge:SetSize(240 * unit, 80 * unit)
    c.badge:ClearAllPoints()
    c.badge:SetPoint("CENTER", c, "CENTER", 0, (c.faceOnly and -92 or -70) * unit)
end

local movingPlayer = false
local function PlacePlayerFrame()
    local pf = _G.PlayerFrame
    local fl = clusters.LL
    if not pf or not fl or InCombatLockdown() or CrossHotbarDB.movePlayer ~= true then return end
    local cx, cy = fl:GetCenter()
    if not cx then return end
    local fs = fl:GetEffectiveScale()
    -- right edge of the flyout's face buttons, and their top edge (screen pixels)
    local right = (cx + 105 * unit) * fs
    local top = (cy + 85 * unit) * fs
    local ps = pf:GetEffectiveScale()
    movingPlayer = true
    pf:ClearAllPoints()
    pf:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", right / ps, top / ps)
    movingPlayer = false
end

if PlayerFrame then
    hooksecurefunc(PlayerFrame, "SetPoint", function()
        if movingPlayer or InCombatLockdown() or not CrossHotbarDB.scale then return end
        C_Timer.After(0, PlacePlayerFrame)
    end)
end

local function Layout()
    if not CrossHotbarDB.scale then return end
    unit = UIParent:GetHeight() / REF_H
    local sc = CrossHotbarDB.scale
    local ox, oy = CrossHotbarDB.offsetX, CrossHotbarDB.offsetY
    local by = LAYOUT.bottomY * unit * sc + oy
    local ty = LAYOUT.topY * unit * sc + oy

    LayoutCluster(clusters.L, sc * LAYOUT.bottomScale, ox - LAYOUT.bottomX * unit * sc, by)
    LayoutCluster(clusters.R, sc * LAYOUT.bottomScale, ox + LAYOUT.bottomX * unit * sc, by)
    LayoutCluster(clusters.C, sc * LAYOUT.centerScale, ox, ty)
    local fy = LAYOUT.flyY * unit * sc + oy
    LayoutCluster(clusters.LL, sc * CrossHotbarDB.flyoutScale, ox - LAYOUT.flyX * unit * sc, fy)
    LayoutCluster(clusters.RR, sc * CrossHotbarDB.flyoutScale, ox + LAYOUT.flyX * unit * sc, fy)
    LayoutCluster(clusters.X, sc * LAYOUT.bottomScale, 0, ty)
    clusters.X:Hide()
    PlacePlayerFrame()
end

local function UpdateButton(b)
    local tex = b.slot and b.slot > 0 and GetActionTexture(b.slot) or nil
    b.icon:SetTexture(tex)
    b.icon:SetShown(tex ~= nil)
    b.glyph:SetShown(tex == nil and not (b.useNative and b.hasSlotArt))

    if not tex then
        b.count:SetText("")
        b.cooldown:Clear()
        return
    end
    local stackable = IsConsumableAction(b.slot) or (IsStackableAction and IsStackableAction(b.slot))
    b.count:SetText(stackable and GetActionCount(b.slot) or "")

    local usable, noMana = IsUsableAction(b.slot)
    if usable then
        b.icon:SetVertexColor(1, 1, 1)
    elseif noMana then
        b.icon:SetVertexColor(0.5, 0.5, 1)
    else
        b.icon:SetVertexColor(0.4, 0.4, 0.4)
    end
    local start, duration, enable = GetActionCooldown(b.slot)
    if start and duration then
        CooldownFrame_Set(b.cooldown, start, duration, enable)
    end
end

-- Blizzard's controller glyph for a button (follows Xbox / PlayStation style)
local function ButtonGlyph(key)
    local u = InputIconTextureSetUtility
    if u and u.GetNormalActiveInputIconButtonTexture then
        local ok, a = pcall(u.GetNormalActiveInputIconButtonTexture, key)
        if ok and type(a) == "string" and HasAtlas(a) then return a end
    end
    return nil
end

local function FillCluster(c, set)
    for i, b in ipairs(c.buttons) do
        b.slot = SlotFor(set, i)
        UpdateButton(b)
        local show = CrossHotbarDB.showLabels and b.slot > 0 and GetActionTexture(b.slot) ~= nil
        local glyph = show and ButtonGlyph(KEYS[i])
        if glyph then
            local sz = b:GetWidth() * 0.42
            b.hotkeyIcon:SetAtlas(glyph)
            b.hotkeyIcon:SetSize(sz, sz)
            b.hotkeyIcon:Show()
            b.hotkey:Hide()
        else
            b.hotkeyIcon:Hide()
            b.hotkey:SetShown(show)
        end
    end
end

local function Light(c, isActive, dimAlpha)
    c:SetAlpha(isActive and 1 or dimAlpha)
    if c.bgD then c.bgD:SetAlpha(1) end
    for _, b in ipairs(c.buttons) do
        if b.nSelect then b.nSelect:Hide() end
    end
    if isActive then
        c.title:SetTextColor(0.4, 0.8, 1)
    else
        c.title:SetTextColor(1, 0.82, 0)
    end
end

local function Refresh()
    if not CrossHotbarDB.base then return end
    if suspended then
        -- flyouts appear only while a spell / item is on the cursor, as drop targets
        local holding = GetCursorInfo() ~= nil
        local W, H = UIParent:GetWidth(), UIParent:GetHeight()
        -- key = { x fraction, y fraction, set }
        local DRAG = {
            LL = { 0.60, 0.56, "LL" }, C = { 0.76, 0.56, "base" }, RR = { 0.91, 0.56, "RR" },
            L  = { 0.60, 0.32, "L" },  X = { 0.76, 0.32, "LR" },   R  = { 0.91, 0.32, "R" },
        }
        for key, c in pairs(clusters) do
            local d = DRAG[key]
            if holding and d then
                local sc = 0.6
                c:SetScale(sc)
                c:ClearAllPoints()
                c:SetPoint("CENTER", UIParent, "BOTTOMLEFT", (W * d[1]) / sc, (H * d[2]) / sc)
                FillCluster(c, d[3])
                Light(c, true, 1)
                SetBadge(c, d[3] ~= "base" and d[3] or nil)
                if d[3] == "base" then
                    -- base face buttons are jump / cancel / interact / menu
                    for i, b in ipairs(c.buttons) do b:SetShown(i <= 4) end
                end
                c:Show()
            else
                c:Hide()
            end
        end
        if XHB_EditHint then XHB_EditHint:Hide() end
        return
    end
    local mode = header:GetAttribute("mode") or "none"
    local editing = panel and panel:IsShown() and mode == "none"
    local dim = CrossHotbarDB.dimAlpha or 0.45

    -- Bottom row: LT and RT, always visible, lit while held
    for _, set in ipairs({ "L", "R" }) do
        local c = clusters[set]
        FillCluster(c, set)
        Light(c, mode == set or (editing and editSet == set), dim)
        SetBadge(c, set)
        c:Show()
    end

    -- Top center: base set, or LT + RT while both triggers are held
    local c = clusters.C
    local showLR = (mode == "LR") or (editing and editSet == "LR")
    if XHB_EditHint then XHB_EditHint:SetShown(mode == "LR") end
    if showLR then
        FillCluster(c, "LR")
        SetBadge(c, "LR")
        Light(c, true, dim)
        c:Show()
    elseif CrossHotbarDB.hideNative then
        FillCluster(c, "base")
        SetBadge(c, nil)
        Light(c, mode == "none", dim)
        -- shadow only darkens when both triggers are held
        if c.bgD then c.bgD:SetAlpha(dim * 0.7) end
        c:Show()
    else
        c:Hide()
    end

    -- Flyouts: always visible (unless turned off), lit when active
    for _, set in ipairs({ "LL", "RR" }) do
        local f = clusters[set]
        local isActive = (mode == set) or (editing and editSet == set)
        if CrossHotbarDB.showFlyouts or isActive then
            FillCluster(f, set)
            Light(f, isActive, dim)
            SetBadge(f, set)
            f:Show()
        else
            f:Hide()
        end
    end
end

-- Flash the on-screen button when its controller button is pressed
local MODE_CLUSTER = { L = "L", R = "R", LR = "C", LL = "LL", RR = "RR" }
for i, a in ipairs(active) do
    a:HookScript("OnClick", function()
        local mode = header:GetAttribute("mode") or "none"
        local c = clusters[MODE_CLUSTER[mode] or "C"]
        local b = c.buttons[i]
        SetPressed(b, true)
        C_Timer.After(0.12, function() SetPressed(b, false) end)
    end)
end

header:HookScript("OnAttributeChanged", function(self, name, value)
    if name == "mode" then
        Refresh()
    elseif name == "armed" and value then
        -- Out of combat, a tap stays armed briefly, like a real double-tap.
        -- In combat this can't be timed, so it stays armed until the next press.
        C_Timer.After(CrossHotbarDB.doubleTap or 0.3, function()
            if not InCombatLockdown() and self:GetAttribute("armed") == value then
                self:SetAttribute("armed", nil)
            end
        end)
    end
end)

local function LoadNativeArt(report)
    local found = NativeAvailable()
    Layout()
    Refresh()
    if report then
        if found then
            print("CrossHotbar: using the native button art.")
        else
            print("CrossHotbar: couldn't read the native button art, using the built-in look.")
        end
    end
    return found
end

---------------------------------------------------------------------------
-- Setup (must run out of combat)
---------------------------------------------------------------------------
local function PushSlots()
    if InCombatLockdown() then return end
    for _, set in ipairs(SETS) do
        for i = 1, 8 do
            header:SetAttribute("slot-" .. set .. "-" .. i, SlotFor(set, i))
        end
    end
end

-- Read the action slots the native gamepad bars use, so LT / RT / LT + RT
-- show the same spells as Blizzard's bar. Native button order:
-- 1 Left, 2 Up, 3 Right, 4 Down, 5 X, 6 Y, 7 B, 8 A.
local NATIVE_INDEX = { 2, 3, 4, 1, 6, 7, 8, 5 } -- ours: Up Rt Dn Lt Y B A X
local NATIVE_BARS = {
    base = "GamepadMainActionBarFramePageUnitTopCenteredAnchorTopBar",
    L    = "GamepadMainActionBarFramePageUnitLeftCenteredAnchorLeftBar",
    R    = "GamepadMainActionBarFramePageUnitRightCenteredAnchorRightBar",
    LR   = "GamepadMainActionBarFramePageUnitBottomCenteredAnchorBottomBar",
}

local function NativeAction(btn)
    if not btn then return nil end
    local a = btn.action
    if type(a) ~= "number" then
        local ok, v = pcall(btn.GetAttribute, btn, "action")
        if ok and type(v) == "number" then a = v end
    end
    if type(a) ~= "number" and btn.CalculateAction then
        local ok, v = pcall(btn.CalculateAction, btn)
        if ok and type(v) == "number" then a = v end
    end
    if type(a) ~= "number" and ActionButton_CalculateAction then
        local ok, v = pcall(ActionButton_CalculateAction, btn)
        if ok and type(v) == "number" then a = v end
    end
    return a
end

local function ReadNativeSlots(report)
    if InCombatLockdown() then return end
    local found = {}
    for key, barName in pairs(NATIVE_BARS) do
        local list, ok = {}, true
        for n = 1, 8 do
            local a = NativeAction(_G[barName .. "ActionButton" .. n])
            if not a then ok = false end
            list[n] = a
        end
        if ok then found[key] = list end
    end
    CrossHotbarDB.slots = CrossHotbarDB.slots or {}
    local lines = {}
    if found.base then
        local mine = {}
        for i = 1, 8 do mine[i] = found.base[NATIVE_INDEX[i]] end
        CrossHotbarDB.slots.base = mine
    end
    for _, set in ipairs({ "L", "R", "LR" }) do
        local list = found[set]
        if list then
            local mine = {}
            for i = 1, 8 do mine[i] = list[NATIVE_INDEX[i]] end
            CrossHotbarDB.slots[set] = mine
            lines[#lines + 1] = string.format("%s: %s", SET_NAMES[set], table.concat(mine, ","))
        else
            lines[#lines + 1] = SET_NAMES[set] .. ": native bar not found, keeping own slots"
        end
    end
    PushSlots()
    if Refresh then Refresh() end
    if report then
        print("CrossHotbar: matched native slots")
        for _, l in ipairs(lines) do print("  " .. l) end
    end
end

local hidingNative = false
local KEEP_NATIVE = { FriendlyTargeting = true, HostileTargeting = true, Shortcuts = true }

local function NativeHideTargets()
    local list = {}
    local root = _G["GamepadMainActionBarFrame"]
    if not root then return list end
    local pageUnit = _G["GamepadMainActionBarFramePageUnit"]
    for _, c in ipairs({ root:GetChildren() }) do
        if c ~= pageUnit then list[#list + 1] = c end
    end
    for _, r in ipairs({ root:GetRegions() }) do list[#list + 1] = r end
    if pageUnit then
        for _, c in ipairs({ pageUnit:GetChildren() }) do
            local name = c:GetName() or ""
            local keep = false
            for k in pairs(KEEP_NATIVE) do
                if name:find(k, 1, true) then keep = true end
            end
            if not keep then list[#list + 1] = c end
        end
        for _, r in ipairs({ pageUnit:GetRegions() }) do list[#list + 1] = r end
    end
    return list
end

local function ApplyNativeVisibility()
    for _, f in ipairs(NativeHideTargets()) do
        if f.SetAlpha then
            if not f.xhbHooked then
                f.xhbHooked = true
                hooksecurefunc(f, "SetAlpha", function(self, a)
                    if hidingNative or suspended or not CrossHotbarDB.hideNative or a == 0 then return end
                    hidingNative = true
                    self:SetAlpha(0)
                    hidingNative = false
                end)
            end
            hidingNative = true
            f:SetAlpha((CrossHotbarDB.hideNative and not suspended) and 0 or 1)
            hidingNative = false
        end
    end
end

local function MatchNativeStrata()
    local root = _G["GamepadMainActionBarFrame"]
    local strata = root and root:GetFrameStrata() or "MEDIUM"
    local level = root and root:GetFrameLevel() or 1
    for _, c in pairs(clusters) do
        c:SetFrameStrata(strata)
        c:SetFrameLevel(level + 2)
    end
end

local function BindTriggers()
    SetOverrideBindingClick(triggers.L, true, "PADLTRIGGER", "XHB_TriggerL")
    SetOverrideBindingClick(triggers.R, true, "PADRTRIGGER", "XHB_TriggerR")
end

-- Panels where Blizzard's own bar and bind flow should take over
local PANEL_NAMES = {
    "SpellBookFrame", "PlayerSpellsFrame", "ContainerFrameCombinedBags",
    "CharacterFrame", "TradeSkillFrame", "CraftFrame", "ProfessionsFrame",
}
for i = 1, 13 do PANEL_NAMES[#PANEL_NAMES + 1] = "ContainerFrame" .. i end

local function AnyPanelOpen()
    for _, name in ipairs(PANEL_NAMES) do
        local f = _G[name]
        if f and f.IsShown and f:IsShown() then return true end
    end
    return false
end

local function SetSuspended(on)
    if on == suspended or InCombatLockdown() then return end
    suspended = on
    if on then
        -- release everything so the native bind flow gets every button
        header:SetAttribute("heldL", nil)
        header:SetAttribute("heldR", nil)
        header:SetAttribute("armed", nil)
        header:Execute([[ self:RunAttribute("_apply", "none") ]])
        ClearOverrideBindings(triggers.L)
        ClearOverrideBindings(triggers.R)
        ApplyNativeVisibility()
        Refresh()
    else
        BindTriggers()
        ReadNativeSlots(false)
        ApplyNativeVisibility()
        Layout()
        Refresh()
    end
end

C_Timer.NewTicker(0.25, function()
    if not CrossHotbarDB.base or InCombatLockdown() then return end
    local open = AnyPanelOpen()
    if open ~= suspended then SetSuspended(open) end
end)

local function Setup()
    PushSlots()
    BindTriggers()
    MatchNativeStrata()
    Layout()
    Refresh()
end

do
    local cursorWatch = CreateFrame("Frame")
    for _, e in ipairs({ "CURSOR_CHANGED", "CURSOR_UPDATE", "ACTIONBAR_SHOWGRID", "ACTIONBAR_HIDEGRID" }) do
        pcall(cursorWatch.RegisterEvent, cursorWatch, e)
    end
    local lastHolding = false
    C_Timer.NewTicker(0.1, function()
        if not suspended then lastHolding = false return end
        local h = GetCursorInfo() ~= nil
        if h ~= lastHolding then
            lastHolding = h
            Refresh()
        end
    end)
    cursorWatch:SetScript("OnEvent", function()
        if not suspended then return end
        Refresh()
        C_Timer.After(0.05, Refresh) -- the cursor can clear a moment after the event
    end)
end

local pendingSetup = false
local artLoaded = false
local events = CreateFrame("Frame")
for _, e in ipairs({
    "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
    "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_USABLE",
    "PLAYER_ENTERING_WORLD", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED",
}) do
    events:RegisterEvent(e)
end

events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        LoadSettings()
        if InCombatLockdown() then
            pendingSetup = true
        else
            Setup()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        Refresh()
        if not artLoaded then
            artLoaded = true
            -- give the native bar a moment to build before copying its art
            C_Timer.After(2, function()
                LoadNativeArt(false)
                ReadNativeSlots(true)
                ApplyNativeVisibility()
                MatchNativeStrata()
                Refresh()
            end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingSetup then
            pendingSetup = false
            Setup()
        end
        header:SetAttribute("armed", nil)
    elseif event == "PLAYER_REGEN_DISABLED" then
        if panel and panel:IsShown() then panel:Hide() end
    elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        Layout()
        Refresh()
    else
        Refresh()
    end
end)

---------------------------------------------------------------------------
-- Settings panel (controller or mouse)
--   D-pad up/down: choose   D-pad left/right: adjust   A: select   B: close
---------------------------------------------------------------------------
panel = CreateFrame("Frame", "XHB_Config", UIParent, "BackdropTemplate")
panel:SetSize(360, 510)
panel:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
panel:SetFrameStrata("DIALOG")
panel:EnableMouse(true)
panel:Hide()
panel:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})

local headerArt = panel:CreateTexture(nil, "ARTWORK")
headerArt:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
headerArt:SetSize(256, 64)
headerArt:SetPoint("TOP", panel, "TOP", 0, 12)

local panelTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panelTitle:SetPoint("TOP", headerArt, "TOP", 0, -14)
panelTitle:SetText("CrossHotbar")

local tip = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
tip:SetPoint("BOTTOM", panel, "BOTTOM", 0, 42)
tip:SetWidth(310)
tip:SetText("Drag spells onto the bar to fill the set shown.")

local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("BOTTOM", panel, "BOTTOM", 0, 22)

local selected = 1
local moving = false

local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function Round(v) return math.floor(v * 100 + 0.5) / 100 end

local function IndexOf(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return 1
end

local ROWS = {
    {
        label = "Set to edit",
        value = function() return SET_NAMES[editSet] end,
        adjust = function(d)
            local i = IndexOf(SETS, editSet) + d
            if i < 1 then i = #SETS elseif i > #SETS then i = 1 end
            editSet = SETS[i]
            Refresh()
        end,
    },
    {
        label = "Double-tap window",
        value = function() return string.format("%.2fs", CrossHotbarDB.doubleTap) end,
        adjust = function(d)
            CrossHotbarDB.doubleTap = Clamp(Round(CrossHotbarDB.doubleTap + d * 0.05), 0.15, 0.6)
        end,
    },
    {
        label = "Dim when not held",
        value = function() return string.format("%d%%", CrossHotbarDB.dimAlpha * 100 + 0.5) end,
        adjust = function(d)
            CrossHotbarDB.dimAlpha = Clamp(Round(CrossHotbarDB.dimAlpha + d * 0.05), 0.1, 1)
            Refresh()
        end,
    },
    {
        label = "Size",
        value = function() return string.format("%d%%", CrossHotbarDB.scale * 100 + 0.5) end,
        adjust = function(d)
            CrossHotbarDB.scale = Clamp(Round(CrossHotbarDB.scale + d * 0.05), 0.5, 2)
            Layout()
        end,
    },
    {
        label = "Flyout size",
        value = function() return string.format("%d%%", CrossHotbarDB.flyoutScale * 100 + 0.5) end,
        adjust = function(d)
            CrossHotbarDB.flyoutScale = Clamp(Round(CrossHotbarDB.flyoutScale + d * 0.05), 0.4, 1.2)
            Layout()
        end,
    },
    {
        label = "Flyouts always visible",
        value = function() return CrossHotbarDB.showFlyouts and "On" or "Off" end,
        adjust = function()
            CrossHotbarDB.showFlyouts = not CrossHotbarDB.showFlyouts
            Refresh()
        end,
    },
    {
        label = "Hide Blizzard's bar",
        value = function() return CrossHotbarDB.hideNative and "On" or "Off" end,
        adjust = function()
            CrossHotbarDB.hideNative = not CrossHotbarDB.hideNative
            ApplyNativeVisibility()
            Refresh()
        end,
    },
    {
        label = "Move player frame",
        value = function() return CrossHotbarDB.movePlayer == true and "On" or "Off" end,
        adjust = function()
            CrossHotbarDB.movePlayer = not (CrossHotbarDB.movePlayer == true)
            if CrossHotbarDB.movePlayer then PlacePlayerFrame() else print("CrossHotbar: /reload to put the player frame back.") end
        end,
    },
    {
        label = "Button style",
        value = function() return STYLE_NAMES[CurrentStyle()] end,
        adjust = function(d)
            local cur = CrossHotbarDB.style or CurrentStyle()
            local i = 1
            for k, v in ipairs(STYLES) do if v == cur then i = k end end
            i = i + d
            if i < 1 then i = #STYLES elseif i > #STYLES then i = 1 end
            CrossHotbarDB.style = STYLES[i]
            Layout()
            Refresh()
        end,
    },
    {
        label = "Button labels",
        value = function() return CrossHotbarDB.showLabels and "On" or "Off" end,
        adjust = function()
            CrossHotbarDB.showLabels = not CrossHotbarDB.showLabels
            Refresh()
        end,
    },
    {
        label = "Move bars",
        value = function() return moving and "|cff66ccffMoving|r" or "Press A" end,
        activate = function() moving = not moving end,
    },
    {
        label = "Reset position and size",
        value = function() return "Press A" end,
        activate = function()
            CrossHotbarDB.offsetX, CrossHotbarDB.offsetY = 0, 0
            CrossHotbarDB.scale, CrossHotbarDB.flyoutScale = 1, 0.5
            Layout()
        end,
    },
    {
        label = "Close",
        value = function() return "" end,
        activate = function() panel:Hide() end,
    },
}

local rowFrames = {}
local function UpdatePanel()
    for i, r in ipairs(rowFrames) do
        r.value:SetText(ROWS[i].value())
        r.highlight:SetShown(i == selected)
        r.label:SetFontObject(i == selected and "GameFontHighlight" or "GameFontNormal")
    end
    if moving then
        hint:SetText("D-pad: move the bars    A or B: done")
    else
        hint:SetText("D-pad: choose / adjust    A: select    B: close")
    end
end

for i, row in ipairs(ROWS) do
    local r = CreateFrame("Button", nil, panel)
    r:SetSize(310, 26)
    r:SetPoint("TOP", panel, "TOP", 0, -34 - (i - 1) * 30)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    r.highlight = r:CreateTexture(nil, "BACKGROUND")
    r.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    r.highlight:SetBlendMode("ADD")
    r.highlight:SetAllPoints()

    r.label = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.label:SetPoint("LEFT", r, "LEFT", 8, 0)
    r.label:SetText(row.label)

    r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.value:SetPoint("RIGHT", r, "RIGHT", -8, 0)

    r:SetScript("OnClick", function(_, mouseButton)
        selected = i
        if row.adjust then
            row.adjust(mouseButton == "RightButton" and -1 or 1)
        elseif row.activate then
            row.activate()
        end
        if panel:IsShown() then UpdatePanel() end
    end)
    rowFrames[i] = r
end

local function MoveBy(dx, dy)
    CrossHotbarDB.offsetX = CrossHotbarDB.offsetX + dx
    CrossHotbarDB.offsetY = CrossHotbarDB.offsetY + dy
    Layout()
end

panel:SetScript("OnGamePadButtonDown", function(self, button)
    if moving then
        if button == "PADDUP" then MoveBy(0, 6)
        elseif button == "PADDDOWN" then MoveBy(0, -6)
        elseif button == "PADDLEFT" then MoveBy(-6, 0)
        elseif button == "PADDRIGHT" then MoveBy(6, 0)
        elseif button == "PAD1" or button == "PAD2" then moving = false
        end
        UpdatePanel()
        return
    end

    local row = ROWS[selected]
    if button == "PADDUP" then
        selected = selected > 1 and selected - 1 or #ROWS
    elseif button == "PADDDOWN" then
        selected = selected < #ROWS and selected + 1 or 1
    elseif button == "PADDLEFT" and row.adjust then
        row.adjust(-1)
    elseif button == "PADDRIGHT" and row.adjust then
        row.adjust(1)
    elseif button == "PAD1" then
        if row.activate then row.activate() elseif row.adjust then row.adjust(1) end
    elseif button == "PAD2" then
        self:Hide()
        return
    end
    if self:IsShown() then UpdatePanel() end
end)

panel:SetScript("OnShow", function(self)
    if self.EnableGamePadButton then self:EnableGamePadButton(true) end
    selected, moving = 1, false
    UpdatePanel()
    Refresh()
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
end)

panel:SetScript("OnHide", function(self)
    if self.EnableGamePadButton then self:EnableGamePadButton(false) end
    moving = false
    Refresh()
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851)
end)

local function ToggleEditPanel()
    if InCombatLockdown() then
        print("CrossHotbar: can't edit during combat.")
        return
    end
    panel:SetShown(not panel:IsShown())
end

local optionsCategory -- set when the Options panel is registered
OpenConfig = function()
    if InCombatLockdown() then
        print("CrossHotbar: settings can't be opened during combat.")
        return
    end
    if XHB_Options then
        XHB_Options:SetShown(not XHB_Options:IsShown())
    else
        ToggleEditPanel()
    end
end

---------------------------------------------------------------------------
-- Troubleshooting
---------------------------------------------------------------------------
local function DebugInfo()
    debugMode = not debugMode
    print("CrossHotbar: debug " .. (debugMode and "on - press LT and RT and watch chat." or "off."))
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_CROSSHOTBAR1 = "/xhb"
SlashCmdList["CROSSHOTBAR"] = function(msg)
    local cmd, a, b = (msg or ""):match("^(%S*)%s*(%S*)%s*(%S*)")
    cmd = cmd:lower()

    if cmd == "slots" then
        for _, set in ipairs(SETS) do
            local list = {}
            for i = 1, 8 do list[i] = SlotFor(set, i) end
            print(string.format("  %s: %s", SET_NAMES[set], table.concat(list, ",")))
        end
    elseif cmd == "debug" then
        DebugInfo()
    elseif cmd == "native" then
        ReadNativeSlots(true)
    elseif cmd == "art" then
        LoadNativeArt(true)
    elseif cmd == "set" then
        if InCombatLockdown() then print("CrossHotbar: not during combat.") return end
        local set, slot = a:upper(), tonumber(b)
        if CrossHotbarDB.base[set] and slot and slot >= 1 and slot <= 113 then
            CrossHotbarDB.base[set] = slot
            if CrossHotbarDB.slots then CrossHotbarDB.slots[set] = nil end
            PushSlots()
            Refresh()
            print(string.format("CrossHotbar: %s now uses slots %d-%d", SET_NAMES[set], slot, slot + 7))
        else
            print("CrossHotbar: /xhb set <L|R|LR|LL|RR> <slot 1-113>")
        end
    elseif cmd == "edit" then
        ToggleEditPanel()
    elseif cmd == "help" then
        print("|cffffd100CrossHotbar|r: /xhb opens settings (or hold LT + RT and press View).")
        print("  /xhb slots - which action slots each set uses")
        print("  /xhb set <L|R|LR|LL|RR> <slot> - change a set's first slot")
        print("  /xhb edit - small drag & drop panel for filling sets")
        print("  /xhb native - copy the native bars' slots for LT, RT and LT + RT")
        print("  /xhb debug - check that the triggers reach the addon")
    else
        OpenConfig()
    end
end


---------------------------------------------------------------------------
-- "(View) Edit" prompt shown while both triggers are held
---------------------------------------------------------------------------
do
    local hint = CreateFrame("Frame", "XHB_EditHint", UIParent, "BackdropTemplate")
    hint:SetSize(96, 30)
    hint:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    hint:SetBackdropColor(0, 0, 0, 0.85)
    hint:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    hint.icon = hint:CreateTexture(nil, "OVERLAY")
    hint.icon:SetSize(20, 20)
    hint.icon:SetPoint("LEFT", hint, "LEFT", 8, 0)
    hint.text = hint:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hint.text:SetText("Edit")
    hint:SetScript("OnShow", function(self)
        local glyph = ButtonGlyph("PADBACK")
        if glyph then
            self.icon:SetAtlas(glyph)
            self.icon:Show()
            self.text:SetPoint("LEFT", self.icon, "RIGHT", 6, 0)
        else
            self.icon:Hide()
            self.text:SetText("View: Edit")
            self.text:SetPoint("CENTER")
        end
        self:SetFrameStrata(clusters.C:GetFrameStrata())
        self:ClearAllPoints()
        self:SetPoint("BOTTOM", clusters.C, "TOP", 0, 0)
    end)
    hint:Hide()
end

---------------------------------------------------------------------------
-- Settings window (its own window, fully controller driven)
--   D-pad up/down: choose   D-pad left/right: adjust   A: select   B: close
---------------------------------------------------------------------------
do
    local f = CreateFrame("Frame", "XHB_Options", UIParent, "BackdropTemplate")
    f:SetSize(640, 560)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:Hide()
    tinsert(UISpecialFrames, "XHB_Options") -- Esc closes it

    local header = f:CreateTexture(nil, "ARTWORK")
    header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    header:SetSize(300, 64)
    header:SetPoint("TOP", f, "TOP", 0, 12)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", header, "TOP", 0, -14)
    title:SetText("CrossHotbar")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    local nav, focus = {}, 1
    local function fs(r, key, name) return r[key] or (name and _G[name .. key]) end

    local sliderCount = 0
    local function Slider(label, lowText, highText, min, max, step, get, set, fmt, x, y)
        sliderCount = sliderCount + 1
        local name = "XHB_OptionsSlider" .. sliderCount
        local sl = CreateFrame("Slider", name, f, "OptionsSliderTemplate")
        sl:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        sl:SetWidth(230)
        sl:SetMinMaxValues(min, max)
        sl:SetValueStep(step)
        if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
        local t, lo, hi = fs(sl, "Text", name), fs(sl, "Low", name), fs(sl, "High", name)
        if t then t:SetText(label) end
        if lo then lo:SetText(lowText) end
        if hi then hi:SetText(highText) end
        sl.valueText = sl:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        sl.valueText:SetPoint("TOP", sl, "BOTTOM", 0, -2)
        sl.refresh = function()
            sl.updating = true
            sl:SetValue(get())
            sl.valueText:SetText(fmt(get()))
            sl.updating = false
        end
        sl:SetScript("OnValueChanged", function(self, v)
            if self.updating then return end
            v = math.floor(v / step + 0.5) * step
            set(v)
            self.valueText:SetText(fmt(v))
        end)
        sl.kind, sl.step, sl.min, sl.max = "slider", step, min, max
        nav[#nav + 1] = sl
        return sl
    end

    local function Check(label, get, set, x, y)
        local cb = CreateFrame("CheckButton", nil, f, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        local t = cb.Text
        if not t then
            t = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            t:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        end
        t:SetText(label)
        cb.refresh = function() cb:SetChecked(get() and true or false) end
        cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
        cb.kind = "check"
        nav[#nav + 1] = cb
        return cb
    end

    local function Button(label, onClick, x, y, w)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        b:SetSize(w or 220, 26)
        b:SetText(label)
        b:SetScript("OnClick", onClick)
        b.refresh = function() end
        b.kind = "button"
        nav[#nav + 1] = b
        return b
    end

    local function pct(v) return string.format("%d%%", v * 100 + 0.5) end
    local function relayout() Layout(); Refresh() end

    local L, R = 50, 360

    Slider("Double-tap window", "Fast", "Slow", 0.15, 0.6, 0.05,
        function() return CrossHotbarDB.doubleTap end,
        function(v) CrossHotbarDB.doubleTap = v end,
        function(v) return string.format("%.2f seconds", v) end, L, -60)
    Slider("Dim when not held", "Faint", "Full", 0.1, 1, 0.05,
        function() return CrossHotbarDB.dimAlpha end,
        function(v) CrossHotbarDB.dimAlpha = v; Refresh() end, pct, L, -122)
    Slider("Bar size", "Small", "Large", 0.5, 2, 0.05,
        function() return CrossHotbarDB.scale end,
        function(v) CrossHotbarDB.scale = v; relayout() end, pct, L, -184)
    Slider("Flyout size", "Small", "Large", 0.4, 1.2, 0.05,
        function() return CrossHotbarDB.flyoutScale end,
        function(v) CrossHotbarDB.flyoutScale = v; relayout() end, pct, L, -246)
    Slider("Button style", STYLE_NAMES[STYLES[1]], STYLE_NAMES[STYLES[#STYLES]], 1, #STYLES, 1,
        function()
            local cur = CurrentStyle()
            for i, v in ipairs(STYLES) do if v == cur then return i end end
            return 1
        end,
        function(v) CrossHotbarDB.style = STYLES[v] or STYLES[1]; relayout() end,
        function(v) return STYLE_NAMES[STYLES[v] or STYLES[1]] end, L, -308)
    Slider("Move left / right", "Left", "Right", -800, 800, 5,
        function() return CrossHotbarDB.offsetX end,
        function(v) CrossHotbarDB.offsetX = v; relayout() end,
        function(v) return tostring(v) end, L, -370)
    Slider("Move up / down", "Down", "Up", -200, 600, 5,
        function() return CrossHotbarDB.offsetY end,
        function(v) CrossHotbarDB.offsetY = v; relayout() end,
        function(v) return tostring(v) end, L, -432)

    Check("Flyouts always visible",
        function() return CrossHotbarDB.showFlyouts end,
        function(v) CrossHotbarDB.showFlyouts = v; Refresh() end, R, -56)
    Check("Hide Blizzard's action bar",
        function() return CrossHotbarDB.hideNative end,
        function(v) CrossHotbarDB.hideNative = v; ApplyNativeVisibility(); Refresh() end, R, -92)
    Check("Show button labels",
        function() return CrossHotbarDB.showLabels end,
        function(v) CrossHotbarDB.showLabels = v; Refresh() end, R, -128)
    Button("Reset position and size", function()
        CrossHotbarDB.offsetX, CrossHotbarDB.offsetY = 0, 0
        CrossHotbarDB.scale, CrossHotbarDB.flyoutScale = 1, 0.5
        relayout()
        for _, c in ipairs(nav) do c.refresh() end
    end, R, -180)
    Button("Close", function() f:Hide() end, R, -216)

    local tip = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    tip:SetPoint("TOPLEFT", f, "TOPLEFT", R, -264)
    tip:SetWidth(240)
    tip:SetJustifyH("LEFT")
    tip:SetText("Hold LT + RT and press View to open this window.\n\nLT, RT and LT + RT bind through Blizzard's normal spellbook / bag Bind flow. To fill the flyouts, open the spellbook or bags and drag spells or items onto them with the mouse.")

    -- focus marker: gold arrow + soft highlight, like the native options
    local hl = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.6)
    local arrow = f:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    arrow:SetVertexColor(1, 0.82, 0)
    arrow:SetSize(18, 18)

    local function ShowFocus()
        local c = nav[focus]
        if not c then return end
        hl:ClearAllPoints()
        arrow:ClearAllPoints()
        if c.kind == "slider" then
            hl:SetPoint("TOPLEFT", c, "TOPLEFT", -14, 22)
            hl:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 14, -18)
            arrow:SetPoint("RIGHT", c, "LEFT", -16, 0)
        elseif c.kind == "check" then
            hl:SetPoint("TOPLEFT", c, "TOPLEFT", -6, 2)
            hl:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 210, -2)
            arrow:SetPoint("RIGHT", c, "LEFT", -4, 0)
        else
            hl:SetPoint("TOPLEFT", c, "TOPLEFT", -6, 4)
            hl:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 6, -4)
            arrow:SetPoint("RIGHT", c, "LEFT", -6, 0)
        end
        hl:Show(); arrow:Show()
    end

    -- footer button prompts with controller glyphs
    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    footer:SetPoint("BOTTOM", f, "BOTTOM", 0, 22)
    local function G(key, fallback)
        local a = ButtonGlyph(key)
        return a and ("|A:" .. a .. ":20:20|a") or fallback
    end

    f:SetScript("OnGamePadButtonDown", function(self, button)
        local c = nav[focus]
        if button == "PADDUP" then
            focus = focus > 1 and focus - 1 or #nav
        elseif button == "PADDDOWN" then
            focus = focus < #nav and focus + 1 or 1
        elseif (button == "PADDLEFT" or button == "PADDRIGHT") and c then
            local d = (button == "PADDRIGHT") and 1 or -1
            if c.kind == "slider" then
                local v = math.max(c.min, math.min(c.max, c:GetValue() + d * c.step))
                c:SetValue(v)
            elseif c.kind == "check" then
                c:Click()
            end
        elseif button == "PAD1" and c then
            if c.kind == "check" or c.kind == "button" then c:Click() end
        elseif button == "PAD2" then
            self:Hide()
            return
        end
        ShowFocus()
    end)

    f:SetScript("OnShow", function(self)
        if self.EnableGamePadButton then self:EnableGamePadButton(true) end
        for _, c in ipairs(nav) do c.refresh() end
        focus = 1
        ShowFocus()
        footer:SetText(G("PAD1", "A") .. " Select     " .. G("PAD2", "B") .. " Close     "
            .. G("PADDUP", "Up") .. G("PADDDOWN", "Down") .. " Choose     "
            .. G("PADDLEFT", "Left") .. G("PADDRIGHT", "Right") .. " Adjust")
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
    end)
    f:SetScript("OnHide", function(self)
        if self.EnableGamePadButton then self:EnableGamePadButton(false) end
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851)
    end)

    -- close if combat starts
    local cf = CreateFrame("Frame")
    cf:RegisterEvent("PLAYER_REGEN_DISABLED")
    cf:SetScript("OnEvent", function() if f:IsShown() then f:Hide() end end)
end
