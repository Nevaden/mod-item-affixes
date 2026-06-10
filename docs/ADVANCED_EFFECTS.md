# Advanced Affix Effects — Design Document

This document covers the architecture for affix effects that go beyond the passive
`SpellModifier` system (the current `effects[]` array).  Use it as a reference when
implementing proc-based, periodic, or environmental affix effects.

---

## Background: what the current system can and cannot do

The current system stores up to four `AffixEffect` slots per affix.  Each slot maps
directly to a `SpellModifier` that is added to the player on item equip and removed on
unequip.  `SpellModifier` adjusts a numeric property of a spell family (damage, cost,
cooldown, crit chance, duration, cast time) by a flat or percentage amount.

**Limitations of SpellModifier:**
- Passive only — no events, no counters, no geometry
- Cannot add cast time to instant spells (base cast = 0ms; modifier fires after the
  "is instant?" check in `Spell.cpp` and is never reached)
- Cannot target a second unit
- Cannot fire another spell
- Cannot apply a visual transform to the target

Everything below requires a new system: **AffixProc**.

---

## Concept: AffixProc

An `AffixProc` is an event-driven action attached to an affix definition.  Where
`AffixEffect` is "always on while equipped", an `AffixProc` is "fires when X happens".

```
AffixDefinition
├── effects[4]   — passive SpellModifier slots (existing)
└── procs[]      — event-driven action slots (new)
```

Each proc has three parts:

| Part | What it answers |
|------|-----------------|
| **Trigger** | When does this fire? (on spell cast, on spell hit, on tick, …) |
| **Condition** | Does it fire this time? (every Nth cast, X% chance, always) |
| **Action** | What happens? (cast a spell, splash damage, scale target, …) |

---

## Trigger types

| `trigger` | Fires when… | Hook in AzerothCore |
|-----------|-------------|---------------------|
| `ON_CAST` | Player successfully casts a matching spell | `OnPlayerSpellCast` / `PLAYERHOOK_ON_SPELL_CAST` |
| `ON_HIT` | A matching spell hits a unit | `OnSpellHitTarget` inside a `SpellScript` |
| `ON_PERIODIC` | N milliseconds have elapsed while item is equipped | `WorldScript::OnUpdate` or periodic aura |
| `ON_AURA_REMOVE` | A specific aura is removed from a unit | `OnAuraRemove` |

All trigger types except `ON_PERIODIC` carry a **trigger filter**: the same
`spell_family` + `spell_family_flags` combination used by `AffixEffect`.  A proc with
trigger filter `[family=6, flags=[128,0,0]]` fires only when Smite is cast/hits.

---

## Condition types

| `condition` | Behaviour |
|-------------|-----------|
| `ALWAYS` | Fires every time the trigger fires |
| `EVERY_N_CASTS` | Fires on the Nth trigger, resets counter; N stored in `condition_value` |
| `CHANCE_PCT` | Fires with `condition_value`% probability each trigger |

`EVERY_N_CASTS` requires per-player state (a counter keyed by affix ID).  Store it in
`ItemAffixPlayerData` alongside `activeMods`.  Reset counters on item unequip or logout.

---

## Action types

| `action` | What it does | Key parameters |
|----------|-------------|----------------|
| `CAST_SPELL` | Casts `action_spell_id` from the player | `action_spell_id`, `action_target` (SELF / MAIN_TARGET) |
| `CHAIN_DAMAGE` | Repeats the triggering spell's damage on N nearby hostiles | `action_radius` (yards), `action_target_count` |
| `SCALE_TARGET` | Multiplies the target's display scale | `action_scale_factor`, `action_revert_on_aura_remove` |
| `PERIODIC_CAST` | Autocasts `action_spell_id` from the player on a timer | `action_spell_id`, `action_interval_ms` |

---

## Concrete examples

### Every 3rd cast of Smite also casts Holy Fire

```
trigger:            ON_CAST
trigger_family:     6  (Priest)
trigger_flags:      [128, 0, 0]  (Smite)
condition:          EVERY_N_CASTS
condition_value:    3
action:             CAST_SPELL
action_spell_id:    48819  (Holy Fire rank 11 — or look up max rank at load time)
action_target:      MAIN_TARGET
```

Implementation notes:
- Increment a `castCount[affixId]` in `ItemAffixPlayerData` on every `ON_CAST` trigger.
- When `castCount % N == 0`, call `player->CastSpell(target, spellId, true)` (triggered
  flag = true so it bypasses GCD and mana cost).
