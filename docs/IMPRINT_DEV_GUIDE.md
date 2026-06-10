# Imprint Development Guide

Reference for implementing new Imprint abilities. Each section covers a reusable pattern with the exact code and SQL required, plus the gotchas we hit during development.

---

## Checklist for every new Imprint

1. Add `IMPRINT_YOUR_NAME = N` to the `ImprintId` enum in `src/Imprints/ImprintMgr.h`
2. Create `src/Imprints/[Class]/YourAbility.cpp`
   - 2a. Override `SpellTooltipOverrides()` to return `{ spellId, "one-line description" }` for each spell the imprint affects. See **Spell Tooltip Descriptions** below.
3. Add `void RegisterYourAbilityImprint();` + call in `src/mod_item_affixes_loader.cpp`
4. Add `spell_script_names` row to `data/sql/db-world/spell_script_names_imprint.sql` if the trigger spell is not already hooked
5. Add a `SpellScript` class + `RegisterSpellScript(...)` call in `src/ItemAffixScripts.cpp` (same pattern as `spell_divine_storm_imprint`) if new spell
6. Add imprint row to `data/sql/db-world/imprint_def.sql`
7. Add any creature SQL files if new creature entries are needed

---

## Spell Tooltip Descriptions

Every `ImprintEffect` should override `SpellTooltipOverrides()` to supply the gold
description appended to the spell's tooltip in the spellbook and on action bars.

### Method signature

```cpp
std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
{
    return {{ SPELL_YOUR_SPELL,
        "One sentence describing what the imprint does when this spell is cast." }};
}
```

Return `{}` if the imprint has no spell button visible to the player (e.g. a passive stat bonus).

### How it reaches the client

1. The server sends `IMPRINT_DESC_CLEAR` then `IMPRINT_DESC|spellId|text` in response to every `ALLDATA` message from the addon (triggered on login and `/reload`).
2. Also re-sent on every `SyncImprints` call (equip/unequip).
3. The addon hooks `GameTooltip:OnShow`, reads the first tooltip line (the spell name WoW already placed there), looks up `imprintDescByName[name]`, and appends the gold `[Imprint] …` line. This works for Bartender4 and standard Blizzard bars without any action-slot numbering.

### Current imprints reference

| Imprint | Spell ID | Description |
|---|---|---|
| Righteous Sanctuary | 53595 | `"A strong Consecration is automatically placed at your feet after casting."` |
| Empyrean Echo | 53385 | `"Your strike echoes outward - Divine Storm fires from 4 positions around you 0.5s after cast, each at 75% effectiveness."` |
| Feral Spirit: Stampede | 51533 | `"Calls a stampede of 10 Spirit Rhinos to your side for 30 sec. Each fights at 50% effectiveness and periodically stomps, charges, or roars."` |
| Feral Spirit: Alpha | 51533 | `"Summons an Alpha Spirit Wolf as your permanent companion. Fights at full effectiveness until dismissed or killed."` |
| Celestial Resonance | 600002 | `"Applies a resonant mark to the target for 8 sec. While active, Holy Nova erupts at the target's position every second."` |
| Vanishing Backstab | 600003 | `"Shadowstep behind your target and immediately unleash Backstab."` |
| The Rime Zone | 600004 | `"Activate to summon a frost storm at your feet — chills all enemies within 8 yards once per second. Click again to deactivate."` |

**Shared trigger spell:** Both Feral Spirit variants override spell 51533 with different text. Only one rune can be equipped at a time, so there is no conflict.

---

## Pattern A — Secondary Cast on Trigger (Righteous Sanctuary example) | secondary, trigger, cast, free, proc, on-cast

**Use when:** the imprint fires a secondary spell automatically whenever the player casts a specific trigger spell — e.g. a free Consecration on every Hammer of the Righteous.

### How it works

- `OnEquip` / `OnUnequip`: nothing required (no spell to learn or remove)
- `OnSpellAfterCast`: check `spellInfo->Id == SPELL_TRIGGER`, then cast the secondary spell
- Walk the spell rank chain with `sSpellMgr->GetNextSpellInChain` to always cast the highest rank the player knows
- Save and restore the secondary spell's cooldown so the player's own rotation is unaffected

### Cooldown save/restore for secondary spells (Righteous Sanctuary)

```cpp
// Save the current remaining cooldown before casting the secondary spell
uint32 prevCdDelay = 0;
if (player->HasSpellCooldown(consecId))
{
    auto& cdMap = player->GetSpellCooldownMap();
    auto it = cdMap.find(consecId);
    if (it != cdMap.end())
        prevCdDelay = uint32(it->second.end - GameTime::GetGameTimeMS().count());
}

// Cast with no GCD and no CD check
player->CastSpell(player, consecId,
    TriggerCastFlags(TRIGGERED_IGNORE_GCD |
                     TRIGGERED_IGNORE_SPELL_AND_CATEGORY_CD |
                     TRIGGERED_CAST_DIRECTLY));

// Restore the saved cooldown so the player's own Consecration is untouched
player->RemoveSpellCooldown(consecId, true);          // true = notify client
if (prevCdDelay > 0)
    player->AddSpellCooldown(consecId, 0, prevCdDelay, true); // duration in ms, NOT timestamp
```

**Gotcha:** `AddSpellCooldown` 3rd parameter is a **duration in ms**, not an absolute timestamp. Passing `getMSTime() + delay` (absolute) will set a multi-year cooldown.

### Optional: adding SpellMod modifications

If you also want to change the trigger spell's damage, cost, or cast time (not just fire a secondary spell), use `SpellModifier` objects in `OnEquip`:

