# Talent Affix File — Development Process

## Goal

Write each spec file with **correct `family_flags` from the first pass**.
Never guess flags — always verify with `.spellinfo all <id>` before finalising.

---

## Step 1 — Plan the file

For each talent tree identify:
- **Implementable** multi-rank (≥2) talents: damage/healing/cost/crit/cooldown/duration
  modifiers that fire on a castable spell.
- **NOT implementable**: single-rank talents, proc-based effects, passive stat conversions,
  resist/pushback/immunity mechanics, aura effects with no SpellMod op.

---

## Step 2 — Create the file with placeholders

Write the JSON file with:
- `"family_flags": [0, 0, 0]` for specific-spell entries not yet verified.
- `"verified": false` on every placeholder entry.
- `"family_flags": [4294967295, 4294967295, 4294967295]` + `"verified": true` for all-ones
  entries (match every spell in the family — no spellinfo needed).
- A `"_spellinfo_queue"` array in `_notes` listing every `.spellinfo all <id>` command needed,
  with `"SpellFamilyFlags": "FILL IN"` for the user to populate.

---

## Step 3 — User runs all spellinfo commands

User copies every command from `_spellinfo_queue` into the in-game chat and fills the
`"SpellFamilyFlags"` hex strings back into the array entry in the file.

Typical `.spellinfo all <id>` output line to read:
```
SpellFamilyFlags: 0xXXXXXXXX 0xXXXXXXXX 0xXXXXXXXX
```
Those three words are `mask0`, `mask1`, `mask2` in hex.

---

## Step 4 — Compute and apply flags

With all results filled in:
1. Convert each hex word to decimal: `mask0 = 0x???????? = N`.
2. Identify and **exclude** any shared bits (see table below) from specific-spell masks.
3. For multi-spell entries, bitwise-OR the unique bits per mask slot.
4. Update `family_flags`, `notes`, and `verified: true` for each entry.
5. Remove the `_spellinfo_queue` or leave it as documentation — either is fine.

---

## Step 5 — Run update_affixes.bat

After all flags are confirmed:
```
cd "e:\servers\Wow\azerothcore-standard\modules\mod-item-affixes"
.\update_affixes.bat
```
No server restart needed — `.reload all` in-game reloads talent defs, or restart worldserver.

---

## Shared-bit rules by class

| Class   | Shared bit / value                     | Rule                                                  |
|---------|----------------------------------------|-------------------------------------------------------|
| Priest  | mask2 bit10 = 0x400 = **1024**         | ALWAYS exclude — on PW:Shield, Inner Fire, Fortitude, |
|         |                                        | Holy Fire, Renew, Mending, Cure/Abolish Disease,      |
|         |                                        | Pain Suppression, Power Infusion, Mind Flay           |
| Priest  | mask1 bit12 = 0x1000 = **4096**        | Shared by Fade, Pain Suppression, Power Infusion      |
| Priest  | mask0 bit31 = 0x80000000 = **2147483648** | Shared by Shadowform, Pain Suppression, Power Infusion |
| Rogue   | bit23 = 0x800000 = **8388608** (any mask) | ALWAYS exclude — on Sinister Strike, Backstab,       |
|         |                                        | Eviscerate, Ambush, Hemorrhage                        |
| Paladin | TBD after first spellinfo run          | Fill in here once shared bits are identified          |

---

## Notation

| Value | Meaning |
|-------|---------|
| `[0, 0, 0]` | Placeholder — not yet filled |
| `[4294967295, 4294967295, 4294967295]` | All-ones — matches every spell in the family |
| `mask0` | SpellFamilyFlags word 0 (first hex group in .spellinfo output) |
| `mask1` | Word 1 (second hex group) |
| `mask2` | Word 2 (third hex group) |

---

## SpellMod value units (quick reference)

| spellmod_op      | spellmod_type | Unit / example                        |
|------------------|---------------|---------------------------------------|
| CASTING_TIME     | FLAT          | milliseconds; -100 = -100 ms          |
| COOLDOWN         | FLAT          | milliseconds; -60000 = -60 s          |
| DURATION         | FLAT          | milliseconds; +3000 = +3 s            |
| COST             | PCT           | percent; -5 = -5%                     |
| COST             | FLAT          | resource units (rage/mana points)     |
| DAMAGE           | PCT           | percent; +4 = +4% healing/damage      |
| ALL_EFFECTS      | PCT           | percent; +2 = +2% all effects         |
| CRIT_CHANCE      | FLAT          | 100 = 1% crit                         |
| CRIT_DAMAGE      | FLAT          | 100 = 1% bonus crit damage (verify in-game) |
| RESIST_MISS_CHANCE | FLAT        | -100 = -1% resist/miss chance         |
| THREAT           | PCT           | percent; -10 = -10% threat            |
| EFFECT1 / EFFECT2 | PCT          | percent of the named effect value     |
