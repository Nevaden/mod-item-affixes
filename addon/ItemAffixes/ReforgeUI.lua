-- ReforgeUI.lua
-- Reforge Master frame: pick one already-APPLIED prefix/suffix line on an
-- item and pay to reroll it. See docs/REFORGE_PLAN.md for the full design.
-- Built entirely in Lua, same approach as ItemAffixRollUI.lua.
--
-- Flow: place an item in the socket -> server reports current lines + cost
-- (REFORGE_STATUS) -> click a line to select it (free, just highlights) ->
-- click "Reforge" to actually pay and roll (REFORGE_ROLL) -> pick one of
-- the returned candidates, current value always included and always first
-- (REFORGE_PICK) -> frame refreshes to the new state. Closing the window
-- without picking simply leaves the item's current value in place -- no
-- separate cancel message needed. Once an item is locked to a slot, the
-- other lines stop being offered at all, not just greyed out.
--
-- AFX_DEBUG is declared in ItemAffixes.lua (the shared global).

local MAX_LINES = 6  -- matches the module's SlotCount clamp (1-6)
local MAX_OPTS  = 7  -- current + up to 6 fresh rolls

-- FALLBACK ONLY -- see the pickup-tracking hooks below for the primary path.
-- Finds the (bag, slot) -- in this addon's own Lua convention (255=equipped,
-- 0=backpack, 1-4=bags, all 1-based) -- of the item matching a given item
-- link. This is ambiguous by design: WotLK 3.3.5a only puts a real
-- per-instance uniqueID in an item link for Blizzard "Unique"-flagged items.
-- These custom-rolled items aren't Unique, so two stacks of the same item
-- template with different server-side affix rolls produce byte-identical
-- links, and this always resolves to the first match regardless of which
-- one was actually picked up. Only used if the pickup hooks somehow miss.
local function FindBagSlotForLink(link)
    if not link then return nil end
    for slot = 1, 19 do
        if GetInventoryItemLink("player", slot) == link then
            return 255, slot
        end
    end
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            if GetContainerItemLink(bag, slot) == link then
                return bag, slot
            end
        end
    end
    return nil
end

local function LinkMatchesSlot(bag, slot, link)
    if not bag or not slot or not link then return false end
    if bag == 255 then
        return GetInventoryItemLink("player", slot) == link
    end
    return GetContainerItemLink(bag, slot) == link
end

-- PRIMARY item-identification path. Tracks the exact bag/slot an item was
-- most recently picked up from, in this addon's own convention (255=
-- equipped, 0=backpack, 1-4=bags, all 1-based). PickupContainerItem and
-- PickupInventoryItem are the two engine entry points for putting an item
-- on the cursor -- a plain click, a shift-click, and the start of a drag
-- all funnel through one of them -- so hooking both gives an unambiguous
-- source slot regardless of duplicate items with identical current rolls.
local _lastPickupBag, _lastPickupSlot = nil, nil

hooksecurefunc("PickupContainerItem", function(bag, slot)
    _lastPickupBag, _lastPickupSlot = bag, slot
end)

hooksecurefunc("PickupInventoryItem", function(slot)
    _lastPickupBag, _lastPickupSlot = 255, slot
end)