- `OnEquip`: allocate `SpellModifier` objects and call `player->AddSpellMod()`
- `OnUnequip`: `SyncImprints` automatically calls `RemoveImprintMods` which cleans up tracked mods
- Track mods with `sImprintMgr->TrackImprintMod(player, itemGuid, mod)`

| Op constant | Effect |
|---|---|
| `SPELLMOD_DAMAGE` (0) | % or flat damage bonus |
| `SPELLMOD_CASTING_TIME` (10) | flat ms added to cast time |
| `SPELLMOD_COST` (11) | rage/mana cost change (rage × 10 internally) |

`SPELLMOD_FLAT` (type 107) = flat value. `SPELLMOD_PCT` (type 108) = percentage.

**Core patches required for SpellMods on instant-cast abilities:** See `CORE_PATCHES.md`. Three layered patches in `SpellInfo.cpp` and `Player.cpp` are needed to make `SPELLMOD_CASTING_TIME` work on spells with `CastingTimeIndex = 0`.

---

## Pattern B — Delayed Positional Summons (Empyrean Echo example) | echo, positional, summon, aoe, trigger, delayed

**Use when:** the ability spawns invisible trigger creatures at world positions that each cast a spell, creating an "echo" or "mirror" effect.

### How it works

1. `OnSpellAfterCast` schedules a `BasicEvent` (500 ms delay)
2. The event spawns `TempSummon` creatures at offset positions around the player
3. Each summon calls `CastSpell` passing the **player's GUID as `originalCaster`** — this is what makes damage, threat, and kill credit appear on the player

```cpp
// 4 echo positions at 90° intervals from the caster's facing
float o = caster->GetOrientation();
for (int i = 0; i < 4; ++i)
{
    float angle = o + float(i) * (float(M_PI) * 0.5f);
    float x = caster->GetPositionX() + OFFSET * std::cos(angle);
    float y = caster->GetPositionY() + OFFSET * std::sin(angle);

    TempSummon* echo = caster->SummonCreature(
        CREATURE_ECHO, x, y, z, angle,
        TEMPSUMMON_TIMED_DESPAWN, LIFETIME_MS);

    if (!echo) continue;

    echo->SetFaction(caster->GetFaction());
    // Do NOT call SetLevel — causes level-up visual animation.
    // Set template minlevel=maxlevel=80 in SQL instead.

    // Pass player GUID as 6th argument = originalCaster.
    // Damage, threat, and kill credit go to the player, not the echo creature.
    // Being a Creature (not Player), the SpellScript's ToPlayer() guard prevents
    // this cast from re-triggering the Imprint.
    echo->CastSpell(echo, SPELL_TO_CAST,
        TriggerCastFlags(TRIGGERED_FULL_MASK),
        nullptr, nullptr, caster->GetGUID());
}
```

### Damage attribution — key rule

> Always pass `caster->GetGUID()` as the 6th argument to `CastSpell` on a non-player summon.
> Without it, the creature is the originalCaster and all damage/kills are credited to it.

### Creature SQL for echo/trigger units

```sql
INSERT INTO creature_template (..., unit_flags, flags_extra, ...)
VALUES (...,
    0x02000002,  -- NON_ATTACKABLE | NOT_SELECTABLE
    0x82,        -- TRIGGER (0x80) | CIVILIAN (0x02) — won't engage combat
    ...);

-- Use the Invisible Stalker display (11686) — renders nothing on the client
INSERT INTO creature_template_model VALUES (entry, 0, 11686, 1.0, 1.0);
```

### Copy player weapon/AP stats onto the summon

```cpp
static void CopyPlayerStats(Player* src, TempSummon* dst, float scale = 1.0f)
{
    float minDmg = src->GetWeaponDamageRange(BASE_ATTACK, MINDAMAGE) * scale;
    float maxDmg = src->GetWeaponDamageRange(BASE_ATTACK, MAXDAMAGE) * scale;
    dst->SetBaseWeaponDamage(BASE_ATTACK, MINDAMAGE, minDmg);
    dst->SetBaseWeaponDamage(BASE_ATTACK, MAXDAMAGE, maxDmg);

    float ap = src->GetTotalAttackPowerValue(BASE_ATTACK) * scale;
    dst->SetStatFlatModifier(UNIT_MOD_ATTACK_POWER, BASE_VALUE, ap);
    dst->UpdateAttackPowerAndDamage();
    // Do NOT call SetLevel — use correct level in creature_template SQL instead
}
```

---

## Pattern C — Temporary Guardian Pets (Feral Spirit: Stampede example) | pet, guardian, minion, pack, temporary, combat

**Use when:** you want a pack of short-lived combat pets that follow the player, attack the player's target, and appear in the pet control bar.

### The key ingredient: SummonPropertiesEntry

The Feral Spirit spell creates its wolves as `Guardian` objects because it uses a specific `SummonPropertiesEntry` from the DBC. When we intercept the cast and spawn our own creatures, we must pass the **same properties** — otherwise the creatures are plain `TempSummon` objects with no guardian behaviour.

```cpp
// 1. Collect the wolves the spell just spawned BEFORE doing anything else.
auto existing = FindControlled(player, CREATURE_SPIRIT_WOLF);

// 2. Save properties — m_Properties points to static DBC data, always valid.
SummonPropertiesEntry const* guardianProps =
    !existing.empty() ? existing[0]->m_Properties : nullptr;

// 3. Unsummon the original wolves.
for (TempSummon* wolf : existing)
    wolf->UnSummon();

// 4. Spawn our custom creatures with the guardian properties.
//    This makes each one a Guardian class instance:
//    → appears in pet control bar
//    → follow movement maintained by the engine
//    → kill credit attributed to the player
//    → damage attributed to the player
TempSummon* rhino = caster->SummonCreature(
    CREATURE_STAMPEDE_RHINO,
    x, y, z, angle,
    TEMPSUMMON_TIMED_DESPAWN, DURATION_MS,
    guardianProps);          // <— the crucial argument
```

