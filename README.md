# mod-item-affixes

ARPG-style random affix system for AzerothCore (WoTLK 3.3.5a). Items receive affix slots when
they enter a player's inventory. Affixes are chosen by the player through an in-game Roll Menu
and persist as `SpellModifier` objects (or generic stat bonuses) that survive bank, mail, and
trade.

---

## What it looks like

Every item — from a level 16 dagger to a level 80 epic ring — gets its own set of affixes chosen by the player.

| Level 80 Ret Paladin — ring | Level 18 Mage — staff | Level 16 Rogue — dagger |
|---|---|---|
| ![Signet of Hopeful Light with affixes](screenshots/example1.png) | ![Emberstone Staff with affixes](screenshots/example2.png) | ![Buzzer Blade with affixes](screenshots/example3.png) |
| Stat affixes (+Crit, +Hit) and two talent bonuses to Sacred Duty and Guardian's Favor. | Spell Power stacking and talent ranks in Arctic Reach and Chilled to the Bone — at level 18. | Class skill modifiers on Backstab, plus an Imprint (Vanishing Backstab) showing 2 Return Allowances. |

Affixes scale with item level, so they feel meaningful at every stage of the game without overshadowing base item stats.

---

## How It Works

1. **Acquisition** — when an item enters a player's bags (loot, quest reward, purchase, craft),
   the module assigns 1–3 unrolled affix slots based on item quality and records them in
   `item_affix` (characters DB). Nothing is rolled yet; the item has no class fingerprint at
   this point and can be freely traded.

2. **Roll Menu** — when the player Alt+Clicks an item that has unrolled slots, a preference page
   appears. The player can steer the roll before committing:
   - **What to roll?** — Any / Stats / Class Skills
   - **Talent Tree:** — which spec's passive talent bonus can roll (Any or a specific spec)
   - **Stat family?** — Any / Tank / Physical / Caster / Healer / Ranged *(hidden when Class Skills selected)*
   - **Main stat?** — Any / Strength / Agility / Intellect / Spirit *(hidden when Class Skills selected)*

3. **Rolling** — clicking "Roll Affix" sends preferences to the server. The server presents 1–3
   affix options depending on item quality. The player picks one; it is saved as APPLIED.

4. **Talent affix** — each slot roll also attempts to roll a passive talent bonus (10% chance on
   green items, 50% on blue/epic). Talent affixes stack per slot, so a fully-rolled epic can
   hold up to 3 talent affixes. The Talent Tree preference controls which spec tree the talent
   draws from.

5. **Equip** — `SpellModifier` objects and stat bonuses are applied to the player via
   `Player::AddSpellMod` / `ApplyGenericStat`.

6. **Unequip** — all mods are removed and freed.

7. **Login** — mods are reapplied for all currently equipped affixed items.

---

## Affix Slots by Quality

| Quality       | Regular affix slots  | Options shown per roll | Talent chance per slot |
|---------------|----------------------|------------------------|------------------------|
| Grey (poor)   | 0 — skipped          | —                      | —                      |
| White / Green | 1                    | 1                      | 10%                    |
| Blue (rare)   | 2                    | 2                      | 50%                    |
| Purple (epic) | 3                    | 3                      | 50%                    |

Two-handed weapons receive 1 additional slot above the quality baseline (configurable via `_twoHanderBonusSlots`).

Green items can only roll universal stat affixes (Stamina, Crit, Haste, Hit, etc.). Role-specific
stats (Spell Power, Attack Power, Expertise, Dodge/Defense/Parry) require blue quality or higher.

---

## Stat Value System

Generic stat affix values (Strength, Stamina, Spell Power, etc.) are computed at roll-time from
the item's WotLK stat budget — no hardcoded value tables.

### Budget formula

```
baseBudget  = f(ItemLevel)          # piecewise linear by era (see below)
slotBudget  = baseBudget × slotMod  # 100% / 74% / 54% by slot type
affixBudget = slotBudget × qualityFraction × StatMultiplier
statValue   = irand( floor(affixBudget × BudgetMinRoll / cost),
                     floor(affixBudget / cost) )
```

**Era breakpoints** (using item gear score, not required level):

