# Gem Affixes — Implementation Plan

## Feature Goal

Gems can roll stat-only affixes (no talents, max 2 options). When a gem is socketed into gear,
its affix transfers to the gear item and is displayed as `+120 Stamina (from gem)` in the
gear tooltip. Replacing a gem in the same socket clears the previous gem affix and applies the
new one.

---

## Constraints

- Gem affixes: **stats only** (no spellmod, no talent bonus)
- Max **2 options** presented when rolling a gem
- No talent roll triggered for gems
- Gems only get 1 affix
- Interface UI, from ItemAffix interface addon, should onyl display stat family options, all other options should be hidden, only stat family applies.
- Gem affix transfers to the gear item at socket time; gem item is consumed normally
- Replacing a gem in the same socket clears the old gem affix on the gear
- Display suffix: `(from gem)` appended to the affix line in the gear tooltip
- Colour suggestion: teal (`|cff00CCCC`) to distinguish from regular affix lines (blue)

---

## Core Patch Requirement

There is **no existing script hook** for gem socketing in AzerothCore. `WorldSession::HandleSocketOpcode`
(`src/server/game/Handlers/ItemHandler.cpp`) is a self-contained core handler with no module
callback points.

### Installation note for others

This feature requires a small core patch — the same category as the `ApplyModToSpell` null-guard
already documented in README.md §Step 2. Without the patch, gems roll affixes but the transfer
at socket time cannot fire.

### Patch location

`src/server/game/Handlers/ItemHandler.cpp`, inside the gem socket loop (~line 1379),
**before** `_player->DestroyItem`:

```cpp
// --- existing code context ---
for (int i = 0; i < MAX_GEM_SOCKETS; ++i)
{
    if (GemEnchants[i])
    {
        itemTarget->SetEnchantment(EnchantmentSlot(SOCK_ENCHANTMENT_SLOT + i), GemEnchants[i], 0, 0, _player->GetGUID());
        if (Item* guidItem = _player->GetItemByGuid(packet.GemGuids[i]))
        {
            sScriptMgr->OnPlayerSocketGem(_player, itemTarget, guidItem, i);  // ← ADD THIS LINE
            _player->DestroyItem(guidItem->GetBagSlot(), guidItem->GetSlot(), true);
        }
    }
}
```

### Additional core files to edit

**`src/server/game/Scripting/ScriptDefines/PlayerScript.h`** — add virtual method:
```cpp
// Called just before a gem item is consumed into a socketed gear item.
// socketSlot: 0, 1, or 2 (gem socket index on the gear item).
virtual void OnSocketGem(Player* /*player*/, Item* /*gearItem*/, Item* /*gemItem*/, uint8 /*socketSlot*/) { }
```

**`src/server/game/Scripting/ScriptMgr.h`** — add dispatcher declaration:
```cpp
void OnPlayerSocketGem(Player* player, Item* gearItem, Item* gemItem, uint8 socketSlot);
```

**`src/server/game/Scripting/ScriptMgr.cpp`** — add dispatcher implementation:
```cpp
void ScriptMgr::OnPlayerSocketGem(Player* player, Item* gearItem, Item* gemItem, uint8 socketSlot)
{
    ExecuteScript<PlayerScript>([&](PlayerScript* script)
    {
        script->OnSocketGem(player, gearItem, gemItem, socketSlot);
    });
}
```

---

## New Database Table

File: `data/sql/db-characters/item_gem_affix.sql`

