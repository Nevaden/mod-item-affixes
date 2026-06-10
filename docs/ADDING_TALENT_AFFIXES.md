# Adding Talent Affixes — Authoring Guide

Talent affixes give players bonus ranks in one of their class talents. They roll separately from
regular affixes — once per affix slot (10% chance on green items, 50% on blue and epic). This
guide explains how to add new ones and which pattern to follow depending on what the talent does.

---

## File Organization

Talent affixes live in `talent_affixes/`, with one subdirectory per class:

```
talent_affixes/
├── _maps.json                     ← lookup maps only (spell_family, class_mask, spellmod_op, etc.)
│                                    Read by build script; not a talent data file.
├── Death Knight/
│   ├── blood.json                 ← Blood tree (spec_tree=0, IDs 60–61, 621–622)
│   ├── frost.json                 ← Frost tree (spec_tree=1, IDs 640–643)
│   └── unholy.json                ← Unholy tree (spec_tree=2, IDs 62–63, 660–663)
├── Druid/
│   ├── balance.json               ← Balance tree (spec_tree=0, IDs 90–91, 320–324)
│   ├── feral.json                 ← Feral Combat tree (spec_tree=1, IDs 94, 340–345)
│   └── restoration.json           ← Restoration tree (spec_tree=2, IDs 92–93, 360–363)
├── Hunter/
│   ├── beast_mastery.json         ← Beast Mastery tree (spec_tree=0)
│   ├── marksmanship.json          ← Marksmanship tree (spec_tree=1, IDs 31, 33, 460–462)
│   └── survival.json              ← Survival tree (spec_tree=2)
├── Mage/
│   ├── arcane.json                ← Arcane tree (spec_tree=0, IDs 500–519)
│   ├── fire.json                  ← Fire tree (spec_tree=1, IDs 2, 520–524)
│   └── frost.json                 ← Frost tree (spec_tree=2, IDs 1, 540–544)
├── Paladin/
│   ├── holy.json                  ← Holy tree (spec_tree=0, IDs 21–22, 200–203)
│   ├── protection.json            ← Protection tree (spec_tree=1)
│   └── retribution.json           ← Retribution tree (spec_tree=2, IDs 20, 23, 240–244)
├── Priest/
│   ├── discipline.json            ← Discipline tree (spec_tree=0, IDs 50, 53, 140–149)
│   ├── holy.json                  ← Holy tree (spec_tree=1, IDs 52, 160–166)
│   └── shadow.json                ← Shadow tree (spec_tree=2, IDs 51, 180–188)
├── Rogue/
│   ├── assassination.json         ← Assassination tree (spec_tree=0, IDs 40–49, 95–96)
│   ├── combat.json                ← Combat tree (spec_tree=1, IDs 41, 100–119)
│   └── subtlety.json              ← Subtlety tree (spec_tree=2, IDs 120–139)
├── Shaman/
│   ├── elemental.json             ← Elemental tree (spec_tree=0, IDs 71, 560–565)
│   ├── enhancement.json           ← Enhancement tree (spec_tree=1, IDs 580–599)
│   └── restoration.json           ← Restoration tree (spec_tree=2, IDs 72–73, 600–604)
├── Warlock/
│   ├── affliction.json            ← Affliction tree (spec_tree=0, IDs 81, 83, 260–266)
│   ├── demonology.json            ← Demonology tree (spec_tree=1)
│   └── destruction.json           ← Destruction tree (spec_tree=2, IDs 80, 82, 300–303)
└── Warrior/
    ├── arms.json                  ← Arms tree (spec_tree=0, IDs 10–13, 380–382)
    ├── fury.json                  ← Fury tree (spec_tree=1)
    └── protection.json            ← Protection tree (spec_tree=2)
```

**Rules:**
- `_maps.json` — lookup tables only. Only edit when the DB schema or enum values change.
- `<Class>/<spec>.json` — spec-specific entries (`spec_tree=0/1/2`). Only roll when the player
  selects that spec in the Roll Menu (or "Any"). Every talent affix lives in its correct spec file.
- `removedTalentAffixes` — each class file has its own removed list. The build script collects
  them all and emits `DELETE FROM talent_affix_def WHERE id IN (...)` before the INSERT.

`build_talent_affixes.ps1` reads `_maps.json` explicitly for the lookup tables, then recursively
globs every `*.json` in `talent_affixes/<Class>/`, merging all `talent_affixes` arrays. IDs must
be globally unique across all files — the script warns on duplicates.

