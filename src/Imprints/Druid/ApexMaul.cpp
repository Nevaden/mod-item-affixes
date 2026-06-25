#include "../ImprintMgr.h"
#include "ItemAffix.h"
#include "Player.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "GridNotifiers.h"
#include "GridNotifiersImpl.h"
#include "CellImpl.h"
#include "Log.h"

// Cat Mangle rank 1 and Bear Mangle rank 1 — both checked so either form triggers.
static constexpr uint32 SPELL_MANGLE_CAT_RANK1  = 33876;
static constexpr uint32 SPELL_MANGLE_BEAR_RANK1 = 33878;
static constexpr float  SPREAD_RANGE            = 10.0f;

// All alive enemies within range of origin that are hostile to ref.
// Pass the caster as ref so we find mobs hostile to the player, not the mob's enemies.
static std::vector<Unit*> FindNearbyEnemies(Unit* origin, Unit* ref, float range)
{
    std::list<Unit*> candidates;
    Acore::AnyUnfriendlyUnitInObjectRangeCheck check(origin, ref, range);
    Acore::UnitListSearcher<Acore::AnyUnfriendlyUnitInObjectRangeCheck> searcher(origin, candidates, check);
    Cell::VisitObjects(origin, searcher, range);

    std::vector<Unit*> result;
    for (Unit* u : candidates)
        if (u->IsAlive() && u->IsInWorld())
            result.push_back(u);
    return result;
}

// ---------------------------------------------------------------------------
// ApexMangleImprint — Mangle (cat or bear) copies every debuff on the primary
// target to all enemies within 10 yards, preserving remaining duration and
// stack count.
// ---------------------------------------------------------------------------
class ApexMangleImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_APEX_MANGLE; }

    std::string const& Name() const override
    {
        static const std::string name = "Apex Mangle";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {
            { SPELL_MANGLE_CAT_RANK1,
              "Apex Mangle: every debuff on your Mangle target is instantly spread "
              "to all enemies within 10 yards, preserving duration and stacks." },
            { SPELL_MANGLE_BEAR_RANK1,
              "Apex Mangle: every debuff on your Mangle target is instantly spread "
              "to all enemies within 10 yards, preserving duration and stacks." },
        };
    }

    void OnEquip  (Player* /*player*/, uint64 /*itemGuid*/) override {}
    void OnUnequip(Player* /*player*/, uint64 /*itemGuid*/) override {}

    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) override
    {
        uint32 first = sSpellMgr->GetFirstSpellInChain(spellInfo->Id);
        if (first != SPELL_MANGLE_CAT_RANK1 && first != SPELL_MANGLE_BEAR_RANK1)
            return;

        Unit* victim = caster->GetVictim();
        if (!victim || !victim->IsAlive() || !victim->IsInWorld())
            return;

        // Snapshot debuffs before touching any aura maps.
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

        // Search around the primary target for mobs hostile to the caster.
        std::vector<Unit*> spread = FindNearbyEnemies(victim, caster, SPREAD_RANGE);
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

        LOG_DEBUG("module", "mod-item-affixes: ApexMangle — spread {} debuff(s) to {} target(s) for {}",
            debuffs.size(), spread.size(), caster->GetName());
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
void RegisterApexMangleImprint()
{
    static ApexMangleImprint effect;
    sImprintMgr->RegisterEffect(&effect);
}
