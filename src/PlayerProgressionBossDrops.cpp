// ---------------------------------------------------------------------------
// Player Progression — Boss Drops node (NODE_BOSS_DROPS, see PlayerProgressionNodes.h).
//
// +N extra item roll(s) from a boss's own loot table per kill, where N is the
// SUM of every eligible group member's own invested rank (each player's rank
// contributes independently — 5 players each with rank 1 means 5 bonus items,
// per explicit design decision). The bonus items are added directly to the
// boss's real, shared corpse loot as ordinary non-conditional items, so they
// follow normal group/FFA loot rules and are visible to every looter exactly
// like the rest of the boss's drops — this was a deliberate simplification
// over trying to make the bonus visible only to the contributing player(s),
// which would have required much hackier machinery (see docs/PLAYER_PROGRESSION
// _PLAN.md's "Boss Drops" section for the design discussion).
//
// Each rank is an independent extra roll of the whole table, not a guaranteed
// item — it can whiff on a low-drop-rate table, same as a real extra kill would.
// ---------------------------------------------------------------------------

#include "PlayerProgression.h"
#include "PlayerProgressionNodes.h"
#include "Creature.h"
#include "Group.h"
#include "LootMgr.h"
#include "ObjectAccessor.h"
#include "Player.h"
#include "ScriptMgr.h"

namespace
{
    // Guards against the scratch Loot's own FillLoot re-invoking this same
    // hook (it uses the same LootTemplates_Creature store). In practice the
    // scratch object never gets a sourceWorldObjectGUID set, so the creature
    // resolve below already fails safely on its own — this is an explicit,
    // cheap belt-and-braces guard on top of that, not a load-bearing fix.
    thread_local bool s_rollingBossDropsBonus = false;

    // Sums NODE_BOSS_DROPS rank across every group member within loot reward
    // distance of the boss (matches the exact distance check Loot::FillLoot
    // itself uses to decide group loot access, so "eligible for the bonus"
    // lines up with "eligible for the corpse's loot" by construction). Solo
    // kills just read the lootOwner's own rank.
    int32 SumEligibleBossDropsRanks(Player* lootOwner, Creature* boss)
    {
        int32 total = 0;
        if (Group* group = lootOwner->GetGroup())
        {
            for (GroupReference* ref = group->GetFirstMember(); ref; ref = ref->next())
            {
                Player* member = ref->GetSource();
                if (member && member->IsAtLootRewardDistance(boss))
                    total += int32(sPlayerProgressionMgr->GetNodeBonus(member->GetGUID().GetRawValue(), NODE_BOSS_DROPS));
            }
        }
        else
        {
            total = int32(sPlayerProgressionMgr->GetNodeBonus(lootOwner->GetGUID().GetRawValue(), NODE_BOSS_DROPS));
        }
        return total;
    }
}

class ProgressionBossDropsScript : public MiscScript
{
public:
    ProgressionBossDropsScript() : MiscScript("ProgressionBossDropsScript", {
        MISCHOOK_ON_AFTER_LOOT_TEMPLATE_PROCESS,
    }) {}

    void OnAfterLootTemplateProcess(Loot* loot, LootTemplate const* /*tab*/, LootStore const& store,
        Player* lootOwner, bool /*personal*/, bool /*noEmptyError*/, uint16 lootMode) override
    {
        if (s_rollingBossDropsBonus || !loot || !lootOwner || &store != &LootTemplates_Creature)
            return;

        Creature* boss = ObjectAccessor::GetCreature(*lootOwner, loot->sourceWorldObjectGUID);
        if (!boss || !(boss->isWorldBoss() || boss->IsDungeonBoss()))
            return;

        int32 bonusRolls = SumEligibleBossDropsRanks(lootOwner, boss);
        if (bonusRolls <= 0)
            return;

        CreatureTemplate const* ct = boss->GetCreatureTemplate();
        uint32 lootId = ct ? ct->lootid : 0;
        if (!lootId)
            return;

        // Roll a full separate pass through the same table into a scratch Loot
        // we own and discard — never touches the real corpse loot until we
        // explicitly copy items out below.
        s_rollingBossDropsBonus = true;
        Loot scratch;
        scratch.FillLoot(lootId, LootTemplates_Creature, lootOwner, /*personal=*/true, /*noEmptyError=*/true, lootMode, boss);
        s_rollingBossDropsBonus = false;

        int32 added = 0;
        for (LootItem const& scratchItem : scratch.items)
        {
            if (added >= bonusRolls)
                break;
            if (scratchItem.needs_quest) // quest items have per-player conditional visibility we don't replicate here
                continue;
            if (loot->items.size() >= MAX_NR_LOOT_ITEMS)
                break;

            LootStoreItem storeItem(scratchItem.itemid, 0, 100.0f, false, lootMode, 0,
                int32(scratchItem.count), uint8(scratchItem.count));
            loot->AddItem(storeItem); // handles group visibility + unlootedCount itself, same as any real item add
            ++added;
        }
    }
};

void AddSC_progression_boss_drops()
{
    new ProgressionBossDropsScript();
}
