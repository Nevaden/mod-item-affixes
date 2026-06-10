# Celestial Resonance — Dev Notes

## Goal

Turn Holy Nova into a targeted aura spell. Casting applies an 8-second buff/debuff
to any unit (enemy, ally, or self). While active the aura fires Holy Nova **from the
target's current position** once per second, following a moving target automatically.
Cast time 1.5 s, range 40 yards, standard GCD.

---

## Architecture — how it works

```
Player equips item with Celestial Resonance imprint
  → CelestialResonanceImprint::OnEquip
      → player->learnSpell(600002)          ← custom spell granted

Player casts spell 600002 on a target
  → spell_celestial_resonance (AuraScript, ItemAffixScripts.cpp)
      → SPELL_AURA_PERIODIC_DUMMY fires every 1000 ms for 8000 ms
          → HandlePeriodic()
              → SummonCreature(601105, target->GetPos, 500 ms lifetime)
              → beacon->CastSpell(beacon, 48078,          ← Holy Nova R9
                    TRIGGERED_FULL_MASK, nil, nil,
                    player->GetGUID())                    ← damage attributed to player

Player unequips item
  → CelestialResonanceImprint::OnUnequip
      → player->removeSpell(600002)
      → any active auras tick out naturally
          (HandlePeriodic checks HasImprintEquipped, silently no-ops if gone)
```

Key insight: because `originalCaster = player->GetGUID()` and the beacon is a
Creature (not a Player), the `ToPlayer()` guard in other SpellScripts is safe
and the Imprint does not recurse on its own Holy Nova casts.

---

## Files

| File | Role |
|---|---|
| `src/Imprints/Priest/CelestialResonance.cpp` | Imprint class — OnEquip/OnUnequip |
| `src/ItemAffixScripts.cpp` | AuraScript `spell_celestial_resonance` + registration |
| `src/Imprints/ImprintMgr.h` | `IMPRINT_CELESTIAL_RESONANCE = 5` enum value |
| `src/mod_item_affixes_loader.cpp` | `RegisterCelestialResonanceImprint()` call |
| `data/sql/db-world/spell_dbc_celestial_resonance.sql` | Custom spell definition (server side) |
| `data/sql/db-world/holy_nova_beacon_creature.sql` | Entry 601105, invisible stalker |
| `data/sql/db-world/spell_script_names_imprint.sql` | Binds AuraScript to spell 600002 |
| `data/sql/db-world/imprint_def.sql` | id=5, class_mask=16 (Priest), spec_tree=1 (Holy) |
| `tools/patch_spell_dbc.ps1` | Patches client Spell.dbc binary (see below) |

---

## Client-side DBC patch

The server knows about spell 600002 via the `spell_dbc` MySQL table. The WoW 3.3.5a
client knows nothing about it — it reads from its own binary DBC files loaded out of
MPQ archives. Without a client patch, the spell appears as blank/unknown in the
spellbook and cannot be placed on action bars.

### Running the patch

```powershell
cd "E:\servers\Wow\PlayerBots\azerothcore\modules\mod-item-affixes\tools"
.\patch_spell_dbc.ps1
```

The script:
1. Reads `E:\servers\Wow\Standard\bin\data\dbc\Spell.dbc`
2. Appends a complete record for spell 600002 with the correct icon, name, description,
   cast time, duration, range, effect, and aura fields
3. Writes the patched file to:
   - **Server DBC**: `E:\servers\Wow\Standard\bin\data\dbc\Spell.dbc` (restart worldserver
     after to pick up binary DBC changes — the server already works via spell_dbc SQL)
   - **Client loose file**: `E:\servers\Wow\WoW HD\Data\DBFilesClient\Spell.dbc`

### If the client still shows "Unknown spell"

