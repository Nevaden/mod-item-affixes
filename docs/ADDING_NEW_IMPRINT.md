# Adding a New Imprint — Step-by-Step Guide

Imprints are socket-like effects applied to equipped items that grant custom spells.
This document covers the full pipeline including pitfalls discovered during development.

See `IMPRINT_DEV_GUIDE.md` for pattern libraries (spell-mod, summons, guardians, auras,
trigger spells) and the general gotchas reference.

---

## Quick Reference — File Checklist

| File | What to add |
|---|---|
| `src/Imprints/ImprintMgr.h` | New enum value in `ImprintId` |
| `src/Imprints/<Class>/<Name>.cpp` | C++ effect class + registration function |
| `src/mod_item_affixes_loader.cpp` | `extern` declaration + `Register…()` call |
| `src/ItemAffixScripts.cpp` | SpellScript (if spell has logic) + `RegisterSpellScript` |
| `imprints/custom_spells.json` | Client DBC entry (name, icon, school, SLA binding) |
| `data/sql/db-world/imprint_def.sql` | Row in `imprint_def` table |
| `data/sql/db-world/imprint_rune_items.sql` | `item_template` row for the rune item |
| `data/sql/db-world/spell_dbc_<name>.sql` | Server-side spell override |
| `data/sql/db-world/spell_script_names_imprint.sql` | SpellScript name binding |
| `tools/patch_spell_dbc_custom.ps1` | **Required if imprint uses learnSpell()** — patches binary Spell.dbc for server + client |

Run `update_imprints.bat` after all files are ready to apply SQL + rebuild client MPQ.
If the imprint grants a learnable spell, also run `patch_spell_dbc_custom.ps1` and restart the WoW client.

> **Steps that are ALWAYS required and have caused bugs when skipped:**
> 1. Add the spell to `custom_spells.json` — run `patch_custom_spells.ps1` → rebuilds `patch-z.MPQ` + `patch-enUS-z.MPQ` (SLA spellbook tab + Spell.dbc in MPQ)
> 2. Run `patch_spell_dbc_custom.ps1` → patches server binary Spell.dbc + client loose-file `DBFilesClient\Spell.dbc`
> 3. Restart the WoW client — client reads new DBC on startup only
> 4. After any addon code change: copy source → deployed (`WoW HD\Interface\AddOns\ItemAffixes\`)
> 5. `/reload` in-game or relog — addon picks up new server messages on `PLAYER_ENTERING_WORLD`

---

## Step 1 — Assign IDs

Choose IDs that don't conflict with existing content:

| Thing | Range used by this module | Example |
|---|---|---|
| `ImprintId` enum | 1–99 | `7` |
| Spell ID (custom) | 600001–600099 | `600004` |
| Rune item entry | 602001–602099 | `602007` |
| SLA entry ID | 50000–50099 | `50002` |

Check the current max in each:
- Enum: `src/Imprints/ImprintMgr.h`
- Spell/item: `imprint_def.sql` + `imprint_rune_items.sql`
- SLA: `sla_entry_id` values in `custom_spells.json`

---

## Step 2 — Add the Enum Value

In `src/Imprints/ImprintMgr.h`, add at the end of `ImprintId`:

```cpp
enum ImprintId : uint32
{
    IMPRINT_RIGHTEOUS_SANCTUARY  = 1,
    // ...
    IMPRINT_VANISHING_BACKSTAB   = 6,
    IMPRINT_YOUR_NEW_IMPRINT     = 7,   // add here
};
```

---

## Step 3 — Create the C++ Effect Class

Create `src/Imprints/<Class>/<Name>.cpp`.
The directory is auto-discovered by CMake — no CMakeLists.txt change needed.

```cpp
#include "../ImprintMgr.h"
#include "Player.h"

static constexpr uint32 SPELL_YOUR_SPELL = 600004;

class YourImprintEffect : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_YOUR_NEW_IMPRINT; }

    std::string const& Name() const override {
        static const std::string name = "Your Imprint Name";
        return name;
    }

    // Text appended in gold to this spell's tooltip in the spellbook and on action bars.
    // Sent to the addon on every login and /reload. One entry per affected spell.
    // Keep descriptions to one sentence. Return {} if the imprint has no spell button.
    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_YOUR_SPELL,
            "One sentence describing what the imprint does when this spell is cast." }};
    }

    void OnEquip(Player* player, uint64 /*itemGuid*/) override {
        player->learnSpell(SPELL_YOUR_SPELL, false);
        // CRITICAL: SPELL_YOUR_SPELL's Effect_1 in spell_dbc MUST be 3 (SPELL_EFFECT_DUMMY).
        // learnSpell silently ignores APPLY_AURA and other effects — no error, no log entry.
        // If you need an APPLY_AURA, use a second hidden spell applied via triggered CastSpell
        // in the SpellScript's AfterCast (see Pattern G in IMPRINT_DEV_GUIDE.md).
    }

    // SPEC_MASK_ALL (255) is required — passing 0/false silently does nothing.
    void OnUnequip(Player* player, uint64 /*itemGuid*/) override {
        player->removeSpell(SPELL_YOUR_SPELL, SPEC_MASK_ALL, false);
    }

    void OnSpellAfterCast(Player* /*p*/, SpellInfo const* /*si*/) override {}
};

