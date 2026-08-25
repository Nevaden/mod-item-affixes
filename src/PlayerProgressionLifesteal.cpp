// Player Progression — Lifesteal node (NODE_LIFESTEAL, see PlayerProgressionNodes.h).
// Heals the player for rank * 4% of the damage they deal (5 ranks, 20% max).
//
// Damage/heal logic ported from ZhengPeiRu21's mod-leech
// (https://github.com/ZhengPeiRu21/mod-leech, MIT License), the standalone
// module this node replaces — same OnDamage/pet-vs-owner structure and the
// same heal spell (18984), just driven by node rank instead of a flat
// config value, and always-on rather than dungeon-gated.
//
// Bespoke node — read on-demand via GetNodeBonus, never applied through
// ApplyProgressionStats/RemoveProgressionStats (same as NODE_BOSS_DROPS).

#include "PlayerProgression.h"
#include "PlayerProgressionNodes.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "Unit.h"

namespace
{
    constexpr uint32 SPELL_PROGRESSION_LIFESTEAL_HEAL = 18984; // generic instant heal, already in Spell.dbc
}

class ProgressionLifestealScript : public UnitScript
{
public:
    ProgressionLifestealScript() : UnitScript("ProgressionLifestealScript", true, {
        UNITHOOK_ON_DAMAGE,
    }) {}

    void OnDamage(Unit* attacker, Unit* /*victim*/, uint32& damage) override
    {
        if (!attacker || damage == 0)
            return;

        bool isPet = attacker->GetOwner() && attacker->GetOwner()->GetTypeId() == TYPEID_PLAYER;
        if (!isPet && attacker->GetTypeId() != TYPEID_PLAYER)
            return;

        Player* owner = isPet ? attacker->GetOwner()->ToPlayer() : attacker->ToPlayer();
        if (!owner)
            return;

        float pct = sPlayerProgressionMgr->GetNodeBonus(owner->GetGUID().GetRawValue(), NODE_LIFESTEAL);
        if (pct <= 0.0f)
            return;

        int32 healAmount = int32(float(damage) * pct / 100.0f);
        if (healAmount <= 0)
            return;

        // Pet damage heals the pet itself, not the owner.
        Unit* healTarget = isPet ? attacker : static_cast<Unit*>(owner);
        healTarget->CastCustomSpell(healTarget, SPELL_PROGRESSION_LIFESTEAL_HEAL, &healAmount, nullptr, nullptr, true);
    }
};

void AddSC_progression_lifesteal()
{
    new ProgressionLifestealScript();
}