- Reset the counter on item unequip so the rhythm restarts cleanly.

### Arcane Shot hits one additional hostile within 10 yards

```
trigger:            ON_HIT
trigger_family:     9  (Hunter)
trigger_flags:      [2048, 0, 0]  (Arcane Shot)
condition:          ALWAYS
action:             CHAIN_DAMAGE
action_radius:      10.0
action_target_count: 1
```

Implementation notes:
- In the `OnSpellHitTarget` hook, check if the caster has this affix equipped.
- Use `unit->GetNearbyEnemies(radius, count)` (or the equivalent
  `Cell::VisitGridObjects` call) to find hostiles near the original target.
- Deal damage via `caster->CastSpell(secondTarget, spellId, TRIGGERED_FULL_MASK)` to
  reuse the spell's hit/resist logic, **or** call `Unit::DealDamage` directly for a
  simpler flat value.
- Guard against chain: set a `noChain` flag or use `TRIGGERED_FULL_MASK` so the
  secondary hit does not itself trigger the proc.

### Holy Nova autocasts every 3 seconds while equipped

```
trigger:            ON_PERIODIC
condition:          ALWAYS
action:             PERIODIC_CAST
action_spell_id:    48278  (Holy Nova rank 9)
action_interval_ms: 3000
action_target:      SELF
```

Implementation notes (two options):

**Option A — WorldScript::OnUpdate**
In `ItemAffixScripts.cpp`, track `uint32 msSinceLastTick[playerGuid][affixId]` in a
map updated every `OnUpdate` call.  When threshold exceeded, cast the spell and reset.
Simple but adds work to every server tick for every online player with such an item.

**Option B — Dummy periodic aura (preferred)**
Create a serverside-only dummy spell (add a row to `spell_dbc` or use an existing
placeholder) with a periodic aura effect.  Apply it via `player->AddAura(spellId)`
when the item is equipped, remove it on unequip.  The aura's `OnEffectPeriodic` script
casts the real spell.  Cost: one custom spell entry in the DB.

### Polymorph target grows to 500% size

```
trigger:            ON_HIT
trigger_family:     3  (Mage)
trigger_flags:      [<polymorph flags>]
condition:          ALWAYS
action:             SCALE_TARGET
action_scale_factor: 5.0
action_revert_on_aura_remove: true  (aura = Polymorph aura ID)
```

Implementation notes:
- On `OnSpellHitTarget`, call `target->SetObjectScale(5.0f)` and
  `target->ForceValuesUpdateAtIndex(UNIT_FIELD_SCALE_X)`.
- To revert: register an `OnAuraRemove` hook watching for the Polymorph aura on the
  target; when it falls off (sheep breaks), call `target->SetObjectScale(1.0f)`.
- Gotcha: if the target polymorphs multiple times in a row, ensure the scale is not
  applied redundantly.

---

## Proposed DB schema

A separate table (not more columns on `affix_template`) keeps the schema clean:

```sql
CREATE TABLE IF NOT EXISTS `affix_proc` (
  `id`                  INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  `affix_id`            INT UNSIGNED     NOT NULL,  -- FK → affix_template.id

  -- Trigger
  `trigger_type`        TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `trigger_family`      INT UNSIGNED     NOT NULL DEFAULT 0,
  `trigger_flags0`      INT UNSIGNED     NOT NULL DEFAULT 0,
  `trigger_flags1`      INT UNSIGNED     NOT NULL DEFAULT 0,
  `trigger_flags2`      INT UNSIGNED     NOT NULL DEFAULT 0,

  -- Condition
  `condition_type`      TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `condition_value`     INT UNSIGNED     NOT NULL DEFAULT 0,

  -- Action
  `action_type`         TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `action_spell_id`     INT UNSIGNED     NOT NULL DEFAULT 0,
  `action_target`       TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `action_radius`       FLOAT            NOT NULL DEFAULT 0,
  `action_target_count` TINYINT UNSIGNED NOT NULL DEFAULT 1,
  `action_scale_factor` FLOAT            NOT NULL DEFAULT 1,
  `action_interval_ms`  INT UNSIGNED     NOT NULL DEFAULT 0,

  PRIMARY KEY (`id`),
  INDEX `idx_affix_id` (`affix_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## Proposed C++ structs

