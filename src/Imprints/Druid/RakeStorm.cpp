#include "../ImprintMgr.h"
#include "ItemAffix.h"
#include "Player.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "GridNotifiers.h"
#include "GridNotifiersImpl.h"
#include "CellImpl.h"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static constexpr uint32  SPELL_RAKE_RANK1     = 1822;
static constexpr float   RAKE_SPREAD_RANGE    = 8.0f;
static constexpr uint32  RAKE_SPREAD_MAX      = 3;   // additional targets beyond the primary

// Rake family flags = [64, 0, 0]  (SPELLFAMILY_DRUID = 7 from SharedDefines.h)
static constexpr uint32  RAKE_FAMILY_FLAG0    = 64;

// ---------------------------------------------------------------------------
// FindNearbyEnemies — collect up to maxCount live enemies within range of
// origin, excluding the already-struck primary target.
// ---------------------------------------------------------------------------
static std::vector<Unit*> FindNearbyEnemies(Unit* origin, Unit* exclude, float range, uint32 maxCount)
{
    std::list<Unit*> candidates;
    Acore::AnyUnfriendlyUnitInObjectRangeCheck check(origin, origin, range);
    Acore::UnitListSearcher<Acore::AnyUnfriendlyUnitInObjectRangeCheck> searcher(origin, candidates, check);
    Cell::VisitObjects(origin, searcher, range);

    std::vector<Unit*> result;
    result.reserve(maxCount);
    for (Unit* u : candidates)
    {
        if (u == exclude || !u->IsAlive() || !u->IsInWorld())
            continue;
        result.push_back(u);
        if (result.size() >= maxCount)
            break;
    }
    return result;
}

// ---------------------------------------------------------------------------
// RakeStormImprint
// — Every Rake cast simultaneously applies Rake to up to 3 additional
//   enemies within 8 yards of the caster.
// ---------------------------------------------------------------------------
class RakeStormImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_RAKE_STORM; }

    std::string const& Name() const override
    {
        static const std::string name = "Rake Storm";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_RAKE_RANK1,
            "Rake erupts outward — simultaneously applied to up to 3 additional "
            "enemies within 8 yards." }};
    }

    void OnEquip  (Player* /*player*/, uint64 /*itemGuid*/) override {}
    void OnUnequip(Player* /*player*/, uint64 /*itemGuid*/) override {}

    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) override
    {
        // Match any rank of Rake by family name + flag
        if (spellInfo->SpellFamilyName != SPELLFAMILY_DRUID)
            return;
        if (!(spellInfo->SpellFamilyFlags[0] & RAKE_FAMILY_FLAG0))
            return;

        auto* data = caster->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixPlayerData");
        if (data->rakeStormActive)
            return;  // re-entrance guard: don't spread triggered Rake casts

        Unit* primary = caster->GetVictim();
        if (!primary)
            return;

        // Walk the chain to the highest Rake rank the player knows
        uint32 rakeId = SPELL_RAKE_RANK1;
        for (uint32 next = sSpellMgr->GetNextSpellInChain(rakeId);
             next && caster->HasSpell(next);
             next = sSpellMgr->GetNextSpellInChain(rakeId))
            rakeId = next;

        std::vector<Unit*> spread = FindNearbyEnemies(caster, primary, RAKE_SPREAD_RANGE, RAKE_SPREAD_MAX);
        if (spread.empty())
            return;

        data->rakeStormActive = true;
        for (Unit* target : spread)
            caster->CastSpell(target, rakeId,
                TriggerCastFlags(TRIGGERED_IGNORE_GCD |
                                 TRIGGERED_IGNORE_SPELL_AND_CATEGORY_CD |
                                 TRIGGERED_IGNORE_CAST_IN_PROGRESS |
                                 TRIGGERED_IGNORE_SHAPESHIFT));
        data->rakeStormActive = false;

        LOG_DEBUG("module", "mod-item-affixes: RakeStorm — spread Rake {} to {} targets for {}",
            rakeId, spread.size(), caster->GetName());
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
void RegisterRakeStormImprint()
{
    static RakeStormImprint effect;
    sImprintMgr->RegisterEffect(&effect);
}
