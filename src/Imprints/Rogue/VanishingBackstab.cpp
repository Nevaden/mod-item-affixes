#include "Imprints/ImprintMgr.h"
#include "Player.h"
#include "SpellInfo.h"
#include "Log.h"

static constexpr uint32 SPELL_VANISHING_BACKSTAB = 600003;

class VanishingBackstabImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_VANISHING_BACKSTAB; }

    std::string const& Name() const override
    {
        static const std::string name = "Vanishing Backstab";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_VANISHING_BACKSTAB,
            "Shadowstep behind your target and immediately unleash Backstab." }};
    }

    void OnEquip(Player* player, uint64 /*itemGuid*/) override
    {
        player->learnSpell(SPELL_VANISHING_BACKSTAB, false);
        LOG_DEBUG("module", "mod-item-affixes: VanishingBackstab equipped for {}",
            player->GetName());
    }

    // SPEC_MASK_ALL (255) is required — passing false (0) coerces to 0 which
    // means "remove from no specs" and silently leaves the spell learned.
    void OnUnequip(Player* player, uint64 /*itemGuid*/) override
    {
        player->removeSpell(SPELL_VANISHING_BACKSTAB, SPEC_MASK_ALL, false);
        LOG_DEBUG("module", "mod-item-affixes: VanishingBackstab unequipped for {}",
            player->GetName());
    }

    // All spell behaviour lives in spell_vanishing_backstab (ItemAffixScripts.cpp).
    void OnSpellAfterCast(Player* /*caster*/, SpellInfo const* /*spellInfo*/) override {}
};

void RegisterVanishingBackstabImprint()
{
    static VanishingBackstabImprint effect;
    sImprintMgr->RegisterEffect(&effect);
}
