-- ItemAffixes.lua
-- Communication, cache management, tooltip hooks, and Alt+Click intercept.

local ADDON_NAME = "ItemAffixes"
local PREFIX = "AFXM"
local AFXM = {}
_G["AFXM"] = AFXM

AFX_DEBUG = false  -- *** set to true and /reload to enable verbose debug prints ***

-- Server-controlled feature toggles (updated by CONFIG message on login)
AFX_CFG_TYPE = 1   -- 1=class skill affixes enabled; shows "Stats vs Class Skills" type selector
AFX_CFG_SPEC = 1   -- 1=show spec tree selector; on when class skills OR talent affixes are enabled
AFX_CFG_ROLE = 1   -- 1=show stat family selector
AFX_CFG_MAIN = 1   -- 1=show main stat selector (Str/Agi/Int/Spirit)

-- Per-session roll preferences (persist across frame close, reset on logout)
AFX_PREF_TYPE = 0   -- 0=any 1=stats 2=skills
AFX_PREF_SPEC = 255 -- 255=any; 0/1/2=explicit tree
AFX_PREF_ROLE = 0   -- 0=any 1=caster 2=physical 4=tank 8=healer
AFX_PREF_MAIN = 0   -- 0=any 1=str 2=agi 3=int 4=spirit

if RegisterAddonMessagePrefix then
    RegisterAddonMessagePrefix(PREFIX)
end

-- cache[bag][slot] = { slotCount=N, slots={ {state, text}, ... } }
local cache = {}
local initialized = false

-- imprintDescOverrides[spellId]  = description string  (for SetAction which gives spell ID)
-- imprintDescByName[spellName]   = description string  (for SetSpell which gives spellbook slot)
-- Both populated by IMPRINT_DESC server messages; cleared by IMPRINT_DESC_CLEAR.
local imprintDescOverrides = {}
local imprintDescByName    = {}
AFXM.debug = false
-- Tracks in-flight single-slot DATA requests so we don't spam the server.
local pendingDataReq = {}

-- Read-only affix data for items we don't own (auction house).
-- Keyed by the item's uniqueId (low-32 bits from the item link).
local peekCache = {}       -- [uniqueId] = { slotCount, slots, talentTexts }
local pendingPeekReq = {}  -- [uniqueId] = timestamp of last PEEK request sent
local PEEK_COOLDOWN = 2.0  -- seconds before a repeat request for the same uniqueId

-- Read-only affix data for inspected players' equipped items.
-- WoW 3.3.5a inspect links always have uniqueId=0, so we key by "inspect:name:slot" instead.
local inspectCache = {}       -- ["inspect:name:slot"] = { slotCount, slots, talentTexts }
local pendingInspectReq = {}  -- ["inspect:name:slot"] = timestamp of last PEEKUNIT request
local INSPECT_COOLDOWN = 2.0

-- AH affix cache: WoW 3.3.5a AH links also have uniqueId=0, so we key by "ah:owner:itemId".
local auctionCache = {}       -- ["ah:owner:itemId"] = { slotCount, slots, talentTexts }
local pendingAuctionReq = {}  -- ["ah:owner:itemId"] = timestamp of last PEEKAUCTION request
local AUCTION_COOLDOWN = 2.0

-- Tracks which inspect tooltip the player is currently hovering so INSPECTDATA can
-- retrigger SetInventoryItem in-place (avoiding the "move off and back" requirement).
local _lastInspectTooltipUnit = nil
local _lastInspectTooltipSlot = nil

-- Tracks the last AH tooltip so AUCTIONDATA can retrigger SetAuctionItem in-place.
local _lastAuctionTooltipType  = nil
local _lastAuctionTooltipIndex = nil

local _inspectFrameHooked = false

-- Tracks the last bag tooltip so DATA can retrigger SetBagItem in-place.
local _lastBagTooltipBag  = nil
local _lastBagTooltipSlot = nil

-- Tracks the last player equipment tooltip so DATA can retrigger SetInventoryItem in-place.
local _lastEquipTooltipSlot = nil

-- Tracks the last trade tooltip so PEEKDATA can retrigger SetTrade*Item in-place.
local _lastTradeTooltipIsPlayer = nil  -- true=player side, false=target side
local _lastTradeTooltipSlot     = nil

-- Extract the uniqueId (low-32 GUID counter) from a WoW 3.3.5a item link.
-- Link format: |Hitem:itemId:enchantId:gem1:gem2:gem3:gem4:suffixFactor:uniqueId:...|h
local function GetItemUniqueId(link)
    if not link then return nil end
    return tonumber(link:match("|Hitem:%-?%d+:%-?%d+:%-?%d+:%-?%d+:%-?%d+:%-?%d+:%-?%d+:(%d+)"))
end

-- Send a PEEK request for an item, subject to per-item rate limiting.
local function RequestPeek(uniqueId)
    if not uniqueId or uniqueId == 0 then return end
    local now = GetTime()
    local last = pendingPeekReq[uniqueId]
    if last and (now - last) < PEEK_COOLDOWN then
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r PEEK uid=" .. uniqueId .. " throttled")
        end
        return
    end
    pendingPeekReq[uniqueId] = now
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r PEEK sending uid=" .. uniqueId)
    end
    AFXM:SendToServer("PEEK|" .. uniqueId)
end

-- Add read-only affix lines to a tooltip from peekCache.
-- Unrolled/pending slots show a grey placeholder; applied affixes show normally.
local function AddPeekLines(tooltip, uniqueId)
    if not uniqueId or uniqueId == 0 then return end
    local data = peekCache[uniqueId]
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r AddPeekLines uid=" .. uniqueId
            .. " cached=" .. tostring(data ~= nil))
    end
    if not data then
        RequestPeek(uniqueId)
        return
    end
    if data.slotCount == 0 then return end  -- item carries no affix system
    local addedSep = false
    for _, s in ipairs(data.slots) do
        if not addedSep then tooltip:AddLine(" "); addedSep = true end
        if s.state == "U" or s.state == "P" then
            tooltip:AddLine("|cff888888[Affix slot not yet rolled]|r")
        elseif s.state == "A" and s.text and s.text ~= "" then
            if s.text:sub(1, 1) == "!" then
                tooltip:AddLine("|cffFFD700" .. s.text:sub(2) .. "|r", 1, 0.84, 0)
            else
                tooltip:AddLine("|cff44DDFF" .. s.text .. "|r", 0.27, 0.87, 1)
            end
        end
    end
    if data.talentTexts then
        for _, taText in ipairs(data.talentTexts) do
            if not addedSep then tooltip:AddLine(" "); addedSep = true end
            tooltip:AddLine("|cffd4af37" .. taText .. "|r", 0.83, 0.69, 0.22)
        end
    end
    if addedSep then tooltip:Show() end
end

-- Send a PEEKUNIT request for an inspected player's equip slot, rate-limited per slot.
local function RequestPeekUnit(unit, slot)
    local name = UnitName(unit)
    if not name then return end
    local key = "inspect:" .. name .. ":" .. slot
    local now = GetTime()
    local last = pendingInspectReq[key]
    if last and (now - last) < INSPECT_COOLDOWN then
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r PEEKUNIT " .. key .. " throttled")
        end
        return
    end
    pendingInspectReq[key] = now
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r PEEKUNIT sending " .. key)
    end
    AFXM:SendToServer("PEEKUNIT|" .. name .. "|" .. slot)
end

-- Add read-only affix lines for an inspected player's item.
-- Cache is populated by PEEKUNITALL when the inspect window opens (INSPECT_READY event).
-- Hovers are pure cache reads — no network, no flicker.
-- Falls back to a single PEEKUNIT request only when a slot is completely absent from cache.
local function AddInspectLines(tooltip, unit, slot)
    local name = UnitName(unit)
    if not name then return end
    local key = "inspect:" .. name .. ":" .. slot
    local data = inspectCache[key]
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r AddInspectLines " .. key
            .. " cached=" .. tostring(data ~= nil))
    end
    if not data then
        -- Cache miss: inspect window may not have opened yet, or this slot was
        -- somehow missed. Request a single slot as fallback.
        RequestPeekUnit(unit, slot)
        return
    end
    if data.slotCount == 0 then return end  -- item has no affix slots (cached miss)
    local addedSep = false
    for _, s in ipairs(data.slots) do
        if not addedSep then tooltip:AddLine(" "); addedSep = true end
        if s.state == "U" or s.state == "P" then
            tooltip:AddLine("|cff888888[Affix slot not yet rolled]|r")
        elseif s.state == "A" and s.text and s.text ~= "" then
            if s.text:sub(1, 1) == "!" then
                tooltip:AddLine("|cffFFD700" .. s.text:sub(2) .. "|r", 1, 0.84, 0)
            else
                tooltip:AddLine("|cff44DDFF" .. s.text .. "|r", 0.27, 0.87, 1)
            end
        end
    end
    if data.talentTexts then
        for _, taText in ipairs(data.talentTexts) do
            if not addedSep then tooltip:AddLine(" "); addedSep = true end
            tooltip:AddLine("|cffd4af37" .. taText .. "|r", 0.83, 0.69, 0.22)
        end
    end
    if addedSep then tooltip:Show() end
end

-- Send a PEEKAUCTION request for an AH item by seller name + item template ID.
local function RequestPeekAuction(owner, itemId)
    if not owner or not itemId then return end
    local key = "ah:" .. owner .. ":" .. itemId
    local now = GetTime()
    local last = pendingAuctionReq[key]
    if last and (now - last) < AUCTION_COOLDOWN then
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r PEEKAUCTION " .. key .. " throttled")
        end
        return
    end
    pendingAuctionReq[key] = now
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r PEEKAUCTION sending key=" .. key)
    end
    AFXM:SendToServer("PEEKAUCTION|" .. owner .. "|" .. itemId)
