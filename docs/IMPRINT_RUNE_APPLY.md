# Imprint Rune — Right-Click Apply Flow

Documents the complete "right-click rune → left-click target item → imprint applied" system
implemented in session 2026-05-22. Every layer is described so it can be replicated or debugged.

---

## System Overview

```
Player right-clicks rune in bag
  │
  ├─ CMSG_USE_ITEM fired by client (rune has spellid_1 = 600001)
  ├─ Server processes spell 600001 (SPELL_EFFECT_SCRIPT_EFFECT, silent)
  └─ Addon detects via hooksecurefunc("UseContainerItem", ...) hook
       │
       ├─ Enter targeting mode:
       │    • rune bag/slot saved
       │    • cursor follower frame shown (rune icon follows mouse)
       │    • OnUpdate click detector started
       │    • ESC frame shown (press ESC to cancel)
       │
Player left-clicks a bag item
       │
       ├─ HookButton's OnMouseDown fires
       │    • Sends AFXM IMPRINT_APPLY|runeBag|runeSlot|targetBag|
       |    • Small existing bug where when left clicking to apply rune, also picks up item.
       targetSlot
       │    • Cancels targeting mode
       │    • Calls ClearCursor() to cancel the engine's PickupContainerItem
       │
Server HandleAddonMessage("IMPRINT_APPLY")
       │
       ├─ Resolves runeItem and targetItem via GetItemByLuaBagSlot
       ├─ Calls ImprintMgr::ApplyImprintDirect(player, runeItem, targetItem)
       │    • Validates rune has an ImprintInstance
       │    • Validates target is equippable and not already imprinted
       │    • SaveInstance(targetGuid, imprintId, extractionsLeft)
       │    • DeleteInstance(runeGuid)
       │    • player->DestroyItem(rune)
       │    • If target equipped: activates effect via OnEquip callback
       │
       └─ Sends DATA update for target item → addon refreshes tooltip in-place
```

---

## SQL Layer

### Spell 600001 (`db-world/imprint_apply_spell.sql`)

A minimal custom spell in `spell_dbc` that makes rune items right-clickable
without requiring a SpellScript:

```sql
INSERT INTO `spell_dbc` (`ID`, `CastingTimeIndex`, `RangeIndex`, `Effect_1`, `ImplicitTargetA_1`)
VALUES (600001, 1, 1, 77, 1)
ON DUPLICATE KEY UPDATE ...;
```

| Field | Value | Meaning |
|---|---|---|
| `Effect_1` | 77 | `SPELL_EFFECT_SCRIPT_EFFECT` — succeeds silently without a SpellScript |
| `CastingTimeIndex` | 1 | Instant cast |
| `RangeIndex` | 1 | Self range |
| `ImplicitTargetA_1` | 1 | `TARGET_UNIT_CASTER` (self) |

**Why SCRIPT_EFFECT:** The server needs to process the spell for `CMSG_USE_ITEM` to be accepted,
but we do the actual work in the addon (IMPRINT_APPLY message). SCRIPT_EFFECT is the
lightest valid effect — it succeeds without side-effects if no SpellScript is registered.
`SPELL_EFFECT_DUMMY` (3) also works but SCRIPT_EFFECT is the intended match for addon-driven spells.

### Rune item `spellid_1` (`db-world/imprint_rune_items.sql`)

Each rune item (602001–602004) must have `spellid_1 = 600001` and `spelltrigger_1 = 0`
(ON_USE trigger) so that right-clicking the item fires `CMSG_USE_ITEM`:

```sql
-- In the spell slot columns for each rune item:
600001, 0, 0, 0, -1, 0, -1,   -- spellid_1, spelltrigger_1 (0=ON_USE), charges, ppm, cd, cat, catcd
0,      0, 0, 0, -1, 0, -1,   -- slot 2 (unused)
...
```

Without `spellid_1`, right-clicking a `INVTYPE_NON_EQUIP` item does nothing (no CMSG_USE_ITEM
is sent and the addon hook never fires). With it, the engine sends CMSG_USE_ITEM which triggers
`UseContainerItem` on the client before the hook fires.

### Rune item design constraints

| Property | Value | Why |
|---|---|---|
| `class` | 15 (Misc) | Avoids Trade Goods vendor logic and sort ordering |
| `InventoryType` | 0 (INVTYPE_NON_EQUIP) | Makes right-click trigger `UseContainerItem` instead of equip |
| `Flags` | 0 | **Do NOT set bit 4 (HAS_LOOT)** — opens an unwanted loot window |
| `stackable` | 1 | Each rune needs its own GUID for per-rune extraction tracking in `item_imprint` |
| `bonding` | 1 (BoP) | Runes are personal — no trading after pickup |
| Entry range | 602001–602099 | Addon detects runes via `itemId >= 602001 and itemId <= 602099` |

---

## C++ Layer

### `ImprintMgr::ApplyImprintDirect` (`src/Imprints/ImprintMgr.cpp`)

Direct apply: takes specific runeItem and targetItem (both already resolved),
unlike `ApplyImprint` which finds any rune in bags via `FindRuneInBags`.