local function CopperToString(copper)
    copper = copper or 0
    local gold   = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local bronze = copper % 100
    local parts = {}
    if gold   > 0 then parts[#parts + 1] = gold   .. "|cffffd700g|r" end
    if silver > 0 then parts[#parts + 1] = silver .. "|cffc7c7cfs|r" end
    if bronze > 0 or #parts == 0 then parts[#parts + 1] = bronze .. "|cffeda55fc|r" end
    return table.concat(parts, " ")
end

-- One-time frame build.
local function BuildFrame()
    local f = AFXReforgeFrame
    f:SetSize(420, 360)
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

    -- Explicit solid fill behind the backdrop art. The DialogFrame backdrop
    -- alone looked translucent in testing (world geometry/nameplates visible
    -- through it) -- a plain color texture has no dependency on that art
    -- asset loading correctly and is guaranteed fully opaque.
    local solidBg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    solidBg:SetAllPoints(f)
    solidBg:SetTexture(0, 0, 0, 1)

    f._title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f._title:SetPoint("TOP", f, "TOP", 0, -14)
    f._title:SetText("Reforge Master")
    f._title:SetTextColor(1, 0.82, 0)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
        if AFXReforgePreviewFrame then AFXReforgePreviewFrame:Hide() end
    end)

    -- Item socket. Not a real container slot -- the item never actually
    -- leaves its bag/equipment slot, this just displays a reference to it.
    -- Deliberately NOT using ItemButtonTemplate: its helper globals
    -- (SetItemButtonTexture, etc.) look up child textures via
    -- _G[button:GetName().."IconTexture"], and that lookup errored
    -- ("attempt to concatenate a nil value") even after giving the button
    -- an explicit name -- built manually instead so there's no dependency
    -- on that naming convention at all.
    local socket = CreateFrame("Button", "AFXReforgeSocket", f)
    socket:SetSize(37, 37)
    socket:SetPoint("TOP", f._title, "BOTTOM", 0, -14)

    local socketBg = socket:CreateTexture(nil, "BACKGROUND")
    socketBg:SetAllPoints(socket)
    socketBg:SetTexture("Interface\\PaperDollInfoFrame\\UI-Backpack-EmptySlot")
    socket._bg = socketBg

    local socketIcon = socket:CreateTexture(nil, "ARTWORK")
    socketIcon:SetPoint("TOPLEFT", socket, "TOPLEFT", 2, -2)
    socketIcon:SetPoint("BOTTOMRIGHT", socket, "BOTTOMRIGHT", -2, 2)
    socketIcon:Hide()
    socket._icon = socketIcon

    local socketBorder = socket:CreateTexture(nil, "OVERLAY")
    socketBorder:SetAllPoints(socket)
    socketBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    socket._border = socketBorder
    socket:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    socket:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    socket:SetScript("OnReceiveDrag", function(self)
        local kind, _, itemLink = GetCursorInfo()
        if kind == "item" and itemLink then
            local bag, slot = _lastPickupBag, _lastPickupSlot
            _lastPickupBag, _lastPickupSlot = nil, nil
            ClearCursor()
            f:SetItem(itemLink, bag, slot)
        end
    end)
    socket:SetScript("OnClick", function(self, mouseButton)
        if CursorHasItem() then
            self:GetScript("OnReceiveDrag")(self)
        elseif mouseButton == "RightButton" and f.itemLink then
            f:ClearItem()
        end
    end)
    -- Named so SetItem can re-trigger it below when an item is dropped in
    -- while the cursor is already hovering the socket -- OnEnter alone
    -- doesn't fire again in that case, so the tooltip would otherwise keep
    -- showing whatever item was there before until the mouse actually
    -- leaves and re-enters.
    local function ShowSocketTooltip(self)
        if f.itemLink and f.bag and f.slot then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            -- SetHyperlink only shows the link's own encoded data -- it doesn't
            -- go through the SetBagItem/SetInventoryItem hooks that append affix
            -- lines to every other item tooltip in this addon. Use the same
            -- calls a real bag/equipment slot makes so those hooks fire here too.
            if f.bag == 255 then
                GameTooltip:SetInventoryItem("player", f.slot)
            else
                GameTooltip:SetBagItem(f.bag, f.slot)
            end
            GameTooltip:Show()
        end
    end
    socket:SetScript("OnEnter", ShowSocketTooltip)
    socket:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f._socket = socket
    f._showSocketTooltip = ShowSocketTooltip

    local socketHint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    socketHint:SetPoint("TOP", socket, "BOTTOM", 0, -4)
    socketHint:SetText("Drag an item here (right-click to remove)")
    socketHint:SetTextColor(0.65, 0.65, 0.65)
    f._socketHint = socketHint

    f._statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f._statusText:SetPoint("TOP", socketHint, "BOTTOM", 0, -10)
    f._statusText:SetTextColor(0.9, 0.9, 0.6)

    -- Pre-built line rows (current APPLIED prefix/suffix lines). Narrower
    -- than before (326 instead of 360) to leave room for the "?" preview
    -- button (Stage 5) next to each one.
    f._lineRows = {}
    for i = 1, MAX_LINES do
        local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        btn:SetSize(326, 26)
        btn:SetPoint("TOP", f._statusText, "BOTTOM", 0, -10 - (i - 1) * 30)
        btn:SetScript("OnClick", function(self)
            f:SelectLine(self._affixSlot)
        end)
        btn:Hide()

        -- "?" preview button: read-only, no cost -- lists every affix this
        -- line's bucket could become. Reads _affixSlot off this same row at
        -- click time since ShowLineRows sets that dynamically per reply.
        local previewBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        previewBtn:SetSize(24, 26)
        previewBtn:SetPoint("LEFT", btn, "RIGHT", 4, 0)
        previewBtn:SetText("?")
        previewBtn:SetScript("OnClick", function()
            if btn._affixSlot and f.bag and f.slot then
                AFXM:SendToServer("REFORGE_PREVIEW|" .. f.bag .. "|" .. f.slot .. "|" .. btn._affixSlot)
            end
        end)
        previewBtn:Hide()
        btn._previewBtn = previewBtn

        f._lineRows[i] = btn
    end

    -- Reforge button -- the paid, committing action. Disabled until a line
    -- is selected.
    local reforgeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reforgeBtn:SetSize(140, 30)
    reforgeBtn:SetPoint("TOP", f._lineRows[MAX_LINES], "BOTTOM", 0, -14)
    reforgeBtn:SetText("Reforge")
    reforgeBtn:Disable()
    reforgeBtn:SetScript("OnClick", function()
        if f.bag and f.selectedAffixSlot then
            AFXM:SendToServer("REFORGE_ROLL|" .. f.bag .. "|" .. f.slot .. "|" .. f.selectedAffixSlot)
        end
    end)
    f._reforgeBtn = reforgeBtn

    -- Pre-built option rows (shown instead of the line rows once a reroll
    -- comes back). Reuses the same screen space as the line rows.
    f._optRows = {}
    for i = 1, MAX_OPTS do
        local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        btn:SetSize(360, 26)
        btn:SetPoint("TOP", f._statusText, "BOTTOM", 0, -10 - (i - 1) * 30)
        btn:Hide()
        f._optRows[i] = btn
    end
end

-- Shows the line-selection rows, hides the option rows (if any were shown).
-- Ineligible lines (locked to a different slot) are hidden entirely, not
-- shown-and-disabled -- once an item is locked, those lines are never a
-- valid selection again, so there's nothing useful to show the player.
function AFXReforgeFrame:ShowLineRows()
    for _, btn in ipairs(self._optRows) do btn:Hide() end
    for i, btn in ipairs(self._lineRows) do
        local line = self._lines and self._lines[i]
        if line and line.eligible then
            btn:SetText(line.text)
            btn:Enable()
            btn._affixSlot = line.affixSlot
            btn:Show()
            btn._previewBtn:Show()
        else
            btn:Hide()
            btn._previewBtn:Hide()
        end
    end
    self._reforgeBtn:Show()
end

-- Called when an item is placed in the socket (drag or click-with-cursor-item).
-- hintBag/hintSlot come from the pickup-tracking hooks (the reliable path);
-- they're re-validated against the actual link before use and only fall
-- back to the ambiguous link search if that validation fails.
function AFXReforgeFrame:SetItem(itemLink, hintBag, hintSlot)
    local bag, slot
    if LinkMatchesSlot(hintBag, hintSlot, itemLink) then
        bag, slot = hintBag, hintSlot
    else
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r Reforge: pickup hint didn't match (bag="
                .. tostring(hintBag) .. " slot=" .. tostring(hintSlot)
                .. ") -- falling back to ambiguous link search.")
        end
        bag, slot = FindBagSlotForLink(itemLink)
    end
    if not bag then
        print("|cff44DDFF[ItemAffixes]|r Couldn't locate that item -- try again.")
        return
    end
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r Reforge: socketed item from bag=" .. tostring(bag)
            .. " slot=" .. tostring(slot) .. " link=" .. tostring(itemLink))
    end
    self.itemLink = itemLink
    self.bag, self.slot = bag, slot
    self.selectedAffixSlot = nil
    self._reforgeBtn:Disable()

    local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(itemLink)
    if texture then
        self._socket._icon:SetTexture(texture)
        self._socket._icon:Show()
    end
    -- Hide the empty-slot background art AND the quickslot border overlay
    -- now that a real icon covers the socket -- both are the same size as
    -- the icon and were showing through/around it (the border draws in the
    -- OVERLAY layer, on top of everything, so it stayed visible even after
    -- the background alone was hidden).
    self._socket._bg:Hide()
    self._socket._border:Hide()
    self._socketHint:Hide()
    self._statusText:SetText("Loading...")

    -- If the cursor is still sitting over the socket from the drop that just
    -- happened, OnEnter won't fire again on its own -- refresh the tooltip
    -- in place so it doesn't keep showing whatever item was here before.
    if self._socket:IsMouseOver() then
        self._showSocketTooltip(self._socket)
    end

    AFXM:SendToServer("REFORGE_STATUS|" .. bag .. "|" .. slot)