void RegisterYourNewImprint() {
    static YourImprintEffect effect;
    sImprintMgr->RegisterEffect(&effect);
}
```

---

## Step 4 — Register in the Loader

In `src/mod_item_affixes_loader.cpp`:

```cpp
// Near the other extern declarations:
void RegisterYourNewImprint();

// In Addmod_item_affixesScripts():
RegisterYourNewImprint();
```

---

## Step 5 — Write the SpellScript (if needed)

If the spell has gameplay logic, add a `SpellScript` or `AuraScript` to
`src/ItemAffixScripts.cpp` and call `RegisterSpellScript(your_spell_script)` in
`AddSC_item_affix_scripts()`.

### Hooks quick reference

| Hook | When to use |
|---|---|
| `OnCheckCast` | Validate custom conditions before the spell fires (range, target state, etc.) |
| `OnEffectHitTarget` | Capture the hit target (enemy-targeted spells only) |
| `AfterCast` | Main logic: fire secondary spells, schedule events |
| `OnEffectPeriodic` (AuraScript) | Periodic aura ticks |

### Critical: TRIGGERED_FULL_MASK does NOT bypass all checks

Two checks in `Spell::CheckCast` run **unconditionally** regardless of trigger flags:

1. **Range check** (`Spell.cpp` `CheckRange`): The caster must be within the spell's
   `RangeIndex` distance of the target. Even `TRIGGERED_FULL_MASK` does not skip this.

2. **Behind-target check** (`Spell.cpp` `HasInArc`): For Backstab and similar abilities,
   the caster must be behind the target. Also unconditional.

**Fix for range:** Use a deferred `BasicEvent` (≈250 ms) when the caster teleports
before the secondary cast, so the server-side position propagates before `CheckRange` fires.

**Fix for behind-target:** Call `target->SetOrientation(target->GetAngle(caster) + M_PI)`
directly before `CastSpell`. `SetOrientation` writes synchronously to `m_orientation`;
`HasInArc` reads it immediately.

```cpp
target->SetOrientation(target->GetAngle(caster) + float(M_PI));
caster->CastSpell(target, SPELL_BACKSTAB, TRIGGERED_FULL_MASK);
```

### OnCheckCast — enforcing custom range on self-cast spells

Self-cast spells never gray out in the client UI because the client only checks range
against the selected target when the spell's `ImplicitTargetA` is an enemy/unit target.
To enforce a range limit on a self-cast trigger:

```cpp
SpellCastResult CheckRange()
{
    Player* caster = GetCaster()->ToPlayer();
    if (!caster)
        return SPELL_FAILED_DONT_REPORT;

    Unit* target = ObjectAccessor::GetUnit(*caster, caster->GetTarget());
    if (!target || !target->IsAlive())
        return SPELL_FAILED_BAD_TARGETS;

    if (!caster->IsWithinDistInMap(target, 25.0f))
        return SPELL_FAILED_OUT_OF_RANGE;

    return SPELL_CAST_OK;
}

