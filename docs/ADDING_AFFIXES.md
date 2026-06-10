# Adding Affixes — Authoring Guide

---

## Quick Checklist

- [ ] **`weight` > 0** — affixes with `weight: 0` load into the DB but never roll. Set to `100` to enable.
- [ ] **`enchant_id` is non-zero** — `0` means no green tooltip line. Pick an unused DBC ID (safe range: 3880–3999).
- [ ] **`carrier_spell_id` is a valid spell** — validated at startup. An invalid ID logs an error and skips the affix. Use `Rank1_ID` from `SPELLS_REFERENCE.csv`.
- [ ] **`flags` match the actual spell family flags** — wrong flags mean the mod never applies. Verify with `.spellinfo all <carrier_spell_id>` in-game.
- [ ] **Run `update_affixes.bat` after every change** — regenerates SQL and applies it to the DB. No server rebuild needed for affix data changes.
- [ ] **Unique `id`** — duplicate IDs overwrite the existing row (`ON DUPLICATE KEY UPDATE`).
- [ ] **Unique `enchant_id`** — two affixes sharing an enchant ID display the same tooltip text.
- [ ] **Clear client cache after MPQ rebuild** — delete `WTF\Cache\` if enchant names don't appear.

---

## How the system works

### Source files

Never edit the generated `.sql` files directly.

| File | Contents |
|------|----------|
| `affixes/generics_defs.json` | Stat affixes (Strength, Crit, Spell Power, Dodge, etc.) |
| `affixes/generics_01_10.json` … `generics_71_80.json` | Stat value tiers by level range |
| `class_affixes/[class].json` | SpellMod affixes per class (mage.json, rogue.json, etc.) |
| `talent_affixes/_maps.json` | Lookup maps for the talent build script (enum → integer) |
| `talent_affixes/<Class>/<spec>.json` | Talent affixes for this spec tree (`spec_tree=0/1/2`) |

### Build pipeline

```
update_affixes.bat
  ├── build_affixes.ps1        → data/sql/db-world/affix_template.sql
  ├── build_talent_affixes.ps1 → data/sql/db-world/talent_affix_def.sql
  └── applies both SQL files to the DB