```cpp
bool ImprintMgr::ApplyImprintDirect(Player* player, Item* runeItem, Item* targetItem)
{
    // 1. Rune must have an ImprintInstance
    ImprintInstance const* runeInst = GetInstance(runeGuid);

    // 2. Rune entry must match def->runeItemId (sanity guard against cross-apply)

    // 3. Target must not already have an Imprint

    // 4. Target must be equippable (InventoryType != INVTYPE_NON_EQUIP)

    // 5. Transfer: SaveInstance(targetGuid) → DeleteInstance(runeGuid) → DestroyItem(rune)

    // 6. Activate effect immediately if target is currently equipped
    if (targetItem->IsEquipped())
    {
        data->activeImprints[targetGuid] = imprintId;
        effIt->second->OnEquip(player, targetGuid);
    }
}
```

Declaration in `ImprintMgr.h`:
```cpp
bool ApplyImprintDirect(Player* player, Item* runeItem, Item* targetItem);
```

### `IMPRINT_APPLY` message handler (`src/ItemAffix.cpp`, `HandleAddonMessage`)

Placed **before** the `parts.size() < 3` guard since it parses 4 bag/slot args:

```
Message format:  IMPRINT_APPLY|runeBag|runeSlot|targetBag|targetSlot
```

```cpp
if (cmd == "IMPRINT_APPLY")
{
    if (parts.size() < 5) return;
    // Parse 4 args: rBag, rSlot, tBag, tSlot
    Item* runeItem   = GetItemByLuaBagSlot(player, *rBagOpt, *rSlotOpt);
    Item* targetItem = GetItemByLuaBagSlot(player, *tBagOpt, *tSlotOpt);
    if (sImprintMgr->ApplyImprintDirect(player, runeItem, targetItem))
        SendItemStatus(player, targetItem);   // triggers addon tooltip refresh
    return;
}
```

`GetItemByLuaBagSlot` uses the AFXM bag convention:
- `bag=0` → backpack (INVENTORY_SLOT_ITEM_START + luaSlot - 1)
- `bag=1-4` → extra bags (INVENTORY_SLOT_BAG_START + bag - 1, slot luaSlot - 1)
- `bag=255` → equipment slots (EQUIPMENT_SLOT_START + luaSlot - 1)

---

## Addon Layer (`ItemAffixes.lua`)

### `UseContainerItem` hook

Registered in `Init()`. The hook fires AFTER `UseContainerItem` has already sent
`CMSG_USE_ITEM` to the server, so we don't need to (and can't) prevent the spell cast.

```lua
hooksecurefunc("UseContainerItem", function(bag, slot)
    local itemId = GetContainerItemID(bag, slot)

    -- Already in targeting mode: any right-click-use cancels (except re-clicking same rune)
    if _imprintTargeting then
        if itemId and itemId >= 602001 and itemId <= 602099
            and bag == _imprintRuneBag and slot == _imprintRuneSlot then
            return  -- re-click same rune: keep mode active
        end
        CancelImprintTargeting()
        return
    end

    -- Detect rune → enter targeting mode
    if itemId and itemId >= 602001 and itemId <= 602099 then
        _imprintTargeting = true
        _imprintRuneBag   = bag
        _imprintRuneSlot  = slot
        -- Show icon, ESC frame, start click detector
        ...
    end
end)
```

### Cursor follower frame

`SetCursor()` is overridden every frame by WoW's own cursor manager.
Instead, a small transparent frame follows the cursor position, showing
the rune's own icon as visual feedback:

```lua
local _imprintCursorFrame = CreateFrame("Frame", nil, UIParent)
_imprintCursorFrame:SetSize(32, 32)
_imprintCursorFrame:SetFrameStrata("TOOLTIP")
_imprintCursorFrame:EnableMouse(false)   -- must not block hover events
_imprintCursorFrame:SetScript("OnUpdate", function(self)
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    self:ClearAllPoints()
    self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / s + 10, y / s - 30)
end)
```

The rune's texture is retrieved from `GetContainerItemInfo(bag, slot)` (first return value)
and set on entry into targeting mode.

**Why not SetCursor():** `UseContainerItem` triggers a brief server round-trip which causes
WoW to show a "busy" cursor, then reset to default. Even if `SetCursor()` is called in the
hook, the engine overrides it immediately after the hook returns.

### Click detection (`StartImprintClickDetect`)

An `OnUpdate` frame polls `IsMouseButtonDown` to cancel on right-click or left-click-outside:

```lua
local function StartImprintClickDetect()
    -- Snapshot initial button states to avoid the entry right-click immediately cancelling
    _targetRightWasDown = IsMouseButtonDown("RightButton")
    _targetLeftWasDown  = IsMouseButtonDown("LeftButton")

    _imprintClickDetect:SetScript("OnUpdate", function()
        -- Right mouse down → cancel
        local rightDown = IsMouseButtonDown("RightButton")
        if rightDown and not _targetRightWasDown then
            CancelImprintTargeting(); return
        end
        if not rightDown then _targetRightWasDown = false end

        -- Left mouse down outside a bag item button → cancel
        local leftDown = IsMouseButtonDown("LeftButton")
        if leftDown and not _targetLeftWasDown then
            _targetLeftWasDown = true
            local fname = (GetMouseFocus() and GetMouseFocus():GetName()) or ""
            if not fname:find("^ContainerFrame%d+Item") then
                CancelImprintTargeting()
            end
        end
        if not leftDown then _targetLeftWasDown = false end
    end)
end
```