| Era       | iLvl range | Formula                   | Example iLvl 200 |
|-----------|-----------|---------------------------|-----------------|
| Vanilla   | 1 – 66    | `iLvl × 0.78 + 1.5`      | —               |
| TBC       | 67 – 114  | `iLvl × 1.25 − 28.5`     | —               |
| WotLK     | 115 – 284 | `iLvl × 1.92 − 105`      | 279 pts         |

**Slot multipliers:**

| Multiplier | Slots                                   |
|------------|-----------------------------------------|
| 100%       | Head, Chest, Legs, 2H Weapons, Ranged   |
| 74%        | Shoulders, Hands, Waist, Feet           |
| 54%        | Neck, Cloak, Wrists, Rings, Trinkets, 1H Weapons, Off-hands, Wands |

**Stat exchange rates** (WotLK itemization):

| Stat            | Cost per point | Effect                          |
|-----------------|---------------|---------------------------------|
| Attack Power    | 0.5           | You get 2× the budget in AP     |
| Spell Power     | 0.86          | Slightly more SP than primaries |
| Everything else | 1.0           | 1 budget point = 1 stat point   |

**Example** — iLvl 251 2H weapon, Epic (purple), `StatMultiplier = 1.0`:
- Base budget: `251 × 1.92 − 105 = 377.9`
- Slot (2H = 100%): `377.9`
- Quality fraction (purple = 10%): `37.8`
- Strength roll: `irand(28, 37)` — varies each roll within a fixed window
- Attack Power roll: `irand(56, 75)`
- Spell Power roll: `irand(32, 43)`

---

## Imprint System

Imprints are rare, class-specific enchantments that sit alongside an item's regular affixes. Only
one Imprint can ever be on an item at a time. Imprints are more powerful than stat affixes and
may trigger custom server-side effects (see `src/Imprints/` for implementations).

### Acquiring an Imprint

- **Roll Menu** — when an Imprint option appears during a roll (chance configured by
  `ItemAffixes.ImprintRollChance`), selecting it applies the Imprint to the item. The affix slot
  is **refunded** — Imprints do not consume a regular affix slot.
- **GM command** — `.imprint grant <name>` grants a Rune directly to the player's bags for
  testing. `.imprint apply` applies the Rune from the player's bags to a targeted item.

### Rune apply mechanic (in-game)

An Imprint can be re-applied to a new item using its Rune item:

1. **Right-click the Rune** in your bags — the cursor displays the Rune icon and a message
   prompts you to left-click the target item.
2. **Left-click the target item** — the Imprint is applied. If the item already has an Imprint,
   an error is shown instead.
3. **Right-click anywhere** (or click empty bag space) — cancels apply mode.

The Rune apply mode shows a full-screen click interceptor so the target item is never
accidentally picked up or equipped during the interaction.

### Return Allowances

Each Rune tracks how many times it can be re-applied after disenchanting an imprinted item
(**Return Allowances**). The count is shown in the tooltip as `(N remaining)` in purple, or
`(0 remaining — no rune on disenchant)` in red when the count is zero. Disenchanting an item
with an Imprint whose allowance is 0 does **not** grant a Rune.

### Disenchanting

Disenchanting an imprinted item grants a Rune into the player's bags (if allowances remain) and
removes the Imprint from the item. The returned Rune's allowance count is decremented by one.

---

## Prerequisites

- AzerothCore WOTLK 3.3.5a (standard build)
- CMake, MSVC (or GCC/Clang), MySQL 8.x
- GM account with `SEC_GAMEMASTER` access (for testing)

---

## Installation

### Step 1 — Place the module

```
modules/
└── mod-item-affixes/
```

### Step 2 — Apply the required core patch

This module creates `SpellModifier` objects without an owning aura (`ownerAura = nullptr`). The
stock engine crashes when these are applied mid-cast. Add one null-guard in
`src/server/game/Entities/Player/Player.cpp` inside `Player::ApplyModToSpell`:

```cpp
void Player::ApplyModToSpell(SpellModifier* mod, Spell* spell)
{
    if (!spell)
        return;

    // ownerAura is null for item-affix mods — skip charge logic for those
    if (mod->ownerAura && mod->ownerAura->IsUsingCharges() && !mod->ownerAura->GetCharges())
        return;

    if (mod->ownerAura)
        spell->m_appliedMods.insert(mod->ownerAura);
}
```

