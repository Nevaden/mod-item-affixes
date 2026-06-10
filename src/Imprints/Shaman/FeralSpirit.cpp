#include "../ImprintMgr.h"
#include "ItemAffix.h"
#include "ObjectAccessor.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "ScriptedCreature.h"
#include "SpellInfo.h"
#include "TemporarySummon.h"
#include "Map.h"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static constexpr uint32 SPELL_FERAL_SPIRIT        = 51533;
static constexpr uint32 CREATURE_SPIRIT_WOLF      = 29264;
static constexpr uint32 CREATURE_STAMPEDE_RHINO   = 601104;

// Rhino ability spell IDs
static constexpr uint32 SPELL_RHINO_STOMP         = 51493;   // AoE physical stomp (Dark Rune Giant)
static constexpr uint32 SPELL_RHINO_DEAFENING_ROAR = 55663;  // Drakkari Rhino roar
static constexpr uint32 SPELL_RHINO_CHARGE        = 55193;   // Ice Steppe Rhino charge

// Stampede
static constexpr int    STAMPEDE_TOTAL_RHINOS    = 10;
static constexpr float  STAMPEDE_RHINO_SCALE     = 0.5f;
static constexpr float  STAMPEDE_DAMAGE_SCALE    = 0.5f;
static constexpr uint32 STAMPEDE_DURATION_MS     = 30000;   // 30 s (down from 45 s)
static constexpr float  STAMPEDE_SPAWN_RADIUS    = 4.0f;

// Alpha
static constexpr float  ALPHA_WOLF_SCALE         = 1.5f;
static constexpr float  ALPHA_DAMAGE_MULTIPLIER  = 2.0f;

// ---------------------------------------------------------------------------
// FindControlled — collect all TempSummons of a given entry under the player's control.
// ---------------------------------------------------------------------------
static std::vector<TempSummon*> FindControlled(Player* player, uint32 entry)
{
    std::vector<TempSummon*> result;
    for (Unit* ctrl : player->m_Controlled)
    {
        Creature* c = ctrl->ToCreature();
        if (!c || c->GetEntry() != entry)
            continue;
        if (TempSummon* ts = c->ToTempSummon())
            result.push_back(ts);
    }
    return result;
}

static std::vector<TempSummon*> FindSpiritWolves(Player* player)
{
    return FindControlled(player, CREATURE_SPIRIT_WOLF);
}

// ---------------------------------------------------------------------------
// ScaleWolfStats — copy scaled player weapon/AP onto a wolf summon.
// ---------------------------------------------------------------------------
static void ScaleWolfStats(Player* player, TempSummon* wolf, float scale)
{
    float minDmg = player->GetWeaponDamageRange(BASE_ATTACK, MINDAMAGE) * scale;
    float maxDmg = player->GetWeaponDamageRange(BASE_ATTACK, MAXDAMAGE) * scale;
    wolf->SetBaseWeaponDamage(BASE_ATTACK, MINDAMAGE, minDmg);
    wolf->SetBaseWeaponDamage(BASE_ATTACK, MAXDAMAGE, maxDmg);

    float ap = player->GetTotalAttackPowerValue(BASE_ATTACK) * scale;
    wolf->SetStatFlatModifier(UNIT_MOD_ATTACK_POWER, BASE_VALUE, ap);
    wolf->UpdateAttackPowerAndDamage();
}

// ===========================================================================
// Feral Spirit: Stampede
// — Replaces the 2 summoned wolves with 10 small Spirit Rhinos that last 30 s.
//   Rhinos are fear-immune (set in creature_template) and cast Stomp/AoE
//   abilities via PetAI reading creature_template_spell.
// ===========================================================================

class FeralStampedeEvent : public BasicEvent
{
public:
    explicit FeralStampedeEvent(Player* caster) : _casterGuid(caster->GetGUID()) {}

