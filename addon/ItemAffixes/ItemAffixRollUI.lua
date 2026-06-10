-- ItemAffixRollUI.lua
-- Roll frame: built entirely in Lua so we don't depend on BasicFrameTemplate.
-- AFX_DEBUG is declared in ItemAffixes.lua (the shared global).
-- Set AFX_DEBUG = true in ItemAffixes.lua to enable verbose logging for both files.

-- Called from AFXM:OnServerMsg when an OPTS message arrives.
function AFXM:ShowRollFrame(bag, slot, affixSlot, options)
    if AFX_DEBUG then
        print("|cff44DDFF[AFX]|r ShowRollFrame: bag=" .. tostring(bag)
              .. " slot=" .. tostring(slot) .. " opts=" .. tostring(#options))
    end
    local f = AFFXRollFrame
    if not f then
        print("|cff44DDFF[AFX]|r ERROR: AFFXRollFrame is nil")
        return
    end
    f.bag       = bag
    f.slot      = slot
    f.affixSlot = affixSlot

    -- One-time frame build
    if not f._built then
        f._built = true
        f:SetSize(420, 220)
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

        -- Close button (X)
        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        -- Option buttons stored in f._btns
        f._btns = {}
        for i = 1, 3 do
            local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            btn:SetSize(380, 40)
            if i == 1 then
                btn:SetPoint("TOP", f, "TOP", 0, -50)
            else
                btn:SetPoint("TOP", f._btns[i - 1], "BOTTOM", 0, -6)
            end
            -- Gold glow overlay for crit rolls
            local glow = btn:CreateTexture(nil, "OVERLAY")
            glow:SetAllPoints(btn)
            glow:SetTexture(1, 0.84, 0, 0)
            glow:SetAlpha(0)
            btn._glow      = glow
            btn._glowing   = false
            btn._glowTimer = 0
            btn:SetScript("OnUpdate", function(self, elapsed)
                if not self._glowing then return end
                self._glowTimer = self._glowTimer + elapsed
                self._glow:SetAlpha(0.30 + 0.15 * math.sin(self._glowTimer * 4))
            end)
            f._btns[i] = btn
        end
    end

    f._title:SetText("Choose an Affix")

    for i = 1, 3 do
        local btn = f._btns[i]
        if options[i] then
            local prefix   = options[i]:sub(1, 1)
            local isImprint = prefix == "~"
            local isCrit    = prefix == "!"
            local dispText  = (isImprint or isCrit) and options[i]:sub(2) or options[i]
            if isImprint then
                btn:SetText("|cffA335EE[Imprint] " .. dispText .. "|r")
                btn._glowing = false
                btn._glow:SetAlpha(0)
            elseif isCrit then
                btn:SetText("|cffFFD700** " .. dispText .. " **|r")
                btn._glowing   = true
                btn._glowTimer = 0
                btn._glow:SetAlpha(0.30)
            else
                btn:SetText("|cff44DDFF" .. dispText .. "|r")
                btn._glowing = false
                btn._glow:SetAlpha(0)
            end
            local optIdx = i - 1
            btn:SetScript("OnClick", function()
                AFXM:SendToServer("PICK|" .. bag .. "|" .. slot .. "|" .. optIdx)
                f:Hide()
            end)
            btn:Show()
        else
            btn:Hide()
        end
    end

    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER")
    f:SetAlpha(1)
    f:Show()
    f:Raise()
    if AFX_DEBUG then
        print("|cff44DDFF[AFX]|r Frame IsShown=" .. tostring(f:IsShown())
              .. " size=" .. tostring(f:GetWidth()) .. "x" .. tostring(f:GetHeight()))
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

-- Creates a mutually-exclusive toggle button inside a section frame.
-- prefVar: global name (string) whose value is set to `value` on click.
-- group: shared table; clicking any button refreshes all others in group.
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
