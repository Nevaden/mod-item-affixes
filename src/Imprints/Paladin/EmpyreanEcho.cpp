#include "../ImprintMgr.h"
#include "ItemAffix.h"
#include "ObjectAccessor.h"
#include "Player.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "TemporarySummon.h"
#include "Map.h"
#include "Log.h"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static constexpr uint32 SPELL_DIVINE_STORM          = 53385;
static constexpr uint32 CREATURE_EMPYREAN_ECHO      = 601101;

// Distance from the caster's position to each echo centre (yards).
static constexpr float  ECHO_OFFSET_YARDS           = 5.0f;
// Echo damage as a fraction of the player's weapon damage / AP that is copied
// to the summon.  1.0 = full Divine Storm damage per echo.
static constexpr float  ECHO_DAMAGE_SCALE           = 0.75f;
// How long after the original cast the echoes fire (ms).
static constexpr uint32 ECHO_DELAY_MS               = 500;
// Lifetime of each echo summon — long enough for the spell to fire (ms).
static constexpr uint32 ECHO_SUMMON_LIFETIME_MS     = 1500;

// ---------------------------------------------------------------------------
// EmpyreanEchoEvent — fires 500 ms after the Divine Storm cast.
// Creates 4 temporary echo creatures at compass-offset positions and has each
// cast a triggered Divine Storm.  The echoes inherit the player's weapon stats
// so the damage scales correctly with the player's gear.
// ---------------------------------------------------------------------------

class EmpyreanEchoEvent : public BasicEvent
{
public:
    explicit EmpyreanEchoEvent(Player* caster) : _casterGuid(caster->GetGUID()) {}

    bool Execute(uint64 /*e_time*/, uint32 /*p_time*/) override
    {
        Player* caster = ObjectAccessor::FindPlayer(_casterGuid);
        if (!caster || !caster->IsAlive() || !caster->IsInWorld())
            return true;

        // The 4 echo positions are offset from the caster's CURRENT position,
        // spaced 90° apart starting from the direction they are facing.
        float o = caster->GetOrientation();
        for (int i = 0; i < 4; ++i)
        {
            float angle = o + float(i) * (float(M_PI) * 0.5f);  // 0°, 90°, 180°, 270°
            float x = caster->GetPositionX() + ECHO_OFFSET_YARDS * std::cos(angle);
            float y = caster->GetPositionY() + ECHO_OFFSET_YARDS * std::sin(angle);
            float z = caster->GetPositionZ();

            TempSummon* echo = caster->SummonCreature(
                CREATURE_EMPYREAN_ECHO,
                x, y, z, angle,
                TEMPSUMMON_TIMED_DESPAWN, ECHO_SUMMON_LIFETIME_MS);

            if (!echo)
                continue;

            // Mirror the player's stats so Divine Storm damage is correct.
            CopyPlayerStats(caster, echo);

            // The creature is friendly to the player's enemies so Divine Storm
            // targets them (same faction as the player).
            echo->SetFaction(caster->GetFaction());

            // Cast Divine Storm as triggered — no mana, no CD, no GCD.
            // Pass the player's GUID as originalCaster so damage, threat, and
            // kill credit are attributed to the player, not the echo creature.
            // Being a creature (not a player), our Imprint SpellScript guard
            // (ToPlayer() check) prevents this cast from spawning more echoes.
            echo->CastSpell(echo, SPELL_DIVINE_STORM,
                            TriggerCastFlags(TRIGGERED_FULL_MASK),
                            nullptr, nullptr, caster->GetGUID());
        }

        return true;  // event is complete
    }

private:
    ObjectGuid _casterGuid;

    static void CopyPlayerStats(Player* src, TempSummon* dst)
    {
        // Weapon damage — Divine Storm uses SPELL_EFFECT_WEAPON_PERCENT_DAMAGE,
        // which reads GetWeaponDamageRange().  Scale by ECHO_DAMAGE_SCALE so
        // each echo doesn't deal a full extra Divine Storm.
        float minDmg = src->GetWeaponDamageRange(BASE_ATTACK, MINDAMAGE) * ECHO_DAMAGE_SCALE;
        float maxDmg = src->GetWeaponDamageRange(BASE_ATTACK, MAXDAMAGE) * ECHO_DAMAGE_SCALE;
        dst->SetBaseWeaponDamage(BASE_ATTACK, MINDAMAGE, minDmg);
        dst->SetBaseWeaponDamage(BASE_ATTACK, MAXDAMAGE, maxDmg);

        // Attack power — contributes to DS via the spell's AP coefficient.
        float ap = src->GetTotalAttackPowerValue(BASE_ATTACK) * ECHO_DAMAGE_SCALE;
        dst->SetStatFlatModifier(UNIT_MOD_ATTACK_POWER, BASE_VALUE, ap);
        dst->UpdateAttackPowerAndDamage();
    }
};

// ---------------------------------------------------------------------------
// EmpyreanEchoImprint
// ---------------------------------------------------------------------------

class EmpyreanEchoImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_EMPYREAN_ECHO; }

    std::string const& Name() const override
    {
        static const std::string name = "Empyrean Echo";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_DIVINE_STORM,
            "Your strike echoes outward - Divine Storm fires from 4 positions around you "
            "0.5s after cast, each at 75% effectiveness." }};
    }

    // No equip-time SpellMods — the effect is entirely proc-based.
    void OnEquip  (Player* /*player*/, uint64 /*itemGuid*/) override {}
    void OnUnequip(Player* /*player*/, uint64 /*itemGuid*/) override {}

    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) override
    {
        if (spellInfo->Id != SPELL_DIVINE_STORM)
            return;

        caster->m_Events.AddEvent(
            new EmpyreanEchoEvent(caster),
            caster->m_Events.CalculateTime(ECHO_DELAY_MS));

        LOG_DEBUG("module",
            "mod-item-affixes: EmpyreanEcho — scheduled 4 echoes for {} in {}ms",
            caster->GetName(), ECHO_DELAY_MS);
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

void RegisterEmpyreanEchoImprint()
{
    static EmpyreanEchoImprint effect;
    sImprintMgr->RegisterEffect(&effect);
}