    bool Execute(uint64 /*e_time*/, uint32 /*p_time*/) override
    {
        Player* caster = ObjectAccessor::FindPlayer(_casterGuid);
        if (!caster || !caster->IsAlive() || !caster->IsInWorld())
            return true;

        // Grab guardian SummonProperties from the original spell wolves before dismissing them.
        // m_Properties points to static DBC data — valid even after UnSummon is called.
        auto wolves = FindSpiritWolves(caster);
        SummonPropertiesEntry const* guardianProps = !wolves.empty() ? wolves[0]->m_Properties : nullptr;
        for (TempSummon* wolf : wolves)
            wolf->UnSummon();

        // Spawn STAMPEDE_TOTAL_RHINOS Spirit Rhinos spread around the caster.
        for (int i = 0; i < STAMPEDE_TOTAL_RHINOS; ++i)
        {
            float angle = caster->GetOrientation() + float(i) * (float(M_PI) * 2.0f / STAMPEDE_TOTAL_RHINOS);
            float x = caster->GetPositionX() + STAMPEDE_SPAWN_RADIUS * std::cos(angle);
            float y = caster->GetPositionY() + STAMPEDE_SPAWN_RADIUS * std::sin(angle);

            TempSummon* rhino = caster->SummonCreature(
                CREATURE_STAMPEDE_RHINO,
                x, y, caster->GetPositionZ(), angle,
                TEMPSUMMON_TIMED_DESPAWN, STAMPEDE_DURATION_MS,
                guardianProps);

            if (!rhino)
                continue;

            rhino->SetLevel(caster->GetLevel(), false);
            rhino->SetObjectScale(STAMPEDE_RHINO_SCALE);
            ScaleWolfStats(caster, rhino, STAMPEDE_DAMAGE_SCALE);
        }

        return true;
    }

private:
    ObjectGuid _casterGuid;
};

class FeralStampedeImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_FERAL_STAMPEDE; }

    std::string const& Name() const override
    {
        static const std::string name = "Feral Spirit: Stampede";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_FERAL_SPIRIT,
            "Calls a stampede of 10 Spirit Rhinos to your side for 30 sec. "
            "Each fights at 50% effectiveness and periodically stomps, charges, or roars." }};
    }

    void OnEquip(Player*, uint64) override {}

    void OnUnequip(Player* player, uint64 /*itemGuid*/) override
    {
        for (TempSummon* rhino : FindControlled(player, CREATURE_STAMPEDE_RHINO))
            rhino->UnSummon();
    }

    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) override
    {
        if (spellInfo->Id != SPELL_FERAL_SPIRIT)
            return;

        caster->m_Events.AddEvent(
            new FeralStampedeEvent(caster),
            caster->m_Events.CalculateTime(100));
    }
};

// ===========================================================================
// Feral Spirit: Alpha
// — Dismisses the 2 summoned wolves and replaces them with a single large
//   wolf that deals 2× damage and persists until it dies or is dismissed.
// ===========================================================================

class FeralAlphaEvent : public BasicEvent
{
public:
    explicit FeralAlphaEvent(Player* caster) : _casterGuid(caster->GetGUID()) {}

    bool Execute(uint64 /*e_time*/, uint32 /*p_time*/) override
    {
        Player* caster = ObjectAccessor::FindPlayer(_casterGuid);
        if (!caster || !caster->IsAlive() || !caster->IsInWorld())
            return true;

        // Dismiss the 2 wolves just summoned by the spell, plus any previous alpha wolf.
        auto existing = FindSpiritWolves(caster);

        // Capture guardian properties before unsummoning — DBC pointer stays valid.
        SummonPropertiesEntry const* wolfProps = !existing.empty() ? existing[0]->m_Properties : nullptr;

        for (TempSummon* wolf : existing)
            wolf->UnSummon();

        // wolfProps makes the alpha a proper guardian (follows player, attacks target, owner attribution).
        TempSummon* alpha = caster->SummonCreature(
            CREATURE_SPIRIT_WOLF,
            caster->GetPositionX(), caster->GetPositionY(), caster->GetPositionZ(),
            caster->GetOrientation(),
            TEMPSUMMON_DEAD_DESPAWN, 0,
            wolfProps);

        if (!alpha)
            return true;

        alpha->SetFaction(caster->GetFaction());
        alpha->SetLevel(caster->GetLevel(), false);
        alpha->SetObjectScale(ALPHA_WOLF_SCALE);
        ScaleWolfStats(caster, alpha, ALPHA_DAMAGE_MULTIPLIER);

        // Store the GUID so OnUnequip can dismiss the wolf if it is still alive.
        auto* data = caster->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixPlayerData");
        data->feralAlphaWolfGuid = alpha->GetGUID();

        return true;
    }

private:
    ObjectGuid _casterGuid;
};

class FeralAlphaImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_FERAL_ALPHA; }

    std::string const& Name() const override
    {
        static const std::string name = "Feral Spirit: Alpha";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_FERAL_SPIRIT,
            "Summons an Alpha Spirit Wolf as your permanent companion. "
            "Fights at full effectiveness until dismissed or killed." }};
    }

    void OnEquip(Player*, uint64) override {}

    void OnUnequip(Player* player, uint64 /*itemGuid*/) override
    {
        auto* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixPlayerData");
        if (data->feralAlphaWolfGuid.IsEmpty())
            return;

        if (Creature* wolf = ObjectAccessor::GetCreature(*player, data->feralAlphaWolfGuid))
            wolf->ToTempSummon()->UnSummon();

        data->feralAlphaWolfGuid.Clear();
    }

    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) override
    {
        if (spellInfo->Id != SPELL_FERAL_SPIRIT)
            return;

        caster->m_Events.AddEvent(
            new FeralAlphaEvent(caster),
            caster->m_Events.CalculateTime(100));
    }
};

// ===========================================================================
// npc_spirit_rhino — CreatureScript for the Stampede guardian rhinos.
// ScriptedAI handles combat; the Guardian CLASS (set by wolfProps at spawn)
// handles pet-bar registration, follow movement, and kill-credit attribution.
// All three spells are on independent cooldown timers so none can spam.
// ===========================================================================

class npc_spirit_rhino : public CreatureScript
{
public:
    npc_spirit_rhino() : CreatureScript("npc_spirit_rhino") {}

    struct npc_spirit_rhinoAI : public ScriptedAI
    {
        uint32 _stompTimer;
        uint32 _roarTimer;
        uint32 _chargeTimer;

        explicit npc_spirit_rhinoAI(Creature* c) : ScriptedAI(c) {}

        void Reset() override
        {
            // Stagger first casts so 10 rhinos don't all fire in the same tick.
            _stompTimer  = urand(2000, 5000);
            _roarTimer   = urand(5000, 10000);
            _chargeTimer = urand(10000, 16000);
        }

        void UpdateAI(uint32 diff) override
        {
            // Guardian behaviour: pull the owner's target into combat when idle.
            if (!me->IsInCombat())
            {
                if (Unit* owner = me->GetCharmerOrOwner())
                    if (Unit* target = owner->GetVictim())
                        AttackStart(target);
                return;
            }

            if (!UpdateVictim())
                return;

            // Stomp — AoE physical, 8–10 s cooldown.
            if (_stompTimer <= diff)
            {
                me->CastSpell(me, SPELL_RHINO_STOMP, false);
                _stompTimer = 8000 + urand(0, 2000);
            }
            else _stompTimer -= diff;

            // Deafening Roar — 12–15 s cooldown.
            if (_roarTimer <= diff)
            {
                me->CastSpell(me, SPELL_RHINO_DEAFENING_ROAR, false);
                _roarTimer = 12000 + urand(0, 3000);
            }
            else _roarTimer -= diff;

            // Rhino Charge — 20–25 s cooldown.
            if (_chargeTimer <= diff)
            {
                if (Unit* victim = me->GetVictim())
                    me->CastSpell(victim, SPELL_RHINO_CHARGE, false);
                _chargeTimer = 20000 + urand(0, 5000);
            }
            else _chargeTimer -= diff;

            DoMeleeAttackIfReady();
        }
    };

    CreatureAI* GetAI(Creature* creature) const override
    {
        return new npc_spirit_rhinoAI(creature);
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

void RegisterFeralStampedeImprint()
{
    static FeralStampedeImprint effect;
    sImprintMgr->RegisterEffect(&effect);
    new npc_spirit_rhino();
}

void RegisterFeralAlphaImprint()
{
    static FeralAlphaImprint effect;
    sImprintMgr->RegisterEffect(&effect);
}
