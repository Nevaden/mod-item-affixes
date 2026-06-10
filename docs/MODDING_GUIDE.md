# mod-item-affixes — Modding Guide

This guide explains how to add new affixes, what every parameter means, and how to look up the
spell data you need.

---

## Understanding Affixes

An affix is a row in `affix_template` (world DB). It defines:

- **What gets modified** — which aspect of a spell (`spellmod_op`)
- **How it is modified** — flat value or percentage (`spellmod_type` + `spellmod_value`)
- **Which spells it affects** — a class family + a 96-bit bitmask (`spell_family` + `spell_family_flags0/1/2`)
- **Display name** — a tooltip line via a DBC entry (`enchant_id`)

When a player equips an affixed item, the server calls `Player::AddSpellMod` for each affix. The
engine then applies the modifier whenever the player casts any spell whose `SpellFamilyName` and
`SpellFamilyFlags` match the affix mask.

---

## Full Parameter Reference

### Example row (the default affix)

```sql
(1, 'Smite: Instant Cast', 100, 1, 10, 107, -10000, 6, 128, 0, 0, 585, 3884)
```

Positions: `(id, name, weight, min_quality, spellmod_op, spellmod_type, spellmod_value, spell_family, spell_family_flags0, spell_family_flags1, spell_family_flags2, carrier_spell_id, enchant_id)`

---

### `id` — INT UNSIGNED
Unique affix ID. Use any number not already in the table.

---

### `name` — VARCHAR(64)
Display name shown in server logs and used as the tooltip line in-game (when a matching DBC entry
exists). Keep it short — it appears as-is in the item tooltip.

---

### `weight` — INT UNSIGNED
Relative spawn weight. The module builds a weighted pool: a weight of 200 rolls twice as often as
100. Set to 0 to disable the affix without deleting it.

---

### `min_quality` — TINYINT UNSIGNED
Minimum item quality that can receive this affix:

| Value | Quality         |
|-------|-----------------|
| 0     | Grey (poor)     |
| 1     | White (normal)  |
| 2     | Green (uncommon)|
| 3     | Blue (rare)     |
| 4     | Purple (epic)   |
| 5     | Orange (legendary)|

Grey items are always skipped regardless of this value.

---

### `spellmod_op` — TINYINT UNSIGNED
Which aspect of the spell is modified. Values come from `SpellModOp` in `SpellDefines.h`:

| Value | Constant                    | What it modifies                |
|-------|-----------------------------|---------------------------------|
| 0     | SPELLMOD_DAMAGE             | Spell damage / healing amount   |
| 1     | SPELLMOD_DURATION           | Aura / buff duration            |
| 2     | SPELLMOD_THREAT             | Threat generated                |
| 4     | SPELLMOD_CHARGES            | Charges on the spell            |
| 5     | SPELLMOD_RANGE              | Cast range                      |
| 7     | SPELLMOD_CRITICAL_CHANCE    | Crit chance (in %)              |
| 8     | SPELLMOD_ALL_EFFECTS        | All numeric spell effects       |
| 10    | SPELLMOD_CASTING_TIME       | Cast time (flat = ms, pct = %)  |
| 11    | SPELLMOD_COOLDOWN           | Cooldown (flat = ms, pct = %)   |
| 14    | SPELLMOD_COST               | Mana / resource cost            |
| 15    | SPELLMOD_CRIT_DAMAGE_BONUS  | Crit damage bonus               |
| 22    | SPELLMOD_DOT                | Damage-over-time tick amount    |
| 27    | SPELLMOD_VALUE_MULTIPLIER   | General value multiplier        |

---

### `spellmod_type` — SMALLINT UNSIGNED

| Value | Constant       | Behaviour                                     |
|-------|----------------|-----------------------------------------------|
| 107   | SPELLMOD_FLAT  | Add `spellmod_value` directly to the stat     |
| 108   | SPELLMOD_PCT   | Multiply the stat by `(1 + spellmod_value/100)` |

---

### `spellmod_value` — INT (signed)

The amount applied by the modifier.

- **SPELLMOD_FLAT**: raw units. For cast time (`op=10`), the unit is **milliseconds**. `-10000`
  removes 10 seconds of cast time (effectively making any spell ≤10 s instant). For damage/healing
  (`op=0`), it is a flat point bonus.
- **SPELLMOD_PCT**: percentage points. `-25` means "25% faster / shorter / cheaper". Note that
  negative values reduce the stat.

---

### `spell_family` — INT UNSIGNED
Which class/family of spells this affix can modify. Values from `SpellFamilyNames` in
`SharedDefines.h`:

