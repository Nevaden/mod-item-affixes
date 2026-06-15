-- ItemAffixRollUI.lua
-- Roll frame: built entirely in Lua so we don't depend on BasicFrameTemplate.
-- AFX_DEBUG is declared in ItemAffixes.lua (the shared global).
-- Set AFX_DEBUG = true in ItemAffixes.lua to enable verbose logging for both files.

local CLASS_SPEC_NAMES = {
    WARRIOR     = {"Arms",          "Fury",         "Protection"},
    PALADIN     = {"Holy",          "Protection",   "Retribution"},
    HUNTER      = {"Beast Mastery", "Marksmanship", "Survival"},
    ROGUE       = {"Assassination", "Combat",       "Subtlety"},
    PRIEST      = {"Discipline",    "Holy",         "Shadow"},
    DEATHKNIGHT = {"Blood",         "Frost",        "Unholy"},
    SHAMAN      = {"Elemental",     "Enhancement",  "Restoration"},
    MAGE        = {"Arcane",        "Fire",         "Frost"},
    WARLOCK     = {"Affliction",    "Demonology",   "Destruction"},
    DRUID       = {"Balance",       "Feral Combat", "Restoration"},
}

-- Creates a mutually-exclusive toggle button inside a parent frame.
-- group: shared table; clicking any button refreshes all others.
-- prefVar: global name (string) whose value is set to `value` on click.
local function BuildToggleBtn(parent, label, w, group, value, prefVar)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(w, 26)
    btn._label   = label
    btn._value   = value
    btn._prefVar = prefVar
    btn._group   = group
    table.insert(group, btn)
    local function Refresh(self)
        if _G[self._prefVar] == self._value then
            self:SetText("|cffFFD700" .. self._label .. "|r")
        else
            self:SetText("|cffAAAAAA" .. self._label .. "|r")
        end
    end
    btn.Refresh = Refresh
    btn:SetScript("OnClick", function(self)
        _G[self._prefVar] = self._value
        for _, b in ipairs(self._group) do b:Refresh(b) end
    end)
    Refresh(btn)
    return btn
end