**Per-file structure** (no maps needed — they live in `_maps.json`):
```jsonc
{
  "_comment": "Brief description of this file's scope",
  "_notes": { "confirmed_flags": { ... } },   // optional, for verified spell flag records
  "talent_affixes": [
    {"_section": "Tier 1"},
    { "id": 101, "name": "...", ... },
    {"_todo": "SomeTalent (Xr, tier N) — reason not implementable as SpellMod."}
  ],
  "removedTalentAffixes": []
}
```

Each talent should have a `_notes` (implemented) or `_todo` (not yet implementable) block
before its entry. See `talent_affixes/Rogue/assassination.json` as the reference example.

---

## Quick Checklist

- [ ] **`max_rank >= 2`** — single-rank talents are excluded by design; don't add them.
- [ ] **`id` is unique** — check all spec files across the class to find the highest ID in use,
  then add 1. The build script warns on duplicates.
- [ ] **`spec_tree`** — use `0/1/2` matching the talent's actual tree; place the entry in the
  corresponding `<spec>.json` file. There are no cross-tree entries.
- [ ] **`family_flags` matches the target** — wrong flags mean the SpellMod never fires. Verify
  with `.spellinfo all <carrier_spell>` in-game for specific-spell affixes, or use all-ones for
  broad affixes (see Pattern 2 below).
- [ ] **`carrier_spell` belongs to `spell_family`** — the server uses this to resolve the family
  internally. Use a rank-1 spell ID from `SPELLS_REFERENCE.csv`.
- [ ] **`value_per_rank` uses the right unit** — units differ per `spellmod_op`. See the
  reference table below.
- [ ] **Run `update_affixes.bat` after every change** — regenerates SQL and applies it to the DB.
  No server rebuild needed for talent data changes.

---

## Two Patterns for Talent Affixes

The most important choice when adding a talent affix is whether it affects **one specific spell**
or **all of the class's spells**. Each requires a different `family_flags` value.

---

### Pattern 1 — Specific-Spell Affixes