### After spawning, apply overrides

```cpp
rhino->SetLevel(caster->GetLevel(), false);  // false = no level-up visual animation
rhino->SetObjectScale(0.5f);                 // 50 % size
ScaleStats(caster, rhino, 0.5f);             // 50 % weapon/AP
// SetFaction is not needed — the guardian setup inherits the owner's faction
```

**Gotcha:** `SetLevel(level, true)` (default) sends a level-change packet to the client which plays a level-up animation on the creature. Always pass `false` for programmatic level setting.

### Controlling spell cooldowns

If the creature needs timed spell casts, use a **`CreatureScript`** rather than `creature_template_spell`. `PetAI` reads from `creature_template_spell` but spams spells with zero cooldown if the DBC `RecoveryTime` is 0.

```cpp
struct npc_your_petAI : public ScriptedAI
{
    uint32 _stompTimer;

    void Reset() override
    {
        _stompTimer = urand(2000, 5000); // stagger so 10 pets don't all cast at once
    }

    void UpdateAI(uint32 diff) override
    {
        // Guardian attack behaviour: follow owner into combat
        if (!me->IsInCombat())
        {
            if (Unit* owner = me->GetCharmerOrOwner())
                if (Unit* target = owner->GetVictim())
                    AttackStart(target);
            return;
        }

        if (!UpdateVictim()) return;

        if (_stompTimer <= diff)
        {
            me->CastSpell(me, SPELL_STOMP, false);   // AoE around self
            _stompTimer = 8000 + urand(0, 2000);
        }
        else _stompTimer -= diff;

        DoMeleeAttackIfReady();
    }
};
```

**Note:** With `ScriptedAI`, abilities do NOT appear in the pet control bar. If you want them in the bar, use empty `AIName` + `creature_template_spell`. If the creature only lives 30 s and the bar display doesn't matter, `ScriptedAI` is the right choice.

**Note:** With `ScriptedAI` the follow movement is still maintained because the guardian *class* (set by `guardianProps`) handles movement separately from AI logic.

### Cleanup on unequip

```cpp
void OnUnequip(Player* player, uint64 /*itemGuid*/) override
{
    for (TempSummon* pet : FindControlled(player, CREATURE_YOUR_PET))
        pet->UnSummon();
}

// Helper: collect all TempSummons of a given entry under the player's control
static std::vector<TempSummon*> FindControlled(Player* player, uint32 entry)
{
    std::vector<TempSummon*> result;
    for (Unit* ctrl : player->m_Controlled)
    {
        Creature* c = ctrl->ToCreature();
        if (!c || c->GetEntry() != entry) continue;
        if (TempSummon* ts = c->ToTempSummon())
            result.push_back(ts);
    }
    return result;
}
```

### Fear immunity (creature SQL)

```sql
-- creature_immunities.ID = 95 already exists: MechanicsMask=32 = bit MECHANIC_FEAR (1<<5)
INSERT INTO creature_template (..., CreatureImmunitiesId, ...)
VALUES (..., 95, ...);
```

### Feral Spirit: Stampede — specific spell notes

