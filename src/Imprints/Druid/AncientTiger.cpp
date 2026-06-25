#include "../ImprintMgr.h"
#include "ItemAffix.h"
#include "ObjectAccessor.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "ScriptedCreature.h"
#include "SpellInfo.h"
#include "Map.h"
#include "Log.h"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static constexpr uint32 SPELL_TIGERS_FURY       = 5217;   // rank 1 — family flag used for matching
static constexpr uint32 CREATURE_ANCIENT_TIGER  = 601106;

// Gondria display (spectral blue-white spirit cat, WotLK spirit beast)
static constexpr uint32 DISPLAY_GONDRIA         = 28871;

static constexpr float  TIGER_SCALE             = 1.5f;
static constexpr float  TIGER_DAMAGE_SCALE      = 1.5f;

// Tiger's Fury family flags = [0, 0, 2048]  (SPELLFAMILY_DRUID = 7 from SharedDefines.h)
static constexpr uint32 TIGERS_FURY_FLAG2       = 2048;

// Ability timers (ms)
static constexpr uint32 RAKE_COOLDOWN_MIN       = 6000;
static constexpr uint32 RAKE_COOLDOWN_MAX       = 9000;
static constexpr uint32 SHRED_COOLDOWN_MIN      = 8000;
static constexpr uint32 SHRED_COOLDOWN_MAX      = 12000;

// High-rank druid cat abilities used for the tiger's special attacks.
// SPELL_EFFECT_WEAPON_PERCENT_DAMAGE — scale with the weapon damage we set from player AP.
// These bypass form requirements when cast by a creature (non-player).
static constexpr uint32 SPELL_TIGER_RAKE        = 48574;  // Rake rank 9: DoT bleed
static constexpr uint32 SPELL_TIGER_SHRED       = 48572;  // Shred rank 9: 525% weapon damage burst

// ---------------------------------------------------------------------------
// ScaleWolfStats — copy player AP-derived weapon/AP onto the tiger.
// Reused from the Alpha Wolf pattern.
// ---------------------------------------------------------------------------
static void ScaleTigerStats(Player* player, TempSummon* tiger, float scale)
{
    float minDmg = player->GetWeaponDamageRange(BASE_ATTACK, MINDAMAGE) * scale;
    float maxDmg = player->GetWeaponDamageRange(BASE_ATTACK, MAXDAMAGE) * scale;
    tiger->SetBaseWeaponDamage(BASE_ATTACK, MINDAMAGE, minDmg);
    tiger->SetBaseWeaponDamage(BASE_ATTACK, MAXDAMAGE, maxDmg);

    float ap = player->GetTotalAttackPowerValue(BASE_ATTACK) * scale;
    tiger->SetStatFlatModifier(UNIT_MOD_ATTACK_POWER, BASE_VALUE, ap);
    tiger->UpdateAttackPowerAndDamage();
}

// ---------------------------------------------------------------------------
// npc_ancient_tiger — guardian AI with Rake and Shred on independent timers.
// Re-checks the owner's target every tick so target switches feel instant.
// ---------------------------------------------------------------------------
class npc_ancient_tiger : public CreatureScript
{
public:
    npc_ancient_tiger() : CreatureScript("npc_ancient_tiger") {}

    struct npc_ancient_tigerAI : public ScriptedAI
    {
        uint32 _rakeTimer;
        uint32 _shredTimer;

        explicit npc_ancient_tigerAI(Creature* c) : ScriptedAI(c) {}

        void Reset() override
        {
            _rakeTimer  = urand(RAKE_COOLDOWN_MIN,  RAKE_COOLDOWN_MAX);
            _shredTimer = urand(SHRED_COOLDOWN_MIN, SHRED_COOLDOWN_MAX);
        }

        void UpdateAI(uint32 diff) override
        {
            // Always mirror the owner's current target — ensures target switches
            // feel responsive (max 100ms lag at default UpdateAI interval).
            if (Unit* owner = me->GetCharmerOrOwner())
            {
                if (Unit* ownerTarget = owner->GetVictim())
                {
                    if (me->GetVictim() != ownerTarget)
                        AttackStart(ownerTarget);
                }
            }

            if (!UpdateVictim())
                return;

            // Rake — periodic bleed DoT, 6–9 s cooldown
            if (_rakeTimer <= diff)
            {
                me->CastSpell(me->GetVictim(), SPELL_TIGER_RAKE, false);
                _rakeTimer = urand(RAKE_COOLDOWN_MIN, RAKE_COOLDOWN_MAX);
            }
            else _rakeTimer -= diff;

            // Shred — heavy burst strike, 8–12 s cooldown
            if (_shredTimer <= diff)
            {
                me->CastSpell(me->GetVictim(), SPELL_TIGER_SHRED, false);
                _shredTimer = urand(SHRED_COOLDOWN_MIN, SHRED_COOLDOWN_MAX);
            }
            else _shredTimer -= diff;

            DoMeleeAttackIfReady();
        }
    };