-- Called from AFXM:OnServerMsg when an OPTS message arrives.
-- rerolls    = number of rerolls remaining (0 = no reroll button shown)
-- lockedMask = bitmask: bit N set means option N is locked
function AFXM:ShowRollFrame(bag, slot, affixSlot, options, rerolls, lockedMask)
    rerolls    = rerolls    or 0
    lockedMask = lockedMask or 0
    if AFX_DEBUG then
        print("|cff44DDFF[AFX]|r ShowRollFrame: bag=" .. tostring(bag)
              .. " slot=" .. tostring(slot) .. " opts=" .. tostring(#options)
              .. " rerolls=" .. tostring(rerolls) .. " locked=" .. tostring(lockedMask))
    end
    local f = AFFXRollFrame
    if not f then
        print("|cff44DDFF[AFX]|r ERROR: AFFXRollFrame is nil")
        return
    end
    f.bag       = bag
    f.slot      = slot
    f.affixSlot = affixSlot

    local MAX_OPTS = 6

    -- One-time frame build
    if not f._built then
        f._built = true
        f:SetSize(420, 260)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(self) self:StartMoving() end)
        f:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        f:SetBackdropColor(0, 0, 0, 1)

        -- Title
        f._title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f._title:SetPoint("TOP", f, "TOP", 0, -14)
        f._title:SetTextColor(1, 0.82, 0)
        f._title:SetJustifyH("CENTER")
        f._title:SetWidth(380)

        -- Close button
        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        -- Pre-build MAX_OPTS option rows: each row = lock toggle button + option button
        f._optRows = {}
        for i = 1, MAX_OPTS do
            local lockBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            lockBtn:SetSize(36, 36)

            local optBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            optBtn:SetSize(334, 36)

            local glow = optBtn:CreateTexture(nil, "OVERLAY")
            glow:SetAllPoints(optBtn)
            glow:SetTexture(1, 0.84, 0, 0)
            glow:SetAlpha(0)
            optBtn._glow      = glow
            optBtn._glowing   = false
            optBtn._glowTimer = 0
            optBtn:SetScript("OnUpdate", function(self, elapsed)
                if not self._glowing then return end
                self._glowTimer = self._glowTimer + elapsed
                self._glow:SetAlpha(0.30 + 0.15 * math.sin(self._glowTimer * 4))
            end)

            lockBtn:Hide()
            optBtn:Hide()
            f._optRows[i] = { lockBtn = lockBtn, optBtn = optBtn }
        end

        -- Preference sections shown below options when rerolls > 0.
        -- Each section: label + row of BuildToggleBtn buttons.
        local MARGIN_L = 20

        -- Type section (any / stats / class skills)
        local ts = CreateFrame("Frame", nil, f)
        ts:SetSize(380, 44)
        ts._height = 44
        local tLbl = ts:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tLbl:SetPoint("TOPLEFT", ts, "TOPLEFT", 0, 0)
        tLbl:SetText("Roll type:")
        tLbl:SetTextColor(0.9, 0.9, 0.6)
        local tg = {}
        local typeInfo = {{"Any", 0, 60}, {"Stats", 1, 60}, {"Class Skills", 2, 100}}
        local prevB
        for i, info in ipairs(typeInfo) do
            local b = BuildToggleBtn(ts, info[1], info[3], tg, info[2], "AFX_PREF_TYPE")
            if i == 1 then b:SetPoint("TOPLEFT", tLbl, "BOTTOMLEFT", 0, -4)
            else            b:SetPoint("LEFT", prevB, "RIGHT", 4, 0) end
            prevB = b
        end
        ts._group = tg
        -- Type buttons also trigger a layout refresh to show/hide role + main sections.
        for _, tb in ipairs(tg) do
            local origClick = tb:GetScript("OnClick")
            tb:SetScript("OnClick", function(self)
                origClick(self)
                f:RefreshRerollLayout()
            end)
        end
        f._typeSection = ts

        -- Spec section
        local ss = CreateFrame("Frame", nil, f)
        ss:SetSize(380, 44)
        ss._height = 44
        local sLbl = ss:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        sLbl:SetPoint("TOPLEFT", ss, "TOPLEFT", 0, 0)
        sLbl:SetText("Spec:")
        sLbl:SetTextColor(0.9, 0.9, 0.6)
        local sg = {}
        local specBtns = {}
        specBtns[1] = BuildToggleBtn(ss, "Any", 52, sg, 255, "AFX_PREF_SPEC")
        specBtns[1]:SetPoint("TOPLEFT", sLbl, "BOTTOMLEFT", 0, -4)
        for i = 2, 4 do
            specBtns[i] = BuildToggleBtn(ss, "?", 86, sg, i - 2, "AFX_PREF_SPEC")
            specBtns[i]:SetPoint("LEFT", specBtns[i - 1], "RIGHT", 4, 0)
        end
        ss._group    = sg
        ss._specBtns = specBtns
        f._specSection = ss

        -- Stat-family / role section
        local rs = CreateFrame("Frame", nil, f)
        rs:SetSize(380, 44)
        rs._height = 44
        local rLbl = rs:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        rLbl:SetPoint("TOPLEFT", rs, "TOPLEFT", 0, 0)
        rLbl:SetText("Stat family:")
        rLbl:SetTextColor(0.9, 0.9, 0.6)
        local rg = {}
        local roleInfo = {{"Any",0,48},{"Tank",4,52},{"Physical",2,68},{"Caster",1,58},{"Healer",8,58},{"Ranged",16,62}}
        prevB = nil
        for i, info in ipairs(roleInfo) do
            local b = BuildToggleBtn(rs, info[1], info[3], rg, info[2], "AFX_PREF_ROLE")
            if i == 1 then b:SetPoint("TOPLEFT", rLbl, "BOTTOMLEFT", 0, -4)
            else            b:SetPoint("LEFT", prevB, "RIGHT", 4, 0) end
            prevB = b
        end
        rs._group = rg
        f._roleSection = rs

        -- Main stat section
        local ms = CreateFrame("Frame", nil, f)
        ms:SetSize(380, 44)
        ms._height = 44
        local mLbl = ms:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        mLbl:SetPoint("TOPLEFT", ms, "TOPLEFT", 0, 0)
        mLbl:SetText("Main stat:")
        mLbl:SetTextColor(0.9, 0.9, 0.6)
        local mg = {}
        local mainInfo = {{"Any",0,48},{"Strength",1,74},{"Agility",2,68},{"Intellect",3,78},{"Spirit",4,62}}
        prevB = nil
        for i, info in ipairs(mainInfo) do
            local b = BuildToggleBtn(ms, info[1], info[3], mg, info[2], "AFX_PREF_MAIN")
            if i == 1 then b:SetPoint("TOPLEFT", mLbl, "BOTTOMLEFT", 0, -4)
            else            b:SetPoint("LEFT", prevB, "RIGHT", 4, 0) end
            prevB = b
        end
        ms._group = mg
        f._mainSection = ms

        -- RefreshRerollLayout: positions visible sections below option rows and resizes frame.
        -- Reads f._numOpts and f._rerolls set in the update path below.
        f.RefreshRerollLayout = function(self)
            local ROW_H    = 36
            local ROW_GAP  = 8
            local SECT_GAP = 8
            local nOpts    = self._numOpts or 0
            local nRolls   = self._rerolls or 0

            -- First pixel below last option row (50px title + option rows + 14px gap)
            local sectionTop = 50 + math.max(nOpts - 1, 0) * (ROW_H + ROW_GAP) + ROW_H + 14
            if nOpts == 0 then sectionTop = 50 end

            local contentH   = sectionTop
            local nextPx     = sectionTop
            local classSkills = (AFX_PREF_TYPE == 2)
            local showCtrls   = (nRolls > 0)

            local function placeSection(sec, show)
                if show then
                    sec:ClearAllPoints()
                    sec:SetPoint("TOPLEFT", self, "TOPLEFT", MARGIN_L, -nextPx)
                    nextPx   = nextPx   + (sec._height or 44) + SECT_GAP
                    contentH = contentH + (sec._height or 44) + SECT_GAP
                    sec:Show()
                else
                    sec:Hide()
                end
            end

            placeSection(self._typeSection, showCtrls and AFX_CFG_TYPE == 1)
            placeSection(self._specSection, showCtrls and AFX_CFG_SPEC == 1)
            placeSection(self._roleSection, showCtrls and AFX_CFG_ROLE == 1 and not classSkills)
            placeSection(self._mainSection, showCtrls and AFX_CFG_MAIN == 1 and not classSkills)

            if nRolls > 0 then contentH = contentH + 34 + 20 end  -- reroll button + gap
            contentH = contentH + 20                                -- bottom margin
            self:SetSize(420, math.max(contentH, 180))
        end

        -- Reroll button (anchored at frame bottom; frame resizes to keep it visible)
        f._rerollBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        f._rerollBtn:SetSize(140, 34)
        f._rerollBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 16)
        f._rerollBtn:Hide()
    end  -- end one-time build

    f._title:SetText("Choose an Affix")
    f._numOpts = #options
    f._rerolls = rerolls

    -- Layout constants
    local MARGIN_L = 20
    local LOCK_W   = 36
    local OPT_GAP  = 10
    local ROW_H    = 36
    local ROW_GAP  = 8
    local TOP_Y    = -50  -- Y offset of first option row from frame TOP

    local function IsBitSet(mask, b)
        return math.floor(mask / (2 ^ b)) % 2 ~= 0
    end

    local numOpts = #options

    local anyUnlocked = false
    for i = 0, numOpts - 1 do
        if not IsBitSet(lockedMask, i) then anyUnlocked = true; break end
    end

    -- Configure and position each option row
    for i = 1, MAX_OPTS do
        local row = f._optRows[i]
        if options[i] then
            local yOff   = TOP_Y - (i - 1) * (ROW_H + ROW_GAP)
            local optIdx = i - 1

            row.lockBtn:ClearAllPoints()
            row.lockBtn:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN_L, yOff)
            row.optBtn:ClearAllPoints()
            row.optBtn:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN_L + LOCK_W + OPT_GAP, yOff)

            local isLocked = IsBitSet(lockedMask, optIdx)
            row.lockBtn:SetText(isLocked and "|cffFFD700[L]|r" or "|cff888888[ ]|r")
            local capturedLocked = isLocked
            local capturedIdx    = optIdx
            row.lockBtn:SetScript("OnClick", function()
                local newState = capturedLocked and "0" or "1"
                AFXM:SendToServer("LOCK|" .. bag .. "|" .. slot .. "|" .. capturedIdx .. "|" .. newState)
            end)

            local prefix    = options[i]:sub(1, 1)
            local isImprint = prefix == "~"
            local isCrit    = prefix == "!"
            local dispText  = (isImprint or isCrit) and options[i]:sub(2) or options[i]
            if isImprint then
                row.optBtn:SetText("|cffA335EE[Imprint] " .. dispText .. "|r")
                row.optBtn._glowing = false
                row.optBtn._glow:SetAlpha(0)
            elseif isCrit then
                row.optBtn:SetText("|cffFFD700** " .. dispText .. " **|r")
                row.optBtn._glowing   = true
                row.optBtn._glowTimer = 0
                row.optBtn._glow:SetAlpha(0.30)
            else
                row.optBtn:SetText("|cff44DDFF" .. dispText .. "|r")
                row.optBtn._glowing = false
                row.optBtn._glow:SetAlpha(0)
            end
            local capturedOptIdx = optIdx
            row.optBtn:SetScript("OnClick", function()
                AFXM:SendToServer("PICK|" .. bag .. "|" .. slot .. "|" .. capturedOptIdx)
                f:Hide()
            end)

            row.lockBtn:Show()
            row.optBtn:Show()
        else
            row.lockBtn:Hide()
            row.optBtn:Hide()
        end
    end

    -- Update spec button labels for this character's class
    local _, classFile = UnitClass("player")
    local specs = CLASS_SPEC_NAMES[classFile] or {"Tree 1", "Tree 2", "Tree 3"}
    local sb = f._specSection._specBtns
    for i = 1, 3 do
        sb[i + 1]._label = specs[i]
        sb[i + 1]:Refresh(sb[i + 1])
    end

    -- Refresh all toggle button visuals from current preference globals
    for _, b in ipairs(f._typeSection._group) do b:Refresh(b) end
    for _, b in ipairs(f._specSection._group) do b:Refresh(b) end
    for _, b in ipairs(f._roleSection._group) do b:Refresh(b) end
    for _, b in ipairs(f._mainSection._group) do b:Refresh(b) end

    -- Position preference sections and resize the frame
    f:RefreshRerollLayout()

    -- Configure reroll button
    if rerolls > 0 then
        f._rerollBtn:SetText("Reroll (" .. rerolls .. ")")
        if anyUnlocked then
            f._rerollBtn:Enable()
            f._rerollBtn:SetAlpha(1.0)
        else
            f._rerollBtn:Disable()
            f._rerollBtn:SetAlpha(0.5)
        end
        f._rerollBtn:SetScript("OnClick", function()
            if not anyUnlocked then return end
            AFXM:SendToServer("REROLL|" .. bag .. "|" .. slot .. "|" .. AFX_PREF_SPEC
                .. "|" .. AFX_PREF_TYPE .. "|" .. AFX_PREF_ROLE .. "|" .. AFX_PREF_MAIN)
        end)
        f._rerollBtn:Show()
    else
        f._rerollBtn:Hide()
    end

    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER")
    f:SetAlpha(1)
    f:Show()
    f:Raise()
    if AFX_DEBUG then
        print("|cff44DDFF[AFX]|r Frame shown, size=" .. f:GetWidth() .. "x" .. f:GetHeight())
    end
