# Class Affixes Guide

This document describes how to systematically add affixes for each class. The Priest
and Mage sets serve as the reference implementation.

---

## ID & Enchant Namespace

Each class owns a **1000-ID block** in `affixes.json`. Enchant IDs come from
`SpellItemEnchantment.dbc`; the base 3.3.5a DBC has no entries in the 3880–3999 range.
IDs above 3999 should be verified empty before use (run `patch_dbc.ps1 --list`).

| Class        | Affix ID block | Enchant IDs     | Status     |
|--------------|----------------|-----------------|------------|
| Priest       | 1000–1999      | 3890–3949       | Done (1000–1059) |
| Mage         | 2000–2999      | 3950–3997       | Done (2000–2047) |
| Warrior      | 3000–3999      | 4005–4049       | Done (3000–3044) |
| Paladin      | 4000–4999      | 4050–4099       | Done (4000–4043) |
| Hunter       | 5000–5999      | 4094–4127       | Done (5000–5033) |
| Rogue        | 6000–6999      | 4128–4161       | Done (6000–6033) |
| Druid        | 7000–7999      | 4200–4249 (TBD) | Pending    |
| Shaman       | 8000–8999      | 4250–4299 (TBD) | Pending    |
| Warlock      | 9000–9999      | 4300–4349 (TBD) | Pending    |
| Death Knight | 10000–10999    | 4350–4399 (TBD) | Pending    |
| Generic      | 11000–11999    | 4400–4449 (TBD) | Pending    |

**Legacy IDs (pre-namespace):**
- 1, 2, 101, 102 — archived Priest affixes (weight=0)
- 108, 109 — active Hunter affixes (weight=100); migrate to 5000-range in a future pass

> **Note on enchant IDs above 3999**: verify these ranges are unused in the base DBC
> before assigning them. Run `patch_dbc.ps1 --list` to see what IDs already exist.

---

## Process for Adding a New Class

### Step 1 — Find spells in SPELLS_REFERENCE.csv

Open `SPELLS_REFERENCE.csv` (generate with `build_spell_ref.ps1` if stale). For each
spell you want to target, note:
- `Rank1_ID` → use as `carrier_spell_id`
- `flags0`, `flags1`, `flags2` → use as `flags: [flags0, flags1, flags2]`
- `Class` / family number → use as `family`

### Step 2 — Classify each spell

For each spell, determine which modifier ops make sense:

| Spell type | Valid ops |
|------------|-----------|
| Has cast time > 0ms | DAMAGE, CRIT, CASTING_TIME (negative only) |
| Instant cast | DAMAGE, CRIT, COOLDOWN (if CD exists), DURATION (if buff/debuff) |
| Has cooldown | COOLDOWN (negative = shorter) |
| Deals damage | DAMAGE PCT |
| Heals | DAMAGE PCT (same op, same code path) |
| Has a DoT/HoT duration | DURATION FLAT or PCT |
| Applies a buff to self | DURATION FLAT (extend buff), COOLDOWN (shorten reuse) |
| CC / control effect | DURATION FLAT (extend CC), COOLDOWN FLAT (shorten reuse) |

> **Never add CASTING_TIME to instant spells** — the modifier fires after the
> "is instant?" check in Spell.cpp and has no effect. Use COOLDOWN or DURATION instead.

### Step 3 — Plan affix table

For each spell, create 2–5 affixes following the weight/quality schema:

| Affix type | weight | min_quality |
|------------|--------|-------------|
| Standard single-effect | 100 | 1 |
| Strong cast reduction (-1s to -1.5s) | 40–80 | 1 |
| Instant-cast (CASTING_TIME -10000) | 20 | 2 |
| Standard dual-effect | 10 | 2 |
| High-power dual (instant + damage) | 5 | 3 |

Assign IDs sequentially from the class block start. Assign enchant IDs sequentially
from the class enchant range start.

### Step 4 — Write JSON entries

Each entry format (add to the `affixes` array in `class_affixes/[class].json`):

```json
{ "id": ID, "name": "SpellName: Effect", "weight": W, "min_quality": Q,
  "target": { "family": F, "family_name": "CLASS", "carrier_spell_id": C, "flags": [F0,F1,F2], "verified": false, "verify_command": ".spellinfo all C" },
  "effect": { "op": OP, "op_name": "OPNAME", "modifier": MOD, "modifier_name": "MODNAME", "value": VAL },
  "tooltip": { "enchant_id": E, "display_name": "SpellName: Effect" } },
```

For dual-effect, add `"effect2": { ... }` between `effect` and `tooltip`.

### Step 5 — Run the pipeline

```
update_affixes.bat
```

This runs `build_affixes.ps1` (generates SQL), applies SQL to `acore_world`, patches
DBC, rebuilds MPQ, and restarts the worldserver.

### Step 6 — Verify in-game

For each spell:
1. `.spellinfo all <carrier_spell_id>` — confirm SpellFamilyFlags match your flags values
2. `.additem <item_id> 1` on a character of that class — check `item_affix` table
3. Equip the item and cast the spell — observe the effect

Update `"verified": true` in the JSON after confirming each spell's flags.

---

## Op & Modifier Reference

| op | Name | modifier | Unit | Notes |
|----|------|----------|------|-------|
| 0 | DAMAGE | 108=PCT | % | Also controls heal amount |
| 1 | DURATION | 107=FLAT or 108=PCT | ms or % | Buff/debuff/HoT/DoT duration |
| 7 | CRITICAL_CHANCE | 107=FLAT | percentage points | +5 = +5% crit |
| 10 | CASTING_TIME | 107=FLAT | ms | Negative = faster; **no effect on instants** |
| 11 | COOLDOWN | 107=FLAT | ms | Negative = shorter cooldown |

---

## Flag Conflicts (known)

Some spells share identical SpellFamilyFlags within the same class, causing affixes
for one spell to also affect the other. This is expected and acceptable — note it in
`_purpose` if the overlap is surprising.

| Class | Spells | Shared flags |
|-------|--------|-------------|
| Mage | Blast Wave (carrier 11113) + Ice Lance (carrier 30455) | flags=[131072,0,0] |

When adding a new class, look for collisions by sorting the CSV by flags0/flags1/flags2
within the same family and checking for duplicate rows.

---

## Verification Checklist

- [ ] `.spellinfo all <carrier_spell_id>` — SpellFamilyFlags match JSON flags
- [ ] New item rolled on correct class character → `item_affix` table shows ID in class range
- [ ] Hunter still rolls 108/109 (cross-class isolation working)
- [ ] Equip item → cast spell → stat changes match expected effect
- [ ] No server errors in worldserver log about invalid carrier_spell_id
- [ ] Client shows green enchant tooltip on item
- [ ] Set `"verified": true` in JSON after in-game confirmation