```

After running, restart worldserver (or use `.reload all` if the command is available).

### How affixes reach players

1. **Acquisition** — `InitItemSlots` assigns 1–3 UNROLLED rows to `item_affix` based on item
   quality. The item can be traded freely at this point (no class fingerprint).

2. **Roll Menu** — when the player Alt+Clicks an item with UNROLLED slots, the Roll Menu frame
   appears. The player selects preferences:
   - **What to roll?** → Any / Stats / Class Skills
   - **Talent Tree:** → Any or a specific spec (controls which spec's talent bonus can roll)
   - **Stat family?** → Any / Tank / Physical / Caster / Healer *(hidden when Class Skills selected)*
   - **Main stat?** → Any / Strength / Agility / Intellect / Spirit *(hidden when Class Skills selected)*

3. **Server-side roll** — preferences are sent to the server. `RollAffixId` filters the pool
   using role mask, item category, and class family. The pool is never filtered by spec tree for
   regular affixes — spec selection only affects talent affixes. A talent roll is also attempted
   for each slot (10% green, 50% blue/epic).

4. **Pick** — the player receives 1–3 options and picks one. It is saved as APPLIED.

5. **Equip** — `ApplyAffixes` and `ApplyTalentAffixes` apply the stored mods.

### How player preferences steer rolls

| Preference | Effect on `RollAffixId` |
|------------|-------------------------|
| Stats only | Pool limited to `affix_type=STAT` and `spell_family=0` affixes |
| Class Skills only | Pool limited to `affix_type=SPELLMOD` with `spell_family != 0` |
| Stat family (role) | Affixes with `role_mask != 0` must match the chosen role; `role_mask=0` (universal) always eligible |
| Main stat | Only the chosen main stat (`GSTAT_STRENGTH` … `GSTAT_SPIRIT`) is included |
| Talent Tree (spec) | Only affects `InitTalentAffix` — picks which spec tree's talents are eligible |

Stat affixes are never filtered by class family. The `spell_family` field on stat rows is ignored
for filtering; only `role_mask` and `min_quality` gate which players see which stats.

---

## Stat affixes (`generics_defs.json`)

Each entry defines one stat affix. All stat affixes use `"target": { "family": 0 }` (universal —
no class restriction at the pool level). Role mask is the only player-scoping mechanism.

```jsonc
{
  "id": 20010,
  "name": "Strength",
  "weight": 100,
  "min_quality": 1,          // 1=green+, 2=blue+, 3=epic+

  // Optional: restrict to a role. Omit (or "ANY") for universal stats.
  // Values: "TANK", "PHYSICAL", "CASTER", "HEALER", "CASTER_HEALER"
  // "role": "PHYSICAL",

  "target": {
    "family": 0,             // 0 = universal; never change for stat affixes
    "stat_op": "STRENGTH"    // Which stat to boost — see stat_op reference below
  },

  // Values come from generics_##_##.json tier files, keyed by "family" name.
  // The tier file defines min/max values per level bracket.
  "value_family": "STRENGTH",

  "tooltip": {
    "enchant_id": 4100,
    "display_name": "Strength"
  }
}
```

### Role mask values

| `role` string | role_mask | Who gets it |
|---------------|-----------|-------------|
| *(omitted)*   | 0         | Everyone regardless of role |
| `"CASTER"`    | 1         | Caster specs (Shadow Priest, Mage, Warlock, Balance Druid, etc.) |
| `"PHYSICAL"`  | 2         | Physical DPS specs (Rogue, Hunter, Fury Warrior, Feral Druid, etc.) |
| `"TANK"`      | 4         | Tank specs (Prot Warrior/Paladin, Blood DK, etc.) |
| `"HEALER"`    | 8         | Healing specs (Holy/Disc Priest, Resto Shaman/Druid, Holy Paladin) |
| `"CASTER_HEALER"` | 9    | Casters and healers (e.g. Mp5) |

The player's current role is derived from class + dominant talent tree at roll time. When the
player selects a Stat family preference in the Roll Menu, that choice overrides the automatic
role detection.

### min_quality guide

| `min_quality` | Rolls on |
|---------------|----------|
| 1             | Green, blue, epic |
| 2             | Blue, epic (recommended for role-specific stats like Spell Power, Attack Power) |
| 3             | Epic only |

Universal stats (Stamina, Crit Rating, Haste Rating, Hit Rating, Armor Pen, main stats) use
`min_quality: 1`. Role-specific stats that would be wasted on wrong specs use `min_quality: 2`
so green items only get broadly useful stats.

---

## SpellMod affixes (`class_affixes/[class].json`)

Each entry modifies a specific class's spell. The `spell_family` field ties the affix to a
class — only players of that class can roll it.

```jsonc
{
  "id": 6000,
  "name": "Sinister Strike: +15% Damage",
  "weight": 100,
  "min_quality": 1,

  // Optional: restrict to items of a specific type.
  // 0=any, 1=1H weapon, 2=2H weapon, 3=any weapon, 4=armor, 6=wand, 8=dagger-or-non-weapon
  "item_category": 0,

  // Optional: which spec tree "owns" this ability.
  // 255 (default) = any spec. 0/1/2 = tree index (e.g., Rogue: 0=Assassination, 1=Combat, 2=Subtlety).
  // This field is informational for future use; it does NOT filter the roll pool for class skills.
  // (Spec selection in the Roll Menu only affects talent affixes, not class skill rolls.)
  "spec_tree": 1,

  "target": {
    "family": 8,             // SpellFamilyName — 8=Rogue, 3=Mage, 6=Priest, etc.
    "family_name": "ROGUE",
    "carrier_spell_id": 1752,
    "flags": [32, 0, 0],
    "verified": true,
    "verify_command": ".spellinfo all 1752"
  },

  "effect": {
    "op": 0,                 // 0=DAMAGE, 10=CASTING_TIME, 11=COOLDOWN, 14=COST, etc.
    "op_name": "DAMAGE",
    "modifier": 108,         // 107=FLAT, 108=PCT
    "modifier_name": "PCT",
    "value": 15
  },

  // Up to 4 effects on the same spell (effect, effect2, effect3, effect4).

  "tooltip": {
    "enchant_id": 4200,
    "display_name": "Sinister Strike: +15% Damage"
  }
}
```

### SpellFamily numbers

| Class       | `family` |
|-------------|----------|
| Mage        | 3        |
| Warrior     | 4        |
| Warlock     | 5        |
| Priest      | 6        |
| Druid       | 7        |
| Rogue       | 8        |
| Hunter      | 9        |
| Paladin     | 10       |
| Shaman      | 11       |
| Death Knight| 15       |

### `item_category` values

| Value | Rolls on |
|-------|----------|
| 0     | Any equippable item |
| 1     | 1H weapons (main hand, off hand, shield) |
| 2     | 2H weapons and ranged |
| 3     | Any weapon (1H or 2H) |
| 4     | Armor (head, chest, legs, etc.) |
| 6     | Wand only |
| 8     | Daggers **and** all non-weapon items (use for dagger-requirement abilities like Backstab) |

### Effect `op` reference

| `op` | Constant         | Notes |
|------|------------------|-------|
| 0    | DAMAGE           | Also controls heal amount |
| 1    | DURATION         | Buff/debuff duration |
| 5    | RANGE            | Cast range |
| 7    | CRITICAL_CHANCE  | FLAT only; value = percentage points |
| 10   | CASTING_TIME     | FLAT = ms; negative = faster. Cannot add time to instant spells |
| 11   | COOLDOWN         | FLAT = ms; negative = shorter |
| 14   | COST             | Resource cost; PCT negative = cheaper |
| 22   | DOT              | Periodic damage tick |

### `modifier` values

| `modifier` | Meaning |
|------------|---------|
| 107 (FLAT) | Add/subtract raw units (ms, % points, etc.) |
| 108 (PCT)  | Percentage relative to base (+20 = +20%, -10 = -10%) |

---

## Talent affixes (`talent_affixes/<Class>/`)

Talent affixes add bonus ranks to a class talent. They are rolled separately from regular affixes
— one attempt per regular affix slot (10% green, 50% blue/epic). The Talent Tree preference in
the Roll Menu steers which spec tree's talents are eligible.

Each class has its own subdirectory under `talent_affixes/`:
- `<Class>/<spec>.json` — spec-specific entries (`spec_tree=0/1/2`); every talent lives here
- `_maps.json` — enum lookup tables (read by build script only, not a talent data file)

```jsonc
{
  "id": 41,
  "name": "Improved Sinister Strike",
  "class": "ROGUE",           // String key — build script maps to class_mask integer
  "spec_tree": 1,             // 0/1/2 = the talent's actual tree (leftmost=0, middle=1, rightmost=2)
  "max_rank": 2,              // Maximum bonus ranks that can roll (must be >= 2)
  "spell_family": "ROGUE",   // String key — build script maps to SpellFamilyName integer
  "family_flags": [2, 0, 0], // SpellClassMask bits — from .spellinfo all <carrier_spell>
  "carrier_spell": 1752,     // A real spell from this family; used for family resolution
  "spellmod_op": "COST",     // What the modifier changes (DAMAGE, COOLDOWN, COST, etc.)
  "spellmod_type": "FLAT",   // How it's applied: FLAT (raw units) or PCT (percentage)
  "value_per_rank": -3,      // Amount per rolled rank. 2 ranks = -6 energy cost.
  "notes": "Sinister Strike energy cost -3 per rank",
  "verified": true,
  "verify_command": ".spellinfo all 1752"
}
```

Only add talents with `max_rank >= 2`. Single-rank talents are excluded by design.

See `ADDING_TALENT_AFFIXES.md` for the full authoring guide including flag patterns, field
reference, and step-by-step instructions.

After editing any talent affix file, run `update_affixes.bat` to regenerate and apply
`talent_affix_def.sql`. No server restart is required.

---

## Finding spell values

Open `SPELLS_REFERENCE.csv`. Columns you need:

| CSV column    | JSON field                    |
|---------------|-------------------------------|
| `Class`       | `target.family_name`          |
| Family number | `target.family`               |
| `Rank1_ID`    | `target.carrier_spell_id`     |
| `flags0`      | `target.flags[0]`             |
| `flags1`      | `target.flags[1]`             |
| `flags2`      | `target.flags[2]`             |

Verify in-game: `.spellinfo all <rank1_id>` shows the family flags the server sees.

---

## Removing an affix

Move the entry from the `affixes` array to `removedAffixes` in the same file. On next
`update_affixes.bat`, the row is `DELETE`d from `affix_template`. The JSON stays in
`removedAffixes` for history and can be restored by moving it back.

Items that already rolled a removed affix keep their `item_affix` row but `GetAffixDef()`
returns null, so no mods are applied.

---

## Choosing enchant IDs

- **Safe range**: 3880–3999 (empty in base 3.3.5a DBC)
- **Never reuse** an enchant ID between two different affixes — they will share the same tooltip text
- **Never use 0** — means "no tooltip"

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Affix never rolls | `weight: 0` or not in DB | Set weight > 0, run `update_affixes.bat` |
| Stat affix never rolls | `role_mask` doesn't match player's current role/preference | Verify role_mask value; check player's spec role |
| No green tooltip | `enchant_id: 0`, DBC not patched, or client cache stale | Set non-zero ID, run `update_affixes.bat`, clear `WTF\Cache\` |
| Spell mod has no effect | Wrong `flags` | Verify with `.spellinfo all <carrier_spell_id>`, fix flags |
| Affix skipped at startup (error log) | Invalid `carrier_spell_id` | Use Rank1_ID from `SPELLS_REFERENCE.csv` |
| Class skill rolling on wrong class | Wrong `spell_family` | Check class family table above |
| Dagger-only skill rolling on swords | Missing `item_category: 8` | Set `"item_category": 8` in JSON |
| Talent affix shows for wrong spec | Wrong `spec_tree` in class file | Match 0/1/2 to the correct tree index for that class |
| Old affixes still rolling after removal | DB not updated | Run `update_affixes.bat` |