void Register() override
{
    OnCheckCast += SpellCheckCastFn(YourScript::CheckRange);
    AfterCast   += SpellCastFn(YourScript::HandleAfterCast);
}
```

### Getting the selected target in a self-cast SpellScript

With a self-cast trigger, `OnHitTarget` never fires on the enemy. Read the player's
currently-selected target directly in `AfterCast`:

```cpp
void HandleAfterCast()
{
    Player* caster = GetCaster()->ToPlayer();
    if (!caster) return;

    Unit* target = ObjectAccessor::GetUnit(*caster, caster->GetTarget());
    if (!target || !target->IsAlive()) return;

    // ... do work on target
}
```

---

## Step 6 — Patch the Custom Spell DBCs

Any spell given to the player via `learnSpell()` must exist in the **client's** Spell.dbc.
If it is missing, the client silently drops `SMSG_LEARNED_SPELL` — no "You have learned"
message appears and the spell never shows in the spellbook.

**After adding a new custom spell entry, always run:**

```powershell
cd "modules/mod-item-affixes/tools"
powershell -ExecutionPolicy Bypass -File .\patch_spell_dbc_custom.ps1
```

This patches ALL module custom spells (600002–600005 and any you add) into:
- **Server binary DBC** — `E:\servers\Wow\Standard\bin\data\dbc\Spell.dbc`
- **Client loose-file override** — `E:\servers\Wow\WoW HD\Data\DBFilesClient\Spell.dbc`
  (the client reads this before any MPQ file)

Add your new spell entry to the `$spells` array in `patch_spell_dbc_custom.ps1` using the
same ordered-hashtable pattern as the existing spells. Restart the WoW client after running.

### Spellbook tab — `custom_spells.json` and SkillLineAbility

To make the spell appear under the correct spellbook tab (e.g. "Frost" for Mage),
add it to `imprints/custom_spells.json`. This drives the **SkillLineAbility.dbc** entry
in the patch MPQ, which assigns the spell to its tab:

```json
{
  "id": 600004,
  "name": "Your Spell Name",
  "description": "What it does.",
  "aura_description": "",
  "icon": 243,
  "school": "physical",
  "damage_class": "melee",
  "prevention_type": "none",
  "dispel_type": 0,
  "power_type": "energy",
  "cost": 60,
  "cast_time_index": 1,
  "duration_index": 0,
  "cooldown_ms": 0,
  "interrupt_flags": 0,
  "gcd_category": 133,
  "gcd_ms": 1000,
  "range_index": 34,
  "targets_flag": 2,
  "spell_family": 8,
  "family_flags": [0, 0, 0],
  "effects": [
    {
      "type": "DUMMY",
      "aura": null,
      "amplitude_ms": 0,
      "base_points": 0,
      "target": "TARGET_SELF"
    }
  ],
  "skill_line": 38,
  "sla_entry_id": 50002
}
```

Then run `patch_mpq_spells.ps1` to rebuild the client MPQ:

```powershell
cd "modules/mod-item-affixes/tools"
powershell -ExecutionPolicy Bypass -File .\patch_mpq_spells.ps1
```

> **Note:** `patch_spell_dbc_custom.ps1` handles Spell.dbc for both server and client.
> `patch_mpq_spells.ps1` still handles SkillLineAbility.dbc (spellbook tab assignment).
> Both must be run when adding a new learnable spell.

**`range_index`** controls which SpellRange.dbc entry governs the button grayout in the
client UI. Set this to the range of the ability the imprint actually triggers (e.g. 34 = 25 yards
for Shadowstep). Field indices for known ranges:

| RangeIndex | Max yards | Notes |
|---|---|---|
| 1 | 0 (self) | Self-cast; button never grays based on target |
| 34 | 25 | Shadowstep / melee-gap range |
| 5 | 40 | Standard long-range |
| 37 | 50 | Extended long-range |

**`targets_flag`** = `2` means the client expects the player to have a selected unit target.
This is needed for the range-based grayout to work even on self-cast spells (see Step 7).

### Finding the Correct `icon` (SpellIconID)

**The `icon` field is a SpellIcon.dbc entry ID, NOT a texture file number.**
Using a raw texture file number results in the spell being invisible in the spellbook.

To find the correct value, look up an existing spell with the same icon in `Spell.dbc`
(field 133, 0-based). PowerShell snippet:

```powershell
$path = "E:\servers\Wow\Standard\bin\data\dbc\Spell.dbc"
$raw  = [System.IO.File]::ReadAllBytes($path)
$recCount = [BitConverter]::ToUInt32($raw, 4)
$recSize  = [BitConverter]::ToUInt32($raw, 12)
for ($i = 0; $i -lt [int]$recCount; $i++) {
    $off = 20 + $i * [int]$recSize
    $id  = [BitConverter]::ToUInt32($raw, $off)
    if ($id -eq 53) {   # Backstab rank 1 — swap for any spell with the icon you want
        Write-Host "SpellIconID = $([BitConverter]::ToUInt32($raw, $off + 133 * 4))"
    }
}
# Outputs: SpellIconID = 243
```

### Finding the Correct `range_index` for an existing spell

RangeIndex is at **field 46** (0-based) in Spell.dbc:

```powershell
$path  = "E:\servers\Wow\Standard\bin\data\dbc\Spell.dbc"
$bytes = [System.IO.File]::ReadAllBytes($path)
$recCount = [BitConverter]::ToInt32($bytes, 4)
$recSize  = [BitConverter]::ToInt32($bytes, 12)
for ($i = 0; $i -lt $recCount; $i++) {
    $base = 20 + $i * $recSize
    $id   = [BitConverter]::ToInt32($bytes, $base)
    if ($id -eq 36554) {   # Shadowstep — swap for the spell whose range you want to match
        Write-Host "RangeIndex = $([BitConverter]::ToInt32($bytes, $base + 46 * 4))"
        break
    }
}
# Outputs: RangeIndex = 34
```

### Finding the Correct `skill_line` (Spellbook Tab)

```powershell
$slaPath = "E:\servers\Wow\Standard\bin\data\dbc\SkillLineAbility.dbc"
$raw     = [System.IO.File]::ReadAllBytes($slaPath)
$recCount = [BitConverter]::ToUInt32($raw, 4)
$recSize  = [BitConverter]::ToUInt32($raw, 12)
for ($i = 0; $i -lt [int]$recCount; $i++) {
    $off     = 20 + $i * [int]$recSize
    $spellId = [BitConverter]::ToUInt32($raw, $off + 8)   # field 2 = Spell
    if ($spellId -eq 13877) {  # Blade Flurry — swap for a known ability in the target spec
        Write-Host "SkillLine = $([BitConverter]::ToUInt32($raw, $off + 4))"
    }
}
# Outputs: SkillLine = 38  (Rogue Combat tab)
```

Known skill line values (WotLK 3.3.5a, confirmed from SkillLineAbility.dbc):

| Class + Tab | SkillLine | Example Spell |
|---|---|---|
| Mage (Frost) | 6 | Frostbolt (116), Blizzard (10), Frost Nova (122) |
| Mage (Fire) | 8 | Fireball (133) |
| Mage (Arcane) | 237 | Arcane Missiles (5143) |
| Rogue | 38 | Sinister Strike (1752), Backstab (53), Blade Flurry (13877) |
| Priest | 56 | Holy Nova (15237), Flash Heal (2061) |
| Paladin (Holy) | 594 | Holy Light (635) |

---

## Step 7 — Create the Server-Side spell_dbc SQL

`data/sql/db-world/spell_dbc_<name>.sql`

### Standard enemy-targeted spell

```sql
INSERT INTO `spell_dbc` (
    `ID`, `CastingTimeIndex`, `RangeIndex`, `SpellIconID`, `ActiveIconID`,
    `SchoolMask`, `SpellClassSet`, `Targets`, `EquippedItemClass`,
    `Effect_1`, `ImplicitTargetA_1`, `PowerType`, `ManaCost`,
    `StartRecoveryCategory`, `StartRecoveryTime`, `Name_Lang_enUS`, `Name_Lang_Mask`
) VALUES (
    600004, 1, 5, 243, 243, 1, 8, 2, -1, 3, 6, 3, 60, 133, 1000, 'Your Spell', 1
)
ON DUPLICATE KEY UPDATE ...;
```

### Self-cast trigger (avoids EngageWithTarget — PREFERRED for ability triggers)

When the DUMMY spell hits an enemy unit, the engine calls `Unit::EngageWithTarget`
regardless of whether the SpellScript's secondary cast fires. This means the mob
enters combat the moment the button is pressed, even if the caster is out of range.

**Solution:** Make the trigger spell self-cast so it never touches the enemy.
The SpellScript reads the selected target via `caster->GetTarget()` instead.

| Field | Enemy-targeted | Self-cast trigger |
|---|---|---|
| `ImplicitTargetA_1` | 6 (TARGET_UNIT_TARGET_ENEMY) | 1 (TARGET_UNIT_CASTER) |
| `Targets` | 2 (unit required) | 2 (keep for client range display) |
| `RangeIndex` | spell's actual range | RangeIndex of the triggered ability |

```sql
-- Self-cast trigger example (Vanishing Backstab pattern)
INSERT INTO `spell_dbc` (
    `ID`, `CastingTimeIndex`, `RangeIndex`, `SpellIconID`, `ActiveIconID`,
    `SchoolMask`, `SpellClassSet`, `Targets`, `EquippedItemClass`,
    `Effect_1`, `ImplicitTargetA_1`, `PowerType`, `ManaCost`,
    `StartRecoveryCategory`, `StartRecoveryTime`, `Name_Lang_enUS`, `Name_Lang_Mask`
) VALUES (
    600004,
    1,     -- instant
    34,    -- 25 yards: RangeIndex of Shadowstep (must match triggered ability's range)
    243, 243,
    1,     -- physical school
    8,     -- SPELLFAMILY_ROGUE
    2,     -- TARGET_FLAG_UNIT: client sends unit GUID and applies range grayout
    -1,    -- EquippedItemClass = -1 (default 0 causes SPELL_FAILED_EQUIPPED_ITEM_CLASS)
    3,     -- SPELL_EFFECT_DUMMY
    1,     -- TARGET_UNIT_CASTER: server resolves onto caster; enemy never touched
    3,     -- energy
    60,    -- energy cost
    133, 1000,   -- Rogue GCD (1000 ms, not 1500)
    'Your Spell', 1
)
ON DUPLICATE KEY UPDATE ...;
```

**Why `Targets=2` on a self-cast:** The client uses the `Targets` field to decide whether
to include the selected unit in the range check. With `Targets=0`, the button is always lit
regardless of distance. With `Targets=2`, the client checks the selected unit's distance
against `RangeIndex` and grays the button appropriately.

**Critical fields:**

| Field | Value | Notes |
|---|---|---|
| `EquippedItemClass` | -1 | **Required.** Default 0 → `SPELL_FAILED_EQUIPPED_ITEM_CLASS` on every cast |
| `StartRecoveryTime` | 1000 | Rogue GCD is 1000 ms; most other classes use 1500 |
| `ImplicitTargetA_1` | 1 for self-cast, 6 for enemy | See combat engagement note above |
| `RangeIndex` | Match the triggered ability | Use DBC lookup (field 46) — see Step 6 |

---

## Step 8 — Add the Rune Item

In `data/sql/db-world/imprint_rune_items.sql`:
1. Add the new entry ID to the `DELETE FROM item_template WHERE entry IN (...)` line
2. Add a new `VALUES` row following the pattern of existing runes
   - `AllowableClass = -1` (class restriction enforced by `imprint_def.class_mask`)
   - `spellid_1 = 600001` (the rune-use script trigger, same for all runes)

---

## Step 9 — Update `imprint_def.sql`

Add a row:

```sql
(7, 'Your Imprint Name', 602007, 2, 8, 1)  -- class_mask=8=Rogue, spec_tree=1=Combat
```

`class_mask` bit values: Warrior=1, Paladin=2, Hunter=4, **Rogue=8**, Priest=16,
DeathKnight=32, Shaman=64, Mage=128, Warlock=256, Druid=1024.

`spec_tree`: 0=first tree, 1=second tree, 2=third tree, -1=any spec.

---

## Step 10 — Add the SpellScript Binding

In `data/sql/db-world/spell_script_names_imprint.sql`:

```sql
(600004, 'spell_your_script_name')
```

---

## Step 11 — Apply Everything

```bat
update_imprints.bat
```

Then **restart the worldserver** (SQL + spell_dbc rows are loaded at startup).

If the imprint grants a learnable spell (uses `learnSpell()`), also run these before testing:

```powershell
# 1. Patch binary Spell.dbc for server + loose-file client override
powershell -ExecutionPolicy Bypass -File .\tools\patch_spell_dbc_custom.ps1

# 2. Rebuild client patch MPQ (SkillLineAbility.dbc for spellbook tab)
powershell -ExecutionPolicy Bypass -File .\tools\patch_mpq_spells.ps1
```

Restart the WoW client so it picks up the updated `DBFilesClient\Spell.dbc`.

If the addon was changed, sync source to deployed before relaunching the client:

```powershell
Copy-Item "modules\mod-item-affixes\addon\ItemAffixes\ItemAffixes.lua" `
          "E:\servers\Wow\WoW HD\Interface\AddOns\ItemAffixes\ItemAffixes.lua"
```

Test with `.imprint grant <id>` on a character of the correct class/spec.

---

## Enabling Debug Logs

`LOG_DEBUG("scripts", ...)` in SpellScripts goes to the `scripts` logger.
The default Console appender has level 4 (WARN) and silently drops DEBUG output.
Route it to the `Errors` appender which has level 2 (DEBUG):

In `worldserver.conf`:

```
Logger.scripts=2,Console Server Errors
```

Debug output then appears in `bin/logs/Errors.log`.
Remove the `Errors` entry (or raise the level back to 4) after debugging to keep the log file clean.
