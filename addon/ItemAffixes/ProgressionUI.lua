-- ProgressionUI.lua
-- Player Progression frame: three tabs (Affixes | Player | Misc), each listing
-- that category's nodes. Stage rank changes locally and commit them with an
-- explicit Apply. Points already committed server-side can never be removed
-- for free (that's what Respec is for) — only locally staged, not-yet-applied
-- ranks can be undone.
--
-- Node metadata (name/category/suffix) is static here and keyed by the same
-- node ids as PlayerProgressionNodes.h on the server — the wire protocol only
-- sends id:rank:maxRank:unlockTier per node, not display text.

local AFXM = _G["AFXM"]

local NODE_INFO = {
    [1]  = { name = "Reroll Tier",          category = "Affixes", suffix = " reroll(s)" },
    [2]  = { name = "Options Tier",         category = "Affixes", suffix = " option(s)" },
    [3]  = { name = "Extra Slot",           category = "Affixes", suffix = " slot" },
    [4]  = { name = "Crit Roll Chance",     category = "Affixes", suffix = "%" },
    [5]  = { name = "Unlock Class Affixes", category = "Affixes", suffix = "" },
    [6]  = { name = "Meta-XP Bonus",        category = "Affixes", suffix = "%" },
    [10] = { name = "Stamina",              category = "Player",  suffix = "" },
    [11] = { name = "Strength",             category = "Player",  suffix = "" },
    [12] = { name = "Agility",              category = "Player",  suffix = "" },
    [13] = { name = "Intellect",            category = "Player",  suffix = "" },
    [14] = { name = "Spirit",               category = "Player",  suffix = "" },
    [15] = { name = "Attack Power",         category = "Player",  suffix = "" },
    [16] = { name = "Spell Power",          category = "Player",  suffix = "" },
    [17] = { name = "Crit Rating",          category = "Player",  suffix = "" },
    [18] = { name = "Haste Rating",         category = "Player",  suffix = "" },
    [19] = { name = "Mp5",                  category = "Player",  suffix = "" },
    [20] = { name = "Move Speed",           category = "Misc",    suffix = "%" },
    [21] = { name = "Armor",                category = "Misc",    suffix = "" },
    [22] = { name = "Damage Reduction",     category = "Misc",    suffix = "%" },
    [24] = { name = "Character XP Bonus",   category = "Misc",    suffix = "%" },
    [26] = { name = "Boss Drops",           category = "Misc",    suffix = " extra item(s)" },
    [27] = { name = "Lifesteal",            category = "Misc",    suffix = "%" },
}

local CATEGORY_ORDER = { "Affixes", "Player", "Misc" }
local NODES_BY_CATEGORY = {
    Affixes = { 1, 2, 3, 4, 5, 6 },
    Player  = { 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 },
    Misc    = { 20, 21, 22, 24, 26, 27 },
}

local function FormatGold(copper)
    if GetCoinTextureString then
        return GetCoinTextureString(copper)
    end
    return copper .. "c"
end

-- ---------------------------------------------------------------------------
-- Draft state — AFXM.progDraft[nodeId] = staged rank (defaults to the
-- server-committed rank for any node not yet touched this session).
-- ---------------------------------------------------------------------------

local function DraftRank(nodeId)
    local s, d = AFXM.progState, AFXM.progDraft
    if not s or not s.nodes[nodeId] then return 0 end
    -- AFXM.progDraft is nil right after opening the window (ShowProgressionFrame
    -- resets it on purpose) and stays nil until the first +/- click creates it —
    -- that must NOT be treated as "draft everything to 0". Only an explicit
    -- per-node override (d[nodeId] ~= nil) should win; otherwise fall through to
    -- the real server-committed rank.
    if d and d[nodeId] ~= nil then return d[nodeId] end
    return s.nodes[nodeId].rank
end

local function IsDirty()
    local s = AFXM.progState
    if not s then return false end
    for nodeId, node in pairs(s.nodes) do
        if DraftRank(nodeId) ~= node.rank then
            return true
        end
    end
    return false
end

local function LocalPointsRemaining()
    local s = AFXM.progState
    if not s then return 0 end
    local staged = 0
    for nodeId, node in pairs(s.nodes) do
        staged = staged + (DraftRank(nodeId) - node.rank)
    end
    return s.pointsAvailable - staged
end

-- Replays the draft as INVEST calls (server already validates each one atomically,
-- so this is just "click Invest N times" collapsed into one explicit action).
local function ApplyDraft()
    local s = AFXM.progState
    if not s then return end
    for nodeId, node in pairs(s.nodes) do
        local target = DraftRank(nodeId)
        for _ = 1, (target - node.rank) do
            AFXM:SendToServer("PROG|INVEST|" .. nodeId)
        end
    end
end

local function DiscardDraft()
    AFXM.progDraft = {}
end

-- Escape and the "Discard" button both dismiss via OnCancel in classic StaticPopup;
-- both mean the same thing here (drop the unapplied staged points).
StaticPopupDialogs["AFX_PROGRESSION_UNSAVED_CONFIRM"] = {
    text = "You have unapplied Progression changes. Apply them before closing?",
    button1 = "Apply",
    button2 = "Discard",
    OnAccept = function()
        ApplyDraft()
        if _G["AFXProgressionFrame"] then _G["AFXProgressionFrame"]:Hide() end
    end,
    OnCancel = function()
        DiscardDraft()
        if _G["AFXProgressionFrame"] then _G["AFXProgressionFrame"]:Hide() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
}

StaticPopupDialogs["AFX_PROGRESSION_RESPEC_CONFIRM"] = {
    text = "Respec your Progression tree? This resets every node on this character to 0 for a gold fee so you can re-invest your points.",
    button1 = "Respec",
    button2 = "Cancel",
    OnAccept = function()
        AFXM.progDraft = nil  -- next STATE reply reinitializes fresh, see ProgressionUI.lua header note
        AFXM:SendToServer("PROG|RESPEC")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
local FRAME_WIDTH  = 420
local ROW_HEIGHT   = 24
local TAB_HEIGHT   = 22

local function BuildRow(parent, nodeId, y)
    local info = NODE_INFO[nodeId]

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, y)
    label:SetWidth(150)
    label:SetJustifyH("LEFT")
    label:SetText(info.name .. ":")

    local minusBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    minusBtn:SetSize(24, ROW_HEIGHT - 2)
    minusBtn:SetText("-")
    minusBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 160, y + 3)
    minusBtn:SetScript("OnClick", function()
        local s = AFXM.progState
        if not s or not s.nodes[nodeId] then return end
        local cur = DraftRank(nodeId)
        if cur > s.nodes[nodeId].rank then
            AFXM.progDraft = AFXM.progDraft or {}
            AFXM.progDraft[nodeId] = cur - 1
            AFXM:UpdateProgressionFrame()
        end
    end)

    local value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    value:SetPoint("LEFT", minusBtn, "RIGHT", 8, 0)
    value:SetWidth(140)
    value:SetJustifyH("CENTER")

    local plusBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    plusBtn:SetSize(24, ROW_HEIGHT - 2)
    plusBtn:SetText("+")
    plusBtn:SetPoint("LEFT", value, "RIGHT", 8, 0)
    plusBtn:SetScript("OnClick", function()
        local s = AFXM.progState
        if not s or not s.nodes[nodeId] then return end
        local node = s.nodes[nodeId]
        local cur = DraftRank(nodeId)
        if LocalPointsRemaining() > 0 and cur < node.maxRank and node.unlockTier <= s.currentTier then
            AFXM.progDraft = AFXM.progDraft or {}
            AFXM.progDraft[nodeId] = cur + 1
            AFXM:UpdateProgressionFrame()
        end
    end)

    return { label = label, minusBtn = minusBtn, value = value, plusBtn = plusBtn }