WoW 3.3.5a reads loose files from `Data\DBFilesClient\` **only if the client binary
has been patched to support it** (many custom private-server clients already have this).

If your client does not pick up the loose file:
1. Open `Spell.dbc` (the patched version the script wrote) with **Ladik's MPQ Editor**
2. Create a new archive named `patch-4.mpq` (or `patch-Z.mpq` for highest priority)
   in `E:\servers\Wow\WoW HD\Data\`
3. Add the DBC file inside the archive at path `DBFilesClient\Spell.dbc`
4. Restart the WoW client

---

## DBC field reference used by the patch script

All field indices are verified against `src/server/shared/DataStores/DBCStructure.h`.
WotLK 3.3.5a Spell.dbc: 234 fields, 936 bytes per record.

| Field | Index | Value set |
|---|---|---|
| Id | 0 | 600002 |
| Dispel | 2 | 1 (DISPEL_MAGIC) |
| Targets | 16 | 2 (TARGET_FLAG_UNIT) |
| CastingTimeIndex | 28 | 16 → 1500 ms |
| InterruptFlags | 31 | 0xF — interrupted by movement |
| DurationIndex | 40 | 31 → 8000 ms |
| RangeIndex | 46 | 5 → 40 yards |
| Effect[0] | 71 | 6 (SPELL_EFFECT_APPLY_AURA) |
| EffectImplicitTargetA[0] | 86 | 25 (TARGET_UNIT_TARGET_ANY) |
| EffectApplyAuraName[0] | 95 | 226 (SPELL_AURA_PERIODIC_DUMMY) |
| EffectAmplitude[0] | 98 | 1000 ms |
| SpellIconID | 133 | 1874 (Holy Nova icon) |
| SpellName[enUS] | 136 | "Celestial Resonance" |
| Description[enUS] | 170 | description string |
| ToolTip[enUS] | 187 | "Radiating Holy Nova once per second." |
| StartRecoveryCategory | 205 | 133 (standard GCD) |
| StartRecoveryTime | 206 | 1500 ms |
| SpellFamilyName | 208 | 6 (SPELLFAMILY_PRIEST) |
| DmgClass | 213 | 2 (SPELL_DAMAGE_CLASS_MAGIC) |
| PreventionType | 214 | 1 (SPELL_PREVENTION_TYPE_SILENCE) |
| SchoolMask | 225 | 2 (SPELL_SCHOOL_MASK_HOLY) |

---

## Holy Nova beacon creature (601105)

| Property | Value |
|---|---|
| Display | 11686 (Invisible Stalker) — renders nothing on client |
| Level | 80 (set in template; `SetLevel` not called on spawn) |
| Faction | Copied from player at spawn time (same as player) |
| Lifetime | 500 ms (despawns after spell fires) |
| Flags | NON_ATTACKABLE \| NOT_SELECTABLE \| TRIGGER \| CIVILIAN |
| AI | None (empty AIName, empty ScriptName) |

Damage attribution: `originalCaster = player->GetGUID()` passed as 6th arg to
`CastSpell`. Holy Nova's SP coefficient is applied against the **player's** spell
power, so the damage scales correctly with gear.

---

## What was tried and dropped

**Holy Nova removal on equip**: original plan was to remove all Holy Nova ranks and
replace them with Celestial Resonance. Dropped — too invasive, restoration logic on
unequip was fragile, and keeping Holy Nova alongside is harmless.

---

## Testing checklist

- [ ] Equip item → Celestial Resonance appears in spellbook
- [ ] Unequip item → Celestial Resonance removed from spellbook
- [ ] Re-login with item equipped → spell is re-granted (learnSpell is idempotent)
- [ ] Cast on enemy → Holy Nova fires from enemy position each second, damages nearby
- [ ] Cast on ally → Holy Nova fires from ally position, heals nearby friendlies
- [ ] Target moves → beacon spawns at new position on each tick
- [ ] Unequip mid-aura → aura ticks silently no-op; no beacons spawned
- [ ] Damage attribution → kill credit and threat go to player, not beacon creature
- [ ] Spell power scaling → verify Holy Nova damage matches player SP coefficient
