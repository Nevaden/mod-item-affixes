-- ============================================================================
-- ItemAffixesToast -- optional companion addon for ItemAffixes.
--
-- Adds:
--   1. A toast + sound when you pick a Critical or Imprint roll option.
--   2. A chat alert when you equip an item that still has affix rolls to do.
--
-- Fully self-contained: hooks ItemAffixes' public AFXM table from the outside
-- (hooksecurefunc on AFXM.OnServerMsg) and independently parses the same raw
-- server messages ItemAffixes itself parses. No changes to ItemAffixes' own
-- files are required or made -- disable this addon any time from the AddOns
-- list and ItemAffixes keeps working exactly as it does without it.
-- ============================================================================

if not AFXM then return end  -- ItemAffixes didn't load; nothing to hook

-- ----------------------------------------------------------------------------
-- Toast notifications
-- ----------------------------------------------------------------------------

local AFX_TOAST_SOUND_ID = 6555  -- shaybells; change if you'd prefer a different sound
local AFX_TOAST_HOLD_SEC = 2.2   -- how long the toast stays fully visible
local AFX_TOAST_FADE_SEC = 0.6   -- fade-out duration after the hold

local toastFrame   = nil
local toastQueue    = {}
local toastShowing  = false
local toastUpdater  = nil

local function GetToastFrame()
    if toastFrame then return toastFrame end

    local f = CreateFrame("Frame", "AFXToastFrame", UIParent)
    f:SetSize(380, 54)
    f:SetPoint("TOP", UIParent, "TOP", 0, -140)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.75)
    f:SetBackdropBorderColor(1, 0.82, 0, 1)

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("CENTER", f, "CENTER", 0, 0)
    text:SetJustifyH("CENTER")
    text:SetWidth(360)
    f._text = text

    f:SetAlpha(0)
    f:Hide()
    toastFrame = f
    return f
end

local function ShowNextToast()
    if toastShowing or #toastQueue == 0 then return end
    toastShowing = true

    local entry = table.remove(toastQueue, 1)
    local f = GetToastFrame()
    f._text:SetText(entry.text)
    f:Show()
    f:SetAlpha(0)
    UIFrameFadeIn(f, 0.35, 0, 1)

    if entry.sound then
        PlaySound(AFX_TOAST_SOUND_ID)
    end

    local elapsed = 0
    local fadeStarted = false
    if not toastUpdater then
        toastUpdater = CreateFrame("Frame")
    end
    toastUpdater:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if not fadeStarted and elapsed >= AFX_TOAST_HOLD_SEC then
            fadeStarted = true
            UIFrameFadeOut(f, AFX_TOAST_FADE_SEC, 1, 0)
        end
        if elapsed >= (AFX_TOAST_HOLD_SEC + AFX_TOAST_FADE_SEC) then
            self:SetScript("OnUpdate", nil)
            f:Hide()
            toastShowing = false
            ShowNextToast()
        end
    end)
end