end

local function BuildFrame()
    local f = CreateFrame("Frame", "AFXProgressionFrame", UIParent)
    f:SetWidth(FRAME_WIDTH)
    f:SetPoint("CENTER", UIParent, "CENTER")
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
    f:Hide()

    -- Poll for fresh xp/points every few seconds so trickle XP (from kills/quests,
    -- which doesn't push a STATE update on its own — see PlayerProgression.cpp) shows
    -- up live while this window is open. OnUpdate only runs while the frame is shown.
    f._pollElapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self._pollElapsed = self._pollElapsed + elapsed
        if self._pollElapsed >= 3 then
            self._pollElapsed = 0
            AFXM:SendToServer("PROG|QUERY")
        end
    end)

    local cursorY = 0

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        if IsDirty() then
            StaticPopup_Show("AFX_PROGRESSION_UNSAVED_CONFIRM")
        else
            f:Hide()
        end
    end)

    cursorY = cursorY - 14
    f._title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f._title:SetPoint("TOP", f, "TOP", 0, cursorY)
    f._title:SetTextColor(1, 0.82, 0)
    f._title:SetText("Player Progression")
    cursorY = cursorY - 22

    cursorY = cursorY - 10
    f._xpText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f._xpText:SetPoint("TOP", f, "TOP", 0, cursorY)
    f._xpText:SetTextColor(0.7, 0.7, 0.7)
    cursorY = cursorY - 14

    cursorY = cursorY - 4
    f._pointsText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f._pointsText:SetPoint("TOP", f, "TOP", 0, cursorY)
    f._pointsText:SetTextColor(0.9, 0.9, 0.6)
    cursorY = cursorY - 14

    -- Tab strip
    cursorY = cursorY - 16
    f._tabs = {}
    local tabX = 20
    for _, category in ipairs(CATEGORY_ORDER) do
        local tabBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        tabBtn:SetSize(90, TAB_HEIGHT)
        tabBtn:SetText(category)
        tabBtn:SetPoint("TOPLEFT", f, "TOPLEFT", tabX, cursorY)
        tabBtn:SetScript("OnClick", function()
            f._activeCategory = category
            AFXM:UpdateProgressionFrame()
        end)
        f._tabs[category] = tabBtn
        tabX = tabX + 96
    end
    cursorY = cursorY - TAB_HEIGHT

    -- Content: one child frame per category, all anchored at the same spot;
    -- only the active one is shown. Sized to the tallest category (Player)
    -- so switching tabs never resizes the window.
    cursorY = cursorY - 10
    local contentTop = cursorY
    local maxRows = 0
    for _, ids in pairs(NODES_BY_CATEGORY) do
        if #ids > maxRows then maxRows = #ids end
    end
    local contentHeight = maxRows * ROW_HEIGHT

    f._content = {}
    f._rows = {}
    for _, category in ipairs(CATEGORY_ORDER) do
        local content = CreateFrame("Frame", nil, f)
        content:SetSize(FRAME_WIDTH - 40, contentHeight)
        content:SetPoint("TOP", f, "TOP", 0, contentTop)
        content:Hide()
        f._content[category] = content

        local rowY = 0
        for _, nodeId in ipairs(NODES_BY_CATEGORY[category]) do
            f._rows[nodeId] = BuildRow(content, nodeId, rowY)
            rowY = rowY - ROW_HEIGHT
        end
    end
    cursorY = contentTop - contentHeight

    -- Apply — commits the staged draft to the server.
    cursorY = cursorY - 16
    local applyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    applyBtn:SetSize(140, 24)
    applyBtn:SetPoint("TOP", f, "TOP", 0, cursorY)
    applyBtn:SetText("Apply")
    applyBtn:SetScript("OnClick", function(self)
        -- Disable immediately so a fast double-click can't re-send the same staged
        -- points before the server's confirmation round-trip updates progState.
        self:Disable()
        ApplyDraft()
    end)
    f._applyBtn = applyBtn
    cursorY = cursorY - 24

    -- Respec cost text + button
    cursorY = cursorY - 14
    f._respecCostText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f._respecCostText:SetPoint("TOP", f, "TOP", 0, cursorY)
    f._respecCostText:SetTextColor(0.65, 0.65, 0.65)
    cursorY = cursorY - 12

    cursorY = cursorY - 6
    local respecBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    respecBtn:SetSize(140, 24)
    respecBtn:SetPoint("TOP", f, "TOP", 0, cursorY)
    respecBtn:SetText("Respec")
    respecBtn:SetScript("OnClick", function()
        StaticPopup_Show("AFX_PROGRESSION_RESPEC_CONFIRM")
    end)
    f._respecBtn = respecBtn
    cursorY = cursorY - 24

    f:SetHeight(-cursorY + 18)

    f._activeCategory = CATEGORY_ORDER[1]
    return f
