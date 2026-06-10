#include "../ImprintMgr.h"
#include "ItemAffix.h"
#include "Player.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "Log.h"

static constexpr uint32 SPELL_HAMMER_OF_THE_RIGHTEOUS = 53595;
static constexpr uint32 SPELL_CONSECRATION_RANK1      = 26573;  // chain start

class RighteousSanctuaryImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_RIGHTEOUS_SANCTUARY; }

    std::string const& Name() const override
    {
        static const std::string name = "Righteous Sanctuary";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_HAMMER_OF_THE_RIGHTEOUS,
            "A strong Consecration is automatically placed at your feet after casting." }};
    }

    // No SpellModifiers needed — the imprint's power is entirely in the free Consecration.
    void OnEquip(Player* player, uint64 /*itemGuid*/) override
    {
        LOG_DEBUG("module", "mod-item-affixes: RighteousSanctuary equipped for {}", player->GetName());
    }

    void OnUnequip(Player* player, uint64 /*itemGuid*/) override
    {
        LOG_DEBUG("module", "mod-item-affixes: RighteousSanctuary unequipped for {}", player->GetName());
    }

    // After every Hammer of the Righteous cast, fire the highest Consecration
    // the player knows as a free triggered spell without consuming its cooldown.
    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) override
    {
        if (spellInfo->Id != SPELL_HAMMER_OF_THE_RIGHTEOUS)
            return;

        // Walk the chain to find the highest rank the player knows.
        uint32 consecId = SPELL_CONSECRATION_RANK1;
        for (uint32 next = sSpellMgr->GetNextSpellInChain(consecId);
             next && caster->HasSpell(next);
             next = sSpellMgr->GetNextSpellInChain(consecId))
            consecId = next;

        if (!caster->HasSpell(consecId))
            return;

        // Save and restore the existing cooldown so the triggered cast doesn't reset it.
        uint32 prevCd = caster->HasSpellCooldown(consecId)
                        ? caster->GetSpellCooldownDelay(consecId)
                        : 0;

        caster->CastSpell(caster, consecId,
            TriggerCastFlags(TRIGGERED_IGNORE_GCD |
                             TRIGGERED_IGNORE_SPELL_AND_CATEGORY_CD |
                             TRIGGERED_IGNORE_CAST_IN_PROGRESS));

        caster->RemoveSpellCooldown(consecId, true);
        if (prevCd > 0)
            caster->AddSpellCooldown(consecId, 0, prevCd, true);

        LOG_DEBUG("module", "mod-item-affixes: RighteousSanctuary — cast Consecration {} for {}",
            consecId, caster->GetName());
    }
};

void RegisterSanctuaryStormImprint()
{
    static RighteousSanctuaryImprint effect;
    sImprintMgr->RegisterEffect(&effect);
}