Run `apply_core_patches.ps1` to apply all required patches automatically, or see
`docs/CORE_PATCHES.md` for manual instructions.

### Step 3 — Build

Run `Rebuild-Server.bat` from the AzerothCore root, or manually:

```powershell
cmake --build "path\to\build" --config RelWithDebInfo --target worldserver
cmake --build "path\to\build" --config RelWithDebInfo --target INSTALL
```

Stop the worldserver before the INSTALL step (the binary will be locked).

### Step 4 — Run the SQL files

**Characters database** — creates `item_affix`, `item_talent_affix`, and `item_imprint`:

```powershell
Get-Content data\sql\db-characters\item_affix.sql |
    & mysql.exe -u acore -pPASSWORD acore_characters
Get-Content data\sql\db-characters\item_talent_affix.sql |
    & mysql.exe -u acore -pPASSWORD acore_characters
Get-Content data\sql\db-characters\item_imprint.sql |
    & mysql.exe -u acore -pPASSWORD acore_characters
```

**World database** — generates and applies affix/talent/imprint template data:

```powershell
.\build_affixes.ps1
.\build_talent_affixes.ps1
Get-Content data\sql\db-world\affix_template.sql |
    & mysql.exe -u acore -pPASSWORD acore_world
Get-Content data\sql\db-world\talent_affix_def.sql |
    & mysql.exe -u acore -pPASSWORD acore_world
Get-Content data\sql\db-world\imprint_def.sql |
    & mysql.exe -u acore -pPASSWORD acore_world
```

Or run `update_affixes.bat` which handles the affix and talent SQL automatically.

### Step 5 — Install the client addon

