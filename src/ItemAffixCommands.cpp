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
    // Marks the player in "pending reroll" mode.  The next Alt+Click (ROLL message)
    // rerolls all affixes on that item from scratch instead of rolling the next unrolled slot.
    static bool HandleAffixRerollCommand(ChatHandler* handler)
    {
        Player* player = handler->GetSession()->GetPlayer();
        sItemAffixMgr->SetPendingReroll(player->GetGUID().GetRawValue());
        handler->SendSysMessage("|cffFFFF00[ItemAffixes]|r Reroll mode active. Alt+Click the item you want to reroll.");
        return true;
    }

    // .affix info
    // Prints current affix slot states for the item in the main hand.
    static bool HandleAffixInfoCommand(ChatHandler* handler)
    {
        Player* player = handler->GetSession()->GetPlayer();

        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, EQUIPMENT_SLOT_MAINHAND);
        if (!item)
        {
            handler->SendErrorMessage("No item in main hand.");
            return false;
        }

        ItemTemplate const* proto = item->GetTemplate();
        handler->PSendSysMessage("|cffFFFF00[ItemAffixes]|r %s (entry %u, GUID %u, quality %u)",
            proto ? proto->Name1.c_str() : "?",
            item->GetEntry(),
            item->GetGUID().GetCounter(),
            proto ? proto->Quality : 0u);

        sItemAffixMgr->SendItemStatus(player, item);

        QueryResult result = CharacterDatabase.Query(
            "SELECT affix_slot, roll_state, affix_id, rolled_value, pending_opts "
            "FROM item_affix WHERE item_guid = {} ORDER BY affix_slot",
            static_cast<uint64>(item->GetGUID().GetRawValue()));

        if (!result)
        {
            handler->SendSysMessage("  (no affix rows — item not eligible or not yet looted)");
            return true;
        }

        static const char* stateNames[] = { "UNROLLED", "PENDING", "APPLIED" };
        do
        {
            Field* f = result->Fetch();
            uint8  slot      = f[0].Get<uint8>();
            uint8  state     = f[1].Get<uint8>();
            uint32 affixId   = f[2].Get<uint32>();
            int32  rolled    = f[3].Get<int32>();
            std::string opts = f[4].Get<std::string>();

            const char* stateName = (state <= 2) ? stateNames[state] : "UNKNOWN";
            if (state == 2 && affixId)
            {
                auto const* def = sItemAffixMgr->GetAffixDef(affixId);
                handler->PSendSysMessage("  Slot %u: %s — %s (id %u, val %d)",
                    slot, stateName,
                    def ? def->name.c_str() : "?",
                    affixId, rolled);
            }
            else if (state == 1)
            {
                handler->PSendSysMessage("  Slot %u: %s — pending opts: [%s]",
                    slot, stateName, opts.c_str());
            }
            else
            {
                handler->PSendSysMessage("  Slot %u: %s", slot, stateName);
            }
        } while (result->NextRow());

        return true;
    }
};

void AddSC_item_affix_commands()
{
    new ItemAffixCommandScript();
}
