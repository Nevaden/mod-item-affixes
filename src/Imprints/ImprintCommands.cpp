#include "ImprintMgr.h"
#include "Bag.h"
#include "Chat.h"
#include "ChatCommand.h"
#include "Item.h"
#include "ItemTemplate.h"
#include "Player.h"
#include "ScriptMgr.h"

using namespace Acore::ChatCommands;

// ---------------------------------------------------------------------------
// Helper: resolve an equipment slot by name or number string.
// ---------------------------------------------------------------------------
static uint8 ResolveEquipSlot(std::string const& slotStr)
{
    if (!slotStr.empty() && std::isdigit(static_cast<unsigned char>(slotStr[0])))
    {
        uint32 n = std::stoul(slotStr);
        return (n < EQUIPMENT_SLOT_END) ? static_cast<uint8>(n) : EQUIPMENT_SLOT_END;
    }

    std::string s = slotStr;
    std::transform(s.begin(), s.end(), s.begin(), ::tolower);

    if (s == "head")        return EQUIPMENT_SLOT_HEAD;
    if (s == "neck")        return EQUIPMENT_SLOT_NECK;
    if (s == "shoulders")   return EQUIPMENT_SLOT_SHOULDERS;
    if (s == "back")        return EQUIPMENT_SLOT_BACK;
    if (s == "chest")       return EQUIPMENT_SLOT_CHEST;
    if (s == "shirt")       return EQUIPMENT_SLOT_BODY;
    if (s == "tabard")      return EQUIPMENT_SLOT_TABARD;
    if (s == "wrists")      return EQUIPMENT_SLOT_WRISTS;
    if (s == "hands")       return EQUIPMENT_SLOT_HANDS;
    if (s == "waist")       return EQUIPMENT_SLOT_WAIST;
    if (s == "legs")        return EQUIPMENT_SLOT_LEGS;
    if (s == "feet")        return EQUIPMENT_SLOT_FEET;
    if (s == "finger1")     return EQUIPMENT_SLOT_FINGER1;
    if (s == "finger2")     return EQUIPMENT_SLOT_FINGER2;
    if (s == "trinket1")    return EQUIPMENT_SLOT_TRINKET1;
    if (s == "trinket2")    return EQUIPMENT_SLOT_TRINKET2;
    if (s == "mainhand")    return EQUIPMENT_SLOT_MAINHAND;
    if (s == "offhand")     return EQUIPMENT_SLOT_OFFHAND;
    if (s == "ranged")      return EQUIPMENT_SLOT_RANGED;

    return EQUIPMENT_SLOT_END;
}

// ---------------------------------------------------------------------------
// .imprint inspect
// ---------------------------------------------------------------------------
static bool HandleImprintInspect(ChatHandler* handler)
{
    Player* player = handler->GetPlayer();
    if (!player)
        return false;

    bool found = false;

    // Equipped items
    for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
    {
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (!item)
            continue;
        ImprintInstance const* inst = sImprintMgr->GetInstance(item->GetGUID().GetRawValue());
        if (!inst)
            continue;
        ImprintDef const* def = sImprintMgr->GetDef(inst->imprintId);
        std::string name = def ? def->name : "Unknown";
        handler->PSendSysMessage("[Equipped] {} — |cffA335EE{}|r (extractions left: {})",
            item->GetTemplate()->Name1, name, inst->extractionsLeft);
        found = true;
    }

    // Backpack
    for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
    {
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (!item) continue;
        ImprintInstance const* inst = sImprintMgr->GetInstance(item->GetGUID().GetRawValue());
        if (!inst) continue;
        ImprintDef const* def = sImprintMgr->GetDef(inst->imprintId);
        std::string name = def ? def->name : "Unknown";
        handler->PSendSysMessage("[Rune in bags] |cffA335EE{} Rune|r (extractions left: {})",
            name, inst->extractionsLeft);
        found = true;
    }

    // Equipped bags
    for (uint8 bag = INVENTORY_SLOT_BAG_START; bag < INVENTORY_SLOT_BAG_END; ++bag)
    {
        Bag* bagPtr = player->GetBagByPos(bag);
        if (!bagPtr) continue;
        for (uint8 slot = 0; slot < static_cast<uint8>(bagPtr->GetBagSize()); ++slot)
        {
            Item* item = player->GetItemByPos(bag, slot);
            if (!item) continue;
            ImprintInstance const* inst = sImprintMgr->GetInstance(item->GetGUID().GetRawValue());
            if (!inst) continue;
            ImprintDef const* def = sImprintMgr->GetDef(inst->imprintId);
            std::string name = def ? def->name : "Unknown";
            handler->PSendSysMessage("[Rune in bags] |cffA335EE{} Rune|r (extractions left: {})",
                name, inst->extractionsLeft);
            found = true;
        }
    }

    if (!found)
        handler->SendSysMessage("No Imprints found on equipped gear or in bags.");

    return true;
}