end

function AFXReforgeFrame:ClearItem()
    self.itemLink = nil
    self.bag, self.slot = nil, nil
    self.selectedAffixSlot = nil
    self._lines = nil
    self._previewPending = nil
    self._socket._icon:Hide()
    self._socket._bg:Show()
    self._socket._border:Show()
    self._socketHint:Show()
    self._statusText:SetText("")
    for _, btn in ipairs(self._lineRows) do
        btn:Hide()
        btn._previewBtn:Hide()
    end
    for _, btn in ipairs(self._optRows) do btn:Hide() end
    self._reforgeBtn:Hide()
    if AFXReforgePreviewFrame then AFXReforgePreviewFrame:Hide() end
end

-- Free -- just highlights the choice and enables the Reforge button.
-- Nothing is sent to the server until the button is actually clicked.
function AFXReforgeFrame:SelectLine(affixSlot)
    if not affixSlot then return end
    self.selectedAffixSlot = affixSlot
    for _, btn in ipairs(self._lineRows) do
        if btn._affixSlot == affixSlot then
            btn:LockHighlight()
        else
            btn:UnlockHighlight()
        end
    end
    self._reforgeBtn:Enable()
end

function AFXM:ShowReforgeFrame()
    local f = AFXReforgeFrame
    if not f then
        print("|cffFF0000[ItemAffixes]|r AFXReforgeFrame is nil -- ReforgeUI.xml didn't load?")
        return
    end
    if not f._built then
        BuildFrame()
        f._built = true  -- only set after BuildFrame() completes without erroring
    end
    f:ClearItem()
    f:Show()