```cpp
enum AffixProcTrigger : uint8
{
    AFFIX_TRIGGER_NONE       = 0,
    AFFIX_TRIGGER_ON_CAST    = 1,
    AFFIX_TRIGGER_ON_HIT     = 2,
    AFFIX_TRIGGER_ON_PERIODIC = 3,
    AFFIX_TRIGGER_ON_AURA_REMOVE = 4,
};

enum AffixProcCondition : uint8
{
    AFFIX_COND_ALWAYS        = 0,
    AFFIX_COND_EVERY_N_CASTS = 1,
    AFFIX_COND_CHANCE_PCT    = 2,
};

enum AffixProcAction : uint8
{
    AFFIX_ACTION_NONE        = 0,
    AFFIX_ACTION_CAST_SPELL  = 1,
    AFFIX_ACTION_CHAIN_DAMAGE = 2,
    AFFIX_ACTION_SCALE_TARGET = 3,
    AFFIX_ACTION_PERIODIC_CAST = 4,
};

enum AffixProcTarget : uint8
{
    AFFIX_TARGET_SELF        = 0,
    AFFIX_TARGET_MAIN_TARGET = 1,
};

struct AffixProc
{
    uint32             affixId;
    AffixProcTrigger   trigger;
    uint32             triggerFamily;
    uint32             triggerFlags[3];
    AffixProcCondition condition;
    uint32             conditionValue;     // N for EVERY_N_CASTS, % for CHANCE_PCT
    AffixProcAction    action;
    uint32             actionSpellId;
    AffixProcTarget    actionTarget;
    float              actionRadius;
    uint32             actionTargetCount;
    float              actionScaleFactor;
    uint32             actionIntervalMs;
};
```

Add to `AffixDefinition`:
```cpp
std::vector<AffixProc> procs;
```

Add to `ItemAffixPlayerData` for stateful conditions:
```cpp
// [affixId] -> cast counter for EVERY_N_CASTS procs
std::unordered_map<uint32, uint32> procCastCounters;
// [affixId] -> ms elapsed for ON_PERIODIC procs
std::unordered_map<uint32, uint32> procTimers;
```

---

## Implementation order (recommended)

1. **`AFFIX_TRIGGER_ON_CAST` + `AFFIX_ACTION_CAST_SPELL` + `AFFIX_COND_EVERY_N_CASTS`**
   The Nth-cast pattern. Needs: new DB table, struct loading in `LoadAffixTemplates`,
   cast counter in `ItemAffixPlayerData`, one new hook (`PLAYERHOOK_ON_SPELL_CAST`).
   Covers: "every 3rd Smite fires Holy Fire."

2. **`AFFIX_TRIGGER_ON_HIT` + `AFFIX_ACTION_CHAIN_DAMAGE`**
   Needs: a `SpellScript` shim that calls back into the module, or a
   `PLAYERHOOK_ON_SPELL_HIT_TARGET` if one exists.
   Covers: "Arcane Shot chains to a nearby target."

3. **`AFFIX_TRIGGER_ON_PERIODIC` + `AFFIX_ACTION_PERIODIC_CAST`**
   Needs: WorldScript::OnUpdate accumulator, or dummy-aura approach.
   Covers: "Holy Nova autocasts every 3 seconds."

4. **`AFFIX_ACTION_SCALE_TARGET` + `AFFIX_TRIGGER_ON_AURA_REMOVE`**
   Covers: visual mutations like the Polymorph size effect.

---

## Notes and gotchas

- **Triggered spell flag**: always use `TRIGGERED_FULL_MASK` (or `true` in the
  two-arg `CastSpell` overload) for proc-fired spells so they bypass GCD, mana cost,
  and do not proc further procs recursively.
- **Counter persistence**: `EVERY_N_CASTS` counters live in `ItemAffixPlayerData`
  which is transient (session only).  Counters reset on logout / server restart.
  This is intentional — persisting them to DB adds complexity for minimal gain.
- **Instant-spell cast time**: `SPELLMOD_CASTING_TIME` FLAT cannot add cast time to
  spells with a base cast time of 0ms (instant).  The engine marks the spell instant
  before the modifier is evaluated.  Use `COST` or `COOLDOWN` as a penalty on instant
  spells instead.
- **Scale revert**: `SetObjectScale` persists on the unit; always pair a scale-up with
  a guaranteed revert path (aura remove hook or session end hook).