| Slot | Spell ID | Name | Cast by | Cooldown |
|---|---|---|---|---|
| 0 | 55663 | Deafening Roar | Drakkari Rhino (Zul'Drak) | 12–15 s (script) |
| 1 | 55193 | Rhino Charge | Ice Steppe Rhino (Northrend) | 20–25 s (script) |
| 2 | 51493 | Stomp | Dark Rune Giant (Ulduar) | 8–10 s (script) |

All three are native creature spells with no class/stance requirements. They were found by querying `smart_scripts` for large Northrend creatures.

---

## Pattern D — Permanent Guardian Pet (Feral Spirit: Alpha example) | pet, guardian, minion, companion, persistent, single

**Use when:** you want a single powerful companion that persists until it dies or is dismissed.

### Differences from Pattern C

- Use `TEMPSUMMON_DEAD_DESPAWN, 0` — persists until the creature dies; no timer
- Store the GUID in `ItemAffixPlayerData` for cleanup on unequip:

```cpp
// In ItemAffix.h, inside ItemAffixPlayerData:
ObjectGuid feralAlphaWolfGuid;

// After spawning:
auto* data = caster->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixPlayerData");
data->feralAlphaWolfGuid = alpha->GetGUID();

// In OnUnequip:
auto* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixPlayerData");
if (!data->feralAlphaWolfGuid.IsEmpty())
{
    if (Creature* pet = ObjectAccessor::GetCreature(*player, data->feralAlphaWolfGuid))
        pet->ToTempSummon()->UnSummon();
    data->feralAlphaWolfGuid.Clear();
}
```

- On re-cast (player casts the base spell again), dismiss the old permanent pet first:

```cpp
// The event collects ALL existing wolves/pets by entry, saving props from the first one,
// then unsummons them all before spawning a single new one.
auto existing = FindControlled(caster, CREATURE_SPIRIT_WOLF);
SummonPropertiesEntry const* wolfProps = !existing.empty() ? existing[0]->m_Properties : nullptr;
for (TempSummon* wolf : existing)
    wolf->UnSummon();
// (also catches any still-living alpha from a previous cast)
```

---

## Pattern E — Targeted Periodic Aura (Celestial Resonance example) | aura, periodic, castable, spellbook, tracking, beacon, enemy, ally

**Use when:** you want a spell the player casts themselves (appears in spellbook, has a cast time)
that applies a lasting aura to any unit (ally or enemy), where each periodic tick fires a positional
effect at the target's CURRENT position — tracking movement over the aura's duration.

Key distinction from Pattern B: the effect repeats every N seconds and follows a moving target.
Pattern B fires a single burst of fixed-position summons immediately after one spell cast.

### How it works

1. Player equips item → `learnSpell` → spell appears in spellbook
2. Player casts the spell on any target (1500 ms cast time)
3. `SPELL_AURA_PERIODIC_DUMMY` applied to the target, lasts 8 s, ticks every 1 s
4. Each tick: `HandlePeriodic` spawns a short-lived TempSummon at the target's current position
5. The summon casts the real AoE spell attributed to the player via `originalCaster` GUID
6. Player unequips item → `removeSpell` → spell removed from spellbook

### ImprintEffect

```cpp
void OnEquip(Player* player, uint64 /*itemGuid*/) override
{
    player->learnSpell(SPELL_CELESTIAL_RESONANCE, false);
}

void OnUnequip(Player* player, uint64 /*itemGuid*/) override
{
    // SPEC_MASK_ALL (255) is required. Passing 0 or false for removeSpecMask is a silent no-op.
    player->removeSpell(SPELL_CELESTIAL_RESONANCE, SPEC_MASK_ALL, false);
}

void OnSpellAfterCast(Player* /*caster*/, SpellInfo const* /*spellInfo*/) override {}
```

**Gotcha:** `removeSpell` signature is `(uint32 spellId, uint8 removeSpecMask, bool onlyTemporary)`.
`SPEC_MASK_ALL = 255` is defined in `Player.h`. Passing `false` for `removeSpecMask` silently
becomes 0 — "remove from no specs" — and the spell stays in the spellbook.

### Custom spell: server + client both required

This pattern is unique in that the spell must exist in two places:

**Server (`spell_dbc`):** so the server knows effect, duration, and targeting. No `spell_script_names`
row is needed — the AuraScript is registered directly via `RegisterSpellScript`.

**Client (Spell.dbc inside patch-z.MPQ):** so the spell renders in the spellbook with the correct
icon, name, and description. A matching `SkillLineAbility.dbc` entry in the same MPQ assigns it to
the correct spellbook tab (skill line 594 = Priest Holy tree tab).

Run `tools/patch_custom_spells.ps1` whenever spell data changes (add the spell to `custom_spells.json` first), then replace the client MPQ files:

```powershell
cd "modules/mod-item-affixes/tools"
powershell -ExecutionPolicy Bypass -File .\patch_custom_spells.ps1
# Outputs: WoW HD\data\patch-z.MPQ and WoW HD\data\enus\patch-enUS-z.MPQ
# Also run patch_spell_dbc_custom.ps1 for the loose DBFilesClient override (dev convenience)
powershell -ExecutionPolicy Bypass -File .\patch_spell_dbc_custom.ps1
```

**Critical `spell_dbc` fields:**

| Field | Value | Notes |
|---|---|---|
| `EquippedItemClass` | -1 | **Required.** Default 0 = "requires item class 0 equipped" → `SPELL_FAILED_EQUIPPED_ITEM_CLASS` |
| `Effect_1` | 6 | `SPELL_EFFECT_APPLY_AURA` |
| `EffectAura_1` | 226 | `SPELL_AURA_PERIODIC_DUMMY` |
| `EffectAuraPeriod_1` | 1000 | tick interval ms |
| `ImplicitTargetA_1` | 25 | `TARGET_UNIT_TARGET_ANY` — ally + enemy. Use 21 (`TARGET_UNIT_TARGET_ALLY`) to allow normal self-recast at the cost of enemy targeting |
| `DurationIndex` | 31 | 8000 ms |
| `CastingTimeIndex` | 16 | 1500 ms |
| `Targets` | 2 | `TARGET_FLAG_UNIT` |

### AuraScript

```cpp
class spell_celestial_resonance : public AuraScript
{
    PrepareAuraScript(spell_celestial_resonance);

    void HandlePeriodic(AuraEffect const* /*aurEff*/)
    {
        Unit* target = GetTarget();
        if (!target)
            return;

        // GetCaster() returns nullptr if the caster logged out mid-aura — always guard.
        Unit* casterUnit = GetCaster();
        Player* player = casterUnit ? casterUnit->ToPlayer() : nullptr;
        if (!player)
            return;

        // Abort silently if the rune was unequipped while the aura is still running.
        if (!sImprintMgr->HasImprintEquipped(player, IMPRINT_CELESTIAL_RESONANCE))
            return;

        // Spawn at the target's CURRENT position — intentionally tracks movement.
        TempSummon* beacon = player->SummonCreature(
            CREATURE_HOLY_NOVA_BEACON,
            target->GetPositionX(), target->GetPositionY(), target->GetPositionZ(),
            0.0f, TEMPSUMMON_TIMED_DESPAWN, 500);

        if (!beacon)
            return;

        beacon->SetFaction(player->GetFaction());

        // Pass player GUID as originalCaster → damage/healing attributed to the player.
        beacon->CastSpell(beacon, SPELL_HOLY_NOVA_R9,
            TriggerCastFlags(TRIGGERED_FULL_MASK),
            nullptr, nullptr, player->GetGUID());
    }

    void Register() override
    {
        OnEffectPeriodic += AuraEffectPeriodicFn(
            spell_celestial_resonance::HandlePeriodic, EFFECT_0, SPELL_AURA_PERIODIC_DUMMY);
    }
};
```

No SpellScript is needed. `OnSpellAfterCast` in the ImprintEffect stays empty `{}`.

### Beacon creature SQL

Same invisible-trigger pattern as Pattern B:

```sql
-- unit_flags: 0x02000002 = NON_ATTACKABLE | NOT_SELECTABLE
-- flags_extra: 0x82 = TRIGGER | CIVILIAN (won't pull aggro)
-- display: 11686 = Invisible Stalker (renders nothing)
-- minlevel/maxlevel: 80 (avoids needing SetLevel on the summon)
-- lifetime: 500 ms is sufficient — creature despawns after the cast fires
```

### Self-cast toggle behavior (known limitation)

`TARGET_UNIT_TARGET_ANY` (25) lets the spell target both allies and enemies. However, the WoW
3.3.5a client sends `CMSG_CANCEL_AURA` instead of initiating a new cast when you click the spell
button while the buff is already active on yourself. Standard buffs (Fortitude, PW:Shield) use
`TARGET_UNIT_TARGET_ALLY` (21), which avoids this.

Accepted trade-off: ally + enemy targeting is the primary use case for this ability. Self-recast
behaviour is left as-is rather than restricting to ally-only targets.

### Gotchas

| Problem | Cause | Fix |
|---|---|---|
| "Must have a %s equipped" on cast | `EquippedItemClass` defaults to 0 | Set to -1 in `spell_dbc` |
| Spell not removed on unequip | `removeSpell(id, false, false)` — second arg coerces to 0 | Use `removeSpell(id, SPEC_MASK_ALL, false)` |
| Spell in wrong spellbook tab | No `SkillLineAbility.dbc` entry in MPQ | Add entry with SkillLine 594 (Priest Holy tree); re-run patch script |
| Spell unknown to client (no icon/name) | `Spell.dbc` not patched in client MPQ | Re-run `patch_mpq_spells.ps1`, replace client MPQ files |
| Damage not credited to player | No `originalCaster` on beacon's `CastSpell` | Pass `player->GetGUID()` as the 6th argument |
| `GetCaster()` nullptr crash | Caster logged out while aura is active on target | Always null-check before dereferencing |

---

## Pattern F — Combat-Safe Trigger Spell (Vanishing Backstab example) | teleport, gap-close, stealth, opener, combat, engagement, self-cast

**Use when:** the imprint grants an active ability that fires a secondary spell at an enemy
(e.g. Shadowstep then Backstab), but must NOT cause the enemy to enter combat if the cast
is pressed while out of range or if the secondary spell fails for any reason.

### The problem

A DUMMY spell with `ImplicitTargetA = TARGET_UNIT_TARGET_ENEMY` (6) hits the enemy.
`Unit::SpellHitTarget` calls `EngageWithTarget` for any non-positive spell that touches a
hostile unit — even a pure DUMMY with no damage. The mob runs toward the player the
instant the button is pressed, before any Shadowstep or Backstab fires.

### The fix: self-cast trigger

Set `ImplicitTargetA = TARGET_UNIT_CASTER` (1) in `spell_dbc`. The server resolves the
DUMMY effect onto the caster — the enemy is never touched, so `EngageWithTarget` is never
called. The SpellScript reads the selected target via `caster->GetTarget()` instead.

```sql
-- spell_dbc key fields for a self-cast trigger:
ImplicitTargetA_1 = 1,   -- TARGET_UNIT_CASTER: server resolves onto caster
Targets           = 2,   -- TARGET_FLAG_UNIT: client checks range against selected target
RangeIndex        = 34,  -- must match the range of the triggered ability (Shadowstep = 25 yd)
```

**Why keep `Targets=2` on a self-cast:** With `Targets=0` the client never performs a
range check and the spell button is always lit. With `Targets=2` the client sends the
selected unit's GUID and grays the button when the unit is outside `RangeIndex`.

### OnCheckCast for server-side range enforcement

The client grayout is not 100% reliable for all cases. Add `OnCheckCast` as a
server-side guard matching the triggered ability's exact range:

```cpp
static constexpr float TRIGGERED_ABILITY_RANGE = 25.0f;  // Shadowstep's range

SpellCastResult CheckRange()
{
    Player* caster = GetCaster()->ToPlayer();
    if (!caster)
        return SPELL_FAILED_DONT_REPORT;

    Unit* target = ObjectAccessor::GetUnit(*caster, caster->GetTarget());
    if (!target || !target->IsAlive())
        return SPELL_FAILED_BAD_TARGETS;

    if (!caster->IsWithinDistInMap(target, TRIGGERED_ABILITY_RANGE))
        return SPELL_FAILED_OUT_OF_RANGE;

    return SPELL_CAST_OK;
}
```

### Getting the target in AfterCast

With a self-cast trigger, `OnHitTarget` never fires on the enemy.
Read the selected target directly from the caster:

```cpp
void HandleAfterCast()
{
    Player* caster = GetCaster()->ToPlayer();
    if (!caster) return;

    if (!sImprintMgr->HasImprintEquipped(caster, IMPRINT_YOUR_ID))
        return;

    Unit* target = ObjectAccessor::GetUnit(*caster, caster->GetTarget());
    if (!target || !target->IsAlive()) return;

    caster->CastSpell(target, SPELL_SHADOWSTEP_ID, TRIGGERED_FULL_MASK);

    caster->m_Events.AddEventAtOffset(
        new YourDeferredEvent(caster->GetGUID(), target->GetGUID()),
        Milliseconds(250));
}
```

### TRIGGERED_FULL_MASK does NOT bypass range or behind-target checks

Two checks in `Spell::CheckCast` are **unconditional** — no trigger flag skips them:

**Range check (`CheckRange`):** The caster's distance to the target is always verified.
For a player teleporting via Shadowstep: `Unit::NearTeleportTo` for players is async
(requires a client ack of the teleport packet). Firing Backstab inline means
`CheckRange` sees the pre-teleport distance and returns `SPELL_FAILED_OUT_OF_RANGE`.

**Fix:** Defer the secondary cast by ~250 ms to allow the client round-trip:

```cpp
struct YourDeferredEvent : public BasicEvent
{
    ObjectGuid _playerGuid;
    ObjectGuid _targetGuid;

    YourDeferredEvent(ObjectGuid playerGuid, ObjectGuid targetGuid)
        : _playerGuid(playerGuid), _targetGuid(targetGuid) {}

    bool Execute(uint64 /*e_time*/, uint32 /*p_time*/) override
    {
        Player* player = ObjectAccessor::FindPlayer(_playerGuid);
        if (!player || !player->IsAlive()) return true;

        Unit* target = ObjectAccessor::GetUnit(*player, _targetGuid);
        if (!target || !target->IsAlive()) return true;

        // Orient target away so behind-arc check passes unconditionally.
        target->SetOrientation(target->GetAngle(player) + float(M_PI));
        player->CastSpell(target, SPELL_YOUR_SECONDARY, TRIGGERED_FULL_MASK);
        return true;
    }
};
```

**Behind-target check (`HasInArc`):** Backstab requires the caster to be in the 180-degree
arc behind the target. This check also runs unconditionally. Fix: call `SetOrientation` on
the target immediately before `CastSpell`. `SetOrientation` writes directly to
`m_orientation`; `HasInArc` reads it synchronously.

```cpp
// In the deferred event's Execute(), just before CastSpell:
target->SetOrientation(target->GetAngle(player) + float(M_PI));
player->CastSpell(target, SPELL_BACKSTAB, TRIGGERED_FULL_MASK);
```

### Register() hookup

```cpp
void Register() override
{
    OnCheckCast += SpellCheckCastFn(YourScript::CheckRange);
    AfterCast   += SpellCastFn(YourScript::HandleAfterCast);
}
```

No `OnEffectHitTarget` line needed — the trigger is self-cast.

### Gotchas

| Problem | Cause | Fix |
|---|---|---|
| Mob enters combat on keypress | `ImplicitTargetA=6` (enemy) hits unit → `EngageWithTarget` | Use `ImplicitTargetA=1` (self-cast) |
| Button always lit, ignores range | `Targets=0` — client skips range check | Set `Targets=2` (TARGET_FLAG_UNIT) so client checks `RangeIndex` |
| Wrong range shown in tooltip | `RangeIndex` doesn't match triggered ability | Look up `RangeIndex` from Spell.dbc field 46 for the triggered spell |
| Backstab fails out of range (opener) | Player position not committed after Shadowstep | Defer secondary cast ~250 ms via `BasicEvent` |
| Backstab fails behind check | `HasInArc` is unconditional even for TRIGGERED | `SetOrientation(angle + M_PI)` on target before `CastSpell` |
| Target not found in AfterCast | Used `OnHitTarget` to capture GUID, but that never fires on self-cast | Use `caster->GetTarget()` in `HandleAfterCast` instead |

---

## Pattern G — Two-Spell Toggle Aura (The Rime Zone example) | toggle, aura, periodic, frost, mage, two-spell, button, on-off

**Use when:** the imprint grants a player-controlled toggle button (visible in spellbook)
that, when active, applies a persistent aura doing periodic work. The player clicks the
button to turn the effect on and clicks again to turn it off.

### Why two spells are required

`Player::learnSpell` silently ignores spells whose first effect is not `SPELL_EFFECT_DUMMY`
or `SPELL_EFFECT_SKILL` — it returns without sending `SMSG_LEARNED_SPELL`, so the player
never sees "You have learned a new spell" and the spell never appears in the spellbook.

Use two cooperating spells:

| Spell | Effect | How applied | Player sees it? |
|---|---|---|---|
| BTN (600004) | SPELL_EFFECT_DUMMY | `learnSpell()` on equip | Yes — spellbook button |
| AURA (600005) | SPELL_EFFECT_APPLY_AURA + PERIODIC_DUMMY | triggered `CastSpell()` in SpellScript | Yes — buff bar only |

Additionally, both spells must exist in the **client's** Spell.dbc or the client silently
drops the `SMSG_LEARNED_SPELL` packet. See "Client DBC requirement" below.

### ImprintEffect

```cpp
static constexpr uint32 SPELL_RIME_ZONE_BTN  = 600004;   // DUMMY button, learned
static constexpr uint32 SPELL_RIME_ZONE_AURA = 600005;   // APPLY_AURA, not learned

void OnEquip(Player* player, uint64 /*itemGuid*/) override
{
    player->learnSpell(SPELL_RIME_ZONE_BTN, false);
}

void OnUnequip(Player* player, uint64 /*itemGuid*/) override
{
    player->RemoveAurasDueToSpell(SPELL_RIME_ZONE_AURA);
    player->removeSpell(SPELL_RIME_ZONE_BTN, SPEC_MASK_ALL, false);
}
```

### SpellScript on the DUMMY button — toggle logic

```cpp
SpellCastResult CheckCast()
{
    Player* caster = GetCaster()->ToPlayer();
    if (!caster)
        return SPELL_FAILED_DONT_REPORT;

    if (!sImprintMgr->HasImprintEquipped(caster, IMPRINT_RIME_ZONE))
        return SPELL_FAILED_DONT_REPORT;

    // Toggle OFF: aura is running — remove it and cancel the cast silently.
    if (caster->HasAura(SPELL_RIME_ZONE_AURA))
    {
        caster->RemoveAurasDueToSpell(SPELL_RIME_ZONE_AURA);
        return SPELL_FAILED_DONT_REPORT;   // AfterCast is skipped — aura NOT re-applied
    }

    return SPELL_CAST_OK;  // Toggle ON — AfterCast will apply the aura
}

void HandleAfterCast()
{
    Player* caster = GetCaster()->ToPlayer();
    if (!caster) return;
    caster->CastSpell(caster, SPELL_RIME_ZONE_AURA, true);  // triggered: no GCD, no cost
}

void Register() override
{
    OnCheckCast += SpellCheckCastFn(spell_rime_zone_cast::CheckCast);
    AfterCast   += SpellCastFn(spell_rime_zone_cast::HandleAfterCast);
}
```

**Toggle pattern:** `CheckCast` handles the off case (remove aura + `SPELL_FAILED_DONT_REPORT`).
`FAILED_DONT_REPORT` prevents `AfterCast` from running, so the aura is not re-applied.
Do NOT duplicate the off logic in `AfterCast`.

### AuraScript on the APPLY_AURA spell — periodic work

```cpp
void HandlePeriodic(AuraEffect const* /*aurEff*/)
{
    Unit* casterUnit = GetCaster();
    if (!casterUnit) return;
    Player* player = casterUnit->ToPlayer();
    if (!player || !player->IsAlive()) return;

    // Safety guard: unequipped rune should have already removed the aura,
    // but prevents edge-case leaks.
    if (!sImprintMgr->HasImprintEquipped(player, IMPRINT_RIME_ZONE))
        return;

    // Periodic work: deal damage, apply effects, spawn visuals, etc.
}

void Register() override
{
    OnEffectPeriodic += AuraEffectPeriodicFn(
        spell_rime_zone::HandlePeriodic, EFFECT_0, SPELL_AURA_PERIODIC_DUMMY);
}
```

### spell_dbc fields for both spells

| Field | BTN (DUMMY) | AURA (APPLY_AURA) | Notes |
|---|---|---|---|
| `Effect_1` | **3 (DUMMY)** | 6 (APPLY_AURA) | DUMMY is required for learnSpell |
| `EffectAura_1` | — | 226 (PERIODIC_DUMMY) | triggers AuraScript |
| `EffectAuraPeriod_1` | — | 1000 | tick interval ms |
| `DurationIndex` | 0 | 21 (permanent) | aura lasts until explicitly removed |
| `StartRecoveryCategory` | 133 | **0** | 0 = no GCD (server-applied only) |
| `StartRecoveryTime` | 1500 | **0** | standard mage GCD on button only |
| `EquippedItemClass` | **-1** | **-1** | required — 0 → FAILED_EQUIPPED_ITEM_CLASS |

### Client DBC requirement — both spells must be present

Both spells must exist in the client's Spell.dbc. If the BTN spell is missing, the client
silently drops `SMSG_LEARNED_SPELL(600004)` and the spell never appears in the spellbook —
no error, no message. If the AURA spell is missing, the buff bar icon shows no name or tooltip.

The comprehensive tool that patches all module custom spells into both the server binary DBC
and a loose client override file is:

```powershell
cd "modules/mod-item-affixes/tools"
powershell -ExecutionPolicy Bypass -File .\patch_spell_dbc_custom.ps1
```

This writes:
- **Server:** `E:\servers\Wow\Standard\bin\data\dbc\Spell.dbc` (in-place patch)
- **Client:** `E:\servers\Wow\WoW HD\Data\DBFilesClient\Spell.dbc` (loose override)

The loose-file path takes priority over all MPQ files. Restart the WoW client after running.

When adding a new custom spell to this module, add it to `patch_spell_dbc_custom.ps1`
alongside the existing four spells (600002–600005).

### Diagnosing learnSpell failures

| Symptom | Likely cause | Fix |
|---|---|---|
| No "You have learned" message; server called learnSpell | Spell missing from client Spell.dbc | Run `patch_spell_dbc_custom.ps1`; restart client |
| learnSpell returns without calling it (check logs) | Effect is APPLY_AURA not DUMMY | Change `Effect_1` to 3 in spell_dbc |
| "You have learned" appears but spell not in spellbook | Missing SkillLineAbility.dbc entry | Add SLA entry in patch MPQ for the spell's skill line |
| Spell disappears on relog | `learnSpell(id, true)` — temporary flag | Use `false` for the `temporary` parameter |

---

## AuraScript registration

AuraScript classes use the **same** `RegisterSpellScript(ClassName)` macro as SpellScript —
there is no separate `RegisterAuraScript` in this AzerothCore build.

```cpp
// In AddSC_item_affix_scripts():
RegisterSpellScript(spell_celestial_resonance);   // works for AuraScript subclasses too
```

The `PrepareAuraScript(ClassName)` macro inside the class body is still correct and required.

---

## General gotchas reference

| Problem | Cause | Fix |
|---|---|---|
| `IsTemporarySummon()` compile error | Method doesn't exist on `Creature` | Use `c->ToTempSummon() != nullptr` |
| `ForcedDespawn` inaccessible | Private on `Creature` | Use `TempSummon::UnSummon(Milliseconds delay)` or `SetTimer(uint32 ms)` |
| `SummonCreature` produces non-guardian | Missing `SummonPropertiesEntry` | Pass `existing[0]->m_Properties` as 8th arg |
| Extra pets spawn as enemies | Template faction applied | Set faction after spawn — OR guardianProps handles it if Category=PET |
| Pet at wrong level | Template level 70, no override | `SetLevel(player->GetLevel(), false)` after spawn |
| Level-up animation on summon | `SetLevel(lvl, true)` (default) | Pass `false`: `SetLevel(lvl, false)` |
| Spell spammed with no cooldown | PetAI reads `creature_template_spell` but DBC `RecoveryTime = 0` | Use `CreatureScript` with timer variables |
| `0xFF` sentinel collision | `INVENTORY_SLOT_BAG_0 = 255 = 0xFF` | Use `0xFE` as not-found sentinel in bag iteration |
| `AddSpellCooldown` sets year-long CD | Passing `getMSTime() + delay` (absolute) | Pass just `delay` (duration in ms) |
| Client doesn't see cooldown removed | `RemoveSpellCooldown(id)` default = no notify | `RemoveSpellCooldown(id, true)` then `AddSpellCooldown(..., true)` |
| Positional summon damage attributed to creature | No `originalCaster` set | Pass `caster->GetGUID()` as 6th arg to `CastSpell` |
| Imprint re-triggers on echo cast | SpellScript fires on any caster | Guard with `if (!GetCaster()->ToPlayer()) return;` |
| learnSpell silently no-ops (no "learned" message) | Spell's primary effect is APPLY_AURA not DUMMY | Use SPELL_EFFECT_DUMMY (3) for the learnable button; apply aura via a second triggered spell |
| learnSpell sends packet but client ignores it | Spell missing from client's Spell.dbc | Run `patch_spell_dbc_custom.ps1`; restart WoW client |

---

## SQL tables reference

| Table | Purpose |
|---|---|
| `imprint_def` | id, name, rune_item_id, extractions_max, class_mask (0=any) |
| `spell_script_names` | Bind a `SpellScript` C++ class name to a spell ID |
| `creature_template` | Entry, display, AI, level, faction, flags, ScriptName |
| `creature_template_model` | Display ID + scale per creature entry |
| `creature_template_spell` | Up to 8 spell slots auto-cast by PetAI (only active when no ScriptName AI) |
| `creature_immunities` | Named immunity sets; reference via `CreatureImmunitiesId` in creature_template |

### class_mask bits (1 << (classId − 1))

| Class | ID | Bit |
|---|---|---|
| Warrior | 1 | 1 |
| Paladin | 2 | 2 |
| Hunter | 3 | 4 |
| Rogue | 4 | 8 |
| Priest | 5 | 16 |
| Death Knight | 6 | 32 |
| Shaman | 7 | 64 |
| Mage | 8 | 128 |
| Warlock | 9 | 256 |
| Druid | 11 | 1024 |

Use `0` during development (any class); tighten later.

---

## File layout for a new Imprint

```
src/Imprints/
  ImprintMgr.h                  ← add ImprintId enum value here
  [Class]/
    YourAbility.cpp             ← new file: event, imprint class, registration fn

src/
  mod_item_affixes_loader.cpp   ← add extern declaration + call
  ItemAffixScripts.cpp          ← add SpellScript class + RegisterSpellScript

data/sql/db-world/
  imprint_def.sql               ← add row (id, name, rune_item_id, ...)
  spell_script_names_imprint.sql← add row (spell_id, 'spell_your_name')
  your_creature.sql             ← if a new creature entry is needed
```

## Querying the world DB from PowerShell

The `-e` flag is unreliable from PowerShell (argument parsing breaks on `=` signs and reserved
words).  Use a temp SQL file + `cmd /c` with input redirection instead:

```powershell
$env:MYSQL_PWD = "UnlimitedCosmicPower"
$sql = 'SELECT `spell_id`,`rank` FROM spell_ranks WHERE `first_spell_id`=15237;'
[System.IO.File]::WriteAllText("$env:TEMP\q.sql", $sql, [System.Text.Encoding]::ASCII)
cmd /c "`"C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe`" -u acore acore_world < `"$env:TEMP\q.sql`""
```

**Rules that avoid hour-long debugging sessions:**

| Rule | Why |
|---|---|
| Write the SQL file with `[System.IO.File]::WriteAllText(..., [Encoding]::ASCII)` | UTF-8 BOM from `Set-Content` causes parse error 1064 |
| Backtick-quote reserved words: `` `rank` ``, `` `spell_id` ``, `` `first_spell_id` `` | MySQL 8.4 is stricter about reserved identifiers |
| Use `cmd /c` with `<` redirection | Direct PowerShell stdin piping to native exe is flaky |
| Run `SELECT 1;` first if debugging — proves the connection works | Separates auth/path errors from SQL errors |

**Key table / column name differences from what you might expect:**

| What you want | Correct name in acore_world |
|---|---|
| Spell name | Not in `spell_dbc` — use DBC editor or `.spellinfo` in-game |
| Spell family | `SpellClassSet` (column in `spell_dbc`) |
| Family flags 0/1/2 | `SpellClassMask_1`, `SpellClassMask_2`, `SpellClassMask_3` |
| Casting time index | `CastingTimeIndex` (column in `spell_dbc`) |
| All ranks of a spell | `spell_ranks` table: `first_spell_id`, `spell_id`, `rank` |
| `spell_template` | Does not exist — use `spell_dbc` |

**Common lookup recipes:**

```sql
-- All ranks of Holy Nova (first_spell_id = lowest-rank spell ID)
SELECT `spell_id`,`rank` FROM spell_ranks WHERE `first_spell_id`=15237;

-- Family/flags for a specific spell ID
SELECT ID,CastingTimeIndex,SpellClassSet,SpellClassMask_1,SpellClassMask_2,SpellClassMask_3
FROM spell_dbc WHERE ID IN (48077,48078);

-- Check if a spell_script_names binding already exists
SELECT * FROM spell_script_names WHERE spell_id IN (15237,48078);
```

---

## Custom creature entry IDs in use

| Entry | Name | Used by |
|---|---|---|
| 601001 | Imprint Rune | Rune item for all Imprints |
| 601101 | Empyrean Echo | Paladin: Empyrean Echo positional trigger |
| 601104 | Spirit Rhino | Shaman: Feral Spirit Stampede guardian |
| 601105 | Holy Nova Beacon | Priest: Celestial Resonance positional echo |
