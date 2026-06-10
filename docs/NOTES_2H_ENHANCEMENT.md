# 2H Weapon Enhancement — Dev Notes

## Goal

Two-handed weapons felt weaker than dual-wielding because a blue 2H weapon got 2 affix slots
while two blue 1H weapons got 4 total. This feature closes that gap by giving all 2H weapons
an extra affix slot and a +50% multiplier on all affix values.

---

## What Changed

### Extra slot per 2H weapon

| Quality  | Before | After |
|----------|--------|-------|
| Green    | 1      | 2     |
| Blue     | 2      | 3     |
| Epic     | 3      | 4     |

**Covered weapon types:** 2H sword, 2H axe, 2H mace, polearm, staff (`INVTYPE_2HWEAPON = 17`).  
**Excluded:** bows, guns, crossbows (`INVTYPE_RANGED = 15`) — these do not receive the bonus.

`Is2HWeapon()` in `ItemAffix.cpp` performs the check:
```cpp
static bool Is2HWeapon(Item const* item)
{
    return item && item->GetTemplate()->InventoryType == INVTYPE_2HWEAPON;
}
```

### +50% value multiplier

Applied after rolling, before the options are presented to the player (so the roll UI always
shows the final boosted values).

- **Stat affixes** — integer ceiling of value × 1.5: `(val * 3 + 1) / 2`
- **SpellMod affixes** — `rolledValue` is set to `150` as a boost flag. At apply time and
  display time, effect values and the affix name's embedded numbers are scaled × 1.5.

The `rolledValue` field in `item_affix` is normally `0` for SpellMod affixes (they have no
per-roll magnitude). Repurposing it as `150` is safe because that value is otherwise never
written.

`ScaleNameNumerics()` handles SpellMod name scaling (e.g. "Fireball: +15% Damage" → "+23%"):
it scans the name string for digit sequences and applies `ceil(val * factor)` to each.

### Ranged AP tier values preserved

2H weapon Attack Power entries (IDs 20201, 20231) were moved from the `ap_2h` tier variable to
`ap_1h` in all 8 `generics_XX_XX.json` tier files. The C++ +50% boost brings them back to
parity with what `ap_2h` would have given.

Ranged AP (ID 20220, Hunter bows/guns) stays on `ap_2h` — ranged weapons don't get the C++
boost, so they keep their higher base tier values.

---

## Files Modified

| File | What changed |
|------|--------------|
| `src/ItemAffix.cpp` | `Is2HWeapon()`, `ScaleNameNumerics()`, `InitItemSlots()` (+1 slot), `HandleRollRequest()` (boost after dedup), `ApplyAffixes()` (scale SpellMod value), `BuildAffixDisplayString()` (scaled name), `SendRollOptions()` (use `opt.rolledValue` for all types), `Upgrade2HSlots()`, `UpgradeAll2HSlots()` |
| `src/ItemAffix.h` | Declarations for `Upgrade2HSlots()` and `UpgradeAll2HSlots()` |
| `src/ItemAffixScripts.cpp` | `OnPlayerLogin` calls `UpgradeAll2HSlots(player)` before `ReapplyAllEquipped` |
| `affixes/generics_01_10.json` … `generics_71_80.json` (×8) | Split 2H weapon AP and ranged AP into separate entries with different tier vars |

---

## Issues Encountered and Resolved

### 1. Blue 2H weapon showing only 2 slots instead of 3

**Root cause (primary):** The worldserver binary in `E:\servers\Wow\bin\` was stale. CMake's
`cmake --build . --config RelWithDebInfo` compiles AND runs the INSTALL step — but INSTALL fails
silently with MSB3073 if the worldserver exe is locked by a running process. The newly compiled
exe stayed in `build-standard\bin\RelWithDebInfo\` and was never copied to the live bin path.

**Fix:** Stop the worldserver before building, or compare file sizes/timestamps after every
build:
```
ls -la /e/servers/Wow/bin/worldserver.exe
ls -la /e/servers/Wow/build-standard/bin/RelWithDebInfo/worldserver.exe
```
If sizes differ, copy manually:
```
cp /e/servers/Wow/build-standard/bin/RelWithDebInfo/worldserver.exe /e/servers/Wow/bin/worldserver.exe
```

### 2. Pre-existing 2H items not getting the extra slot on login

`InitItemSlots()` only fires on item acquisition — it never revisits items already in the DB.
Items acquired before the 2H enhancement was deployed had 2 rows in `item_affix` and were
never upgraded.

**Fix:** Added `Upgrade2HSlots(Player*, Item*)` (per-item) and `UpgradeAll2HSlots(Player*)`
(iterates all bags + equipment). `UpgradeAll2HSlots` is called from `OnPlayerLogin` so every
login retroactively checks and patches any 2H items that are short a slot.

`DirectExecute` (synchronous) is used for the INSERT so the new row is committed before
`SendItemStatus` queries the DB for the item's slot count.

### 3. `InitItemSlots` mismatch logic was destructive

The old mismatch path deleted ALL `item_affix` rows whenever `existingCount != numSlots`, which
would destroy any already-rolled affixes whenever the slot count changed.

**Fix:** Changed to:
- Delete all rows only when `existingCount > numSlots` (slots were removed — unlikely, but safe).
- When `existingCount < numSlots`, add only the missing slots starting from `existingCount`.
  Existing rolled affixes are left untouched.

### 4. Talent affixes are independent — not competing with regular slots

Concern: could the talent affix be "taking" the third slot?  
Answer: no. Regular affixes live in `item_affix`; talent affixes live in `item_talent_affix`.
They are entirely separate tables and the slot counts do not interact. A purple 2H weapon gets
4 regular affix slots (in `item_affix`) plus 1 talent affix line (in `item_talent_affix`) — 5
visible tooltip lines total.

### 5. Boost applied before dedup check (ordering concern)

The dedup check keeps a strictly-higher roll of the same stat type and discards a lower one.
This comparison must run on raw rolled values — not on the boosted values — so both options are
scaled by the same factor and the comparison stays accurate.

**Order in `HandleRollRequest()`:**
1. Roll N options (raw values).
2. Dedup: reject if same stat op AND value ≤ existing option.
3. Apply 2H boost to all surviving options.
4. Send `OPTS` to client (player sees boosted values).

---

## Dedup Logic (reference)

When rolling multiple options for a single slot, a new candidate is rejected if:
- It has the same `statOp` (same stat type), AND
- Its rolled value is ≤ the already-queued option's value.

A strictly higher value is kept — the player gets to choose between a lower-tier and a
higher-tier roll. This prevents the roll UI from showing two identical affixes but allows
"upgrade tier" scenarios.

---

## Verification Checklist

- [ ] Acquire a **blue 2H sword** → 3 affix slots appear in roll UI
- [ ] Acquire an **epic 2H mace** → 4 slots
- [ ] Acquire a **blue 1H sword** → still 2 slots, unscaled values
- [ ] Roll a stat affix on 2H weapon → value is ~1.5× equivalent 1H roll (ceiling)
- [ ] Roll a SpellMod affix on a staff → tooltip shows boosted % (e.g. +23% not +15%)
- [ ] Equip the 2H weapon → combat log / stat sheet confirms boosted magnitude
- [ ] Login with character holding a pre-existing 2H weapon → `Upgrade2HSlots` adds missing slot without destroying rolled affixes
- [ ] Acquire a **bow/gun** → ranged AP rolls from `ap_2h` tier, no C++ boost
- [ ] Purple 2H weapon → 4 regular slots + 1 talent affix line in tooltip (independent)