| Value | Constant               | Class / Type              |
|-------|------------------------|---------------------------|
| 0     | SPELLFAMILY_GENERIC    | Generic (non-class spells)|
| 3     | SPELLFAMILY_MAGE       | Mage                      |
| 4     | SPELLFAMILY_WARRIOR    | Warrior                   |
| 5     | SPELLFAMILY_WARLOCK    | Warlock                   |
| 6     | SPELLFAMILY_PRIEST     | Priest                    |
| 7     | SPELLFAMILY_DRUID      | Druid                     |
| 8     | SPELLFAMILY_ROGUE      | Rogue                     |
| 9     | SPELLFAMILY_HUNTER     | Hunter                    |
| 10    | SPELLFAMILY_PALADIN    | Paladin                   |
| 11    | SPELLFAMILY_SHAMAN     | Shaman                    |
| 15    | SPELLFAMILY_DEATHKNIGHT| Death Knight              |

---

### `spell_family_flags0`, `spell_family_flags1`, `spell_family_flags2` — INT UNSIGNED

Together these form a **96-bit bitmask** (three 32-bit words). Every spell in WoW has a unique
combination of bits within its class family. The affix applies only to spells where:

```
(spell.SpellFamilyFlags[0] & flags0) ||
(spell.SpellFamilyFlags[1] & flags1) ||
(spell.SpellFamilyFlags[2] & flags2)
```

Setting all three to `0` means "no spells" — the affix won't fire. Setting `flags0 = 0xFFFFFFFF`
and the others to `0xFFFFFFFF` would match **all** spells in the family (useful for wide buffs like
"all Paladin spells deal 5% more damage").

To target a specific spell, set only the bit(s) for that spell and leave the rest at 0.

---

### `carrier_spell_id` — INT UNSIGNED
The **Rank 1** spell ID from which the server resolves `SpellFamilyName`. The `IsAffectedBySpellMod`
check looks at the carrier spell's `SpellFamilyName` to confirm the family matches. Always use the
lowest rank (Rank 1) of the target spell here.

---

### `enchant_id` — INT UNSIGNED
The `SpellItemEnchantment.dbc` entry ID used to display the affix name as a green line in the item
tooltip. Set to `0` to disable tooltip display (the SpellMod still works).

To add a tooltip, you need a custom DBC entry — see the **Tooltip Setup** section below.

---

## Finding SpellFamilyFlags for a Spell

The `SpellFamilyName` and `SpellFamilyFlags` values are stored in the binary `Spell.dbc` client
file. The easiest way to look them up on a running server is the built-in GM command:

```
.spellinfo all <spellId>
```

Example output for Smite (ID 585):
```
SpellFamilyName: 6 (Priest)
SpellFamilyFlags: 0x00000080 0x00000000 0x00000000
```

This tells you: `spell_family=6`, `spell_family_flags0=128` (0x80), flags1 and flags2 both 0.

> **Tip**: Always use the **Rank 1** spell ID for the lookup — higher ranks share the same family
> flags but it is clearest to verify with Rank 1.

### Quick reference for common spells

| Spell                     | Class   | family | flags0     | flags1 | flags2 | Rank 1 ID |
|---------------------------|---------|--------|------------|--------|--------|-----------|
| Smite                     | Priest  | 6      | 128 (0x80) | 0      | 0      | 585       |
| Power Word: Shield        | Priest  | 6      | 1          | 0      | 0      | 17        |
| Renew                     | Priest  | 6      | 64         | 0      | 0      | 139       |
| Flash Heal                | Priest  | 6      | 524288     | 0      | 0      | 2061      |
| Shadow Word: Pain         | Priest  | 6      | 32768      | 0      | 0      | 589       |
| Mind Flay                 | Priest  | 6      | 16777216   | 0      | 0      | 15407     |
| Holy Fire                 | Priest  | 6      | 2097152    | 0      | 0      | 14914     |
| Fireball                  | Mage    | 3      | 1          | 0      | 0      | 133       |
| Frostbolt                 | Mage    | 3      | 32         | 0      | 0      | 116       |
| Arcane Missiles           | Mage    | 3      | 2048       | 0      | 0      | 5143      |
| Corruption                | Warlock | 5      | 2          | 0      | 0      | 172       |
| Shadow Bolt               | Warlock | 5      | 16         | 0      | 0      | 686       |
| Immolate                  | Warlock | 5      | 4          | 0      | 0      | 348       |
| Moonfire                  | Druid   | 7      | 4          | 0      | 0      | 8921      |
| Wrath                     | Druid   | 7      | 1          | 0      | 0      | 5176      |
| Rejuvenation              | Druid   | 7      | 16         | 0      | 0      | 774       |
| Seal of Righteousness     | Paladin | 10     | 8388608    | 0      | 0      | 20154     |
| Holy Light                | Paladin | 10     | 262144     | 0      | 0      | 635       |
| Flash of Light            | Paladin | 10     | 524288     | 0      | 0      | 19750     |
| Steady Shot               | Hunter  | 9      | 2          | 0      | 0      | 56641     |
| Serpent Sting             | Hunter  | 9      | 16384      | 0      | 0      | 1978      |
| Sinister Strike           | Rogue   | 8      | 2          | 0      | 0      | 1752      |
| Backstab                  | Rogue   | 8      | 1          | 0      | 0      | 53        |
| Chain Lightning           | Shaman  | 11     | 1          | 0      | 0      | 421       |
| Healing Wave              | Shaman  | 11     | 2          | 0      | 0      | 331       |
| Icy Touch                 | DK      | 15     | 2          | 0      | 0      | 45477     |
| Death Coil                | DK      | 15     | 131072     | 0      | 0      | 47541     |