end

-- Refresh tooltip when the roll frame is closed without picking.
AFFXRollFrame:SetScript("OnHide", function(self)
    if GameTooltip:IsVisible() then
        GameTooltip:Hide()
        GameTooltip:Show()
    end
end)

-- ============================================================================
-- Roll Menu frame: preference landing page shown before rolling
-- ============================================================================

function AFXM:ShowRollMenu(bag, slot, rollsLeft, isGem)
    if AFX_DEBUG then
        print("|cff44DDFF[AFX]|r ShowRollMenu bag=" .. tostring(bag)
            .. " slot=" .. tostring(slot) .. " rolls=" .. tostring(rollsLeft))
        print("|cff44DDFF[AFX]|r   CFG type=" .. tostring(AFX_CFG_TYPE)
            .. " spec=" .. tostring(AFX_CFG_SPEC)
            .. " role=" .. tostring(AFX_CFG_ROLE)
            .. " main=" .. tostring(AFX_CFG_MAIN))
        print("|cff44DDFF[AFX]|r   FrameExists=" .. tostring(_G["AFFXRollMenuFrame"] ~= nil))
    end

    -- One-time frame construction
    if not _G["AFFXRollMenuFrame"] then
        if AFX_DEBUG then print("|cff44DDFF[AFX]|r   Building AFFXRollMenuFrame...") end
        local f = CreateFrame("Frame", "AFFXRollMenuFrame", UIParent)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(self) self:StartMoving() end)
        f:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
        f:SetFrameStrata("DIALOG")
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        f:SetBackdropColor(0, 0, 0, 1)

        f._title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f._title:SetPoint("TOP", f, "TOP", 0, -14)
        f._title:SetTextColor(1, 0.82, 0)
        f._title:SetText("Choose Your Affix")

        f._subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f._subtitle:SetPoint("TOP", f._title, "BOTTOM", 0, -4)
        f._subtitle:SetTextColor(0.7, 0.7, 0.7)

        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        -- Section 1: Affix type
        local ts = CreateFrame("Frame", nil, f)
        ts:SetSize(420, 52)
        f._typeSection = ts
        local tLbl = ts:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tLbl:SetPoint("TOPLEFT", ts, "TOPLEFT", 0, 0)
        tLbl:SetText("What to roll?")
        tLbl:SetTextColor(0.9, 0.9, 0.6)
        local tg = {}
        local typeInfo = {{"Any", 0, 65}, {"Stats", 1, 65}, {"Class Skills", 2, 115}}
        local prevB
        for i, info in ipairs(typeInfo) do
            local b = BuildToggleBtn(ts, info[1], info[3], tg, info[2], "AFX_PREF_TYPE")
            if i == 1 then b:SetPoint("TOPLEFT", tLbl, "BOTTOMLEFT", 0, -4)
            else            b:SetPoint("LEFT", prevB, "RIGHT", 4, 0) end
            prevB = b
        end
        ts._group = tg
        ts._height = 52

        -- Type buttons control role/main section visibility.
        -- We hook after BuildToggleBtn wires its own OnClick.
        for _, tb in ipairs(tg) do
            local origClick = tb:GetScript("OnClick")
            tb:SetScript("OnClick", function(self)
                origClick(self)
                if _G["AFFXRollMenuFrame"] then
                    _G["AFFXRollMenuFrame"]:RefreshLayout()
                end
            end)
        end

        -- Section 2: Talent tree
        local ss = CreateFrame("Frame", nil, f)
        ss:SetSize(420, 70)
        f._specSection = ss
        local sLbl = ss:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        sLbl:SetPoint("TOPLEFT", ss, "TOPLEFT", 0, 0)
        sLbl:SetText("Talent Tree:")
        sLbl:SetTextColor(0.9, 0.9, 0.6)
        local sDesc = ss:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sDesc:SetPoint("TOPLEFT", sLbl, "BOTTOMLEFT", 0, -2)
        sDesc:SetText("Selects which spec's passive talent bonus can roll on this item.")
        sDesc:SetTextColor(0.65, 0.65, 0.65)
        local sg = {}
        local specBtns = {}
        specBtns[1] = BuildToggleBtn(ss, "Any", 60, sg, 255, "AFX_PREF_SPEC")
        specBtns[1]:SetPoint("TOPLEFT", sDesc, "BOTTOMLEFT", 0, -4)
        for i = 2, 4 do
            specBtns[i] = BuildToggleBtn(ss, "Spec"..i, 95, sg, i-2, "AFX_PREF_SPEC")
            specBtns[i]:SetPoint("LEFT", specBtns[i-1], "RIGHT", 4, 0)
        end
        ss._group = sg
        ss._specBtns = specBtns
        ss._height = 70

        -- Section 3: Stat family / role
        local rs = CreateFrame("Frame", nil, f)
        rs:SetSize(420, 52)
        f._roleSection = rs
        local rLbl = rs:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        rLbl:SetPoint("TOPLEFT", rs, "TOPLEFT", 0, 0)
        rLbl:SetText("Stat family?")
        rLbl:SetTextColor(0.9, 0.9, 0.6)
        local rg = {}
        local roleInfo = {{"Any",0,55},{"Tank",4,60},{"Physical",2,80},{"Caster",1,65},{"Healer",8,65},{"Ranged",16,75}}
        prevB = nil
        for i, info in ipairs(roleInfo) do
            local b = BuildToggleBtn(rs, info[1], info[3], rg, info[2], "AFX_PREF_ROLE")
            if i == 1 then b:SetPoint("TOPLEFT", rLbl, "BOTTOMLEFT", 0, -4)
            else            b:SetPoint("LEFT", prevB, "RIGHT", 4, 0) end
            prevB = b
        end
        rs._group = rg
        rs._height = 52

        -- Section 4: Main stat preference
        local ms = CreateFrame("Frame", nil, f)
        ms:SetSize(420, 52)
        f._mainSection = ms
        local mLbl = ms:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        mLbl:SetPoint("TOPLEFT", ms, "TOPLEFT", 0, 0)
        mLbl:SetText("Main stat?")
        mLbl:SetTextColor(0.9, 0.9, 0.6)
        local mg = {}
        local mainInfo = {{"Any",0,55},{"Strength",1,85},{"Agility",2,80},{"Intellect",3,90},{"Spirit",4,70}}
        prevB = nil
        for i, info in ipairs(mainInfo) do
            local b = BuildToggleBtn(ms, info[1], info[3], mg, info[2], "AFX_PREF_MAIN")
            if i == 1 then b:SetPoint("TOPLEFT", mLbl, "BOTTOMLEFT", 0, -4)
            else            b:SetPoint("LEFT", prevB, "RIGHT", 4, 0) end
            prevB = b
        end
        ms._group = mg
        ms._height = 52

        -- RefreshLayout: show/hide sections based on config flags, type preference,
        -- and gem mode (gems: only stat family selector is shown).
        f.RefreshLayout = function(self)
            local gemMode         = self._isGem
            local classSkillsMode = (AFX_PREF_TYPE == 2) and not gemMode
            local SECT_GAP = 10
            local MARGIN_L = 20
            local topOff   = 62  -- below title + subtitle

            local function placeSection(sec, show)
                if show then
                    sec:ClearAllPoints()
                    sec:SetPoint("TOPLEFT", self, "TOPLEFT", MARGIN_L, -topOff)
                    topOff = topOff + (sec._height or 52) + SECT_GAP
                    sec:Show()
                else
                    sec:Hide()
                end
            end

            -- Gems show stat family (role) + main stat selectors; type and spec are hidden.
            placeSection(self._typeSection, AFX_CFG_TYPE == 1 and not gemMode)
            placeSection(self._specSection, AFX_CFG_SPEC == 1 and not gemMode)
            placeSection(self._roleSection, AFX_CFG_ROLE == 1 and not classSkillsMode)
            placeSection(self._mainSection, AFX_CFG_MAIN == 1 and not classSkillsMode)

            local frameH = topOff + 14 + 34 + 20
            self:SetSize(460, math.max(frameH, 150))
        end

        -- Roll Affix button (always shown at bottom)
        f._rollBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        f._rollBtn:SetSize(140, 34)
        f._rollBtn:SetText("Roll Affix")
        f._rollBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 16)

        f:SetScript("OnHide", function()
            if GameTooltip:IsVisible() then GameTooltip:Hide(); GameTooltip:Show() end
        end)
        if AFX_DEBUG then print("|cff44DDFF[AFX]|r   Build complete.") end
    end -- end one-time build

    local f = _G["AFFXRollMenuFrame"]
    if AFX_DEBUG then
        print("|cff44DDFF[AFX]|r   Sections exist: type=" .. tostring(f._typeSection ~= nil)
            .. " spec=" .. tostring(f._specSection ~= nil)
            .. " role=" .. tostring(f._roleSection ~= nil)
            .. " main=" .. tostring(f._mainSection ~= nil))
    end
    f._bag   = bag
    f._slot  = slot
    f._isGem = isGem or false

    f._subtitle:SetText("Rolls remaining: " .. rollsLeft)

    -- Populate spec button labels for this character's class
    local _, classFile = UnitClass("player")
    local specs = CLASS_SPEC_NAMES[classFile] or {"Tree 1", "Tree 2", "Tree 3"}
    local sb = f._specSection._specBtns
    for i = 1, 3 do
        sb[i+1]._label = specs[i]
        sb[i+1]:Refresh(sb[i+1])
    end

    -- Refresh all toggle visuals from current globals
    for _, b in ipairs(f._typeSection._group) do b:Refresh(b) end
    for _, b in ipairs(f._specSection._group) do b:Refresh(b) end
    for _, b in ipairs(f._roleSection._group) do b:Refresh(b) end
    for _, b in ipairs(f._mainSection._group) do b:Refresh(b) end

    -- Show/hide sections and re-anchor; role/main hidden when Class Skills is selected.
    f:RefreshLayout()

    -- Rewire Roll Affix click with fresh bag/slot capture.
    -- For gems: force type=stats-only, spec=any; main stat preference still applies.
    f._rollBtn:SetScript("OnClick", function()
        local typeVal = f._isGem and 1   or AFX_PREF_TYPE
        local specVal = f._isGem and 255 or AFX_PREF_SPEC
        local mainVal = AFX_PREF_MAIN
        AFXM:SendToServer("ROLL|" .. f._bag .. "|" .. f._slot .. "|"
            .. typeVal .. "|" .. specVal .. "|" .. AFX_PREF_ROLE
            .. "|" .. mainVal)
        f:Hide()
    end)

    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER")
    f:SetAlpha(1)
    f:Show()
    f:Raise()

    if AFX_DEBUG then
        print("|cff44DDFF[AFX]|r ShowRollMenu bag=" .. bag .. " slot=" .. slot
            .. " rolls=" .. rollsLeft .. " h=" .. f:GetHeight())
        -- Position of first section and its first button (sanity check)
        local sec = f._typeSection
        if sec and sec:IsVisible() then
            local sx, sy = sec:GetCenter()
            print("|cff44DDFF[AFX]|r   typeSection center=(" .. tostring(sx) .. "," .. tostring(sy)
                .. ") w=" .. sec:GetWidth() .. " h=" .. sec:GetHeight())
            local bg = f._typeSection._group
            if bg and bg[1] then
                local bx, by = bg[1]:GetCenter()
                print("|cff44DDFF[AFX]|r   typeBtn1 center=(" .. tostring(bx) .. "," .. tostring(by)
                    .. ") vis=" .. tostring(bg[1]:IsVisible()))
            end
        else
            print("|cff44DDFF[AFX]|r   typeSection IsVisible=false (check parent)")
        end
    end
end
