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
static constexpr uint32 SPELL_MOONFIRE_RANK1  = 8921;
static constexpr float  CASCADE_RANGE         = 12.0f;
static constexpr uint32 CASCADE_MAX           = 3;   // additional targets

// Moonfire family flags = [32, 0, 0]  (SPELLFAMILY_DRUID = 7 from SharedDefines.h)
static constexpr uint32 MOONFIRE_FAMILY_FLAG0 = 32;

// ---------------------------------------------------------------------------
// FindNearbyEnemies — same helper as RakeStorm, local to this translation unit.
// Searches around `origin` within `range`, skipping `exclude`.
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
// LunarCascadeImprint
// — Every Moonfire cast simultaneously strikes up to 3 additional enemies
//   within 12 yards of the caster — full initial damage and full DoT on each.
// ---------------------------------------------------------------------------
class LunarCascadeImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_LUNAR_CASCADE; }

    std::string const& Name() const override
    {
        static const std::string name = "Lunar Cascade";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_MOONFIRE_RANK1,
            "Moonfire cascades outward — simultaneously strikes up to 3 additional "
            "enemies within 12 yards with full damage and full DoT." }};
    }

    void OnEquip  (Player* /*player*/, uint64 /*itemGuid*/) override {}
    void OnUnequip(Player* /*player*/, uint64 /*itemGuid*/) override {}

    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) override
    {
        // Match any rank of Moonfire by family name + flag
        if (spellInfo->SpellFamilyName != SPELLFAMILY_DRUID)
            return;
        if (!(spellInfo->SpellFamilyFlags[0] & MOONFIRE_FAMILY_FLAG0))
            return;

        auto* data = caster->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixPlayerData");
        if (data->lunarCascadeActive)
            return;  // re-entrance guard: don't spread triggered Moonfire casts

        Unit* primary = caster->GetVictim();
        if (!primary)
        {
            // Balance druids often cast without auto-attack target — use selected unit
            primary = caster->GetSelectedUnit();
            if (!primary || !caster->IsValidAttackTarget(primary))
                return;
        }

        // Walk the chain to find the highest Moonfire rank the player knows
        uint32 moonfireId = SPELL_MOONFIRE_RANK1;
        for (uint32 next = sSpellMgr->GetNextSpellInChain(moonfireId);
             next && caster->HasSpell(next);
             next = sSpellMgr->GetNextSpellInChain(moonfireId))
            moonfireId = next;

        // Search around the caster — raid mobs cluster near the tank, not necessarily
        // near the balance druid.  Searching around the caster's position handles both
        // melee-range boomkin and ranged scenarios where the druid is within the group.
        std::vector<Unit*> spread = FindNearbyEnemies(caster, primary, CASCADE_RANGE, CASCADE_MAX);
        if (spread.empty())
            return;

        data->lunarCascadeActive = true;
        for (Unit* target : spread)
            caster->CastSpell(target, moonfireId,
                TriggerCastFlags(TRIGGERED_IGNORE_GCD |
                                 TRIGGERED_IGNORE_SPELL_AND_CATEGORY_CD |
                                 TRIGGERED_IGNORE_CAST_IN_PROGRESS));
        data->lunarCascadeActive = false;

        LOG_DEBUG("module", "mod-item-affixes: LunarCascade — spread Moonfire {} to {} targets for {}",
            moonfireId, spread.size(), caster->GetName());
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
void RegisterLunarCascadeImprint()
{
    static LunarCascadeImprint effect;
    sImprintMgr->RegisterEffect(&effect);
}