```sql
CREATE TABLE IF NOT EXISTS `item_gem_affix` (
    `gear_guid`    BIGINT   UNSIGNED NOT NULL,
    `socket_slot`  TINYINT  UNSIGNED NOT NULL COMMENT '0,1,2 — gem socket index',
    `affix_id`     INT      UNSIGNED NOT NULL DEFAULT 0,
    `rolled_value` INT      NOT NULL DEFAULT 0,
    PRIMARY KEY (`gear_guid`, `socket_slot`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## C++ Implementation

### ItemAffix.h additions

```cpp
// New method declarations on ItemAffixMgr:
void OnSocketGem(Player* player, Item* gearItem, Item* gemItem, uint8 socketSlot);
void ApplyGemAffixes(Player* player, Item* gearItem);
void RemoveGemAffixes(Player* player, Item* gearItem);
```

### ItemAffix.cpp — InitItemSlots() gem handling

Gems (`ITEM_CLASS_GEM`) pass the equippable check (they are not `INVTYPE_NON_EQUIP` etc.)
but should receive special treatment:
- Only stat affixes eligible (filter `AFFIX_TYPE_SPELLMOD` out)
- Max 2 options (regardless of item quality)
- No talent roll

Suggested approach: detect `proto->Class == ITEM_CLASS_GEM` at the top of `InitItemSlots`
and set a local `isGem = true` flag that is passed through to `HandleRollRequest` to cap
options and skip talent rolls.

### ItemAffix.cpp — OnSocketGem()

```
OnSocketGem(player, gearItem, gemItem, socketSlot):
    gemGuid   = gemItem->GetGUID().GetRawValue()
    gearGuid  = gearItem->GetGUID().GetRawValue()

    // 1. Find the gem's applied affix (if any)
    query item_affix WHERE item_guid=gemGuid AND roll_state=APPLIED
    if no rows → clean up any gem affix for this slot and return

    affixId     = row.affix_id
    rolledValue = row.rolled_value

    // 2. If gear is equipped, remove its current gem affixes first
    if gearItem->IsEquipped():
        RemoveGemAffixes(player, gearItem)

    // 3. Transfer: delete old gem affix for this socket slot, insert new one
    CharacterDatabase.Execute(
        "DELETE FROM item_gem_affix WHERE gear_guid={} AND socket_slot={}", gearGuid, socketSlot)
    CharacterDatabase.Execute(
        "INSERT INTO item_gem_affix VALUES ({},{},{},{})", gearGuid, socketSlot, affixId, rolledValue)

    // 4. Clean up gem's own item_affix rows (gem is about to be destroyed)
    CharacterDatabase.Execute(
        "DELETE FROM item_affix WHERE item_guid={}", gemGuid)
    CharacterDatabase.Execute(
        "DELETE FROM item_talent_affix WHERE item_guid={}", gemGuid)

    // 5. Re-apply all gem affixes to gear if equipped
    if gearItem->IsEquipped():
        ApplyGemAffixes(player, gearItem)
```

### ItemAffix.cpp — ApplyGemAffixes() / RemoveGemAffixes()

Mirror the pattern of `ApplyAffixes` / `RemoveAffixes` but read from `item_gem_affix`.
Each row is a stat-only affix — call `ApplyGenericStat` / `UnapplyGenericStat` using the
`affix_id` to look up the `statOp` from `_defs`.

### ItemAffixScripts.cpp — hook registration

```cpp
void OnSocketGem(Player* player, Item* gearItem, Item* gemItem, uint8 socketSlot) override
{
    sItemAffixMgr->OnSocketGem(player, gearItem, gemItem, socketSlot);
}
```

Also call `ApplyGemAffixes` from `OnPlayerEquip` (alongside `ApplyAffixes`) and
`RemoveGemAffixes` from `OnPlayerUnequip` (alongside `RemoveAffixes`).

### SendItemStatus() — include gem affix lines

When building the `DATA|...` message for an item, also query `item_gem_affix` and append
`gem:slot:affixId:rolledValue` segments so the Lua addon can display them.

---

## Lua Addon Changes (ItemAffixes.lua)

### Parsing gem affix segments in DATA handler

Extend the `DATA` message parser to read `gem:slot:id:val` segments alongside `s0:...`
regular slots and `ta:...` talent lines.

### AddAffixLines() — gem display

After rendering regular affix lines, iterate the parsed gem segments and add:
```lua
tooltip:AddLine("|cff00CCCC+" .. val .. " " .. statName .. " (from gem)|r")
```
Teal colour (`00CCCC`) distinguishes gem affixes from regular blue affix lines.

---

## README.md Addition

Add a Step 2b (between the existing Step 2 `ApplyModToSpell` and Step 3 build):

```
### Step 2b — Apply the gem socketing hook patch (optional — required for gem affixes)

In `src/server/game/Handlers/ItemHandler.cpp`, inside `HandleSocketOpcode`,
add the script callback before `DestroyItem`:

    sScriptMgr->OnPlayerSocketGem(_player, itemTarget, guidItem, i);

Also add the virtual method to `PlayerScript.h` and the dispatcher to `ScriptMgr.h/cpp`
as described in GEM_AFFIXES_PLAN.md.

If you skip this patch, gems will still roll affixes but the affix will never transfer
to the gear item — gem affixes are silently dropped at socket time.
```

---

## Implementation Order

1. `data/sql/db-characters/item_gem_affix.sql` — new table
2. Core patch: `ItemHandler.cpp` + `PlayerScript.h` + `ScriptMgr.h/cpp`
3. `ItemAffix.h` — new method declarations
4. `ItemAffix.cpp` — `OnSocketGem`, `ApplyGemAffixes`, `RemoveGemAffixes`, gem flag in roll path
5. `ItemAffixScripts.cpp` — `OnSocketGem` override + equip/unequip gem apply/remove calls
6. `ItemAffix.cpp` — `SendItemStatus` gem segments
7. `ItemAffixes.lua` — parse gem segments, render `(from gem)` lines
8. `README.md` — Step 2b
9. Build + test
