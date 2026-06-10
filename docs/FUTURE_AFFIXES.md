# Plan: Talent Level Affixes + Custom Spell Behavior Affixes

## Context

The current affix system supports two types:
- `AFFIX_TYPE_SPELLMOD = 0` — allocates a `SpellModifier*` to modify how a spell class behaves (cast time, damage pct, cooldown, etc.)
- `AFFIX_TYPE_STAT = 1` — calls `HandleStatFlatModifier` / `ApplyRatingMod` to add stats directly

Both are data-driven: define the affix in JSON, run `build_affixes.ps1`, the values land in `affix_template`, and C++ reads them at startup.

This plan adds two new affix types that require more bespoke work:
- `AFFIX_TYPE_TALENT = 2` — grants a bonus equivalent to one or more extra talent ranks
- `AFFIX_TYPE_CUSTOM = 3` — custom spell behavior (AoE conversion, permanent summons, proc removal, etc.)

---

## Part 1: Talent Level Affixes (`AFFIX_TYPE_TALENT = 2`)

### What it means

"+1 to Arcane Stability" on an item means the player gets the mechanical benefit of one additional rank of Arcane Stability — **without** spending a talent point. The talent UI will NOT show the change; the effect is applied invisibly as a spell aura on equip, identical to how SPELLMOD affixes already work.

### Why it isn't magic

Mechanically, "one rank of Arcane Stability" is just `SPELLMOD_FLAT` on the `REDUCE_PUSHBACK` modifier for Arcane spells. That is **exactly** what `AFFIX_TYPE_SPELLMOD` already does. The distinction is:

1. **Display string** — shows "+1 to Arcane Stability" rather than "+12% Spell Pushback Reduction"
2. **Curated metadata** — the JSON encodes which talent, what rank count, what the per-rank effect is
3. **Class + spec gate** — a TALENT affix for Arcane Stability only rolls for Mages; a Feral talent only rolls for Feral-spec Druids
4. **Roll eligibility** — optionally: only roll this affix if the player has ≥1 rank in the talent already

### Design Decision: "Any talent" vs "Only talents you have"

| Option | Pros | Cons |
|---|---|---|
| **Any talent of your class** | Simpler; allows interesting builds where the item teaches you a new mini-talent | Strong on specs that normally skip the talent; could feel weird |
| **Only talents with ≥1 rank spent** | Fits the ARPG fantasy of "pushing a build further"; weaker on untouched trees | Requires a roll-time `GetTalentRank()` check; interacts with respecs |

**Recommendation**: Start with "any talent of your class/spec." If a Mage equips "+1 Arcane Stability" but has no Arcane talents, the spellmod is still active but affects spells they may rarely cast — effectively low power. This avoids respec-interaction complexity entirely. Add the rank-gate as a later opt-in per affix via a `require_talent_rank: true` JSON flag.

### What happens on respec

The spellmod is applied on equip and removed on unequip. If the player respecs out of Arcane entirely and still has the item equipped, the spellmod remains active. Because the player can no longer cast Arcane spells (if they went full Fire), the bonus is effectively zero — no harm done. No special respec hook needed.

### Data model additions

**`affix_template` table** — no new columns needed. TALENT affixes store their effect in the existing `effect_*` columns exactly like SPELLMOD affixes. A new `affix_type = 2` value distinguishes them for display purposes only.

**JSON definition example:**
```json
{
  "id": 40000,
  "name": "Arcane Stability",
  "talent_display": "+{value} to Arcane Stability",
  "affix_type": 2,
  "weight": 8,
  "min_quality": 3,
  "item_category": 0,
  "target": {"family": 3, "family_name": "MAGE"},
  "spec_tree": 0,
  "effects": [
    {
      "spell_family": 3,
      "spell_family_flags": ["0x00040000", "0x00000000", "0x00000000"],
      "carrier_spell_id": 11210,
      "op": 7,
      "op_name": "SPELLMOD_NOT_LOSE_CASTING_TIME",
      "type": "FLAT",
      "value_per_rank": 20
    }
  ],
  "tooltip": {"enchant_id": 0}
}
```

`value_per_rank` replaces `value_min`/`value_max` for TALENT affixes — the rolled value is always 1..N (the roll range), and the actual spellmod magnitude is `rolled_value * value_per_rank`.

**`build_affixes.ps1` additions:**
- Recognize `affix_type: 2` and `talent_display` field
- Compute `value_min: 1`, `value_max: max_talent_rank` (specified in JSON or defaulted to 5)
- Write `affix_type = 2` into the SQL row
- Generate display template that the C++ `BuildAffixDisplayString` can use