    CreatureAI* GetAI(Creature* creature) const override
    {
        return new npc_ancient_tigerAI(creature);
    }
};

// ---------------------------------------------------------------------------
// AncientTigerEvent — fires 100 ms after Tiger's Fury cast.
// Dismisses any existing spirit tiger (from a previous Tiger's Fury cast)
// and summons a fresh one as a permanent TEMPSUMMON_DEAD_DESPAWN guardian.
// ---------------------------------------------------------------------------
class AncientTigerEvent : public BasicEvent
{
public:
    explicit AncientTigerEvent(Player* caster) : _casterGuid(caster->GetGUID()) {}

    bool Execute(uint64 /*e_time*/, uint32 /*p_time*/) override
    {
        Player* caster = ObjectAccessor::FindPlayer(_casterGuid);
        if (!caster || !caster->IsAlive() || !caster->IsInWorld())
            return true;

        auto* data = caster->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixPlayerData");

        // Dismiss any previous spirit tiger still alive
        if (!data->ancientTigerGuid.IsEmpty())
        {
            if (Creature* prev = ObjectAccessor::GetCreature(*caster, data->ancientTigerGuid))
                if (TempSummon* ts = prev->ToTempSummon())
                    ts->UnSummon();
            data->ancientTigerGuid.Clear();
        }

        TempSummon* tiger = caster->SummonCreature(
            CREATURE_ANCIENT_TIGER,
            caster->GetPositionX(), caster->GetPositionY(), caster->GetPositionZ(),
            caster->GetOrientation(),
            TEMPSUMMON_DEAD_DESPAWN, 0);

        if (!tiger)
            return true;

        tiger->SetFaction(caster->GetFaction());
        tiger->SetLevel(caster->GetLevel(), false);
        tiger->SetObjectScale(TIGER_SCALE);
        ScaleTigerStats(caster, tiger, TIGER_DAMAGE_SCALE);

        data->ancientTigerGuid = tiger->GetGUID();

        LOG_DEBUG("module", "mod-item-affixes: AncientTiger — summoned spirit tiger ({}) for {}",
            tiger->GetGUID().GetRawValue(), caster->GetName());

        return true;
    }

private:
    ObjectGuid _casterGuid;
};

// ---------------------------------------------------------------------------
// AncientTigerImprint
// ---------------------------------------------------------------------------
class AncientTigerImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_ANCIENT_TIGER; }

    std::string const& Name() const override
    {
        static const std::string name = "Ancient Tiger";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_TIGERS_FURY,
            "Channels the fury of an ancient spirit — a spectral tiger companion "
            "manifests and fights at your side until slain." }};
    }

    void OnEquip(Player* /*player*/, uint64 /*itemGuid*/) override {}

    void OnUnequip(Player* player, uint64 /*itemGuid*/) override
    {
        auto* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixPlayerData");
        if (data->ancientTigerGuid.IsEmpty())
            return;

        if (Creature* tiger = ObjectAccessor::GetCreature(*player, data->ancientTigerGuid))
            if (TempSummon* ts = tiger->ToTempSummon())
                ts->UnSummon();

        data->ancientTigerGuid.Clear();
    }

    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) override
    {
        // Match any rank of Tiger's Fury by family name + flag
        if (spellInfo->SpellFamilyName != SPELLFAMILY_DRUID)
            return;
        if (!(spellInfo->SpellFamilyFlags[2] & TIGERS_FURY_FLAG2))
            return;

        caster->m_Events.AddEvent(
            new AncientTigerEvent(caster),
            caster->m_Events.CalculateTime(100));
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
void RegisterAncientTigerImprint()
{
    static AncientTigerImprint effect;
    sImprintMgr->RegisterEffect(&effect);
    new npc_ancient_tiger();
}