end

-- Add read-only affix lines for an AH item, keyed by seller+template.
-- Always refreshes (rate-limited) in case the seller relisted with a different item.
local function AddAuctionLines(tooltip, owner, itemId)
    if not owner or not itemId then return end
    local key = "ah:" .. owner .. ":" .. itemId
    local data = auctionCache[key]
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r AddAuctionLines key=" .. key
            .. " cached=" .. tostring(data ~= nil))
    end
    RequestPeekAuction(owner, itemId)
    if not data then return end
    if data.slotCount == 0 then return end
    local addedSep = false
    for _, s in ipairs(data.slots) do
        if not addedSep then tooltip:AddLine(" "); addedSep = true end
        if s.state == "U" or s.state == "P" then
            tooltip:AddLine("|cff888888[Affix slot not yet rolled]|r")
        elseif s.state == "A" and s.text and s.text ~= "" then
            if s.text:sub(1, 1) == "!" then
                tooltip:AddLine("|cffFFD700" .. s.text:sub(2) .. "|r", 1, 0.84, 0)
            else
                tooltip:AddLine("|cff44DDFF" .. s.text .. "|r", 0.27, 0.87, 1)
            end
        end
    end
    if data.talentTexts then
        for _, taText in ipairs(data.talentTexts) do
            if not addedSep then tooltip:AddLine(" "); addedSep = true end
            tooltip:AddLine("|cffd4af37" .. taText .. "|r", 0.83, 0.69, 0.22)
        end
    end
    if addedSep then tooltip:Show() end
end

-- Remove all inspect cache entries for a specific player so the next inspect
-- session always gets fresh data from the server.
local function ClearInspectCacheForPlayer(name)
    local prefix = "inspect:" .. name .. ":"
    local plen = #prefix
    for key in pairs(inspectCache) do
        if key:sub(1, plen) == prefix then inspectCache[key] = nil end
    end
    for key in pairs(pendingInspectReq) do
        if key:sub(1, plen) == prefix then pendingInspectReq[key] = nil end
    end
end

-- Hook InspectFrame:OnShow to prefetch affixes for all equipped slots whenever
-- the inspect window opens.  InspectFrame is lazy-loaded (Blizzard_InspectUI),
-- so this is called from Init() AND every ADDON_LOADED event.
local function TryHookInspectFrame()
    if _inspectFrameHooked then return end
    if not InspectFrame then return end
    _inspectFrameHooked = true
    InspectFrame:HookScript("OnShow", function(self)
        local name = (self.unit and UnitName(self.unit)) or UnitName("target")
        if not name or name == UnitName("player") then return end
        ClearInspectCacheForPlayer(name)
        AFXM:SendToServer("PEEKUNITALL|" .. name)
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r InspectFrame:OnShow → PEEKUNITALL|" .. name)
        end
    end)
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r Hooked InspectFrame:OnShow")
    end
end

-- Clears all bag-slot cache entries (bag ~= 255) so stale position-keyed data
-- cannot survive an item move. Equipment slot (255) is managed separately by
-- PLAYER_EQUIPMENT_CHANGED. ALLDATA will repopulate all bag entries.
local function ClearBagCache()
    if AFX_DEBUG then
        local n = 0
        for bag in pairs(cache) do if bag ~= 255 then n = n + 1 end end
        print("|cff44DDFF[ItemAffixes]|r ClearBagCache — clearing " .. n .. " bag(s)")
    end
    for bag in pairs(cache) do
        if bag ~= 255 then cache[bag] = nil end
    end
    pendingDataReq = {}
end

-- ============================================================================
-- Server communication
-- ============================================================================

function AFXM:SendToServer(msg)
    SendAddonMessage(PREFIX, msg, "WHISPER", UnitName("player"))
end

-- Send ALLDATA to server. Callers must clear stale cache entries before calling
-- so that position-keyed data from moved items cannot survive the refresh.
-- No debounce: BAG_UPDATE_DELAYED already fires once per frame (batching multiple
-- BAG_UPDATE events), so duplicate ALLDATA calls within the same event are safe.
function AFXM:RequestAllData()
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r ALLDATA sent")
    end
    AFXM:SendToServer("ALLDATA")
end

-- ============================================================================
-- Incoming message parser
-- ============================================================================

