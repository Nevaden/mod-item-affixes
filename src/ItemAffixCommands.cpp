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
        static ChatCommandTable reforgeCommandTable =
        {
            { "status",  HandleAffixReforgeStatusCommand,  rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "roll",    HandleAffixReforgeRollCommand,    rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "pick",    HandleAffixReforgePickCommand,    rbac::RBAC_PERM_COMMAND_GM, Console::No },
        };
        static ChatCommandTable affixCommandTable =
        {
            { "reroll",       HandleAffixRerollCommand,   rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "info",         HandleAffixInfoCommand,     rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "talents",      HandleAffixTalentsCommand,  rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "progression",  progressionCommandTable },
            { "reforge",      reforgeCommandTable },
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

    // .affix talents -- debug: dumps the SERVER-SIDE state of currently-active
    // talent-affix SpellModifiers (activeTalentMods), independent of any
    // client display. Use this to check whether a talent affix's SpellModifier
    // is genuinely still attached after removing an item, since the character
    // pane's crit % display can lag behind the real server state until an
    // unrelated stat recompute happens to trigger a repaint.
    static bool HandleAffixTalentsCommand(ChatHandler* handler)
    {
        Player* player = handler->GetSession()->GetPlayer();
        ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");

        if (data->activeTalentMods.empty())
        {
            handler->SendSysMessage("No active talent-affix SpellModifiers.");
            return true;
        }

        for (auto const& [guid, mods] : data->activeTalentMods)
        {
            Item* item = player->GetItemByGuid(ObjectGuid(guid));
            handler->PSendSysMessage("|cffFFFF00[item guid {}]|r {}",
                guid, (item && item->GetTemplate()) ? item->GetTemplate()->Name1.c_str() : "(NOT currently equipped)");
            for (SpellModifier const* mod : mods)
            {
                handler->PSendSysMessage("  spellId={} op={} type={} value={}",
                    mod->spellId, static_cast<int>(mod->op), static_cast<int>(mod->type), mod->value);
            }
        }
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

    // Reforge NPC test commands (docs/REFORGE_PLAN.md, Stage 2) -- exercise
    // the engine and protocol handlers before the real addon UI (Stage 4)
    // exists. equipSlot is a normal equipment slot index (0-18).

    // .affix reforge status <equipSlot>
    static bool HandleAffixReforgeStatusCommand(ChatHandler* handler, uint8 equipSlot)
    {
        Player* player = handler->GetSession()->GetPlayer();
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, equipSlot);
        if (!item)
        {
            handler->SendSysMessage("No item in that equip slot.");
            return true;
        }

        uint64 itemGuid = item->GetGUID().GetRawValue();
        ItemTemplate const* proto = item->GetTemplate();
        handler->PSendSysMessage("|cffFFFF00[Reforge]|r {} (GUID {})",
            proto ? proto->Name1.c_str() : "?", item->GetGUID().GetCounter());

        ReforgeState state = sItemAffixMgr->GetReforgeState(itemGuid);
        if (state.exists)
            handler->PSendSysMessage("  Locked to slot {} (reforged {} time(s)).", state.lockedSlot, state.rerollCount);
        else
            handler->SendSysMessage("  Not yet reforged -- any APPLIED line below is eligible.");

        QueryResult result = CharacterDatabase.Query(
            "SELECT affix_slot, roll_state, affix_id, rolled_value FROM item_affix "
            "WHERE item_guid = {} ORDER BY affix_slot", itemGuid);
        if (result)
        {
            do
            {
                Field* f = result->Fetch();
                uint8  affixSlot = f[0].Get<uint8>();
                uint8  rollState = f[1].Get<uint8>();
                uint32 affixId   = f[2].Get<uint32>();
                int32  rolled    = f[3].Get<int32>();
                if (rollState == 2 && affixId)
                {
                    auto const* def = sItemAffixMgr->GetAffixDef(affixId);
                    handler->PSendSysMessage("  [{}] APPLIED - {} (val {})",
                        affixSlot, def ? def->name.c_str() : "?", rolled);
                }
                else
                {
                    handler->PSendSysMessage("  [{}] not applied (roll_state={})", affixSlot, rollState);
                }
            } while (result->NextRow());
        }
        return true;
    }

    // .affix reforge roll <equipSlot> <affixSlot> -- the paid, committing step.
    static bool HandleAffixReforgeRollCommand(ChatHandler* handler, uint8 equipSlot, uint8 affixSlot)
    {
        Player* player = handler->GetSession()->GetPlayer();
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, equipSlot);
        if (!item)
        {
            handler->SendSysMessage("No item in that equip slot.");
            return true;
        }

        std::vector<PendingOpt> opts;
        ReforgeRollResult result = sItemAffixMgr->RollReforgeOptions(player, item, affixSlot, &opts);
        if (result != ReforgeRollResult::OK)
        {
            handler->PSendSysMessage("|cffFF0000[Reforge]|r Failed (code {}) -- nothing charged.", uint32(result));
            return true;
        }

        handler->SendSysMessage("|cffFFFF00[Reforge]|r Options:");
        for (size_t i = 0; i < opts.size(); ++i)
        {
            auto const* def = sItemAffixMgr->GetAffixDef(opts[i].affixId);
            handler->PSendSysMessage("  [{}] {} (val {}){}",
                i, def ? def->name.c_str() : "?", opts[i].rolledValue,
                (i == 0) ? " -- current" : "");
        }
        handler->SendSysMessage("Use .affix reforge pick <equipSlot> <affixSlot> <optIdx> to commit.");
        return true;
    }

    // .affix reforge pick <equipSlot> <affixSlot> <optIdx>
    static bool HandleAffixReforgePickCommand(ChatHandler* handler, uint8 equipSlot, uint8 affixSlot, uint32 optIdx)
    {
        Player* player = handler->GetSession()->GetPlayer();
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, equipSlot);
        if (!item)
        {
            handler->SendSysMessage("No item in that equip slot.");
            return true;
        }

        ReforgePickResult result = sItemAffixMgr->CommitReforgePick(player, item, affixSlot, optIdx);
        if (result != ReforgePickResult::OK)
            handler->PSendSysMessage("|cffFF0000[Reforge]|r Failed (code {}).", uint32(result));
        else
            handler->SendSysMessage("|cffFFFF00[Reforge]|r Applied.");
        return true;
    }
};

void AddSC_item_affix_commands()
{
    new ItemAffixCommandScript();
}