// ---------------------------------------------------------------------------
// .imprint extract <slot> [confirm]
// ---------------------------------------------------------------------------
static bool HandleImprintExtract(ChatHandler* handler, std::string const& slotStr,
                                  Optional<std::string_view> confirm)
{
    Player* player = handler->GetPlayer();
    if (!player)
        return false;

    uint8 slot = ResolveEquipSlot(slotStr);
    if (slot == EQUIPMENT_SLOT_END)
    {
        handler->PSendSysMessage("Unknown slot '{}'. Use mainhand, chest, head… or a number.", slotStr);
        return false;
    }

    Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
    if (!item)
    {
        handler->PSendSysMessage("No item equipped in slot '{}'.", slotStr);
        return false;
    }

    ImprintInstance const* inst = sImprintMgr->GetInstance(item->GetGUID().GetRawValue());
    if (!inst)
    {
        handler->SendSysMessage("That item has no Imprint to extract.");
        return false;
    }

    ImprintDef const* def = sImprintMgr->GetDef(inst->imprintId);
    std::string name = def ? def->name : "Unknown";

    if (!confirm || *confirm != "confirm")
    {
        handler->PSendSysMessage(
            "|cffFF0000WARNING:|r Extracting '{}' will |cffFF0000DESTROY|r {}. "
            "Run: .imprint extract {} confirm",
            name, item->GetTemplate()->Name1, slotStr);
        return true;
    }

    sImprintMgr->ExtractImprint(player, item);
    return true;
}

// ---------------------------------------------------------------------------
// .imprint apply <slot>
// ---------------------------------------------------------------------------
static bool HandleImprintApply(ChatHandler* handler, std::string const& slotStr)
{
    Player* player = handler->GetPlayer();
    if (!player)
        return false;

    uint8 slot = ResolveEquipSlot(slotStr);
    if (slot == EQUIPMENT_SLOT_END)
    {
        handler->PSendSysMessage("Unknown slot '{}'. Use mainhand, chest, head… or a number.", slotStr);
        return false;
    }

    Item* targetItem = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
    if (!targetItem)
    {
        handler->PSendSysMessage("No item equipped in slot '{}'.", slotStr);
        return false;
    }

    sImprintMgr->ApplyImprint(player, targetItem);
    return true;
}

// ---------------------------------------------------------------------------
// .imprint grant <imprint_id>  (GM only)
// ---------------------------------------------------------------------------
static bool HandleImprintGrant(ChatHandler* handler, uint32 imprintId)
{
    Player* player = handler->GetPlayer();
    if (!player)
        return false;

    sImprintMgr->GrantRune(player, imprintId);
    return true;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

class ImprintCommandScript : public CommandScript
{
public:
    ImprintCommandScript() : CommandScript("ImprintCommandScript") {}

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable imprintTable =
        {
            { "inspect", HandleImprintInspect,  SEC_PLAYER,     Console::No },
            { "extract", HandleImprintExtract,  SEC_PLAYER,     Console::No },
            { "apply",   HandleImprintApply,    SEC_PLAYER,     Console::No },
            { "grant",   HandleImprintGrant,    SEC_GAMEMASTER, Console::No },
        };
        static ChatCommandTable rootTable =
        {
            { "imprint", imprintTable },
        };
        return rootTable;
    }
};

void AddSC_item_imprint_commands()
{
    new ImprintCommandScript();
}
