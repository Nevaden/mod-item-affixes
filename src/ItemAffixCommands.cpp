#include "Bag.h"
#include "Chat.h"
#include "CommandScript.h"
#include "DatabaseEnv.h"
#include "Item.h"
#include "ItemAffix.h"
#include "Player.h"
#include "RBAC.h"

using namespace Acore::ChatCommands;

class ItemAffixCommandScript : public CommandScript
{
public:
    ItemAffixCommandScript() : CommandScript("ItemAffixCommandScript") {}

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable affixCommandTable =
        {
            { "reroll", HandleAffixRerollCommand, rbac::RBAC_PERM_COMMAND_GM, Console::No },
            { "info",   HandleAffixInfoCommand,   rbac::RBAC_PERM_COMMAND_GM, Console::No },
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
};

void AddSC_item_affix_commands()
{
    new ItemAffixCommandScript();
}
