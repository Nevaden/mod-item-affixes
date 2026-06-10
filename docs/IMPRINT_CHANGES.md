# Imprint System — Change Tracking

All changes made to support the Imprint system (special/upgraded abilities).
Keep this file updated as new Imprints are added or existing behaviour is adjusted.

---

## Core Engine Patches

These require a full rebuild. They live outside the module and must be
manually reverted if the Imprint system is removed.

### `src/server/game/Spells/SpellInfo.cpp` — `SpellInfo::CalcCastTime`

**Why:** `SPELLMOD_CASTING_TIME` mods were silently ignored for instant-cast
spells because `CalcCastTime` returned 0 early when `CastTimeEntry` is null,
before ever calling `ModSpellCastTime`. This prevented Imprint effects (like
Sanctuary Storm's +2s cast time) from working on any ability that is normally
instant.

**Change:** When `CastTimeEntry` is null, still call `ModSpellCastTime` and
return the modified value if it is positive.

```cpp
// Before:
if (!CastTimeEntry)
    return 0;

// After:
if (!CastTimeEntry)
{
    int32 castTime = 0;
    if (caster)
        caster->ModSpellCastTime(this, castTime, spell);
    return (castTime > 0) ? uint32(castTime) : 0;
}
```

### `src/server/game/Spells/SpellInfo.cpp` — `SpellInfo::IsAffectedBySpellMod`

**Why:** Melee abilities like Divine Storm have `SPELL_ATTR3_IGNORE_CASTER_MODIFIERS` which
blocks all SpellMods server-side (even though the CLIENT still applies them for tooltips, causing
a tooltip/behaviour mismatch). Without this fix, `SPELLMOD_CASTING_TIME` mods are silently
dropped, so Sanctuary Storm's +2s cast time has no effect.

**Change:** Add `SPELLMOD_CASTING_TIME` as an exemption alongside the existing `SPELLMOD_DURATION`
exemption, so cast-time mods are always applied regardless of `IGNORE_CASTER_MODIFIERS`.

```cpp
// Before:
if (mod->op != SPELLMOD_DURATION)
    if (!IsAffectedBySpellMods())
        return false;

// After:
if (mod->op != SPELLMOD_DURATION && mod->op != SPELLMOD_CASTING_TIME)
    if (!IsAffectedBySpellMods())
        return false;
```

### `src/server/game/Entities/Player/Player.cpp` — `Player::ApplySpellMod` (lambda `calculateSpellMod`)

**Why:** `ApplySpellMod` has an early-return guard: "if the spell is already instant (cast time ≤ 0),
skip this cast time mod." When `basevalue = 0` and no previous flat mods have accumulated yet,
the condition `totalflat <= 0` is true and our +2000ms mod is discarded before it modifies
anything. This silently blocked all positive flat cast time additions to instant-cast spells.

**Change:** Allow positive flat cast time mods to bypass the early-return guard.

```cpp
// Before:
if (mod->op == SPELLMOD_CASTING_TIME || mod->op == SPELLMOD_COST)
    if (((float)basevalue + ...) <= 0)
        return;

// After:
if (mod->op == SPELLMOD_CASTING_TIME || mod->op == SPELLMOD_COST)
    if (!(mod->type == SPELLMOD_FLAT && mod->value > 0))  // allow adding cast time to instant spells
        if (((float)basevalue + ...) <= 0)
            return;
```

---

## Module Source Changes (`mod-item-affixes`)

### New files — `src/Imprints/`

| File | Purpose |
|---|---|
| `ImprintMgr.h` | `ImprintEffect` base class, `ImprintDef`, `ImprintInstance`, `ImprintMgr` singleton declaration |
| `ImprintMgr.cpp` | Manager implementation: DB load, equip/unequip routing, lazy-load cache, `ExtractImprint`, `ApplyImprint`, `GrantRune` |
| `ImprintCommands.cpp` | `.imprint inspect / extract / apply / grant` chat commands |
| `SanctuaryStorm.cpp` | Concrete Imprint #1: 2× Divine Storm damage, +2s cast time, free Consecration on cast |

### Modified files

| File | Change |
|---|---|
| `src/ItemAffix.h` | Added `activeImprints` and `activeImprintMods` maps to `ItemAffixPlayerData` |
| `src/ItemAffixScripts.cpp` | Wired `ImprintMgr::OnItemEquipped/Unequipped` into equip hooks; added `spell_divine_storm_imprint` SpellScript; calls `LoadConfig` + `LoadDefs` on world init; reapplies Imprints on player login |
| `src/mod_item_affixes_loader.cpp` | Added `AddSC_item_imprint_commands()` and `RegisterSanctuaryStormImprint()` calls |

---

## Database Changes

### Characters DB (`pb_characters`)

**Table: `item_imprint`**
```sql
CREATE TABLE item_imprint (
  item_guid        BIGINT UNSIGNED  NOT NULL,
  imprint_id       INT UNSIGNED     NOT NULL,
  extractions_left TINYINT UNSIGNED NOT NULL DEFAULT 2,
  PRIMARY KEY (item_guid)
);
```
File: `data/sql/db-characters/item_imprint.sql`

---

### World DB (`pb_world`)

**Table: `imprint_def`**
```sql
CREATE TABLE imprint_def (
  id              INT UNSIGNED     NOT NULL,
  name            VARCHAR(64)      NOT NULL DEFAULT '',
  rune_item_id    INT UNSIGNED     NOT NULL DEFAULT 0,
  extractions_max TINYINT UNSIGNED NOT NULL DEFAULT 2,
  class_mask      INT UNSIGNED     NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
);
```
Sanctuary Storm row: `id=1, name='Sanctuary Storm', rune_item_id=601001, extractions_max=2, class_mask=0`

File: `data/sql/db-world/imprint_def.sql`

---

**Item template: Imprint Rune (entry 601001)**
- class=7 (Trade Goods), subclass=0
- Quality=4 (Epic), Flags=0
- maxcount=1, stackable=1, not equippable
- displayid=39201 (Void Crystal)

File: `data/sql/db-world/imprint_rune_item.sql`

---

**`spell_script_names` binding**
```sql
INSERT INTO spell_script_names (spell_id, ScriptName)
VALUES (53385, 'spell_divine_storm_imprint');
```
Binds our module SpellScript to Divine Storm alongside the existing core script.

File: `data/sql/db-world/spell_script_names_imprint.sql`

---

## Config Additions

In `mod_item_affixes.conf` (or worldserver.conf):
```ini
ItemAffixes.ImprintExtractionCount = 2   # how many times a Rune can be extracted
```
Loaded in `ImprintMgr::LoadConfig()`.

---

## Adding a New Imprint (checklist)

1. Add `IMPRINT_<NAME> = <id>` to the `ImprintId` enum in `ImprintMgr.h`
2. Create `src/Imprints/<Name>.cpp` implementing `ImprintEffect`
3. Add `void Register<Name>Imprint();` forward declaration in `mod_item_affixes_loader.cpp`
4. Call `Register<Name>Imprint()` in `Addmod_item_affixesScripts()`
5. Add a row to `imprint_def` SQL (or add via `.imprint` GM commands later)
6. Add an item template SQL if a new Rune type is needed (or reuse 601001)
7. Add a `spell_script_names` row if the Imprint hooks a new spell
8. If the Imprint uses a new spell event not yet routed (e.g. `OnSpellHit` for a different spell), add a new SpellScript in `ItemAffixScripts.cpp`
9. Update this file

---

---

## Imprint #6 — Vanishing Backstab (Rogue Combat, 2026-05-28)

### New files

| File | Purpose |
|---|---|
| `src/Imprints/Rogue/VanishingBackstab.cpp` | Imprint class — OnEquip/OnUnequip (learnSpell/removeSpell 600003) |
| `data/sql/db-world/spell_dbc_vanishing_backstab.sql` | Custom spell 600003 server-side definition |

### Modified files

| File | Change |
|---|---|
| `src/Imprints/ImprintMgr.h` | Added `IMPRINT_VANISHING_BACKSTAB = 6` |
| `src/mod_item_affixes_loader.cpp` | Added `RegisterVanishingBackstabImprint()` |
| `src/ItemAffixScripts.cpp` | Added `VanishingBackstabEvent` (BasicEvent) + `spell_vanishing_backstab` SpellScript |
| `imprints/custom_spells.json` | Added spell 600003 entry |
| `data/sql/db-world/imprint_def.sql` | Added id=6, class_mask=8 (Rogue), spec_tree=1 (Combat) |
| `data/sql/db-world/imprint_rune_items.sql` | Added rune item 602006 |

### Spell 600003 design

| Field | Value | Notes |
|---|---|---|
| `ImplicitTargetA_1` | 1 (TARGET_UNIT_CASTER) | Self-cast: enemy never touched, no EngageWithTarget |
| `Targets` | 2 (TARGET_FLAG_UNIT) | Client grays button when selected enemy is >25 yards |
| `RangeIndex` | 34 (0-25 yards) | Matches Shadowstep's exact range (SpellRange ID 34) |
| `Effect_1` | 3 (SPELL_EFFECT_DUMMY) | All logic in SpellScript |
| `StartRecoveryTime` | 1000 ms | Rogue GCD |

### SpellScript behaviour

1. `OnCheckCast`: validates selected target exists, is alive, and is within 25 yards. Returns `SPELL_FAILED_OUT_OF_RANGE` otherwise.
2. `AfterCast`: reads `caster->GetTarget()` (no `OnHitTarget` — spell is self-cast). Calls Shadowstep (`TRIGGERED_FULL_MASK`). Schedules `VanishingBackstabEvent` at +250 ms.
3. `VanishingBackstabEvent::Execute`: finds highest-rank Backstab the player knows, calls `target->SetOrientation(angle + M_PI)` to pass behind-arc check, then casts Backstab (`TRIGGERED_FULL_MASK`).

### Key lessons (see Pattern F in IMPRINT_DEV_GUIDE.md)

- DUMMY on enemy target triggers `EngageWithTarget` — use self-cast to prevent this
- `TRIGGERED_FULL_MASK` does NOT bypass `CheckRange` or `HasInArc` — both unconditional
- `NearTeleportTo` for players is async — 250 ms deferred event lets Shadowstep position propagate
- `SetOrientation` writes synchronously to `m_orientation`; safe to call immediately before `CastSpell`
- `Targets=2` is needed even on self-cast spells for the client range-grayout to work

---

## Known Deferred Work

- Equip limit (max N Imprints equipped simultaneously) — config-driven, not yet implemented
- Rolling Imprints naturally from the class affix pool — Imprints not yet in `affix_template`
- Disenchanting hook (enchanter path for extraction with materials)
- Addon tooltip support (show Imprint name/extractions in item tooltip)
- Per-class restriction on Imprint items (`class_mask` field exists but not enforced yet)