function AFXM:OnServerMsg(msg)
    if msg:sub(1, 5) == "AFXM\t" then msg = msg:sub(6) end

    local parts = {}
    for part in msg:gmatch("[^|]+") do parts[#parts + 1] = part end
    if #parts == 0 then return end

    local cmd = parts[1]

    if cmd == "DATA" then
        local bag       = tonumber(parts[2])
        local slot      = tonumber(parts[3])
        local slotCount = tonumber(parts[4])
        if not bag or not slot or not slotCount then return end
        cache[bag] = cache[bag] or {}
        cache[bag][slot] = { slotCount = slotCount, slots = {}, talentTexts = {}, gemTexts = {}, isGem = false }
        pendingDataReq[bag .. ":" .. slot] = nil  -- allow re-request if needed
        for i = 5, #parts do
            local idx, state, text = parts[i]:match("^s(%d+):([UPEA%-]):(.*)")
            if idx then
                cache[bag][slot].slots[tonumber(idx) + 1] = { state = state, text = text }
            else
                local taText = parts[i]:match("^ta:(.+)$")
                if taText then
                    cache[bag][slot].talentTexts[#cache[bag][slot].talentTexts + 1] = taText
                else
                    local gemText = parts[i]:match("^gem:(.+)$")
                    if gemText then
                        cache[bag][slot].gemTexts[#cache[bag][slot].gemTexts + 1] = gemText
                    elseif parts[i] == "isGem" then
                        cache[bag][slot].isGem = true
                    else
                        local impName = parts[i]:match("^imprint:(.+):%d+$")
                        if impName then
                            cache[bag][slot].imprintText = impName
                        end
                    end
                end
            end
        end
        if AFX_DEBUG then
            local stateStrs = {}
            for _, s in ipairs(cache[bag][slot].slots) do
                stateStrs[#stateStrs + 1] = s.state .. (s.text ~= "" and (":" .. s.text) or "")
            end
            print("|cff44DDFF[ItemAffixes]|r DATA bag=" .. bag .. " slot=" .. slot
                .. " slotCount=" .. slotCount .. " [" .. table.concat(stateStrs, ", ") .. "]")
        end
        -- If this is an equipped item, rebuild talent bonus map so the talent tree updates.
        if bag == 255 then
            AFXM:RebuildTalentBonuses()
        end
        if GameTooltip:IsVisible() then
            if bag == _lastBagTooltipBag and slot == _lastBagTooltipSlot then
                pcall(function() GameTooltip:SetBagItem(_lastBagTooltipBag, _lastBagTooltipSlot) end)
            elseif bag == 255 and slot == _lastEquipTooltipSlot then
                pcall(function() GameTooltip:SetInventoryItem("player", _lastEquipTooltipSlot) end)
            else
                GameTooltip:Hide(); GameTooltip:Show()
            end
        end

    elseif cmd == "OPTS" then
        local bag       = tonumber(parts[2])
        local slot      = tonumber(parts[3])
        local affixSlot = tonumber(parts[4])
        if not bag or not slot or (affixSlot == nil) then return end
        local options = {}
        for i = 5, #parts do options[#options + 1] = parts[i] end
        AFXM:ShowRollFrame(bag, slot, affixSlot, options)

    elseif cmd == "APPLY" then
        local bag       = tonumber(parts[2])
        local slot      = tonumber(parts[3])
        local affixSlot = tonumber(parts[4])
        local text      = parts[5] or ""
        if bag and slot and affixSlot ~= nil then
            cache[bag] = cache[bag] or {}
            local entry = cache[bag][slot]
            if entry and entry.slots then
                local s = entry.slots[affixSlot + 1]
                if s then s.state = "A"; s.text = text end
            end
        end
        if AFFXRollFrame and AFFXRollFrame:IsShown() then
            if AFFXRollFrame.bag == bag and AFFXRollFrame.slot == slot then
                AFFXRollFrame:Hide()
            end
        end
        if GameTooltip:IsVisible() then GameTooltip:Hide(); GameTooltip:Show() end

    elseif cmd == "CONFIG" then
        AFX_CFG_TYPE = tonumber(parts[2]) or 1
        AFX_CFG_SPEC = tonumber(parts[3]) or 1
        AFX_CFG_ROLE = tonumber(parts[4]) or 1
        AFX_CFG_MAIN = tonumber(parts[5]) or 1
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r CONFIG type=" .. AFX_CFG_TYPE
                .. " spec=" .. AFX_CFG_SPEC .. " role=" .. AFX_CFG_ROLE
                .. " main=" .. AFX_CFG_MAIN)
        end

    elseif cmd == "PEEKDATA" then
        local uniqueId  = tonumber(parts[2])
        local slotCount = tonumber(parts[3])
        if not uniqueId or not slotCount then return end
        peekCache[uniqueId] = { slotCount = slotCount, slots = {}, talentTexts = {} }
        for i = 4, #parts do
            local idx, state, text = parts[i]:match("^s(%d+):([UPEA%-]):(.*)")
            if idx then
                peekCache[uniqueId].slots[tonumber(idx) + 1] = { state = state, text = text }
            else
                local taText = parts[i]:match("^ta:(.+)$")
                if taText then
                    peekCache[uniqueId].talentTexts[#peekCache[uniqueId].talentTexts + 1] = taText
                end
            end
        end
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r PEEKDATA uid=" .. uniqueId
                .. " slots=" .. slotCount)
        end
        if GameTooltip:IsVisible() then
            if _lastTradeTooltipIsPlayer ~= nil and _lastTradeTooltipSlot then
                pcall(function()
                    if _lastTradeTooltipIsPlayer then
                        GameTooltip:SetTradePlayerItem(_lastTradeTooltipSlot)
                    else
                        GameTooltip:SetTradeTargetItem(_lastTradeTooltipSlot)
                    end
                end)
            else
                GameTooltip:Hide(); GameTooltip:Show()
            end
        end

    elseif cmd == "INSPECTDATA" then
        local playerName = parts[2]
        local luaSlot    = tonumber(parts[3])
        local slotCount  = tonumber(parts[4])
        if not playerName or not luaSlot or not slotCount then return end
        local key = "inspect:" .. playerName .. ":" .. luaSlot
        inspectCache[key] = { slotCount = slotCount, slots = {}, talentTexts = {} }
        for i = 5, #parts do
            local idx, state, text = parts[i]:match("^s(%d+):([UPEA%-]):(.*)")
            if idx then
                inspectCache[key].slots[tonumber(idx) + 1] = { state = state, text = text }
            else
                local taText = parts[i]:match("^ta:(.+)$")
                if taText then
                    inspectCache[key].talentTexts[#inspectCache[key].talentTexts + 1] = taText
                end
            end
        end
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r INSPECTDATA " .. key .. " slots=" .. slotCount)
        end
        -- Retrigger the tooltip in-place if the player is still hovering this item,
        -- so they don't need to move off and back on to see the affix data.
        if GameTooltip:IsVisible() and _lastInspectTooltipUnit and _lastInspectTooltipSlot then
            pcall(function()
                GameTooltip:SetInventoryItem(_lastInspectTooltipUnit, _lastInspectTooltipSlot)
            end)
        elseif GameTooltip:IsVisible() then
            GameTooltip:Hide(); GameTooltip:Show()
        end

    elseif cmd == "AUCTIONDATA" then
        local owner     = parts[2]
        local itemId    = tonumber(parts[3])
        local slotCount = tonumber(parts[4])
        if not owner or not itemId or not slotCount then return end
        local key = "ah:" .. owner .. ":" .. itemId
        auctionCache[key] = { slotCount = slotCount, slots = {}, talentTexts = {} }
        for i = 5, #parts do
            local idx, state, text = parts[i]:match("^s(%d+):([UPEA%-]):(.*)")
            if idx then
                auctionCache[key].slots[tonumber(idx) + 1] = { state = state, text = text }
            else
                local taText = parts[i]:match("^ta:(.+)$")
                if taText then
                    auctionCache[key].talentTexts[#auctionCache[key].talentTexts + 1] = taText
                end
            end
        end
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r AUCTIONDATA key=" .. key .. " slots=" .. slotCount)
        end
        if GameTooltip:IsVisible() and _lastAuctionTooltipType and _lastAuctionTooltipIndex then
            pcall(function()
                GameTooltip:SetAuctionItem(_lastAuctionTooltipType, _lastAuctionTooltipIndex)
            end)
        elseif GameTooltip:IsVisible() then
            GameTooltip:Hide(); GameTooltip:Show()
        end

    elseif cmd == "IMPRINT_DESC_CLEAR" then
        imprintDescOverrides = {}
        imprintDescByName    = {}
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r IMPRINT_DESC_CLEAR")
        end

    elseif cmd == "IMPRINT_DESC" then
        local spellId = tonumber(parts[2])
        local desc    = parts[3] or ""
        if spellId then
            if desc ~= "" then
                imprintDescOverrides[spellId] = desc
                -- Also index by spell name so SetSpell (spellbook slot) hook can find it.
                local spellName = GetSpellInfo(spellId)
                if spellName then
                    imprintDescByName[spellName] = desc
                end
            else
                imprintDescOverrides[spellId] = nil
                local spellName = GetSpellInfo(spellId)
                if spellName then imprintDescByName[spellName] = nil end
            end
            if AFX_DEBUG then
                print("|cff44DDFF[ItemAffixes]|r IMPRINT_DESC spellId=" .. spellId
                    .. " desc=" .. (desc ~= "" and desc or "(cleared)"))
            end
        end

    elseif cmd == "ERR" then
        local reason = parts[4] or (parts[2] ~= "0" and parts[2]) or "unknown"
        print("|cff44DDFF[ItemAffixes]|r " .. reason)
    end
end

-- ============================================================================
-- Tooltip helpers
-- ============================================================================

local function AddAffixLines(tooltip, bag, slot)
    -- Bail out if the slot is empty — prevents stale cache data on empty slots.
    if bag == 255 then
        if not GetInventoryItemLink("player", slot) then return end
    else
        if not GetContainerItemLink(bag, slot) then return end
    end
    local data = cache[bag] and cache[bag][slot]
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r tooltip bag=" .. bag .. " slot=" .. slot
            .. " cache=" .. (data and "HIT" or "MISS"))
    end
    if not data or not data.slots then
        -- Item present but no cache entry — pull data on-demand.
        -- The server responds with DATA|bag|slot which updates cache and refreshes tooltip.
        local key = bag .. ":" .. slot
        local now = GetTime()
        if not pendingDataReq[key] or (now - pendingDataReq[key]) > 1.0 then
            pendingDataReq[key] = now
            AFXM:SendToServer("DATA|" .. bag .. "|" .. slot)
        end
        return
    end
    local addedSep = false
    for _, s in ipairs(data.slots) do
        if s.state == "U" or s.state == "P" then
            if not addedSep then tooltip:AddLine(" "); addedSep = true end
            tooltip:AddLine("|cffFFFF00[Alt+Click to Roll Affix]|r", 1, 1, 0)
            break
        elseif s.state == "A" and s.text and s.text ~= "" then
            if not addedSep then tooltip:AddLine(" "); addedSep = true end
            if s.text:sub(1, 1) == "!" then
                tooltip:AddLine("|cffFFD700" .. s.text:sub(2) .. "|r", 1, 0.84, 0)
            else
                tooltip:AddLine("|cff44DDFF" .. s.text .. "|r", 0.27, 0.87, 1)
            end
        end
    end
    -- Imprint name (epic purple)
    if data.imprintText then
        if not addedSep then tooltip:AddLine(" "); addedSep = true end
        tooltip:AddLine("|cffA335EE[Imprint] " .. data.imprintText .. "|r", 0.64, 0.21, 0.93)
    end
    -- Talent affixes (gold/amber, no roll indicator — always applied)
    if data.talentTexts then
        for _, taText in ipairs(data.talentTexts) do
            if not addedSep then tooltip:AddLine(" "); addedSep = true end
            tooltip:AddLine("|cffd4af37" .. taText .. "|r", 0.83, 0.69, 0.22)
        end
    end
    -- Gem affixes transferred from socketed gems (teal, with "(from gem)" suffix)
    if data.gemTexts then
        for _, gemText in ipairs(data.gemTexts) do
            if not addedSep then tooltip:AddLine(" "); addedSep = true end
            tooltip:AddLine("|cff00CCCC" .. gemText .. " (from gem)|r", 0, 0.8, 0.8)
        end
    end
    if addedSep then tooltip:Show() end
end

-- ============================================================================
-- Imprint spell tooltip overlay
-- ============================================================================

-- Append the imprint description line to an already-populated spell tooltip.
local function AppendImprintDesc(tooltip, spellId)
    if not spellId then return end
    local desc = imprintDescOverrides[spellId]
    if not desc or desc == "" then return end
    tooltip:AddLine(" ")
    tooltip:AddLine("|cffd4af37[Imprint] " .. desc .. "|r", 1, 1, 1, true)
    tooltip:Show()
end

-- ============================================================================
-- Roll trigger
-- ============================================================================

local function TryRollBagItem(bag, slot)
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r TryRollBagItem bag=" .. tostring(bag) .. " slot=" .. tostring(slot))
    end
    local data = cache[bag] and cache[bag][slot]
    if not data or not data.slots then
        -- No cache entry yet — request data and wait for next Alt+Click
        AFXM:SendToServer("DATA|" .. bag .. "|" .. slot)
        return
    end
    local hasUnrolled, hasPending, rollsLeft = false, false, 0
    for _, s in ipairs(data.slots) do
        if s.state == "U" then hasUnrolled = true; rollsLeft = rollsLeft + 1 end
        if s.state == "P" then hasPending = true end
    end
    if hasUnrolled then
        AFXM:ShowRollMenu(bag, slot, rollsLeft, data.isGem)
    elseif hasPending then
        -- Re-request existing OPTS (logout recovery)
        AFXM:SendToServer("ROLL|" .. bag .. "|" .. slot)
    end
end

-- ============================================================================
-- Alt+Click detection
-- ============================================================================

-- Approach A: OnMouseDown hook on each item button.
-- OnMouseDown fires on button-press BEFORE the C engine finishes the click,
-- so it sees Alt+Click that OnClick never receives.
local hookedButtons = {}

local function HookButton(btn)
    if not btn or hookedButtons[btn] then return end
    hookedButtons[btn] = true
    pcall(function()
        btn:HookScript("OnMouseDown", function(self, button)
            if button == "LeftButton" and IsAltKeyDown() then
                TryRollBagItem(self:GetParent():GetID(), self:GetID())
            end
        end)
    end)
end

local function HookContainerFrame(frame)
    if not frame then return end
    for i = 1, frame:GetNumChildren() do
        local child = select(i, frame:GetChildren())
        if child then
            local objType = child:GetObjectType()
            if objType == "Button" or objType == "CheckButton" then
                if (child:GetName() or ""):find("Item") then
                    HookButton(child)
                end
            end
        end
    end
end

-- Approach B: OnUpdate poll using IsMouseButtonDown (if available in this build).
local function StartOnUpdateDetector()
    if type(IsMouseButtonDown) ~= "function" then return end
    local wasDown = false
    local detector = CreateFrame("Frame")
    detector:SetScript("OnUpdate", function()
        local down = IsAltKeyDown() and IsMouseButtonDown("LeftButton")
        if down then
            if not wasDown then
                wasDown = true
                local focus = GetMouseFocus()
                if focus then
                    local name = focus:GetName() or ""
                    if name:find("^ContainerFrame%d+Item") then
                        TryRollBagItem(focus:GetParent():GetID(), focus:GetID())
                    end
                end
            end
        else
            wasDown = false
        end
    end)
end

-- ============================================================================
-- Talent tree bonus display
-- ============================================================================

AFXM.talentBonuses = {}  -- talentName -> total bonus ranks from all equipped items
local _talentUpdatePending = false
local _talentFramesHooked = {}  -- tracks which frames we've already hooked

local function ParseTalentText(text)
    local bonus, name = text:match("^%+(%d+) to (.+)$")
    return tonumber(bonus), name
end

-- Returns true if talent buttons are currently visible.
-- In this client the buttons are named PlayerTalentFrameTalent<N>.
function AFXM:IsTalentDisplayActive()
    local btn = _G["PlayerTalentFrameTalent1"]
    return btn ~= nil and btn:IsVisible()
end

-- Schedule UpdateTalentFrame to run on the very next frame render.
-- Guarantees we run AFTER TalentFrame_Update finishes drawing.
function AFXM:ScheduleTalentUpdate()
    if _talentUpdatePending then return end
    _talentUpdatePending = true
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function(self)
        self:SetScript("OnUpdate", nil)
        _talentUpdatePending = false
        AFXM:UpdateTalentFrame()
    end)
end

-- Appends a bonus rank note to the talent tooltip for any talent that has an affix bonus.
-- GameTooltip:SetTalent is a C method we cannot intercept, so we append AFTER the
-- button's own OnEnter completes (HookScript fires our fn after the original).
-- _affixTipHooked guards against double-hooking when called multiple times.
local function HookTalentButtonTooltips()
    if not PlayerTalentFrame or not GetNumTalents then return end
    local tab = PlayerTalentFrame.selectedTab or 1
    local numTalents = GetNumTalents(tab)
    for idx = 1, numTalents do
        local btn = _G["PlayerTalentFrameTalent" .. idx]
        if not btn then break end
        if not btn._affixTipHooked then
            btn._affixTipHooked = true
            local capturedIdx = idx
            btn:HookScript("OnEnter", function()
                local ctab = PlayerTalentFrame and PlayerTalentFrame.selectedTab or 1
                local name, _, _, _, currentRank, maxRank = GetTalentInfo(ctab, capturedIdx)
                if not name then return end
                local bonus = AFXM.talentBonuses[name] or 0
                if bonus <= 0 then return end
                if not GameTooltip:IsShown() then return end

                local effectiveRank = currentRank + bonus
                -- When currentRank==0 the game previews rank-1 values in the description.
                local displayedRank = (currentRank > 0) and currentRank or 1

                -- 1. Rewrite "Rank X/Y" → "Rank effectiveRank/Y"
                local rankLine = _G["GameTooltipTextLeft2"]
                if rankLine then
                    local txt = rankLine:GetText() or ""
                    local newTxt = txt:gsub("Rank %d+", "Rank " .. effectiveRank, 1)
                    if newTxt ~= txt then rankLine:SetText(newTxt) end
                end

                -- 2. Scale numbers in description lines (linear assumption — valid for all
                --    current affixes; non-linear talents will use a lookup table once the
                --    user's talent data file is delivered).
                if effectiveRank ~= displayedRank then
                    local scale = effectiveRank / displayedRank
                    for i = 3, 10 do
                        local line = _G["GameTooltipTextLeft" .. i]
                        if not line then break end
                        local txt = line:GetText()
                        if not txt or txt == "" then break end
                        if txt:find("affix bonus") then break end
                        -- Match decimals first so "0.5" isn't split into "0" + "5".
                        local scaled = txt:gsub("%d+%.%d+", function(n)
                            local num = tonumber(n)
                            if not num then return n end
                            local result = num * scale
                            if result == math.floor(result) then
                                return tostring(math.floor(result))
                            end
                            return string.format("%.1f", result)
                        end)
                        scaled = scaled:gsub("%d+", function(n)
                            local num = tonumber(n)
                            if not num then return n end
                            return tostring(math.floor(num * scale + 0.5))
                        end)
                        if scaled ~= txt then line:SetText(scaled) end
                    end
                end

                -- 3. Append gold bonus note and force tooltip resize.
                GameTooltip:AddLine("|cffd4af37+" .. bonus
                    .. " affix bonus (effective "
                    .. effectiveRank .. "/" .. maxRank .. ")|r")
                GameTooltip:Show()
            end)
        end
    end
end

-- Try to hook OnShow on any known talent frame globals that exist right now.
-- Called at Init time AND on every ADDON_LOADED event (talent UI is lazy-loaded).
function AFXM:TryHookTalentFrames()
    local candidates = { "TalentFrame", "PlayerTalentFrame" }
    for _, name in ipairs(candidates) do
        local f = _G[name]
        if f and not _talentFramesHooked[name] then
            _talentFramesHooked[name] = true
            f:HookScript("OnShow", function()
                AFXM:RebuildTalentBonuses()
                AFXM:ScheduleTalentUpdate()
                HookTalentButtonTooltips()
            end)
            if name == "PlayerTalentFrame" then
                -- Watch selectedTab for tab-switch reactivity while the frame is open.
                local lastTab = f.selectedTab
                f:HookScript("OnUpdate", function()
                    local tab = f.selectedTab
                    if tab and tab ~= lastTab then
                        lastTab = tab
                        AFXM:ScheduleTalentUpdate()
                    end
                end)
            end
            if f:IsShown() then HookTalentButtonTooltips() end
            if AFX_DEBUG then
                print("|cff44DDFF[ItemAffixes]|r Hooked OnShow on " .. name)
            end
        end
    end
    -- Post-hook update functions (try multiple names; this client uses PlayerTalentFrame).
    for _, fname in ipairs({"TalentFrame_Update", "PlayerTalentFrame_Update"}) do
        if not _talentFramesHooked[fname] and _G[fname] then
            _talentFramesHooked[fname] = true
            pcall(function()
                hooksecurefunc(fname, function()
                    AFXM:ScheduleTalentUpdate()
                end)
            end)
            if AFX_DEBUG then
                print("|cff44DDFF[ItemAffixes]|r Hooked " .. fname)
            end
        end
    end
end

function AFXM:RebuildTalentBonuses()
    self.talentBonuses = {}
    if cache[255] then
        for _, data in pairs(cache[255]) do
            if data.talentTexts then
                for _, text in ipairs(data.talentTexts) do
                    local bonus, name = ParseTalentText(text)
                    if bonus and name then
                        self.talentBonuses[name] = (self.talentBonuses[name] or 0) + bonus
                    end
                end
            end
        end
    end
    if AFX_DEBUG then
        local n = 0
        for k in pairs(self.talentBonuses) do n = n + 1 end
        print("|cff44DDFF[ItemAffixes]|r RebuildTalentBonuses: " .. n .. " bonus(es)")
        for name, bonus in pairs(self.talentBonuses) do
            print("|cff44DDFF[ItemAffixes]|r   +" .. bonus .. " to " .. name)
        end
    end
    self:UpdateTalentFrame()
    if AFXM:IsTalentDisplayActive() then
        self:ScheduleTalentUpdate()
    end
end

-- Find the rank FontString on a talent button.
-- Tries the standard $parentRank global name first, then falls back to scanning
-- the button's regions for a FontString that shows "X/Y" (the rank display).
local function GetTalentRankText(btn)
    local name = btn:GetName()
    if name then
        local t = _G[name .. "Rank"]
        if t then return t end
        local t2 = _G[name .. "RankText"]
        if t2 then return t2 end
    end
    -- Fallback: find a FontString region whose text looks like "0/5"
    local ok, n = pcall(btn.GetNumRegions, btn)
    if ok then
        for i = 1, n do
            local r = select(i, btn:GetRegions())
            if r and r.GetObjectType and r:GetObjectType() == "FontString" then
                local txt = r:GetText()
                if txt and txt:find("/") then
                    return r
                end
            end
        end
    end
    return nil
end

function AFXM:UpdateTalentFrame()
    if not AFXM:IsTalentDisplayActive() then
        if AFX_DEBUG then print("|cff44DDFF[ItemAffixes]|r UpdateTalentFrame: buttons not visible") end
        return
    end
    if not GetNumTalentTabs then return end

    -- Buttons are named PlayerTalentFrameTalent<idx> where idx is the talent's
    -- position within the currently shown tree (1-based, reused across all trees).
    -- PlayerTalentFrame.selectedTab holds the currently shown tree index (1/2/3).
    local currentTab = PlayerTalentFrame and PlayerTalentFrame.selectedTab
    if not currentTab or currentTab < 1 then
        -- Fallback: use the tab with the most spent points as the "main" view.
        local best, bestPts = 1, -1
        for t = 1, GetNumTalentTabs() do
            local _, _, pts = GetTalentTabInfo(t)
            if (pts or 0) > bestPts then best = t; bestPts = pts end
        end
        currentTab = best
    end

    local updated = 0
    for idx = 1, GetNumTalents(currentTab) do
        local name, _, _, _, currentRank, maxRank = GetTalentInfo(currentTab, idx)
        local bonus = (name and self.talentBonuses[name]) or 0
        if bonus > 0 then
            local btn = _G["PlayerTalentFrameTalent" .. idx]
            if btn then
                local rankText = GetTalentRankText(btn)
                if AFX_DEBUG then
                    print("|cff44DDFF[ItemAffixes]|r UpdateTalentFrame: tab=" .. currentTab
                        .. " idx=" .. idx .. " name=" .. (name or "?")
                        .. " +" .. bonus .. " rankText=" .. tostring(rankText ~= nil))
                end
                if rankText then
                    -- Show() is required when currentRank == 0 and the talent
                    -- is in the disabled/greyed state — the rank text is hidden
                    -- by default in that state.
                    rankText:Show()
                    rankText:SetAlpha(1)
                    rankText:SetText((currentRank + bonus) .. "/" .. maxRank)
                    rankText:SetTextColor(1, 0.82, 0)
                    updated = updated + 1
                end
            end
        end
    end
    -- Hook tooltip on any buttons that appeared after a tab switch.
    HookTalentButtonTooltips()
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r UpdateTalentFrame: tab=" .. currentTab .. " updated=" .. updated)
    end
end

-- ============================================================================
-- Character sheet crit display patch
-- ============================================================================

-- Maps talent names → raw crit units per bonus rank (100 units = 1% crit).
-- Synced with CRIT_CHANCE entries in talent_affixes.json.
-- Add a line here whenever a new CRIT_CHANCE talent is added to the JSON.
local AFXM_CRIT_DATA = {
    ["Improved Overpower"]           = 25,   -- 0.25% per rank (Overpower-specific)
    ["Conviction"]                   = 100,  -- 1.00% per rank (all Paladin spells)
    ["Lethal Shots"]                 = 100,  -- 1.00% per rank (all Hunter spells)
    ["Malice"]                       = 100,  -- 1.00% per rank (all Rogue spells)
    ["Puncturing Wounds"]            = 1000, -- 10.00% per rank (Backstab + Mutilate combined)
}

local function GetBonusCritChance()
    local total = 0
    for name, perRankRaw in pairs(AFXM_CRIT_DATA) do
        local ranks = AFXM.talentBonuses[name] or 0
        if ranks > 0 then
            total = total + (ranks * perRankRaw / 100.0)
        end
    end
    return total
end

-- Find the numeric-value FontString in a paper doll stat frame.
-- In 3.3.5a, Blizzard's PaperDollFrame_Set* functions write to statFrame.rightText
-- (a direct table field), not a globally-named child, so we check fields first.
local _lastCritStatFrame = nil  -- stored for /affixes crit frame dump

local function GetStatFrameValueText(statFrame)
    if not statFrame then return nil end

    -- 1. Direct table fields — Blizzard 3.3.5a uses statFrame.rightText
    for _, field in ipairs({ "rightText", "rightLabel", "value", "stat", "text2", "text" }) do
        local fs = statFrame[field]
        if fs and type(fs) == "table" and fs.GetText then return fs end
    end

    -- 2. Global named children
    local name = statFrame:GetName() or ""
    for _, suffix in ipairs({ "RightText", "Right", "Value", "Stat", "Text2", "Text" }) do
        local fs = name ~= "" and _G[name .. suffix]
        if fs and fs.GetText then return fs end
    end

    -- 3. Scan regions (relaxed: any FontString containing digits + "%" is a candidate)
    local ok, n = pcall(statFrame.GetNumRegions, statFrame)
    if ok then
        for i = 1, n do
            local r = select(i, statFrame:GetRegions())
            if r and r.GetObjectType and r:GetObjectType() == "FontString" then
                local txt = r:GetText() or ""
                if txt:find("%%") and txt:match("%d") then return r end
            end
        end
    end

    -- 4. Scan immediate children's regions
    local ok2, n2 = pcall(statFrame.GetNumChildren, statFrame)
    if ok2 then
        for i = 1, n2 do
            local child = select(i, statFrame:GetChildren())
            if child then
                local ok3, n3 = pcall(child.GetNumRegions, child)
                if ok3 then
                    for j = 1, n3 do
                        local r = select(j, child:GetRegions())
                        if r and r.GetObjectType and r:GetObjectType() == "FontString" then
                            local txt = r:GetText() or ""
                            if txt:find("%%") and txt:match("%d") then return r end
                        end
                    end
                end
            end
        end
    end

    return nil
end

-- Patch percentage numbers in tooltip lines for the crit bonus.
-- Replaces "X.XX%" with "(X+bonus).XX%" for values in a plausible crit range.
local function PatchCritTooltipLines()
    local bonus = GetBonusCritChance()
    if bonus == 0 then return end
    for i = 1, 10 do
        local line = _G["GameTooltipTextLeft" .. i]
        if not line then break end
        local t = line:GetText()
        if not t then break end
        local patched = t:gsub("(%d+%.%d+)%%", function(n)
            local v = tonumber(n)
            if v and v > 0 and v < 100 then
                return string.format("%.2f", v + bonus) .. "%"
            end
            return n .. "%"
        end)
        if patched ~= t then line:SetText(patched) end
    end
    GameTooltip:Show()
end

-- Called by the hooksecurefunc callback after WoW updates a crit stat frame.
-- Reads the value WoW just wrote and adds our SpellMod bonus on top.
-- Also hooks the frame's OnEnter once so the hover tooltip shows the correct value.
local function PatchCritStatFrame(statFrame)
    local bonus = GetBonusCritChance()
    if bonus == 0 then return end
    local valueText = GetStatFrameValueText(statFrame)
    if not valueText then return end
    local txt = valueText:GetText() or ""
    local val = tonumber(txt:match("([%d%.]+)"))
    if val then
        valueText:SetText(string.format("%.2f%%", val + bonus))
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r CritPatch: +"
                .. string.format("%.2f", bonus) .. "% → "
                .. string.format("%.2f%%", val + bonus))
        end
    end
    -- One-time OnEnter hook so the tooltip shows the corrected value on hover.
    if not statFrame._affixCritTipHooked then
        statFrame._affixCritTipHooked = true
        pcall(function()
            statFrame:HookScript("OnEnter", PatchCritTooltipLines)
        end)
    end
end

local _critHooksRegistered = false
local _critHookFired       = false  -- diagnostic flag

local function TryHookCritDisplay()
    if _critHooksRegistered then return end
    for _, fname in ipairs({
        "PaperDollFrame_SetMeleeCritChance",
        "PaperDollFrame_SetRangedCritChance",
        "PaperDollFrame_SetSpellCritChance",
        "PaperDollFrame_SetMeleeCrit",
        "PaperDollFrame_SetCrit",
    }) do
        if _G[fname] then
            _critHooksRegistered = true
            pcall(function()
                hooksecurefunc(fname, function(statFrame, unit)
                    if unit and unit ~= "player" then return end
                    _critHookFired = true
                    _lastCritStatFrame = statFrame
                    PatchCritStatFrame(statFrame)
                end)
            end)
            if AFX_DEBUG then
                print("|cff44DDFF[ItemAffixes]|r Hooked crit fn: " .. fname)
            end
        end
    end
end

-- ============================================================================
-- Comparison tooltip hooks
-- ============================================================================

-- Given an item link, find the equipped slot (1-19) whose link shares the same
-- uniqueId.  Returns nil if no match.  Used by the SetHyperlink path to map a
-- comparison tooltip back to a cache[255][slot] entry without a server round-trip.
local function FindEquippedSlotByLink(link)
    local uid = GetItemUniqueId(link)
    if not uid or uid == 0 then return nil end
    for slot = 1, 19 do
        local elink = GetInventoryItemLink("player", slot)
        if elink and GetItemUniqueId(elink) == uid then
            return slot
        end
    end
    return nil
end

-- Hook all three tooltip entry-points on a comparison tooltip frame.
-- Guards against double-hooking with a flag on the frame itself.
local function HookComparisonTooltip(tt)
    if not tt or tt._affixCompareHooked then return end
    tt._affixCompareHooked = true
    -- Path 1: SetInventoryItem("player", slot) — direct slot reference.
    pcall(function()
        hooksecurefunc(tt, "SetInventoryItem", function(self, unit, slot)
            if unit == "player" then
                AddAffixLines(self, 255, slot)
            elseif UnitIsPlayer(unit) then
                AddInspectLines(self, unit, slot)
            end
        end)
    end)
    -- Path 2: SetBagItem(bag, slot) — comparison against another bag item.
    pcall(function()
        hooksecurefunc(tt, "SetBagItem", function(self, bag, slot)
            AddAffixLines(self, bag, slot)
        end)
    end)
    -- Path 3: SetHyperlink(link) — WoW 3.3.5a comparison often uses the item
    -- link rather than a unit+slot reference.  Match back to equipped slot by
    -- uniqueId so we can use the already-cached bag=255 data.
    pcall(function()
        hooksecurefunc(tt, "SetHyperlink", function(self, link)
            if not link then return end
            local slot = FindEquippedSlotByLink(link)
            if slot then
                AddAffixLines(self, 255, slot)
            else
                -- Not an equipped item link — fall back to PEEK by uniqueId.
                local uid = GetItemUniqueId(link)
                if uid and uid ~= 0 then
                    AddPeekLines(self, uid)
                end
            end
        end)
    end)
    if AFX_DEBUG then
        local name = (tt.GetName and tt:GetName()) or "(unnamed)"
        print("|cff44DDFF[ItemAffixes]|r Hooked comparison tooltip: " .. name)
    end
end

local _shoppingTooltipsHooked  = false
local _compareItemFnHooked     = false

local function TryHookShoppingTooltips()
    -- Try all known frame names for the comparison tooltip in WoW 3.3.5a.
    -- ShoppingTooltip1/2 is the common name; GameTooltipCompareItem1/2 appears in
    -- some builds.  We hook any we find and mark done once at least one is found.
    local candidates = {
        "ShoppingTooltip1", "ShoppingTooltip2",
        "GameTooltipCompareItem1", "GameTooltipCompareItem2",
    }
    for _, name in ipairs(candidates) do
        local tt = _G[name]
        if tt then
            HookComparisonTooltip(tt)
            _shoppingTooltipsHooked = true
        end
    end

    -- GameTooltip_ShowCompareItem is called by Blizzard with the actual tooltip
    -- frame references as arguments — hook it as a reliable fallback so we can
    -- discover frames whatever their global name (or even if anonymous).
    if not _compareItemFnHooked and _G["GameTooltip_ShowCompareItem"] then
        _compareItemFnHooked = true
        pcall(function()
            hooksecurefunc("GameTooltip_ShowCompareItem", function(...)
                for i = 1, select('#', ...) do
                    local tt = select(i, ...)
                    if type(tt) == "table" and tt.AddLine then
                        HookComparisonTooltip(tt)
                    end
                end
            end)
        end)
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r Hooked GameTooltip_ShowCompareItem")
        end
    end
end

-- ============================================================================
-- Initialization
-- ============================================================================

local function Init()
    if initialized then return end
    initialized = true

    -- Imprint spell tooltip overlay — single code path for all tooltip sources.
    --
    -- SetSpell (spellbook) is debug-logged here for diagnostics only; the actual
    -- append happens in OnShow so that Bartender4 and any other action-bar addon
    -- is supported without caring about their internal slot/action numbering.
    -- BT4's .action field is its own index, NOT a WoW action slot, so
    -- GetActionInfo(button.action) returns the wrong spell — we use the tooltip's
    -- first line (already the spell name) instead.
    hooksecurefunc(GameTooltip, "SetSpell", function(self, slot, bookType)
        if not AFX_DEBUG then return end
        local spellName = GetSpellInfo(slot, bookType)
        print("|cff44DDFF[ItemAffixes]|r SetSpell slot=" .. tostring(slot)
            .. " bookType=" .. tostring(bookType)
            .. " name=" .. tostring(spellName)
            .. " hasDesc=" .. tostring(spellName and imprintDescByName[spellName] ~= nil))
    end)

    -- GameTooltip:Show fires after all content is set, for every source.
    -- Read line 1 (the spell name WoW already placed there) and append the
    -- imprint desc if it matches a known override.  The _inImprintAppend guard
    -- prevents the self:Show() resize call from recursing back into this handler.
    local _inImprintAppend = false
    GameTooltip:HookScript("OnShow", function(self)
        if _inImprintAppend then return end
        local line1 = _G["GameTooltipTextLeft1"]
        local spellName = line1 and line1:GetText()
        local desc = spellName and imprintDescByName[spellName]
        if AFX_DEBUG then
            local owner = self:GetOwner()
            local ownerName = owner and (owner:GetName() or "(unnamed)") or "(nil)"
            print("|cff44DDFF[ItemAffixes]|r OnShow owner=" .. ownerName
                .. " line1=" .. tostring(spellName)
                .. " hasDesc=" .. tostring(desc ~= nil))
        end
        if not desc or desc == "" then return end
        self:AddLine(" ")
        self:AddLine("|cffd4af37[Imprint] " .. desc .. "|r", 1, 1, 1, true)
        _inImprintAppend = true
        self:Show()
        _inImprintAppend = false
    end)

    hooksecurefunc(GameTooltip, "SetBagItem", function(self, bag, slot)
        _lastBagTooltipBag        = bag
        _lastBagTooltipSlot       = slot
        _lastEquipTooltipSlot     = nil
        _lastTradeTooltipIsPlayer = nil
        _lastTradeTooltipSlot     = nil
        AddAffixLines(self, bag, slot)
    end)
    hooksecurefunc(GameTooltip, "SetInventoryItem", function(self, unit, slot)
        if unit == "player" then
            _lastEquipTooltipSlot     = slot
            _lastBagTooltipBag        = nil
            _lastBagTooltipSlot       = nil
            _lastInspectTooltipUnit   = nil
            _lastInspectTooltipSlot   = nil
            _lastAuctionTooltipType   = nil
            _lastAuctionTooltipIndex  = nil
            _lastTradeTooltipIsPlayer = nil
            _lastTradeTooltipSlot     = nil
            AddAffixLines(self, 255, slot)
        elseif UnitIsPlayer(unit) then
            -- Inspecting another player's item. WoW 3.3.5a inspect links have uniqueId=0,
            -- so we use PEEKUNIT (name+slot) instead of PEEK (uniqueId).
            _lastInspectTooltipUnit = unit
            _lastInspectTooltipSlot = slot
            if AFX_DEBUG then
                print("|cff44DDFF[ItemAffixes]|r SetInventoryItem inspect unit="
                    .. tostring(unit) .. " slot=" .. tostring(slot)
                    .. " name=" .. tostring(UnitName(unit)))
            end
            AddInspectLines(self, unit, slot)
        else
            if AFX_DEBUG then
                print("|cff44DDFF[ItemAffixes]|r SetInventoryItem unit=" .. tostring(unit)
                    .. " UnitIsPlayer=" .. tostring(UnitIsPlayer(unit)) .. " (skipped)")
            end
        end
    end)

    -- Auction house item tooltips.
    -- WoW 3.3.5a AH protocol strips item instance GUIDs so links always have uid=0.
    -- Fall back to PEEKAUCTION (seller name + item template) for the lookup.
    local auctionHookOk, auctionHookErr = pcall(function()
        hooksecurefunc(GameTooltip, "SetAuctionItem", function(self, auctionType, index)
            _lastAuctionTooltipType  = auctionType
            _lastAuctionTooltipIndex = index
            local link = GetAuctionItemLink(auctionType, index)
            local uid  = GetItemUniqueId(link)
            if AFX_DEBUG then
                print("|cff44DDFF[ItemAffixes]|r SetAuctionItem type=" .. tostring(auctionType)
                    .. " idx=" .. tostring(index) .. " uid=" .. tostring(uid))
            end
            if uid and uid ~= 0 then
                AddPeekLines(self, uid)
            else
                -- uid=0: use owner name + item template ID for server-side lookup.
                -- WoW 3.3.5a GetAuctionItemInfo returns 13 values:
                --   name,texture,count,quality,canUse,level,minBid,minIncrement,
                --   buyoutPrice,bidAmount,highBidder,owner,saleStatus
                -- owner=12; itemId is not returned in this version, extract from link.
                local info = {GetAuctionItemInfo(auctionType, index)}
                local owner  = info[12]
                local itemId = link and tonumber(link:match("|Hitem:(%d+):"))
                if AFX_DEBUG then
                    print("|cff44DDFF[ItemAffixes]|r SetAuctionItem owner=" .. tostring(owner)
                        .. " itemId=" .. tostring(itemId))
                end
                if owner and itemId then
                    AddAuctionLines(self, owner, itemId)
                end
            end
        end)
    end)
    if AFX_DEBUG then
        print("|cff44DDFF[ItemAffixes]|r SetAuctionItem hook: ok=" .. tostring(auctionHookOk)
            .. (auctionHookOk and "" or (" err=" .. tostring(auctionHookErr))))
    end

    -- Trade window tooltips.
    --
    -- WoW 3.3.5a trade links often carry uniqueId=0 (the trade protocol strips
    -- GUIDs).  For the player's own offered items the item is still locked in a
    -- bag slot, so we scan for a locked bag item with the matching template ID as
    -- a fallback.  For the partner's items uniqueId=0 means we cannot identify the
    -- specific instance client-side; a server-side TRADEPEEK command would be needed.

    -- Scan all bag slots for a locked item whose template ID matches itemId.
    -- Returns bag, slot on first match; nil, nil if not found.
    local function FindLockedItemInBags(itemId)
        for bag = 0, 4 do
            for slot = 1, GetContainerNumSlots(bag) do
                local _, _, locked = GetContainerItemInfo(bag, slot)
                if locked then
                    local link = GetContainerItemLink(bag, slot)
                    local tid  = link and tonumber(link:match("|Hitem:(%d+):"))
                    if tid == itemId then
                        return bag, slot
                    end
                end
            end
        end
        return nil, nil
    end

    local function AddTradeLines(self, link, isPlayer, tradeSlot)
        _lastTradeTooltipIsPlayer = isPlayer
        _lastTradeTooltipSlot     = tradeSlot
        _lastBagTooltipBag        = nil
        _lastBagTooltipSlot       = nil
        _lastEquipTooltipSlot     = nil
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r AddTradeLines isPlayer=" .. tostring(isPlayer)
                .. " slot=" .. tostring(tradeSlot)
                .. " link=" .. tostring(link)
                .. " uid=" .. tostring(link and GetItemUniqueId(link)))
        end
        local uid = GetItemUniqueId(link)
        if uid and uid ~= 0 then
            -- Normal path: link has a real GUID.
            AddPeekLines(self, uid)
        elseif isPlayer and link then
            -- uid=0 fallback for own trade items: find the locked bag slot.
            local itemId = tonumber(link:match("|Hitem:(%d+):"))
            if itemId then
                local bag, slot = FindLockedItemInBags(itemId)
                if bag and slot then
                    _lastBagTooltipBag  = bag
                    _lastBagTooltipSlot = slot
                    AddAffixLines(self, bag, slot)
                end
            end
        end
        -- Partner items with uid=0: cannot identify without server-side support.
    end
    pcall(function()
        hooksecurefunc(GameTooltip, "SetTradePlayerItem", function(self, tradeSlot)
            AddTradeLines(self, GetTradePlayerItemLink(tradeSlot), true, tradeSlot)
        end)
    end)
    pcall(function()
        hooksecurefunc(GameTooltip, "SetTradeTargetItem", function(self, tradeSlot)
            AddTradeLines(self, GetTradeTargetItemLink(tradeSlot), false, tradeSlot)
        end)
    end)

    -- Comparison tooltips (Shift+hover shows equipped item alongside hovered item).
    -- ShoppingTooltip1/2 may be lazy-loaded; TryHookShoppingTooltips is also called on ADDON_LOADED.
    TryHookShoppingTooltips()

    local numFrames = NUM_CONTAINER_FRAMES or 5
    for i = 1, numFrames do
        local cf = _G["ContainerFrame" .. i]
        if cf then
            HookContainerFrame(cf)
            cf:HookScript("OnShow", function(self)
                HookContainerFrame(self)
            end)
        end
    end

    StartOnUpdateDetector()

    -- Hook talent frame(s) for gold rank overlay display.
    -- Talent UI may be lazy-loaded; TryHookTalentFrames is also called on every
    -- ADDON_LOADED event so hooks are set up whenever the frames become available.
    AFXM:TryHookTalentFrames()

    -- Hook character sheet crit display to show SpellMod crit bonus.
    -- CharacterFrame may also be lazy-loaded; TryHookCritDisplay is called on every
    -- ADDON_LOADED event as well.
    TryHookCritDisplay()

    -- Hook InspectFrame:OnShow to prefetch affixes on every inspect window open.
    -- Blizzard_InspectUI is lazy-loaded; also retried on every ADDON_LOADED.
    TryHookInspectFrame()

    print("|cff44DDFF[ItemAffixes]|r ready — Alt+Click a bag item to roll.")
end

-- ============================================================================
-- Event frame
-- ============================================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("ITEM_LOCK_CHANGED")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("INSPECT_READY")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then Init() end
        -- Retry hooking talent frames on every addon load — the talent UI is
        -- lazy-loaded (Blizzard_TalentUI or similar) and won't exist until then.
        AFXM:TryHookTalentFrames()
        TryHookCritDisplay()
        TryHookInspectFrame()
        TryHookShoppingTooltips()

    elseif event == "CHAT_MSG_ADDON" then
        local pfx, msg = ...
        if pfx == PREFIX then AFXM:OnServerMsg(msg) end

    elseif event == "PLAYER_ENTERING_WORLD" then
        cache = {}
        inspectCache = {}
        pendingInspectReq = {}
        auctionCache = {}
        pendingAuctionReq = {}
        AFXM:SendToServer("CONFIG")
        AFXM:SendToServer("ALLDATA")

    elseif event == "BAG_UPDATE_DELAYED" then
        -- Clear bag cache then send ALLDATA.  BAG_UPDATE_DELAYED fires once per
        -- frame after each confirmed server move, so this always runs at the
        -- correct time (post-swap, post-equip).  A swap triggers two fires:
        -- one at pickup (pre-swap state, stale) and one at drop (post-swap, correct).
        -- ITEM_LOCK_CHANGED clears the cache between those two fires so the stale
        -- ALLDATA response cannot persist when the correct response arrives.
        if AFX_DEBUG then print("|cff44DDFF[ItemAffixes]|r EVENT: BAG_UPDATE_DELAYED") end
        ClearBagCache()
        AFXM:RequestAllData()

    elseif event == "ITEM_LOCK_CHANGED" then
        -- Fires on both pickup (item locked) and drop (item unlocked).
        -- We don't send ALLDATA here — BAG_UPDATE_DELAYED handles that.
        -- We DO clear the bag cache immediately so stale position data from a
        -- previous ALLDATA response cannot show while the swap is in progress.
        if AFX_DEBUG then
            local bag2, slot2 = ...
            print("|cff44DDFF[ItemAffixes]|r EVENT: ITEM_LOCK_CHANGED bag=" .. tostring(bag2) .. " slot=" .. tostring(slot2))
        end
        ClearBagCache()

    elseif event == "INSPECT_READY" then
        -- Backup trigger: InspectFrame:OnShow is the primary trigger, but
        -- INSPECT_READY fires after server data loads and is a reliable fallback.
        -- Also use it to ensure InspectFrame hook is set up (frame may just have loaded).
        TryHookInspectFrame()
        local name = (InspectFrame and InspectFrame.unit and UnitName(InspectFrame.unit))
            or UnitName("target")
        if not name or name == UnitName("player") then return end
        -- Only send if InspectFrame:OnShow didn't already send (it fires first).
        -- Sending again is harmless — the server replies and the client caches.
        AFXM:SendToServer("PEEKUNITALL|" .. name)
        if AFX_DEBUG then
            print("|cff44DDFF[ItemAffixes]|r INSPECT_READY → PEEKUNITALL|" .. name)
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- Clear the changed equip slot and ALL bag entries: both the bag slot
        -- that the newly equipped item vacated and the slot the old equipped
        -- item moved to need fresh data. ALLDATA handles both after the clear.
        local slot = ...
        if AFX_DEBUG then print("|cff44DDFF[ItemAffixes]|r EVENT: PLAYER_EQUIPMENT_CHANGED slot=" .. tostring(slot)) end
        if slot and cache[255] then
            cache[255][slot] = nil
        end
        ClearBagCache()
        AFXM:RebuildTalentBonuses()
        AFXM:RequestAllData()
    end
end)

-- ============================================================================
-- Key bindings
-- ============================================================================

BINDING_HEADER_ITEMAFFIXES    = "Item Affixes"
BINDING_NAME_ITEMAFFIXES_ROLL = "Roll Item Affix (hover item + use key)"

-- ============================================================================
-- /roll — hover a bag item then type /roll
-- ============================================================================

SLASH_ROLLAFFIX1 = "/roll"
SlashCmdList["ROLLAFFIX"] = function()
    local focus = GetMouseFocus()
    if not focus then
        print("|cff44DDFF[ItemAffixes]|r Hover over a bag item first, then type /roll.")
        return
    end
    local name = focus:GetName() or ""
    if name:find("^ContainerFrame%d+Item") then
        TryRollBagItem(focus:GetParent():GetID(), focus:GetID())
    else
        print("|cff44DDFF[ItemAffixes]|r Not hovering a bag item (hovering: " .. name .. ")")
    end
end

-- ============================================================================
-- /affixes status command
-- ============================================================================

SLASH_ITEMAFFIXES1 = "/affixes"
SlashCmdList["ITEMAFFIXES"] = function(msg)
    if msg == "debug" then
        AFX_DEBUG = not AFX_DEBUG
        print("|cff44DDFF[ItemAffixes]|r Debug " .. (AFX_DEBUG and "ON" or "OFF"))
        return

    elseif msg == "crit" then
        print("|cff44DDFF[ItemAffixes]|r === Crit Bonus Diagnostics ===")
        local bonus = GetBonusCritChance()
        print("|cff44DDFF[ItemAffixes]|r  Total bonus: +" .. string.format("%.2f", bonus) .. "%")
        for name, perRankRaw in pairs(AFXM_CRIT_DATA) do
            local ranks = AFXM.talentBonuses[name] or 0
            if ranks > 0 then
                local contrib = ranks * perRankRaw / 100.0
                print("|cff44DDFF[ItemAffixes]|r  " .. name
                    .. " +" .. ranks .. "r × " .. string.format("%.2f", perRankRaw/100.0)
                    .. "% = +" .. string.format("%.2f", contrib) .. "%")
            end
        end
        print("|cff44DDFF[ItemAffixes]|r  Hook registered: " .. tostring(_critHooksRegistered))
        print("|cff44DDFF[ItemAffixes]|r  Hook fired: " .. tostring(_critHookFired))
        local fns = {}
        for _, fn in ipairs({ "PaperDollFrame_SetMeleeCritChance", "PaperDollFrame_SetRangedCritChance",
                              "PaperDollFrame_SetSpellCritChance", "PaperDollFrame_SetMeleeCrit",
                              "PaperDollFrame_SetCrit" }) do
            if _G[fn] then fns[#fns+1] = fn end
        end
        print("|cff44DDFF[ItemAffixes]|r  Available fns: "
            .. (#fns > 0 and table.concat(fns, ", ") or "NONE"))
        if CharacterFrame then
            print("|cff44DDFF[ItemAffixes]|r  CharFrame shown: " .. tostring(CharacterFrame:IsShown()))
        else
            print("|cff44DDFF[ItemAffixes]|r  CharacterFrame: NIL")
        end
        -- Dump the last statFrame the hook received so we can identify the value FontString.
        local sf = _lastCritStatFrame
        if sf then
            local sfname = sf:GetName() or "(no name)"
            print("|cff44DDFF[ItemAffixes]|r  lastStatFrame: " .. sfname)
            -- Direct table fields
            for _, field in ipairs({ "rightText", "rightLabel", "value", "stat", "text2", "text" }) do
                local v = sf[field]
                if v and type(v) == "table" and v.GetText then
                    print("|cff44DDFF[ItemAffixes]|r    ." .. field .. " text='" .. tostring(v:GetText()) .. "'")
                end
            end
            -- Global named children
            for _, suffix in ipairs({ "RightText", "Right", "Value", "Stat", "Text2", "Text" }) do
                local fs = sfname ~= "(no name)" and _G[sfname .. suffix]
                if fs and fs.GetText then
                    print("|cff44DDFF[ItemAffixes]|r    global[" .. sfname .. suffix .. "] text='" .. tostring(fs:GetText()) .. "'")
                end
            end
            -- Regions
            local ok, n = pcall(sf.GetNumRegions, sf)
            if ok then
                for i = 1, n do
                    local r = select(i, sf:GetRegions())
                    if r and r.GetObjectType then
                        print("|cff44DDFF[ItemAffixes]|r    region " .. i .. " type=" .. r:GetObjectType()
                            .. " text='" .. tostring(r.GetText and r:GetText() or "n/a") .. "'")
                    end
                end
            end
            -- Children
            local ok2, n2 = pcall(sf.GetNumChildren, sf)
            if ok2 then
                for i = 1, n2 do
                    local child = select(i, sf:GetChildren())
                    if child then
                        local cname = child:GetName() or ("child" .. i)
                        local ok3, n3 = pcall(child.GetNumRegions, child)
                        if ok3 then
                            for j = 1, n3 do
                                local r = select(j, child:GetRegions())
                                if r and r.GetObjectType then
                                    print("|cff44DDFF[ItemAffixes]|r    child[" .. cname .. "] region " .. j
                                        .. " type=" .. r:GetObjectType()
                                        .. " text='" .. tostring(r.GetText and r:GetText() or "n/a") .. "'")
                                end
                            end
                        end
                    end
                end
            end
        else
            print("|cff44DDFF[ItemAffixes]|r  lastStatFrame: (none yet — open character sheet first)")
        end
        return

    elseif msg == "talent" then
        -- Diagnostics: show bonus state, frame/button existence, and force-apply.
        print("|cff44DDFF[ItemAffixes]|r === Talent Affix Diagnostics ===")
        -- Bonus data
        local n = 0
        for name, bonus in pairs(AFXM.talentBonuses) do
            print("|cff44DDFF[ItemAffixes]|r  bonus: +" .. bonus .. " to " .. name)
            n = n + 1
        end
        if n == 0 then print("|cff44DDFF[ItemAffixes]|r  bonuses: (none)") end
        -- Frame existence
        for _, fname in ipairs({"TalentFrame", "PlayerTalentFrame", "TalentFrameTalentFrame"}) do
            local f = _G[fname]
            print("|cff44DDFF[ItemAffixes]|r  " .. fname .. ": "
                .. (f and ("exists shown=" .. tostring(f:IsShown())) or "NIL"))
        end
        -- PlayerTalentFrame.selectedTab
        print("|cff44DDFF[ItemAffixes]|r  selectedTab=" .. tostring(
            PlayerTalentFrame and PlayerTalentFrame.selectedTab))
        -- Button existence: PlayerTalentFrameTalent1 (new naming)
        do
            local btn = _G["PlayerTalentFrameTalent1"]
            if btn then
                local rankByName  = _G["PlayerTalentFrameTalent1Rank"]
                local rankByName2 = _G["PlayerTalentFrameTalent1RankText"]
                -- Also check regions for a "X/Y" FontString
                local rankByRegion = nil
                local ok, n = pcall(btn.GetNumRegions, btn)
                if ok then
                    for i = 1, n do
                        local r = select(i, btn:GetRegions())
                        if r and r.GetObjectType and r:GetObjectType() == "FontString" then
                            local txt = r:GetText()
                            print("|cff44DDFF[ItemAffixes]|r  btn region " .. i .. " text=" .. tostring(txt))
                        end
                    end
                end
                print("|cff44DDFF[ItemAffixes]|r  PlayerTalentFrameTalent1: exists visible="
                    .. tostring(btn:IsVisible())
                    .. " Rank=" .. tostring(rankByName ~= nil)
                    .. " RankText=" .. tostring(rankByName2 ~= nil))
            else
                print("|cff44DDFF[ItemAffixes]|r  PlayerTalentFrameTalent1: NIL")
            end
        end
        print("|cff44DDFF[ItemAffixes]|r  IsTalentDisplayActive=" .. tostring(AFXM:IsTalentDisplayActive()))
        -- Force update
        if AFXM:IsTalentDisplayActive() then
            print("|cff44DDFF[ItemAffixes]|r  Forcing update now...")
            AFXM:UpdateTalentFrame()
            AFXM:ScheduleTalentUpdate()
        else
            print("|cff44DDFF[ItemAffixes]|r  Talent buttons not visible — open the talent window (N) first.")
        end
        -- Scan PlayerTalentFrame children for talent-related buttons/frames
        if PlayerTalentFrame then
            local found = {}
            local function ScanChildren(frame, depth)
                if depth > 6 or not frame.GetNumChildren then return end
                local ok, n = pcall(frame.GetNumChildren, frame)
                if not ok then return end
                for i = 1, n do
                    local child = select(i, frame:GetChildren())
                    if child then
                        local name = child:GetName() or ""
                        if name ~= "" then
                            found[#found+1] = name
                        end
                        ScanChildren(child, depth + 1)
                    end
                end
            end
            ScanChildren(PlayerTalentFrame, 0)
            -- Only print names that contain "Talent" (case-insensitive)
            local printed = 0
            for _, n in ipairs(found) do
                if n:lower():find("talent") and printed < 30 then
                    print("|cff44DDFF[ItemAffixes]|r  child: " .. n)
                    printed = printed + 1
                end
            end
            if printed == 0 then
                -- Print all named children up to 20 so we can see what's there
                for i = 1, math.min(20, #found) do
                    print("|cff44DDFF[ItemAffixes]|r  child: " .. found[i])
                end
            end
        end
        -- Raw cache
        if cache[255] then
            for slot, data in pairs(cache[255]) do
                if data.talentTexts and #data.talentTexts > 0 then
                    print("|cff44DDFF[ItemAffixes]|r  equip slot " .. slot .. " ta texts:")
                    for _, t in ipairs(data.talentTexts) do
                        print("|cff44DDFF[ItemAffixes]|r    " .. t)
                    end
                end
            end
        end
        return
    elseif msg == "imprint" then
        print("|cff44DDFF[ItemAffixes]|r === Imprint Tooltip Diagnostics ===")
        -- 1. Check hook preconditions
        print("|cff44DDFF[ItemAffixes]|r ActionButton_OnEnter exists: " .. tostring(ActionButton_OnEnter ~= nil))
        local ab1 = _G["ActionButton1"]
        print("|cff44DDFF[ItemAffixes]|r ActionButton1 exists: " .. tostring(ab1 ~= nil))
        if ab1 then
            print("|cff44DDFF[ItemAffixes]|r ActionButton1.action = " .. tostring(ab1.action))
            print("|cff44DDFF[ItemAffixes]|r ActionButton1._affixBarHooked = " .. tostring(ab1._affixBarHooked))
        end
        -- 2. Dump imprintDescOverrides
        local n = 0
        for k in pairs(imprintDescOverrides) do n = n + 1 end
        print("|cff44DDFF[ItemAffixes]|r imprintDescOverrides entries: " .. n)
        for spellId, desc in pairs(imprintDescOverrides) do
            local name = GetSpellInfo(spellId) or "?"
            print("|cff44DDFF[ItemAffixes]|r  [" .. spellId .. "] " .. name .. " -> " .. desc)
        end
        -- 3. Dump imprintDescByName
        local m = 0
        for k in pairs(imprintDescByName) do m = m + 1 end
        print("|cff44DDFF[ItemAffixes]|r imprintDescByName entries: " .. m)
        for spellName, desc in pairs(imprintDescByName) do
            print("|cff44DDFF[ItemAffixes]|r  [" .. spellName .. "] -> " .. desc)
        end
        -- 4. Scan ALL action slots for spells and flag any with imprint descs
        print("|cff44DDFF[ItemAffixes]|r Action slot scan (all 120 slots, spells only):")
        local foundImprint = false
        for slot = 1, 120 do
            local atype, aid = GetActionInfo(slot)
            if atype == "spell" and aid then
                local sname = GetSpellInfo(aid) or "?"
                local hasDesc = imprintDescOverrides[aid] ~= nil
                if hasDesc then
                    foundImprint = true
                    print("|cff44DDFF[ItemAffixes]|r  *** slot=" .. slot .. " spellId=" .. aid
                        .. " name=" .. sname .. " <-- IMPRINT MATCH")
                elseif AFX_DEBUG then
                    print("|cff44DDFF[ItemAffixes]|r  slot=" .. slot .. " spellId=" .. aid
                        .. " name=" .. sname)
                end
            end
        end
        if not foundImprint then
            print("|cff44DDFF[ItemAffixes]|r  (no imprint spells found on any action slot)")
            print("|cff44DDFF[ItemAffixes]|r  Drag the imprint spell onto a bar then re-run.")
        end
        -- 5. Check what GetMouseFocus sees right now
        local focus = GetMouseFocus and GetMouseFocus()
        if focus then
            local fname = focus:GetName() or "(unnamed)"
            local faction = rawget(focus, "action")
            print("|cff44DDFF[ItemAffixes]|r Mouse focus: " .. fname
                .. " .action=" .. tostring(faction))
        end
        return

    end

    print("|cff44DDFF[ItemAffixes]|r v1.0  initialized=" .. tostring(initialized))
    local count = 0
    for bag, slots in pairs(cache) do
        for slot, _ in pairs(slots) do count = count + 1 end
    end
    print("|cff44DDFF[ItemAffixes]|r " .. count .. " item(s) in cache.")
    for bag, slots in pairs(cache) do
        for slot, data in pairs(slots) do
            local states = {}
            for _, s in ipairs(data.slots or {}) do
                local t = s.state
                if s.text and s.text ~= "" then t = t .. ":" .. s.text end
                states[#states + 1] = t
            end
            print(string.format("  bag=%d slot=%d  %s", bag, slot, table.concat(states, "  ")))
        end
    end
end