The canonical addon source lives in `addon\ItemAffixes\` inside the module. Copy it to the live
client path (or symlink the folder):

```
WoW Client 3.3.5a\Interface\AddOns\ItemAffixes\
```

The addon handles the Roll Menu UI, tooltip affix display, the Rune apply mechanic, and all
client↔server communication.

### Step 6 — (Optional) Install the client DBC patch

Affix names appear in item tooltips via `SpellItemEnchantment.dbc`. The patched DBC is
pre-built via the tools in `tools/`.

```
WoW Client 3.3.5a\Data\patch-4.MPQ
WoW Client 3.3.5a\Data\enUS\patch-enUS-4.MPQ
```

Without the patch, affixes function correctly but no green tooltip line appears.

### Step 7 — Start worldserver

Look for this in the console:

```
mod-item-affixes: loaded N affix template(s).
mod-item-affixes: loaded N talent affix def(s).
mod-item-affixes: loaded N imprint def(s).
```

---

## Multiplayer Affix Visibility

### Inspecting other players

When you open another player's inspect window and hover over their equipped items, the addon
shows their affix lines in the tooltip — applied affixes in blue, talent bonuses in gold,
imprints in purple. Items not yet rolled show a grey `[Affix slot not yet rolled]` placeholder.

Shift+hovering an inspected item shows a comparison tooltip of your own equipped item in the
same slot, with your affixes included.

### Trade window

Hovering items in the trade window — both your items and the partner's — shows their affix
state. Shift+hover shows a comparison tooltip against your currently equipped item.

### Auction house

Hovering any item in the Auction House shows its affix state:

- **Applied affixes** — blue, identical to the item owner's tooltip view.
- **Talent bonuses** — gold.
- **Imprints** — purple, with Return Allowance count.
- **Unrolled slots** — `[Affix slot not yet rolled]` in grey.

AH lookups are read-only. Shift+hover shows a comparison tooltip against your equipped item.

Items that have no affixes cached yet show `[Fetching affixes...]` briefly while the server
responds; this resolves automatically without needing to re-hover.

When multiple copies of the same item are listed at the same price by the same seller, each
listing correctly shows its own unique affixes. The addon assigns a per-listing offset so the
server returns the correct physical item instance for each slot.

---

## Screenshots

### Alt+Click to open the Roll Menu
![Alt+Click to roll affix](screenshots/Alt+click%20to%20roll%20affix.png)

The Roll Menu appears when a player Alt+Clicks any item with unrolled affix slots.

### Roll preferences
![Affix roll options menu](screenshots/affix%20roll%20options%20menu.png)

Players can steer the roll before committing — stat family, spec tree, main stat, and type (stats vs. class skills).

### Green item — one choice, one roll
![Green item one choice, one roll](screenshots/green%20item%20one%20choice%2C%20one%20roll.png)

Green items present one option with one roll. The cheapest entry point into the affix system.

### Blue item — two choices, two rolls
![Blue item - two choices - two rolls](screenshots/Blue%20item%20-%20two%20choices%20-%20two%20rolls.png)

Blue items present two options per roll, giving the player a meaningful decision.

### Purple item — three options, three choices
![Purple item - 3 options - 3 choices](screenshots/Purple%20item%20-%203%20options%20-%203%20choices.png)

Epic items present three options per roll — the highest variance and the highest ceiling.

### Class skills roll
![Class skill selected on what to roll menu](screenshots/class%20skill%20selected%20on%20what%20to%20roll%20menu.png)
![Class skills options](screenshots/class%20skills%20options.png)

When "Class Skills" is selected, the server presents spell modifier options for the player's class and the talent tree chosen in the Roll Menu. A class skill only appears as an option if the character has already learned that ability — you will never roll a modifier for a spell you don't know.

### Imprint option
![Imprint option - Eternal Elemental](screenshots/imprint%20option%20-%20eternal%20elemental.png)

Imprint options appear in the roll menu alongside stat and class skill choices. Selecting one applies the Imprint and refunds the affix slot. Imprints display their Return Allowance count in the tooltip so players know whether disenchanting will yield a Rune.

---

## Verifying It Works

1. Log in as a GM character.
2. Loot or purchase any green-quality or better item.
3. Alt+Click the item — the Roll Menu frame should appear.
4. Select preferences (or leave at defaults) and click "Roll Affix."
5. Choose one of the presented options.
6. Equip the item — the tooltip shows the applied affix and any talent bonus.
7. If the affix is a spellmod, cast the affected spell and confirm the modifier applies.

**Testing Imprints:**
1. `.imprint grant <name>` — grants a Rune to your bags.
2. Right-click the Rune — cursor indicator appears and apply mode activates.
3. Left-click a target item — Imprint is applied; Rune is consumed.
4. Disenchant the imprinted item — a Rune is returned (if allowances remain).

---

## Server Configuration

Edit `bin/configs/modules/mod_item_affixes.conf` (created from `conf/mod_item_affixes.conf.dist`):

```ini
# Roll Menu UI toggles (0=off, 1=on)
ItemAffixes.EnableClassSkillAffixes = 1   # "Stats vs Class Skills" section
ItemAffixes.EnableTalentAffixes     = 1   # Talent Tree section
ItemAffixes.EnableRoleSelection     = 1   # Stat Family section
ItemAffixes.EnableMainStatSelection = 1   # Main Stat section

# Extra affix slots granted to two-handed weapons (default: 1)
ItemAffixes.TwoHanderBonusSlots = 1

# Budget fractions — share of item budget allocated per affix roll
ItemAffixes.BudgetFractionGreen  = 0.18  # green (1 affix)
ItemAffixes.BudgetFractionBlue   = 0.13  # blue  (2 affixes)
ItemAffixes.BudgetFractionPurple = 0.10  # epic  (3 affixes)

# Variance floor: 0.75 = rolls land between 75%–100% of max computed value
# 1.0 = always max (no variance); 0.0 = anywhere from 1 to max
ItemAffixes.BudgetMinRoll = 0.75

# Global stat multiplier: 1.0 = WotLK-accurate, 1.5 = power fantasy, 2.0 = high-power server
# Does not affect SpellMod affixes (class skill bonuses).
ItemAffixes.StatMultiplier = 1.0

# Crit rolls — a lucky bonus that inflates a rolled value by 50%
# Shown in the pick menu with a gold "!" prefix
ItemAffixes.EnableCritRolls = 1    # 0 = crits never occur
ItemAffixes.CritRollChance  = 10   # % chance per option (0–100); default 10