**`src/ItemAffix.h`:**
```cpp
enum AffixType : uint8
{
    AFFIX_TYPE_SPELLMOD = 0,
    AFFIX_TYPE_STAT     = 1,
    AFFIX_TYPE_TALENT   = 2,   // spellmod mechanics, talent-flavored display
    AFFIX_TYPE_CUSTOM   = 3,   // bespoke handler (see Part 2)
};
```

**`src/ItemAffix.cpp`:**
- `ApplyAffixes` / `RemoveAffixes` treat `AFFIX_TYPE_TALENT` identically to `AFFIX_TYPE_SPELLMOD` (same `SpellModifier*` allocation path)
- `BuildAffixDisplayString`: check `affixType == AFFIX_TYPE_TALENT`, format "+{value} to {name}"

### Curated talent list (starter set — expand over time)

Building this set is the main labor. Each entry needs:
- The correct `spell_family_flags` bitmask (from `SpellClassOptions.dbc`)
- The right `SpellModOp` (from `SpellDefines.h`)
- A `carrier_spell_id` from that class so `IsAffectedBySpellMod` resolves correctly

Suggested first batch covering all 10 classes, ~3-5 talents each:

| Affix Name | Class | Spec | Effect |
|---|---|---|---|
| Arcane Stability | Mage | Arcane | Reduce spell pushback |
| Missile Barrage | Mage | Arcane | Reduce Arcane Missiles cast time |
| Critical Mass | Mage | Fire | +Crit to Fire spells |
| Precision | Rogue | Any | +Hit |
| Lethality | Rogue | Assassination | +Crit multiplier on poisons |
| Combat Expertise | Paladin | Protection | +Expertise |
| Conviction | Paladin | Retribution | +Crit |
| Elemental Precision | Shaman | Elemental | +Hit to Fire/Frost/Nature |
| Improved Shadow Bolt | Warlock | Destruction | Shadow Bolt debuff duration |
| Suppression | Warlock | Affliction | +Hit for Affliction |
| Morbidity | Death Knight | Unholy | CD reduction on Corpse Explosion/Death Coil |
| Dark Conviction | Death Knight | Any | +Crit |

---

## Part 2: Custom Spell Behavior Affixes (`AFFIX_TYPE_CUSTOM = 3`)

### Architecture overview

Custom affixes cannot be driven by data alone — each one requires hand-written C++ behavior. The architecture is a **handler registry**:

```cpp
// src/CustomAffixHandlers.h
class ICustomAffixHandler
{
public:
    virtual ~ICustomAffixHandler() = default;
    virtual void OnEquip(Player* player, Item* item, int32 rolledValue) {}
    virtual void OnUnequip(Player* player, Item* item) {}
    // Spell hooks — only override what this handler needs:
    virtual void OnAfterSpellHitTarget(Player* player, SpellInfo const* spellInfo,
                                        Unit* target, int32 rolledValue) {}
    virtual void OnSummonCreature(Player* player, Creature* summon, int32 rolledValue) {}
};
```

A singleton `CustomAffixRegistry` maps `uint32 affixId → ICustomAffixHandler*`.

**`ItemAffixMgr` additions:**
- `std::unordered_map<uint64, std::vector<std::pair<uint32,int32>>> _activeCustomAffixes`
  - Key: player GUID
  - Value: vector of (affixId, rolledValue) pairs for all equipped custom affixes
- `OnEquipCustom(player, item, def, rolledValue)` — adds to map, calls handler `OnEquip`
- `OnUnequipCustom(player, item, def)` — removes from map, calls handler `OnUnequip`
- `DispatchSpellHit(player, spellInfo, target)` — iterates player's active custom affix list, calls each handler's `OnAfterSpellHitTarget`

**`ItemAffixScripts.cpp` additions:**
- `OnSpellHit(Player*, SpellInfo*, Unit*)` or equivalent — dispatches to `DispatchSpellHit`
- Check: AzerothCore exposes `PlayerScript::OnSpellCast` but not always post-hit. May need to hook via `SpellScript` on individual spell IDs instead.

**JSON definition example:**
```json
{
  "id": 30000,
  "name": "Spreading Flame",
  "affix_type": 3,
  "custom_handler": "HOLY_FIRE_AOE",
  "weight": 4,
  "min_quality": 4,
  "item_category": 3,
  "target": {"family": 10, "family_name": "PALADIN"},
  "spec_tree": 0,
  "value_min": 10,
  "value_max": 10,
  "tooltip": {"enchant_id": 0}
}
```

`custom_handler` is a string key, stored in `affix_template` as a new `custom_handler` VARCHAR(64) column. At startup, `LoadAffixTemplates` looks up the string in the registry and stores a `ICustomAffixHandler*` pointer in `AffixDefinition`.

---

### Specific custom affixes — feasibility + implementation notes