end

-- REFORGESTATUS|bag|slot|numSlots|lockedSlot|cost|s0:{A|X}:{text}|...
function AFXM:HandleReforgeStatus(bag, slot, numSlots, lockedSlot, cost, lineParts)
    local f = AFXReforgeFrame
    if not f or not f:IsShown() or f.bag ~= bag or f.slot ~= slot then return end

    f.selectedAffixSlot = nil
    f._reforgeBtn:Disable()
    for _, btn in ipairs(f._lineRows) do btn:UnlockHighlight() end

    local locked = (lockedSlot ~= 255)
    f._lines = {}
    for i = 1, numSlots do
        local part = lineParts[i]
        -- Note: NOT "part and part:match(...)" -- and/or in Lua always
        -- collapse a multi-return to a single value, which silently
        -- dropped state/text here and left every line looking ineligible
        -- with empty text (state ~= "A" and text == nil, respectively).
        if part then
            local idx, state, text = part:match("^s(%d+):([AX]):(.*)")
            if idx then
                idx = tonumber(idx)
                local eligible = (state == "A") and (not locked or lockedSlot == idx)
                f._lines[i] = {
                    affixSlot = idx,
                    text      = text ~= "" and text or "(empty)",
                    eligible  = eligible,
                }
            end
        end
    end

    if locked then
        f._statusText:SetText("Locked to slot " .. lockedSlot .. "  |  Cost: " .. CopperToString(cost))
    else
        f._statusText:SetText("Not yet reforged  |  Cost: " .. CopperToString(cost))
    end

    f:ShowLineRows()