Use this when the talent bonus applies to a single named ability (e.g., Improved Sinister Strike
only reduces Sinister Strike's energy cost).

**How it works:** The engine matches a SpellModifier against a spell using bitwise AND between
the spell's `SpellClassOptions.SpellClassMask` and the modifier's `spellFamilyFlags`. You must
supply the exact flags that appear in the spell's DBC data.

**How to find the flags:**
1. Look up the carrier spell's rank-1 ID in `SPELLS_REFERENCE.csv`.
2. Run `.spellinfo all <rank1_id>` in-game on a GM character.
3. Copy `flags0`, `flags1`, `flags2` from the output into `family_flags: [flags0, flags1, flags2]`.

**Example — Improved Sinister Strike** (energy cost reduction):
```jsonc
{
  "id": 41, "name": "Improved Sinister Strike",
  "class": "ROGUE", "spec_tree": 1, "max_rank": 2,
  "spell_family": "ROGUE", "family_flags": [2, 0, 0],
  "carrier_spell": 1752, "carrier_name": "Sinister Strike",
  "spellmod_op": "COST", "spellmod_type": "FLAT", "value_per_rank": -3,
  "notes": "Sinister Strike energy cost -3 per rank",
  "verified": true, "verify_command": ".spellinfo all 1752"
}
```

**What works:** The SpellMod fires precisely when the player casts Sinister Strike. Two rolled
ranks reduce the cost by 6 energy. The effect is real and combat-verified.

**What doesn't appear:** The character sheet does not update its displayed energy cost. This is
a SpellModifier limitation — stat displays read base values, not applied mods. The talent tree
in the UI shows the virtual bonus in gold text via the addon (e.g., 2/2 → 4/2 in gold).

---

### Pattern 2 — Broad-Class Affixes (All-Ones Flags)

Use this when the talent bonus applies to all of the class's abilities — like a class-wide crit
chance increase or a mana cost reduction that affects every spell.

**How it works:** `SpellClassOptions.SpellClassMask & [0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF]` is
always non-zero for any spell that belongs to the class family. This means the SpellMod fires on
every cast the player makes with a spell from that family.

**When to use all-ones flags:**
- The talent's in-game description says "increases your critical strike chance" (not "with X")
- The talent reduces mana/energy cost of all abilities (not a named one)
- Any "all X spells" talent effect

**Example — Malice** (Rogue class-wide crit):
```jsonc
{
  "id": 42, "name": "Malice",
  "class": "ROGUE", "spec_tree": 0, "max_rank": 5,
  "spell_family": "ROGUE",
  "family_flags": [4294967295, 4294967295, 4294967295],
  "carrier_spell": 1752, "carrier_name": "Sinister Strike",
  "spellmod_op": "CRIT_CHANCE", "spellmod_type": "FLAT", "value_per_rank": 100,
  "notes": "All rogue ability crit +1% per rank — all-ones mask matches every Rogue family spell",
  "verified": false, "verify_command": ".spellinfo all 1752"
}
```

**What works:** The crit bonus fires on every Rogue ability cast. 3 rolled ranks of Malice
gives +3% crit on Sinister Strike, Eviscerate, Backstab, Fan of Knives, etc. You can verify
the bonus by inspecting combat logs or using the combat dummy — look for more frequent yellow
"Crit" floats.

**What doesn't appear:** The character sheet crit percentage does not increase. The server
applies the SpellMod at cast time inside the spell damage calculation, but the character sheet
reads static rating values and cannot reflect SpellModifier bonuses without a deeper engine
change. This is a known limitation.

---

## Field Reference

### `class` and `class_mask`

The JSON uses the `class` field (a string like `"ROGUE"`) which the build script maps to an
integer `class_mask` automatically. The mask is `1 << (classId - 1)`:

| `class` string | `class_mask` | Class ID |
|----------------|--------------|----------|
| `WARRIOR`      | 1            | 1        |
| `PALADIN`      | 2            | 2        |
| `HUNTER`       | 4            | 3        |
| `ROGUE`        | 8            | 4        |
| `PRIEST`       | 16           | 5        |
| `DK`           | 32           | 6        |
| `SHAMAN`       | 64           | 7        |
| `MAGE`         | 128          | 8        |
| `WARLOCK`      | 256          | 9        |
| `DRUID`        | 1024         | 11       |

### `spell_family`

Determines which class family the SpellMod operates in. Must match the class:

| `spell_family` string | Number | Class |
|-----------------------|--------|-------|
| `MAGE`                | 3      | Mage |
| `WARRIOR`             | 4      | Warrior |
| `WARLOCK`             | 5      | Warlock |
| `PRIEST`              | 6      | Priest |
| `DRUID`               | 7      | Druid |
| `ROGUE`               | 8      | Rogue |
| `HUNTER`              | 9      | Hunter |
| `PALADIN`             | 10     | Paladin |
| `SHAMAN`              | 11     | Shaman |
| `DK`                  | 15     | Death Knight |

### `spec_tree`

Controls which spec tree selector this talent is eligible under in the Roll Menu. When a player
picks a spec preference in the Roll Menu, only talent affixes matching that spec can roll.

| `spec_tree` | Meaning | File |
|-------------|---------|------|
| `0`         | Tree 0 (leftmost tab in the talent window) | `<spec>.json` |
| `1`         | Tree 1 (middle tab) | `<spec>.json` |
| `2`         | Tree 2 (rightmost tab) | `<spec>.json` |

Tree-to-spec mapping (tree 0 / tree 1 / tree 2):

| Class     | Tree 0         | Tree 1       | Tree 2      |
|-----------|----------------|--------------|-------------|
| Warrior   | Arms           | Fury         | Protection  |
| Paladin   | Holy           | Protection   | Retribution |
| Hunter    | Beast Mastery  | Marksmanship | Survival    |
| Rogue     | Assassination  | Combat       | Subtlety    |
| Priest    | Discipline     | Holy         | Shadow      |
| DK        | Blood          | Frost        | Unholy      |
| Shaman    | Elemental      | Enhancement  | Restoration |
| Mage      | Arcane         | Fire         | Frost       |
| Warlock   | Affliction     | Demonology   | Destruction |
| Druid     | Balance        | Feral Combat | Restoration |

Every talent affix belongs to a specific tree. Place class-wide bonuses (e.g., a cost reduction
that benefits all specs) in the tree that is the most natural home for the talent in WotLK — or
in the spec file most associated with that style of play. There are no cross-tree entries.

### `max_rank`

The maximum number of bonus ranks that can roll on a single item. This must match (or be lower
than) the talent's actual in-game maximum rank. Do not set it higher than the talent's real max.

The system rolls a random number of bonus ranks from 1 to `max_rank`.

### `spellmod_op` — what the modifier changes

| `spellmod_op` | Constant | Notes |
|---------------|----------|-------|
| `DAMAGE`      | 0  | Direct damage and healing amounts |
| `DURATION`    | 1  | Buff/debuff/DoT duration |
| `CRIT_CHANCE` | 7  | Critical strike chance. **FLAT only.** 100 = 1%, 200 = 2%, etc. |
| `CASTING_TIME`| 10 | Cast time in milliseconds. FLAT; negative = faster. Cannot add time to instants. |
| `COOLDOWN`    | 11 | Cooldown in milliseconds. FLAT; negative = shorter. |
| `COST`        | 14 | Resource cost. FLAT = raw internal units (see rage note below). PCT = percentage of base cost; negative = cheaper. |
| `DOT_DURATION`| 22 | Periodic damage/healing duration |

### `spellmod_type` — how the value is applied

| `spellmod_type` | Constant | Meaning |
|-----------------|----------|---------|
| `FLAT`          | 107 | Adds/subtracts raw units. For CASTING_TIME: ms. For CRIT_CHANCE: 100 = 1%. For COST: see rage/energy note below. |
| `PCT`           | 108 | Percentage modifier. 10 = +10%, -5 = -5%. For COST: percentage of base cost. |

### `value_per_rank`

The amount of modifier applied **per rolled rank**. For a 3-rank roll the total modifier is
`value_per_rank × 3`.

**Unit examples:**

| Effect | `spellmod_op` | `spellmod_type` | `value_per_rank` | Result at 3 ranks |
|--------|---------------|-----------------|------------------|-------------------|
| Cast time reduction | `CASTING_TIME` | `FLAT` | `-100` | -300 ms |
| Crit chance | `CRIT_CHANCE` | `FLAT` | `100` | +3% crit (300 total) |
| Rage cost reduction | `COST` | `FLAT` | `-10` | -3 rage (30 internal) |
| Energy cost reduction | `COST` | `FLAT` | `-3` | -3 energy (verify 10x scaling) |
| Mana cost reduction | `COST` | `PCT` | `-2` | -6% mana cost |
| Damage increase | `DAMAGE` | `PCT` | `2` | +6% damage |

> **Rage / Energy scaling for `COST FLAT`:** Rage is stored **10× internally** in AzerothCore —
> displayed "15 rage" = `ManaCost = 150` on the server. A `value_per_rank` of `-1` only reduces
> cost by 0.1 rage (invisible). Use **multiples of 10**: `-10` = -1 rage per rank, `-20` = -2 rage
> per rank, etc. Energy-costing abilities may follow the same 10× rule — verify with the
> `[COST-DBG]` technique (temporary patch to `CalcPowerCost`) before deploying energy COST FLAT
> affixes. Mana costs are **not** scaled (ManaCost = actual mana value).
| Cooldown reduction | `COOLDOWN` | `FLAT` | `-1000` | -3 s (3000 ms) |

---

## Choosing `carrier_spell`

The `carrier_spell` is used by the engine to resolve which spell family the modifier belongs to.
It does not have to be the exact spell the talent affects — it just needs to be a real spell that
belongs to the `spell_family` you declared.

1. Open `SPELLS_REFERENCE.csv`.
2. Find a spell from the correct class.
3. Use the `Rank1_ID` column value.
4. Confirm it belongs to the family: `.spellinfo all <rank1_id>` in-game — look for the
   `SpellFamilyName` line.

For broad-class affixes (Pattern 2), the carrier spell choice doesn't affect which spells the
modifier hits — it only matters that it's a valid spell from the right family.

---

## Removing an Entry

To retire a talent affix that should no longer roll on new items:

1. Move the entry from `talent_affixes` to `removedTalentAffixes` in the same file.
2. Run `update_affixes.bat` — the build script emits `DELETE FROM talent_affix_def WHERE id IN (...)`
   before the INSERT, so the row is removed from the database.
3. Leave the entry in `removedTalentAffixes` for history. The id can be safely reused in
   another entry if needed (the DELETE fires before the INSERT).

---

## Known Limitations

### Character sheet crit display — register in `AFXM_CRIT_DATA`

The addon patches the PaperDoll crit percentage display for known `CRIT_CHANCE` talent affixes.
When a new `CRIT_CHANCE` talent is added to a spec JSON, it must also be added to the
`AFXM_CRIT_DATA` table in `addon/ItemAffixes/ItemAffixes.lua`:

```lua
local AFXM_CRIT_DATA = {
    ["Malice"]                       = 100,  -- 1% per rank (100 units)
    ["Puncturing Wounds (Backstab)"] = 1000, -- 10% per rank
    -- add new entries here, matching the "name" field in the JSON exactly
}
```

The value is the `value_per_rank` from the JSON (`FLAT` units where 100 = 1% crit).
After editing, copy the file to the live client path and `/reload`.

Other stat types (DAMAGE, COST, CASTING_TIME, etc.) are applied at cast time only and have
no character sheet display — this is a known engine limitation. Only `CRIT_CHANCE` affixes
have the display patch.

### Talent tree shows bonus in gold via the addon

The addon reads talent bonus data from `item_talent_affix` and overlays a gold-colored rank
count on the talent tree button. A talent normally showing `5/5` appears as `8/5` in gold when
you have +3 bonus ranks equipped. The game engine still sees 5 points allocated; only the
display changes.

This visual update happens when the talent frame opens or the `TalentFrame_Update` event fires.
It does not change the actual talent rank stored on the character.

---

## Step-by-Step: Adding a New Talent Affix

### 1. Find the talent in-game

Note the talent name, its maximum rank, and its tree position. Confirm `max_rank >= 2`.

### 2. Decide which pattern to use

- **Specific spell** (the talent says "Improved X"): use Pattern 1 (specific flags).
- **Class-wide** (the talent says "all your X abilities" or "your critical strikes"): use Pattern 2 (all-ones flags).

### 3. Decide which file to add it to

Add to `talent_affixes/<Class>/<spec>.json` matching the talent's actual tree (`spec_tree=0/1/2`).
For class-wide talents (e.g., a flat cost reduction), pick the spec most associated with that
playstyle and add it there.

### 4. Get the family flags (Pattern 1 only)

Log in as a GM. Find the rank-1 spell ID from `SPELLS_REFERENCE.csv`. Run:
```
.spellinfo all <rank1_id>
```
Note `ClassMask0`, `ClassMask1`, `ClassMask2` from the output. These become `family_flags`.

### 5. Add the entry to the correct file

Check all existing files for the class to find the highest `id` in use, then use the next
available number. Collisions produce a warning from the build script.

```jsonc
{
  "id": <next_id>, "name": "<Talent Name>",
  "class": "<CLASS>", "spec_tree": <0|1|2>, "max_rank": <N>,
  "spell_family": "<FAMILY>",
  "family_flags": [<mask0>, <mask1>, <mask2>],
  "carrier_spell": <rank1_id>, "carrier_name": "<Spell Name>",
  "spellmod_op": "<OP>", "spellmod_type": "<FLAT|PCT>", "value_per_rank": <value>,
  "notes": "<brief description of what this does>",
  "verified": false, "verify_command": ".spellinfo all <rank1_id>"
}
```

### 6. Run `update_affixes.bat`

From the module directory:
```
update_affixes.bat
```
This regenerates `talent_affix_def.sql` and applies it to the database. Watch the output for
any errors. No server restart or rebuild is required.

### 7. Test in-game

Obtain several items of the right quality (blue or epic). Roll affixes with the spec preference
set to the relevant tree. Check that:
- The talent bonus line appears in the item tooltip (e.g., `+2 to Malice`).
- Opening the talent tree shows the bonus rank in gold.
- For specific-spell affixes: cast the spell and observe the modified behavior (shorter cast,
  lower cost, etc.) in the combat log.
- For broad affixes: compare combat log crit rate or cost with and without the item equipped.

### 8. Mark verified

After confirming the flags are correct, set `"verified": true` in the JSON entry so future
authors know this entry has been tested.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Talent affix never rolls | `max_rank < 2`, or item quality too low (green = 10%) | Verify `max_rank`, test on blue+ items |
| Talent affix rolls but has no combat effect | Wrong `family_flags` or wrong `carrier_spell` family | Run `.spellinfo all <carrier_spell>` and correct flags; or switch to all-ones for broad talents |
| Broad talent (all-ones) has no effect | Wrong `spell_family` value | Ensure `spell_family` matches the class; e.g., Rogue = 8, not 0 |
| Character sheet crit doesn't increase | Expected — SpellModifiers don't update the stat sheet | Test in combat log instead |
| Talent tree still shows base ranks | Addon not loaded or talent frame not refreshed | `/reload` after equipping, then open the talent window |
| `update_affixes.bat` shows overflow error | `family_flags` value `4294967295` cast as `[int]` in old PS1 | `build_talent_affixes.ps1` already uses `[long]` cast — ensure you have the latest version |
| Spec filter excludes this affix unexpectedly | `spec_tree` does not match the player's selected tree | Confirm the entry is in the correct spec file; educate the player to pick "Any" in the Talent Tree preference |
| Duplicate id warning from build script | Two files define the same `id` | Find the collision, remove or renumber the duplicate |