#### "Holy Fire hits all enemies within 10m of target" (AoE Conversion)
- **Feasibility: HIGH**
- **Handler: `HOLY_FIRE_AOE`**
- `OnAfterSpellHitTarget`: if spellId == SPELL_HOLY_FIRE, query nearby hostile units within 10y of target, call `caster->CastCustomSpell(nearbyUnit, SPELL_HOLY_FIRE_SECONDARY, ...)` using a reduced-damage clone (or just deal damage directly via `Unit::DealDamage`)
- Need a secondary spell ID to avoid infinite recursion — create a custom server-side spell that shares Holy Fire's school but has no trigger
- Rolling value can encode the radius (10m fixed, or make it a rolled 5–15m)
- Works for any targeted harmful spell by swapping the spell ID check

#### "Summon Water Elemental is now permanent" (Permanent Summon)
- **Feasibility: HIGH**
- **Handler: `WATER_ELEMENTAL_PERMANENT`**
- WotLK Frost Mage has Glyph of Eternal Water (glyph spell ~57902 → applies aura 63093) which removes the expiry timer
- `OnEquip`: `player->CastSpell(player, 63093, true)` — applies the "no despawn" aura
- `OnUnequip`: `player->RemoveAurasDueToSpell(63093)`
- Verify that spell 63093 exists on this AzerothCore build; if not, create a custom aura in `spell_dbc_override` that removes the duration from the player's active water elemental guardian
- **Complication**: Frost Mage only; if worn by another class (if not class-gated), the aura is harmless (player has no water elemental to affect)
- Gate with `target.family = MAGE, spec_tree = 0` (Frost)

#### "Bloodthirst cooldown –1 second" (Specific CD reduction)
- **Feasibility: HIGH — already achievable with existing SPELLMOD**
- Bloodthirst spell family mask is documented in `SpellClassOptions.dbc`
- Define as `AFFIX_TYPE_SPELLMOD` with `op = SPELLMOD_COOLDOWN`, `type = FLAT`, `value = -1000` (ms)
- **No custom handler needed.** Upgrade existing Warrior SPELLMOD affix library.

#### "Victory Rush no longer requires a killing blow" (Proc → Always-On)
- **Feasibility: MEDIUM**
- Victory Rush is gated by a proc aura (SPELL_AURA_PROC_TRIGGER_SPELL on kill). "Always available" means keeping the proc aura permanently refreshed.
- Handler approach: `OnEquip` starts a periodic `player->CastSpell(player, VICTORY_RUSH_PROC_AURA, true)` via a recurring script event; `OnUnequip` stops it and removes the aura
- Alternatively: apply an aura that permanently enables Victory Rush's "usable" state — requires knowing the internal aura ID
- **Simpler alternative**: Just make it a SPELLMOD that reduces Victory Rush's internal CD to 0.5s (feels "always available") — much less code

#### "Feral Spirit duration ×2, double wolves summoned" (Duration + Count)
- **Feasibility: Duration = HIGH, Double Count = MEDIUM-HIGH**
- **Duration**: `AFFIX_TYPE_SPELLMOD` with `SPELLMOD_DURATION + SPELLMOD_PCT + value=100` targeting Feral Spirit family flags — **already works with existing system**
- **Double wolves**: Feral Spirit summons exactly 2 wolves as hardcoded spell effects
  - Handler `OnSummonCreature`: when `creature->GetEntry() == FERAL_SPIRIT_ENTRY` and it was just summoned by this player, immediately summon 2 more via `player->CastSpell(...)` with the Feral Spirit summon spell, then flag those extra wolves as "already doubled" to prevent recursion
  - Recursion guard needed: mark extra wolves with a custom flag so `OnSummonCreature` ignores them
  - **Concern**: 4 spirit wolves is very powerful. Gate to `min_quality = 4` (purple) and lower rolled value on other stats.

#### "Hex persists after combat ends" (Aura Persistence)
- **Feasibility: MEDIUM**
- Hex (Shaman CC) normally drops out of combat — its aura is flagged with `AURA_INTERRUPT_FLAG_DAMAGE`
- Removing that interrupt flag dynamically per player is non-trivial (SpellInfo is shared, not per-player)
- Cleanest approach: on Hex hit, copy the aura to a custom non-breakable version of the spell
- Practical complexity: HIGH. Defer to later.

#### "Mortal Strike reduces healing received by 75% instead of 50%" (Magnitude Boost)
- **Feasibility: HIGH — existing SPELLMOD**
- Mortal Strike applies SPELL_AURA_MOD_HEALING_PCT. The value of that aura is set by the spell's base points.
- A SPELLMOD on `SPELLMOD_EFFECT1` (or the relevant effect index) for Mortal Strike with the right family flags can increase the base points of the debuff.
- This fits `AFFIX_TYPE_SPELLMOD` with per-rank values → no custom handler.