end

-- REFORGEOPTS|bag|slot|affixSlot|text0|text1|...  (text0 is always current)
function AFXM:HandleReforgeOpts(bag, slot, affixSlot, optionTexts)
    local f = AFXReforgeFrame
    if not f or not f:IsShown() or f.bag ~= bag or f.slot ~= slot then return end

    -- Also hide each row's "?" preview button -- the option rows reuse this
    -- same screen space, and the buttons (siblings of the line rows, not
    -- children) don't hide just because the line row itself does. The
    -- preview PANEL, if one happens to already be open, is left alone --
    -- there's just nothing left on this page that can open a new one.
    for _, btn in ipairs(f._lineRows) do
        btn:Hide()
        btn._previewBtn:Hide()
    end
    f._reforgeBtn:Hide()

    for i, btn in ipairs(f._optRows) do
        local text = optionTexts[i]
        if text then
            -- "!" prefix marks a crit option -- same convention the roll UI
            -- uses (ItemAffixRollUI.lua), stripped and re-styled here too.
            local isCrit = text:sub(1, 1) == "!"
            local label = isCrit and text:sub(2) or text
            if isCrit then
                label = "|cffFFD700** " .. label .. " **|r"
            end
            if i == 1 then label = label .. "  |cff888888(current)|r" end
            btn:SetText(label)
            btn:SetScript("OnClick", function()
                AFXM:SendToServer("REFORGE_PICK|" .. bag .. "|" .. slot .. "|" .. affixSlot .. "|" .. (i - 1))
                -- No explicit success reply -- re-request status to refresh
                -- the line list and pick up the new "current" value.
                AFXM:SendToServer("REFORGE_STATUS|" .. bag .. "|" .. slot)
            end)
            btn:Show()
        else
            btn:Hide()
        end
    end
end

-- ============================================================================
-- Preview panel ("?") -- Stage 5. Read-only, no cost, no side effects: lists
-- every affix eligible for one line's bucket (prefix/suffix) right now, so
-- the player can see what a reroll of that line *could* produce before
-- ever paying for one. Reachable at any time a line is shown -- before the
-- item is ever reforged, and (once locked) for the one remaining line.
-- ============================================================================

-- One-time build, separate frame anchored beside the main Reforge frame.
local PREVIEW_CONTENT_WIDTH = 260

