#include "../ImprintMgr.h"
#include "ItemAffix.h"
#include "ObjectAccessor.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "SpellInfo.h"
#include "TemporarySummon.h"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static constexpr uint32 SPELL_SUMMON_WATER_ELEMENTAL = 31687;
static constexpr uint32 CREATURE_WATER_ELEMENTAL_TEMP = 510;
static constexpr uint32 CREATURE_WATER_ELEMENTAL_PERM = 37994;

static constexpr float  ETERNAL_ELEMENTAL_SCALE = 1.5f;

// ---------------------------------------------------------------------------
// FindWaterElemental — locate the player's active Water Elemental.
// Checks GetPetGUID first (proper pet path), then m_Controlled (guardian path).
// ---------------------------------------------------------------------------
static TempSummon* FindWaterElemental(Player* player)
{
    if (ObjectGuid petGuid = player->GetPetGUID(); !petGuid.IsEmpty())
    {
        if (Creature* c = ObjectAccessor::GetCreature(*player, petGuid))
            if (c->GetEntry() == CREATURE_WATER_ELEMENTAL_TEMP || c->GetEntry() == CREATURE_WATER_ELEMENTAL_PERM)
                if (TempSummon* ts = c->ToTempSummon())
                    return ts;
    }

    for (Unit* ctrl : player->m_Controlled)
    {
        Creature* c = ctrl->ToCreature();
        if (!c)
            continue;
        if (c->GetEntry() != CREATURE_WATER_ELEMENTAL_TEMP && c->GetEntry() != CREATURE_WATER_ELEMENTAL_PERM)
            continue;
        if (TempSummon* ts = c->ToTempSummon())
            return ts;
    }

    return nullptr;
}

// ===========================================================================
// Eternal Elemental
// — Makes the summoned Water Elemental permanent (until death) and 50% larger.
//   Works by changing the summon type to TEMPSUMMON_DEAD_DESPAWN after the
//   cast lands, so the elemental persists across fights until it dies.
// ===========================================================================

class EternalElementalEvent : public BasicEvent
{
public:
    explicit EternalElementalEvent(Player* caster) : _casterGuid(caster->GetGUID()) {}

    bool Execute(uint64 /*e_time*/, uint32 /*p_time*/) override
    {
        Player* caster = ObjectAccessor::FindPlayer(_casterGuid);
        if (!caster || !caster->IsAlive() || !caster->IsInWorld())
            return true;

        TempSummon* elemental = FindWaterElemental(caster);
        if (!elemental)
            return true;

        elemental->SetTempSummonType(TEMPSUMMON_DEAD_DESPAWN);
        elemental->SetObjectScale(ETERNAL_ELEMENTAL_SCALE);

        auto* data = caster->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixPlayerData");
        data->eternalElementalGuid = elemental->GetGUID();

        return true;
    }

private:
    ObjectGuid _casterGuid;
};

class EternalElementalImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_ETERNAL_ELEMENTAL; }

    std::string const& Name() const override
    {
        static const std::string name = "Eternal Elemental";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_SUMMON_WATER_ELEMENTAL,
            "Your Water Elemental becomes a permanent guardian — it persists until slain, "
            "and is summoned at 150% of its normal size." }};
    }

    void OnEquip(Player*, uint64) override {}

    void OnUnequip(Player* player, uint64 /*itemGuid*/) override
    {
        auto* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixPlayerData");
        if (data->eternalElementalGuid.IsEmpty())
            return;

        if (Creature* elemental = ObjectAccessor::GetCreature(*player, data->eternalElementalGuid))
            if (TempSummon* ts = elemental->ToTempSummon())
                ts->UnSummon();

        data->eternalElementalGuid.Clear();
    }

    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) override
    {
        if (spellInfo->Id != SPELL_SUMMON_WATER_ELEMENTAL)
            return;

        caster->m_Events.AddEvent(
            new EternalElementalEvent(caster),
            caster->m_Events.CalculateTime(100));
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

void RegisterEternalElementalImprint()
{
    static EternalElementalImprint effect;
    sImprintMgr->RegisterEffect(&effect);
}