---

## Files Changed

| File | Change |
|---|---|
| `src/ItemAffix.h` | Add `AFFIX_TYPE_TALENT = 2`, `AFFIX_TYPE_CUSTOM = 3`; add `customHandler` field to `AffixDefinition`; add `_activeCustomAffixes` map; add `ICustomAffixHandler` interface + `CustomAffixRegistry` |
| `src/ItemAffix.cpp` | `ApplyAffixes`/`RemoveAffixes`: route TALENT same as SPELLMOD; route CUSTOM to handler `OnEquip`/`OnUnequip`; `BuildAffixDisplayString`: handle TALENT format; add `DispatchSpellHit`, `DispatchSummon` |
| `src/CustomAffixHandlers.h` | Interface + registry declaration |
| `src/CustomAffixHandlers.cpp` | All concrete handler implementations (one class per custom affix) |
| `src/ItemAffixScripts.cpp` | Hook `OnAfterSpellCast` or per-spell `SpellScript` to call `DispatchSpellHit`; hook `OnSummon` for summon-count handlers |
| `data/sql/db-characters/item_affix.sql` | No change |
| `data/sql/db-world/affix_template.sql` | Add `custom_handler VARCHAR(64) NOT NULL DEFAULT ''` column |
| `affixes/talent_defs.json` | New file — all TALENT affix definitions |
| `affixes/custom_defs.json` | New file — all CUSTOM affix definitions |
| `build_affixes.ps1` | Handle `affix_type: 2` (TALENT), `affix_type: 3` (CUSTOM), `talent_display`, `custom_handler`, `value_per_rank` fields |
| `Interface/AddOns/ItemAffixes/ItemAffixes.lua` | Handle TALENT display in tooltip ("+N to [Talent Name]" line); no UI change needed for CUSTOM (display string from server is sufficient) |

---

## Implementation Sequence

### Phase 1: TALENT affixes (lower risk, high player value)
1. Add `affix_template.custom_handler` column (idempotent ALTER)
2. Add `AFFIX_TYPE_TALENT = 2` to enum; update `ApplyAffixes` to treat it same as SPELLMOD
3. Update `BuildAffixDisplayString` to format talent display string
4. Update `build_affixes.ps1` to handle `affix_type: 2`, `talent_display`, `value_per_rank`
5. Create `affixes/talent_defs.json` with first batch of 10–15 talent affixes
6. Run `update_affixes.bat`, test in-game display and stat effect

### Phase 2: CUSTOM affix infrastructure
1. Define `ICustomAffixHandler` interface + `CustomAffixRegistry` singleton
2. Wire `OnEquip`/`OnUnequip` dispatch in `ApplyAffixes`/`RemoveAffixes`
3. Add `_activeCustomAffixes` player cache; add `DispatchSpellHit` / `DispatchSummon`
4. Hook dispatch points in `ItemAffixScripts.cpp`
5. Update `build_affixes.ps1` for `affix_type: 3` + `custom_handler` field

### Phase 3: Individual custom handlers (one at a time)
Implement and test each handler independently:
1. `HOLY_FIRE_AOE` — low recursion risk, easy to validate
2. `WATER_ELEMENTAL_PERMANENT` — `OnEquip` aura apply; very low code
3. `FERAL_SPIRIT_DOUBLE` — summon hook; test recursion guard carefully
4. `VICTORY_RUSH_ALWAYS` — periodic trigger approach
5. Additional handlers as the affix library grows

---

## Open Questions

1. **Talent affixes: require ≥1 rank spent?** Add `"require_talent_rank": true` as an opt-in JSON flag per affix. Default: false (simpler). Re-evaluate after player feedback.

2. **Spell hook availability**: Verify that AzerothCore's `PlayerScript` exposes a usable post-hit hook, or whether we need per-spell `SpellScript` registration. If per-spell, the handler registry approach still works — each handler's `RegisterHook()` method registers a thin `SpellScript` for its target spells at startup.

3. **Custom handler → Addon display**: The server already sends display strings via `BuildAffixDisplayString`. CUSTOM affixes just need a display string template (e.g., `"Holy Fire — chain hits all enemies within 10m"`). The addon shows it verbatim; no new protocol needed.

4. **CUSTOM affix balance**: These are very powerful. Recommend `min_quality = 4` (purple/epic minimum) and low `weight` (3–5) for high-impact ones. AoE conversion / permanent summon should be unique-equipped (only one copy active at a time) — add a `unique_equipped: true` JSON flag and enforce server-side.

5. **Future: delivery via crafting vs. drops?** User noted custom affixes might use a different acquisition method. The module only needs to handle equip/unequip and display — acquisition can be a separate system that writes to `item_affix` directly with the chosen affix ID.