> **These values should be verified** using `.spellinfo all <id>` on your server before deploying —
> some values may differ across AzerothCore versions or if spell data is patched.

---

## Example: Adding a New Affix

### Goal: Fireball deals 10% more damage (Mage, all ranks)

**Step 1** — Look up Fireball Rank 1 in-game:
```
.spellinfo all 133
```
Expected output (in chat): `SpellFamilyName: 3 (Mage)`, `SpellFamilyFlags: 0x00000001 0x00000000 0x00000000`

**Step 2** — Choose a DBC enchant ID for the tooltip (see Tooltip Setup below), or use 0 to skip.

**Step 3** — Add to `affix_template`:
```sql
INSERT INTO affix_template
    (id, name, weight, min_quality, spellmod_op, spellmod_type, spellmod_value,
     spell_family, spell_family_flags0, spell_family_flags1, spell_family_flags2,
     carrier_spell_id, enchant_id)
VALUES
    (2, 'Fireball: +10% Damage', 80, 2, 0, 108, 10,
     3, 1, 0, 0,
     133, 0);
```

**Step 4** — Run `update_affixes.bat` and restart worldserver.

**Step 5** — Test: loot a green+ item on a Mage, equip it, cast Fireball — damage should be 10% higher.

---

### Goal: All Paladin spells cast 5% faster (wide family buff)

To affect all Paladin spells, set all three flag words to `0xFFFFFFFF`. Pick any Paladin Rank 1
spell as the carrier (e.g. Flash of Light = 19750).

```sql
INSERT INTO affix_template
    (id, name, weight, min_quality, spellmod_op, spellmod_type, spellmod_value,
     spell_family, spell_family_flags0, spell_family_flags1, spell_family_flags2,
     carrier_spell_id, enchant_id)
VALUES
    (3, 'Paladin: +5% Cast Speed', 60, 3, 10, 108, -5,
     10, 4294967295, 4294967295, 4294967295,
     19750, 0);
```

Note: `4294967295` is `0xFFFFFFFF` as an unsigned 32-bit integer.

---

## Tooltip Setup

In-game tooltip lines come from `SpellItemEnchantment.dbc`. To add a new tooltip for an affix:

### What you need
- `enchant_id` — a DBC row ID not used by the game (3884+ is safe for custom entries)
- The patching tools in `C:\Users\aaron\AppData\Local\Temp\mpqbuild.exe`
- A modified `SpellItemEnchantment.dbc` with your new row appended

### DBC entry requirements
The DBC row must have:
- All three `Effect` fields set to type `NONE` (0) — no game-side enchantment effects
- `Name_Lang_enUS` = your affix display name (max ~100 chars)
- All other stat fields at 0

Setting any Effect type other than NONE will double-apply stat changes (the SpellMod already handles
the gameplay effect — the DBC is display-only).

### Rebuild the client patch
1. Modify `SpellItemEnchantment.dbc` (use a DBC editor or write a parser)
2. Run `mpqbuild.exe build <dbc_file> <output_patch-4.MPQ> <output_patch-enUS-4.MPQ>`
3. Copy both MPQ files to the client `Data/` and `Data/enUS/` folders
4. Update `enchant_id` in `affix_template` and run `update_affixes.bat`

---

## The Recommended Workflow: affixes.json

All affixes are defined in a single file: `affixes.json`. This is the source of truth.
The SQL file is auto-generated from it. Do not edit `affix_template.sql` by hand.

### Adding a new affix

1. Open `affixes.json` and add a new object to the `"affixes"` array.
2. Use the `_comment` fields as a guide for every parameter.
3. Look up the spell flags with `.spellinfo all <rank1_id>` (GM command, server must be running).
   Or check `SPELLS_REFERENCE.md` for pre-compiled values.
4. Run `build_affixes.ps1` (PowerShell) — this regenerates `affix_template.sql`.
5. Run `update_affixes.bat` — this applies the SQL to the database.
6. Restart worldserver.
7. Loot/buy a qualifying item and equip it to test.

### For the tooltip line
Set `"enchant_id"` to a new DBC entry ID (3886, 3887, etc.). Then run the DBC patcher:
```
PowerShell: .\patch_dbc.ps1  (or manually rebuild the MPQ — see Tooltip Setup section)
```
Copy the rebuilt `patch-4.MPQ` and `patch-enUS-4.MPQ` to your WoW client `Data/` folder.

### Reloading without rebuilding worldserver

`update_affixes.bat` re-runs the SQL. Restart worldserver after. No recompile needed.