### ESC cancellation via `UISpecialFrames`

A hidden Frame named `"AFXImprintEscFrame"` is registered in `UISpecialFrames`.
When ESC is pressed, WoW calls `:Hide()` on all shown frames in the list.
The `OnHide` script cancels targeting mode:

```lua
local _imprintEscFrame = CreateFrame("Frame", "AFXImprintEscFrame", UIParent)
_imprintEscFrame:SetScript("OnHide", function()
    CancelImprintTargeting()   -- re-entry safe: _imprintTargeting cleared first
end)
table.insert(UISpecialFrames, "AFXImprintEscFrame")
```

Shown on targeting mode entry; `CancelImprintTargeting` hides it (triggering `OnHide`
which calls back but returns immediately because `_imprintTargeting` is already false).

### `HookButton` — left-click apply + ClearCursor

The existing `HookButton` function (which hooks `OnMouseDown` on all bag item buttons)
was extended to handle the targeting mode left-click:

```lua
btn:HookScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
        if _imprintTargeting then
            AFXM:SendToServer("IMPRINT_APPLY|"
                .. _imprintRuneBag .. "|" .. _imprintRuneSlot .. "|"
                .. self:GetParent():GetID() .. "|" .. self:GetID())
            CancelImprintTargeting(true)
            ClearCursor()   -- cancel PickupContainerItem before next render
        elseif IsAltKeyDown() then
            TryRollBagItem(...)
        end
    end
end)
```

**`ClearCursor()` timing:** `HookScript` fires in the same event processing pass as the
original `OnMouseDown`. The original handler already called `PickupContainerItem` (item is
now logically on cursor). `ClearCursor()` cancels this before any frame render, so the
player never sees the pickup animation.

---

## Tooltip In-Place Refresh (`RefreshTooltipInPlace`)

Every `DATA` response from the server previously called `GameTooltip:Hide(); Show()`,
causing a visible blink. The fix tracks which bag/slot is currently shown:

```lua
-- Tracking variables (updated in SetBagItem / SetInventoryItem hooks)
local _lastTooltipBag  = nil
local _lastTooltipSlot = nil

-- Clear when tooltip hides (prevents stale-value false positives)
GameTooltip:HookScript("OnHide", function()
    _lastTooltipBag  = nil
    _lastTooltipSlot = nil
end)

local function RefreshTooltipInPlace(bag, slot)
    if not GameTooltip:IsVisible() then return end
    if _lastTooltipBag ~= bag or _lastTooltipSlot ~= slot then return end
    pcall(function()
        if bag == 255 then
            GameTooltip:SetInventoryItem("player", slot)
        else
            GameTooltip:SetBagItem(bag, slot)
        end
    end)
end
```

`SetBagItem` / `SetInventoryItem` rebuild the tooltip atomically:
the C function clears and refills the item stats, then our `hooksecurefunc`
hook appends the affix lines. No blink, no re-hover required.

This is called from both the `DATA` handler and the `APPLY` handler in `OnServerMsg`.

---

## Gotchas

| Problem | Cause | Fix |
|---|---|---|
| `SetCursor()` reverts immediately | WoW overrides cursor every frame after `UseContainerItem` returns | Use a cursor-follower Frame instead |
| Item pickup visible on left-click | `PickupContainerItem` fires in original `OnMouseDown` before our hook | Call `ClearCursor()` synchronously in the hook (same event pass, before render) |
| `ClearCursor()` deferred frame still shows pickup | OnUpdate fires a full frame later — enough for one render | Remove deferral; call synchronously |
| ESC doesn't cancel | `_imprintEscFrame` created without UIParent as parent | Pass `UIParent` to `CreateFrame`: `CreateFrame("Frame", "AFXImprintEscFrame", UIParent)` |
| Right-click that started targeting also immediately cancels | OnUpdate snapshot of button state taken after button is already held | Use `IsMouseButtonDown("RightButton")` at hook entry to initialize `_targetRightWasDown` |
| `spell_dbc` INSERT fails | Wrong column name — `EffectImplicitTargetA_1` doesn't exist | Column is `ImplicitTargetA_1` (no `Effect` prefix); primary key is `ID` (uppercase) |
| `ALTER TABLE ADD COLUMN IF NOT EXISTS` fails | MySQL 8.4 removed this syntax | Use `INFORMATION_SCHEMA.COLUMNS` + prepared statement pattern (see `imprint_def.sql`) |
| Rune item opens loot window on right-click | `Flags` bit 4 (`ITEM_FLAG_HAS_LOOT`) was set | Keep `Flags = 0` on all rune items |
