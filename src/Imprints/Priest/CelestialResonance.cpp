#include "../ImprintMgr.h"
#include "Player.h"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static constexpr uint32 SPELL_CELESTIAL_RESONANCE = 600002;

// ---------------------------------------------------------------------------
// CelestialResonanceImprint
// ---------------------------------------------------------------------------

class CelestialResonanceImprint : public ImprintEffect
{
public:
    uint32 ImprintId() const override { return IMPRINT_CELESTIAL_RESONANCE; }

    std::string const& Name() const override
    {
        static const std::string name = "Celestial Resonance";
        return name;
    }

    std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const override
    {
        return {{ SPELL_CELESTIAL_RESONANCE,
            "Applies a resonant mark to the target for 8 sec. While active, "
            "Holy Nova erupts at the target's position every second." }};
    }

    // Grant the custom spell on equip. learnSpell is idempotent — safe on re-login.
    void OnEquip(Player* player, uint64 /*itemGuid*/) override
    {
        player->learnSpell(SPELL_CELESTIAL_RESONANCE, false);
    }

    // Remove the custom spell on unequip. Active auras on targets expire naturally —
    // each AuraScript tick checks HasImprintEquipped and silently no-ops if gone.
    void OnUnequip(Player* player, uint64 /*itemGuid*/) override
    {
        player->removeSpell(SPELL_CELESTIAL_RESONANCE, SPEC_MASK_ALL, false);
    }

    // All logic lives in spell_celestial_resonance AuraScript in ItemAffixScripts.cpp.
    void OnSpellAfterCast(Player* /*caster*/, SpellInfo const* /*spellInfo*/) override {}
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

void RegisterCelestialResonanceImprint()
{
    static CelestialResonanceImprint effect;
    sImprintMgr->RegisterEffect(&effect);
}