local function ShowToast(text, playSound)
    toastQueue[#toastQueue + 1] = { text = text, sound = (playSound ~= false) }
    ShowNextToast()
end

-- ----------------------------------------------------------------------------
-- Independent OPTS parsing -- mirrors ItemAffixes.lua's own parsing of the
-- same raw message, kept in our own private cache so we don't need any
-- access to ItemAffixes' internal (local) state.
--
-- OPTS|bag|slot|affixSlot|rerolls|lockedMask|opt1|opt2|...   (opt text keeps
--   its "~" Imprint / "!" Crit prefix, same as ItemAffixes itself parses)
--
-- We toast the instant a roll produces a Crit or Imprint option -- whether
-- the player ends up picking it is irrelevant, the roll itself is the event.
-- lockedMask tells us which option indices are carried over unchanged from a
-- previous roll (the player locked them before rerolling the rest): those
-- are skipped since they were already toasted for when they first appeared.
-- Only options that are freshly rolled this message -- the entire first
-- roll, or the unlocked slots on a reroll -- get evaluated.
-- ----------------------------------------------------------------------------

local function IsBitSet(mask, b)
    return math.floor(mask / (2 ^ b)) % 2 ~= 0
end

local function ParseOptsMessage(parts)
    local bag        = tonumber(parts[2])
    local slot       = tonumber(parts[3])
    local lockedMask = tonumber(parts[6]) or 0
    if not bag or not slot then return end

    for i = 7, #parts do
        local optIdx = i - 7  -- 0-based, matches lockedMask bit positions
        if not IsBitSet(lockedMask, optIdx) then
            local raw        = parts[i]
            local prefix     = raw:sub(1, 1)
            local isImprint  = prefix == "~"
            local isCrit     = prefix == "!"
            if isImprint or isCrit then
                local dispText = raw:sub(2)
                if isImprint then
                    ShowToast("|cffA335EEImprint Rolled!|r\n" .. dispText)
                else
                    ShowToast("|cffFFD700Critical Roll!|r\n" .. dispText)
                end
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- Independent DATA parsing -- for the "still has rolls to do" equip alert.
-- DATA|bag|slot|slotCount|s0:STATE:text|s1:STATE:text|...
-- ----------------------------------------------------------------------------

-- pendingEquipAlertSlots[slot] = true after PLAYER_EQUIPMENT_CHANGED, until
-- the next DATA message for that equipped slot resolves it one way or another.
local pendingEquipAlertSlots = {}

local function ParseDataMessage(parts)
    local bag  = tonumber(parts[2])
    local slot = tonumber(parts[3])
    if bag ~= 255 or not slot then return end
    if not pendingEquipAlertSlots[slot] then return end
    pendingEquipAlertSlots[slot] = nil

    local hasUnrolled = false
    for i = 5, #parts do
        local state = parts[i]:match("^s%d+:([UPEA%-]):")
        if state == "U" or state == "P" then
            hasUnrolled = true
            break
        end
    end

    if hasUnrolled then
        local link = GetInventoryItemLink("player", slot)
        print("|cffFFD700[Item Affixes]|r " .. (link or "This item")
            .. " |cffFF4444still has affix rolls to do!|r Alt+Click it to roll.")
    end
end

-- ----------------------------------------------------------------------------
-- Points-gained toast/chat notification.
-- PROG|STATE|xp|pointsAvailable|respecCostCopper|currentTier|totalNodeChunks
--
-- Fires whenever pointsAvailable increases from what we last saw -- covers
-- both passive XP-earned points and a respec refunding spent ones back,
-- since the client has no way to distinguish the two from this message
-- alone (both just look like the same number going up).
-- ----------------------------------------------------------------------------

local lastPointsAvailable = nil  -- nil until the first PROG|STATE arrives, so
                                  -- login/reload syncing in your current total
                                  -- never reads as a false "gain"

local function ParseProgStateMessage(parts)
    local pointsAvailable = tonumber(parts[4])
    if not pointsAvailable then return end

    if lastPointsAvailable and pointsAvailable > lastPointsAvailable then
        local gained = pointsAvailable - lastPointsAvailable
        local pointWord = (gained == 1) and "point" or "points"

        ShowToast("|cff00FF96Progression Point!|r\n" .. gained .. " gained -- "
            .. pointsAvailable .. " to spend")
        print("|cff00FF96[Item Affixes]|r You gained " .. gained .. " Progression "
            .. pointWord .. "! (" .. pointsAvailable .. " available to spend)")
    end

    lastPointsAvailable = pointsAvailable
end

-- ----------------------------------------------------------------------------
-- Hook AFXM.OnServerMsg to see every message ItemAffixes itself processes,
-- without needing any access to its internal (local) state.
-- ----------------------------------------------------------------------------

hooksecurefunc(AFXM, "OnServerMsg", function(_, msg)
    if msg:sub(1, 5) == "AFXM\t" then msg = msg:sub(6) end

    local parts = {}
    for part in msg:gmatch("[^|]+") do parts[#parts + 1] = part end
    if #parts == 0 then return end

    local cmd = parts[1]
    if cmd == "OPTS" then
        ParseOptsMessage(parts)
    elseif cmd == "DATA" then
        ParseDataMessage(parts)
    elseif cmd == "PROG" then
        if parts[2] == "STATE" then
            ParseProgStateMessage(parts)
        end
    end
end)

-- ----------------------------------------------------------------------------
-- Track equip events independently -- no dependency on ItemAffixes' own
-- PLAYER_EQUIPMENT_CHANGED handling. ItemAffixes' own listener still does the
-- actual work of requesting fresh data from the server; we just also listen
-- for the DATA reply that request produces.
-- ----------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:SetScript("OnEvent", function(self, event, slot)
    if slot then
        pendingEquipAlertSlots[slot] = true
    end
end)