# Imprint roll chance — % chance one option is replaced by an Imprint
ItemAffixes.ImprintRollChance = 30

# How many times an Imprint can be extracted and re-applied (Return Allowances)
ItemAffixes.ImprintExtractionCount = 2
```

---

## Adding New Affixes

### Stat affixes (generic)

Edit `affixes/generics_defs.json`. Each entry defines metadata — which stat, which slots, which
role family, minimum quality required. **No value ranges are needed** — values are computed at
runtime from the WotLK item budget formula.

Key fields:
- `stat.op` — maps to `GenericStatOp` enum (0=Stamina, 1=Strength, 2=Agility … see `ItemAffix.h`)
- `role` — `"PHYSICAL"`, `"CASTER"`, `"HEALER"`, `"TANK"`, `"RANGED"`, `"CASTER_HEALER"`, `"PHYSICAL_RANGED"`, or omit for universal
- `item_category` — `0`=any, `1`=1H weapon, `2`=2H weapon, `4`=armor, `5`=jewelry, `6`=wand, `7`=boots, `8`=dagger
- `min_quality` — `1`=green+, `2`=blue+, `3`=epic+

After editing, run `build_affixes.ps1` (or `update_affixes.bat`) to regenerate and apply SQL.

### SpellMod affixes (class-specific)

Edit the appropriate `class_affixes/[class].json`. Key fields: `spell_family`, `family_flags[3]`,
`carrier_spell`, `spellmod_op`, `spellmod_type`, `spellmod_value`.

Use `SPELLS_REFERENCE.csv` to look up spell IDs and family flags.

### Talent affixes

Edit the appropriate `talent_affixes/<Class>/<spec>.json` (spec-specific, `spec_tree=0/1/2`).
Only add talents with `max_rank >= 2` (single-rank talents are excluded by design).

### Imprints

See `docs/ADDING_NEW_IMPRINT.md` for a full walkthrough. The short version:

1. Add a row to `data/sql/db-world/imprint_def.sql` (id, name, runeItemId, extractionsMax, classMask, specTree).
2. Add an enum entry to `ImprintId` in `src/Imprints/ImprintMgr.h`.
3. Create `src/Imprints/<Class>/<ImprintName>.cpp` implementing `ImprintEffect`.
4. Register the handler in `src/mod_item_affixes_loader.cpp`.
5. Rebuild and run the updated SQL.

After any JSON edits: **run `update_affixes.bat`** from the module folder.

---

## Enabling / Disabling the Module

- **`enable.bat`** — re-enables, rebuilds, and installs.
- **`disable.bat`** — excludes from build, rebuilds, and installs.

Items affixed before disabling keep their `item_affix` rows; no mods are applied while the
module is disabled. Re-enabling fully restores all functionality.

---

## Directory Structure

```
mod-item-affixes/
├── README.md
├── build_affixes.ps1        ← generates affix_template.sql from affixes/*.json
├── build_talent_affixes.ps1 ← generates talent_affix_def.sql from talent_affixes/<Class>/*.json
├── update_affixes.bat       ← runs both build scripts and applies SQL to DB
├── apply_core_patches.ps1   ← applies required engine patches
│
├── affixes/
│   └── generics_defs.json   ← stat affix definitions (metadata only — no value ranges)
│
├── class_affixes/
│   └── [class].json         ← spellmod affixes per class (mage.json, rogue.json, etc.)
│
├── talent_affixes/
│   ├── _maps.json           ← lookup maps for build script (enum → integer)
│   └── <Class>/
│       └── <spec>.json      ← per-spec talent entries (spec_tree=0/1/2)
│
├── imprints/
│   └── custom_spells.json   ← spell definitions used by Imprint effects
│
├── src/
│   ├── ItemAffix.h
│   ├── ItemAffix.cpp
│   ├── ItemAffixScripts.cpp
│   ├── ItemAffixCommands.cpp
│   ├── mod_item_affixes_loader.cpp
│   └── Imprints/
│       ├── ImprintMgr.h
│       ├── ImprintMgr.cpp
│       ├── ImprintCommands.cpp
│       └── <Class>/
│           └── <ImprintName>.cpp
│
├── addon/
│   └── ItemAffixes/
│       ├── ItemAffixes.lua       ← main addon logic
│       ├── ItemAffixRollUI.lua   ← roll menu UI
│       └── ItemAffixRollUI.xml   ← roll menu frame definition
│
├── conf/
│   └── mod_item_affixes.conf.dist
│
├── docs/
│   ├── ADDING_AFFIXES.md
│   ├── ADDING_NEW_IMPRINT.md
│   ├── ADDING_TALENT_AFFIXES.md
│   ├── CORE_PATCHES.md
│   └── ...
│
└── data/sql/
    ├── db-characters/
    │   ├── item_affix.sql          ← run on acore_characters
    │   ├── item_talent_affix.sql   ← run on acore_characters
    │   └── item_imprint.sql        ← run on acore_characters
    └── db-world/
        ├── imprint_def.sql         ← run on acore_world
        ├── affix_template.sql      ← generated — do not edit directly
        └── talent_affix_def.sql    ← generated — do not edit directly
```

---

## Database Tables

### `item_affix` (characters DB)
One row per affix slot per item.

| Column          | Type    | Description                                          |
|-----------------|---------|------------------------------------------------------|
| `item_guid`     | BIGINT  | Raw GUID of the item                                 |
| `affix_slot`    | TINYINT | Slot index (0, 1, 2)                                 |
| `roll_state`    | TINYINT | 0=UNROLLED, 1=PENDING (player choosing), 2=APPLIED   |
| `affix_id`      | INT     | ID from `affix_template`; 0 while UNROLLED/PENDING   |
| `rolled_value`  | INT     | Stat value rolled (stat affixes); 0 for spellmods    |
| `pending_opts`  | VARCHAR | Serialised options while PENDING: `"id:val,id:val"`  |

### `item_talent_affix` (characters DB)
One row per affix slot per item that successfully rolled a talent bonus.

| Column          | Type    | Description                                          |
|-----------------|---------|------------------------------------------------------|
| `item_guid`     | BIGINT  | Raw GUID of the item                                 |
| `affix_slot`    | TINYINT | Which regular affix slot triggered this talent roll  |
| `affix_id`      | INT     | ID from `talent_affix_def`                           |
| `rolled_value`  | INT     | Bonus ranks rolled (1 .. maxRank)                    |

### `item_imprint` (characters DB)
One row per imprinted item or Rune.

| Column              | Type    | Description                                              |
|---------------------|---------|----------------------------------------------------------|
| `item_guid`         | BIGINT  | Raw GUID of the imprinted item or Rune                   |
| `imprint_id`        | INT     | ID from `imprint_def`                                    |
| `extractions_left`  | INT     | Return Allowances remaining (0 = no Rune on disenchant)  |

### `affix_template` (world DB) — generated, do not edit directly

| Column          | Description                                                              |
|-----------------|--------------------------------------------------------------------------|
| `id`            | Unique affix ID                                                          |
| `name`          | Internal name (logging / tooltip)                                        |
| `weight`        | Roll pool weight; 0 = disabled                                           |
| `min_quality`   | Minimum item quality: 1=green+, 2=blue+, 3=epic+                        |
| `affix_type`    | 0=SPELLMOD, 1=STAT                                                       |
| `stat_op`       | GenericStatOp enum value (STAT affixes only; 0 for SPELLMOD)             |
| `spell_family`  | SpellFamilyName (0=generic; 8=Rogue; 3=Mage; etc.)                      |
| `spec_tree`     | 255=any spec; 0/1/2=specific talent tree (spellmod affixes only)         |
| `role_mask`     | AffixRoleGroup bitmask: 0=any, 1=CASTER, 2=PHYSICAL, 4=TANK, 8=HEALER, 16=RANGED |
| `item_category` | 0=any item; 1=1H weapon; 2=2H weapon; 4=armor; 8=dagger-or-non-weapon   |
| `carrier_spell` | Rank-1 spell ID; used for `IsAffectedBySpellMod` resolution              |
| `enchant_id`    | `SpellItemEnchantment.dbc` ID for the green tooltip line (0=none)        |

See `docs/ADDING_AFFIXES.md` for a full authoring guide.