local function BuildPreviewFrame()
    local p = CreateFrame("Frame", "AFXReforgePreviewFrame", UIParent)
    p:SetSize(320, 380)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:Hide()
    p:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    p:SetBackdropColor(0, 0, 0, 1)
    local solidBg = p:CreateTexture(nil, "BACKGROUND", nil, -8)
    solidBg:SetAllPoints(p)
    solidBg:SetTexture(0, 0, 0, 1)

    p._title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p._title:SetPoint("TOP", p, "TOP", 0, -14)
    p._title:SetText("Possible Rolls")
    p._title:SetTextColor(1, 0.82, 0)

    local closeBtn = CreateFrame("Button", nil, p, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() p:Hide() end)

    -- Scrollable body -- the eligible-pool list has no fixed size (a wide
    -- generic bucket can easily run to a few dozen entries), so this can't
    -- just be a fixed set of pre-built rows the way the line/option rows are.
    --
    -- Anchored to the PANEL's own corners, not the title's rendered
    -- bottom-left -- a single-point "TOP" anchor on the title auto-centers
    -- it, so its bottom-left X shifts with however wide "Possible Rolls"
    -- happens to render. That made the scrollframe's actual left edge
    -- drift inward while its right edge stayed pinned to the panel, so the
    -- real viewport ended up narrower than PREVIEW_CONTENT_WIDTH -- the
    -- text had wrapped correctly within its own logical width, but the
    -- scrollframe clipped anything past its (narrower) true viewport,
    -- which is what actually caused longer lines to look cut off.
    local scroll = CreateFrame("ScrollFrame", "AFXReforgePreviewScroll", p, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -44)
    scroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -30, 16)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(PREVIEW_CONTENT_WIDTH, 1)
    scroll:SetScrollChild(content)

    local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    text:SetWidth(PREVIEW_CONTENT_WIDTH)  -- explicit, not anchor-derived -- fixes the wrap width directly
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    content._text = text
    p._content = content

    return p
end

-- Renders the (already fully-assembled) list of preview-option display
-- strings sent by the server for one affix slot.
function AFXReforgeFrame:ShowPreviewPanel(affixSlot, texts)
    local p = AFXReforgePreviewFrame or BuildPreviewFrame()
    p:ClearAllPoints()
    p:SetPoint("LEFT", self, "RIGHT", 8, 0)

    local body
    if #texts == 0 then
        body = "|cff888888No other options for this line right now.|r"
    else
        local lines = {}
        for _, t in ipairs(texts) do lines[#lines + 1] = "- " .. t end
        body = table.concat(lines, "\n")
    end
    p._content._text:SetText(body)
    p._content:SetHeight(math.max(1, p._content._text:GetStringHeight() + 10))
    p:Show()
end

-- REFORGEPREVIEW|bag|slot|affixSlot|totalChunks -- header only; the actual
-- option text arrives in separate REFORGEPREVIEWDATA chunks (same 255-char
-- addon-message cap and buffer-then-commit pattern as PROG|STATE/PROG|NODES).
function AFXM:HandleReforgePreviewHeader(bag, slot, affixSlot, totalChunks)
    local f = AFXReforgeFrame
    if not f or not f:IsShown() or f.bag ~= bag or f.slot ~= slot then return end
    f._previewPending = { affixSlot = affixSlot, totalChunks = totalChunks, chunksSeen = 0, texts = {} }
    if totalChunks == 0 then
        f._previewPending = nil
        f:ShowPreviewPanel(affixSlot, {})
    end
end

-- REFORGEPREVIEWDATA|bag|slot|affixSlot|chunkIdx|totalChunks|text0|text1|...
function AFXM:HandleReforgePreviewData(bag, slot, affixSlot, chunkIdx, totalChunks, texts)
    local f = AFXReforgeFrame
    if not f or not f:IsShown() or f.bag ~= bag or f.slot ~= slot then return end
    local pending = f._previewPending
    if not pending or pending.affixSlot ~= affixSlot then return end

    for _, t in ipairs(texts) do pending.texts[#pending.texts + 1] = t end
    pending.chunksSeen = pending.chunksSeen + 1
    if pending.chunksSeen >= pending.totalChunks then
        f._previewPending = nil
        f:ShowPreviewPanel(affixSlot, pending.texts)
    end
end
