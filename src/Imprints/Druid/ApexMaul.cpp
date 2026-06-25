#include "../ImprintMgr.h"
#include "ItemAffix.h"
#include "Player.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "GridNotifiers.h"
#include "GridNotifiersImpl.h"
#include "CellImpl.h"
#include "Log.h"

static constexpr uint32 SPELL_MAUL_RANK1 = 6807;
static constexpr float  SPREAD_RANGE     = 10.0f;

// All enemies within range of origin, excluding origin itself.
static std::vector<Unit*> FindNearbyEnemies(Unit* origin, float range)
{
    std::list<Unit*> candidates;
    Acore::AnyUnfriendlyUnitInObjectRangeCheck check(origin, origin, range);
    Acore::UnitListSearcher<Acore::AnyUnfriendlyUnitInObjectRangeCheck> searcher(origin, candidates, check);
    Cell::VisitObjects(origin, searcher, range);

    std::vector<Unit*> result;
    for (Unit* u : candidates)
        if (u->IsAlive() && u->IsInWorld())
            result.push_back(u);
    return result;
}

// ---------------------------------------------------------------------------
// ApexMaulImprint — Maul copies every debuff on the primary target to all
// enemies within 10 yards, preserving remaining duration and stack count.
// ---------------------------------------------------------------------------
class ApexMaulImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_APEX_MAUL; }

    std::string const& Name() const override
    {
        static const std::string name = "Apex Maul";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_MAUL_RANK1,
            "Apex Maul: every debuff on your Maul target is instantly spread "
            "to all enemies within 10 yards, preserving duration and stacks." }};
    }

    void OnEquip  (Player* /*player*/, uint64 /*itemGuid*/) override {}
    void OnUnequip(Player* /*player*/, uint64 /*itemGuid*/) override {}

    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) override
    {
        if (sSpellMgr->GetFirstSpellInChain(spellInfo->Id) != SPELL_MAUL_RANK1)
            return;

        Unit* victim = caster->GetVictim();
        if (!victim || !victim->IsAlive() || !victim->IsInWorld())
            return;

        // Snapshot debuffs before we touch any aura maps.
        struct DebuffSnap { uint32 spellId; int32 duration; uint8 stacks; };
        std::vector<DebuffSnap> debuffs;

        for (auto const& [id, app] : victim->GetAppliedAuras())
        {
            Aura* aura = app->GetBase();
            if (!aura) continue;
            if (aura->GetSpellInfo()->IsPositive()) continue;
            debuffs.push_back({ aura->GetId(), aura->GetDuration(), aura->GetStackAmount() });
        }

        if (debuffs.empty())
            return;

        // Search around the primary target — enemies cluster near the tank/target,
        // not necessarily near a bear Druid who may be anywhere in the pack.
        std::vector<Unit*> spread = FindNearbyEnemies(victim, SPREAD_RANGE);
        // Exclude the victim itself (they already have the debuffs).
        spread.erase(std::remove(spread.begin(), spread.end(), victim), spread.end());

        if (spread.empty())
            return;

        for (Unit* target : spread)
        {
            for (DebuffSnap const& d : debuffs)
            {
                if (Aura* a = caster->AddAura(d.spellId, target))
                {
                    if (d.duration > 0)
                        a->SetDuration(d.duration);
                    if (d.stacks > 1)
                        a->SetStackAmount(d.stacks);
                }
            }
        }

        LOG_DEBUG("module", "mod-item-affixes: ApexMaul — spread {} debuff(s) to {} target(s) for {}",
            debuffs.size(), spread.size(), caster->GetName());
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
void RegisterApexMaulImprint()
{
    static ApexMaulImprint effect;
    sImprintMgr->RegisterEffect(&effect);
}