end

function AFXM:UpdateProgressionFrame()
    local f = _G["AFXProgressionFrame"]
    local s = AFXM.progState
    if not f or not s or not f:IsShown() then return end

    f._xpText:SetText("Lifetime Meta-XP: " .. s.xp)
    f._pointsText:SetText("Points Available: " .. LocalPointsRemaining())
    f._respecCostText:SetText("Respec cost: " .. FormatGold(s.respecCost))

    -- Tab highlight + visible content
    for category, tabBtn in pairs(f._tabs) do
        if category == f._activeCategory then
            tabBtn:Disable() -- reads as "selected" (greyed, matches active-tab convention)
        else
            tabBtn:Enable()
        end
        if category == f._activeCategory then
            f._content[category]:Show()
        else
            f._content[category]:Hide()
        end
    end

    -- Every row updates regardless of which tab is visible, so switching tabs
    -- shows correct state instantly with no extra round-trip.
    for nodeId, node in pairs(s.nodes) do
        local row = f._rows[nodeId]
        if row then
            local draftRank = DraftRank(nodeId)
            local locked = node.unlockTier > s.currentTier
            local suffix = ""
            if draftRank ~= node.rank then
                suffix = "  |cffFFFF00(pending)|r"
            elseif locked then
                suffix = "  |cff888888(locked)|r"
            end
            -- Flat and % are independent contributions — a hybrid node (e.g. Stamina)
            -- shows both ("+18, +6%"); a pure-% bespoke node (e.g. Move Speed, where the
            -- percent itself lives in valuePerRank, not valuePerRankPct) shows just the one.
            local flatValue = draftRank * (node.valuePerRank or 0)
            local pctValue  = draftRank * (node.valuePerRankPct or 0)
            local valueParts = {}
            if flatValue > 0 then
                table.insert(valueParts, "+" .. flatValue .. NODE_INFO[nodeId].suffix)
            end
            if pctValue > 0 then
                table.insert(valueParts, "+" .. pctValue .. "%")
            end
            local valueText = (#valueParts > 0) and ("  (" .. table.concat(valueParts, ", ") .. ")") or ""
            row.value:SetText(draftRank .. " / " .. node.maxRank .. valueText .. suffix)

            if draftRank > node.rank then
                row.minusBtn:Enable()
            else
                row.minusBtn:Disable()
            end

            if not locked and LocalPointsRemaining() > 0 and draftRank < node.maxRank then
                row.plusBtn:Enable()
            else
                row.plusBtn:Disable()
            end
        end
    end

    local dirty = IsDirty()
    if dirty then f._applyBtn:Enable() else f._applyBtn:Disable() end

    local anyCommitted = false
    for _, node in pairs(s.nodes) do
        if node.rank > 0 then anyCommitted = true; break end
    end
    if dirty or not anyCommitted then f._respecBtn:Disable() else f._respecBtn:Enable() end
end

function AFXM:ShowProgressionFrame()
    local f = _G["AFXProgressionFrame"] or BuildFrame()
    AFXM.progDraft = nil  -- always start a fresh session synced to server truth
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER")
    f:Show()
    f:Raise()
    AFXM:SendToServer("PROG|QUERY")
end
