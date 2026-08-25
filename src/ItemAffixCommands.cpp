#include "Bag.h"
#include "Chat.h"
#include "CommandScript.h"
#include "Creature.h"
#include "DatabaseEnv.h"
#include "Item.h"
#include "ItemAffix.h"
#include "Player.h"
#include "PlayerProgression.h"
#include "RBAC.h"

using namespace Acore::ChatCommands;

class ItemAffixCommandScript : public CommandScript
{
public:
    ItemAffixCommandScript() : CommandScript("ItemAffixCommandScript") {}

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable progressionCommandTable =
        {
            { "info",       HandleAffixProgressionInfoCommand,       rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "grantxp",    HandleAffixProgressionGrantXpCommand,    rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "reset",      HandleAffixProgressionResetCommand,      rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "bossdebug",  HandleAffixProgressionBossDebugCommand,  rbac::RBAC_PERM_COMMAND_GM, Console::No },
        };
        static ChatCommandTable affixCommandTable =
        {
            { "reroll",       HandleAffixRerollCommand, rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "info",         HandleAffixInfoCommand,   rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "progression",  progressionCommandTable },
        };
        static ChatCommandTable commandTable =
        {
            { "affix", affixCommandTable },
        };
        return commandTable;
    }

    // .affix reroll
    static bool HandleAffixRerollCommand(ChatHandler* handler)
    {
        Player* player = handler->GetSession()->GetPlayer();
        sItemAffixMgr->SetPendingReroll(player->GetGUID().GetRawValue());
        handler->SendSysMessage("|cffFFFF00[ItemAffixes]|r Reroll mode active. Alt+Click the item you want to reroll.");
        return true;
    }

    // .affix info — shows affix data for every equipped item that has affix rows.
    static bool HandleAffixInfoCommand(ChatHandler* handler)
    {
        Player* player = handler->GetSession()->GetPlayer();

        static const char* stateNames[] = { "UNROLLED", "PENDING", "APPLIED" };
        static const char* slotNames[]  = {
            "Head","Neck","Shoulders","Shirt","Chest","Waist","Legs","Feet",
            "Wrist","Hands","Ring1","Ring2","Trinket1","Trinket2","Back",
            "MainHand","OffHand","Ranged","Tabard"
        };

        bool anyItem = false;
        for (uint8 equipSlot = EQUIPMENT_SLOT_START; equipSlot < EQUIPMENT_SLOT_END; ++equipSlot)
        {
            Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, equipSlot);
            if (!item)
                continue;

            QueryResult result = CharacterDatabase.Query(
                "SELECT affix_slot, roll_state, affix_id, rolled_value, pending_opts "
                "FROM item_affix WHERE item_guid = {} ORDER BY affix_slot",
                static_cast<uint64>(item->GetGUID().GetRawValue()));

            if (!result)
                continue;

            anyItem = true;
            ItemTemplate const* proto = item->GetTemplate();
            const char* slotLabel = (equipSlot < 19) ? slotNames[equipSlot] : "?";
            handler->PSendSysMessage("|cffFFFF00[{}]|r {} (entry {}, GUID {})",
                slotLabel,
                proto ? proto->Name1.c_str() : "?",
                item->GetEntry(),
                item->GetGUID().GetCounter());

            sItemAffixMgr->SendItemStatus(player, item);

            do
            {
                Field* f = result->Fetch();
                uint8       affixSlot = f[0].Get<uint8>();
                uint8       state     = f[1].Get<uint8>();
                uint32      affixId   = f[2].Get<uint32>();
                int32       rolled    = f[3].Get<int32>();
                std::string opts      = f[4].Get<std::string>();

                const char* stateName = (state <= 2) ? stateNames[state] : "UNKNOWN";
                if (state == 2 && affixId)
                {
                    auto const* def = sItemAffixMgr->GetAffixDef(affixId);
                    handler->PSendSysMessage("  [{}] {} - {} (id {}, val {})",
                        affixSlot, stateName,
                        def ? def->name.c_str() : "?",
                        affixId, rolled);
                }
                else if (state == 1)
                {
                    handler->PSendSysMessage("  [{}] {} - pending opts: [{}]",
                        affixSlot, stateName, opts.c_str());
                }
                else
                {
                    handler->PSendSysMessage("  [{}] {}", affixSlot, stateName);
                }
            } while (result->NextRow());
        }

        if (!anyItem)
            handler->SendSysMessage("No equipped items have affix data.");

        return true;
    }

    // .affix progression info — shows the account's shared XP alongside this
    // character's own invested node ranks (ranks are per-character, XP is per-account).
    static bool HandleAffixProgressionInfoCommand(ChatHandler* handler)
    {
        uint32 accountId = handler->GetSession()->GetAccountId();
        uint64 guid = handler->GetSession()->GetPlayer()->GetGUID().GetRawValue();

        AccountProgressionState account = sPlayerProgressionMgr->GetAccountState(accountId);
        handler->PSendSysMessage("|cffFFFF00[Progression]|r account xp={}", account.xp);

        auto ranks = sPlayerProgressionMgr->GetCharacterNodeRanks(guid);
        bool anyInvested = false;
        for (auto const& [nodeId, rank] : ranks)
        {
            if (rank == 0)
                continue;
            anyInvested = true;
            handler->PSendSysMessage("  node {} = rank {}", nodeId, rank);
        }
        if (!anyInvested)
            handler->SendSysMessage("  (no nodes invested on this character)");
        return true;
    }

    // .affix progression grantxp <amount> — grants raw meta-XP for testing.
    static bool HandleAffixProgressionGrantXpCommand(ChatHandler* handler, uint32 amount)
    {
        Player* player = handler->GetSession()->GetPlayer();
        sPlayerProgressionMgr->GrantXp(player, amount);
        handler->PSendSysMessage("|cffFFFF00[Progression]|r Granted {} meta-XP.", amount);
        return true;
    }

    // .affix progression reset — resets THIS character's invested nodes with no
    // gold cost (support use). Other characters on the account are unaffected.
    static bool HandleAffixProgressionResetCommand(ChatHandler* handler)
    {
        Player* player = handler->GetSession()->GetPlayer();
        sPlayerProgressionMgr->ForceReset(player);
        handler->SendSysMessage("|cffFFFF00[Progression]|r Reset this character's invested nodes to 0 (no gold charged).");
        return true;
    }

    // .affix progression bossdebug — select a creature, reports whether the
    // Boss Drops node (id 26) would trigger on it and this character's own
    // current rank/bonus. Mirrors mod_custom_loot's ".rewardtoken debug".
    static bool HandleAffixProgressionBossDebugCommand(ChatHandler* handler)
    {
        Creature* target = handler->getSelectedCreature();
        if (!target)
        {
            handler->SendSysMessage("Select a creature first.");
            return true;
        }

        uint64 guid = handler->GetSession()->GetPlayer()->GetGUID().GetRawValue();
        uint8 rank = sPlayerProgressionMgr->GetNodeRank(guid, NODE_BOSS_DROPS);

        handler->PSendSysMessage("|cffFFFF00[Progression]|r Creature: {} (entry {})", target->GetName(), target->GetEntry());
        handler->PSendSysMessage("  isWorldBoss:    {}", target->isWorldBoss()   ? "YES" : "no");
        handler->PSendSysMessage("  IsDungeonBoss:  {}", target->IsDungeonBoss() ? "YES" : "no");
        handler->PSendSysMessage("  lootid:         {}", target->GetCreatureTemplate() ? target->GetCreatureTemplate()->lootid : 0);
        handler->PSendSysMessage("  Would trigger:  {}", (target->isWorldBoss() || target->IsDungeonBoss()) ? "YES" : "NO");
        handler->PSendSysMessage("  Your Boss Drops rank: {} (bonus rolls this character contributes: {})", rank, rank);
        return true;
    }
};

void AddSC_item_affix_commands()
{
    new ItemAffixCommandScript();
}
