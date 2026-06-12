#include "ImprintMgr.h"
#include "ItemAffix.h"          // ItemAffixPlayerData
#include <unordered_set>
#include "Bag.h"
#include "Chat.h"
#include "Config.h"
#include "DatabaseEnv.h"
#include "Item.h"
#include "ItemTemplate.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Opcodes.h"
#include "Player.h"
#include "SpellInfo.h"
#include "WorldPacket.h"

// ---------------------------------------------------------------------------
// Shared addon message transport (mirrors ItemAffixMgr::SendAddonMsg)
// ---------------------------------------------------------------------------
static void SendAddonMsg(Player* player, std::string const& payload)
{
    if (!player || !player->GetSession())
        return;
    std::string fullMsg = std::string("AFXM\t") + payload;
    WorldPacket data(SMSG_MESSAGECHAT, 1 + 4 + 8 + 4 + 8 + 4 + fullMsg.size() + 2);
    data << uint8(CHAT_MSG_WHISPER);
    data << uint32(LANG_ADDON);
    data << player->GetGUID();
    data << uint32(0);
    data << player->GetGUID();
    data << uint32(fullMsg.size() + 1);
    data << fullMsg;
    data << uint8(0);
    player->GetSession()->SendPacket(&data);
}

ImprintMgr* ImprintMgr::instance()
{
    static ImprintMgr inst;
    return &inst;
}

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

void ImprintMgr::LoadConfig()
{
    _extractionCount = sConfigMgr->GetOption<uint32>("ItemAffixes.ImprintExtractionCount", 2);
    LOG_INFO("module", "mod-item-affixes: Imprint extraction count = {}", _extractionCount);
}

void ImprintMgr::LoadDefs()
{
    _defs.clear();

    QueryResult result = WorldDatabase.Query(
        "SELECT id, name, rune_item_id, extractions_max, class_mask, spec_tree FROM imprint_def");

    if (!result)
    {
        LOG_INFO("module", "mod-item-affixes: imprint_def is empty — no Imprints loaded.");
        return;
    }

    uint32 count = 0;
    do
    {
        Field* f = result->Fetch();
        ImprintDef def;
        def.id             = f[0].Get<uint32>();
        def.name           = f[1].Get<std::string>();
        def.runeItemId     = f[2].Get<uint32>();
        def.extractionsMax = f[3].Get<uint32>();
        def.classMask      = f[4].Get<uint32>();
        def.specTree       = f[5].Get<int8>();
        _defs[def.id]      = def;
        ++count;
    } while (result->NextRow());

    LOG_INFO("module", "mod-item-affixes: Loaded {} Imprint definition(s).", count);
}

void ImprintMgr::RegisterEffect(ImprintEffect* effect)
{
    _effects[effect->ImprintId()] = effect;
}

// ---------------------------------------------------------------------------
// Accessors
// ---------------------------------------------------------------------------

ImprintDef const* ImprintMgr::GetDef(uint32 imprintId) const
{
    auto it = _defs.find(imprintId);
    return (it != _defs.end()) ? &it->second : nullptr;
}

ImprintInstance const* ImprintMgr::GetInstance(uint64 itemGuid)
{
    auto it = _instances.find(itemGuid);
    if (it != _instances.end())
        return &it->second;

    // Lazy-load from DB for items that are in bags (never trigger OnItemEquipped).
    QueryResult result = CharacterDatabase.Query(
        "SELECT imprint_id, extractions_left FROM item_imprint WHERE item_guid = {}", itemGuid);
    if (!result)
        return nullptr;

    Field* f = result->Fetch();
    _instances[itemGuid] = ImprintInstance{ f[0].Get<uint32>(), f[1].Get<uint32>() };
    return &_instances[itemGuid];
}

// ---------------------------------------------------------------------------
// SpellModifier tracking (owned by Imprint effects, freed on unequip)
// ---------------------------------------------------------------------------

void ImprintMgr::TrackImprintMod(Player* player, uint64 itemGuid, SpellModifier* mod)
{
    ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");
    data->activeImprintMods[itemGuid].push_back(mod);
}

void ImprintMgr::RemoveImprintMods(Player* player, uint64 itemGuid)
{
    ItemAffixPlayerData* data = player->CustomData.Get<ItemAffixPlayerData>("ItemAffixData");
    if (!data)
        return;
    auto it = data->activeImprintMods.find(itemGuid);
    if (it == data->activeImprintMods.end())
        return;
    for (SpellModifier* mod : it->second)
        player->AddSpellMod(mod, false);   // false = remove & delete
    data->activeImprintMods.erase(it);
}

// ---------------------------------------------------------------------------
// SyncImprints — mirrors SyncAffixes for Imprints
// ---------------------------------------------------------------------------

void ImprintMgr::SyncImprints(Player* player)
{
    if (!player)
        return;

    ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");

    // Build set of currently equipped item GUIDs
    std::unordered_set<uint64> equippedGuids;
    for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
    {
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (item)
            equippedGuids.insert(item->GetGUID().GetRawValue());
    }

    // Remove mods for items no longer equipped
    std::vector<uint64> toRemove;
    for (auto const& [guid, imprintId] : data->activeImprints)
        if (!equippedGuids.count(guid))
            toRemove.push_back(guid);

    for (uint64 guid : toRemove)
    {
        uint32 imprintId = data->activeImprints[guid];
        auto effIt = _effects.find(imprintId);
        if (effIt != _effects.end())
            effIt->second->OnUnequip(player, guid);
        RemoveImprintMods(player, guid);
        data->activeImprints.erase(guid);
    }

    // Add mods for newly equipped items with Imprints (guard inside prevents double-apply)
    for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
    {
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (item)
            OnItemEquipped(player, item);
    }

    // Push updated tooltip overrides to the client.
    SendImprintDescriptions(player);
}

// ---------------------------------------------------------------------------
// SendImprintDescriptions — push spell tooltip overrides to the addon
// ---------------------------------------------------------------------------

void ImprintMgr::SendImprintDescriptions(Player* player)
{
    if (!player)
        return;

    // Clear all previous overrides on the client first.
    SendAddonMsg(player, "IMPRINT_DESC_CLEAR");

    ItemAffixPlayerData* data = player->CustomData.Get<ItemAffixPlayerData>("ItemAffixData");
    if (!data || data->activeImprints.empty())
        return;

    // Collect overrides — last writer wins if two imprints target the same spell.
    std::unordered_map<uint32, std::string> overrides;
    for (auto const& [guid, imprintId] : data->activeImprints)
    {
        auto effIt = _effects.find(imprintId);
        if (effIt == _effects.end())
            continue;
        for (auto const& [spellId, desc] : effIt->second->SpellTooltipOverrides())
            if (!desc.empty())
                overrides[spellId] = desc;
    }

    for (auto const& [spellId, desc] : overrides)
        SendAddonMsg(player, Acore::StringFormat("IMPRINT_DESC|{}|{}", spellId, desc));
}

// ---------------------------------------------------------------------------
// Equip / Unequip
// ---------------------------------------------------------------------------

void ImprintMgr::OnItemEquipped(Player* player, Item* item)
{
    if (!player || !item)
        return;

    uint64 guid = item->GetGUID().GetRawValue();

    // Load from DB if not yet cached
    if (_instances.find(guid) == _instances.end())
    {
        QueryResult result = CharacterDatabase.Query(
            "SELECT imprint_id, extractions_left FROM item_imprint WHERE item_guid = {}", guid);
        if (!result)
            return;  // item has no Imprint
        Field* f = result->Fetch();
        _instances[guid] = ImprintInstance{ f[0].Get<uint32>(), f[1].Get<uint32>() };
    }

    ImprintInstance const& inst = _instances[guid];

    // Track in player data — guard against double-application when login fires equip hooks
    // before OnPlayerLogin's explicit loop.
    ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");
    if (data->activeImprints.count(guid))
        return;  // already applied
    data->activeImprints[guid] = inst.imprintId;

    // Call effect handler
    auto effIt = _effects.find(inst.imprintId);
    if (effIt != _effects.end())
        effIt->second->OnEquip(player, guid);
}

void ImprintMgr::OnItemUnequipped(Player* player, Item* item)
{
    if (!player || !item)
        return;

    uint64 guid = item->GetGUID().GetRawValue();

    ItemAffixPlayerData* data = player->CustomData.Get<ItemAffixPlayerData>("ItemAffixData");
    if (!data)
        return;

    auto it = data->activeImprints.find(guid);
    if (it == data->activeImprints.end())
        return;

    uint32 imprintId = it->second;

    // Call effect handler first (it may read activeImprints)
    auto effIt = _effects.find(imprintId);
    if (effIt != _effects.end())
        effIt->second->OnUnequip(player, guid);

    // Clean up SpellMods and tracking entry
    RemoveImprintMods(player, guid);
    data->activeImprints.erase(it);
}

// ---------------------------------------------------------------------------
// Spell event routing
// ---------------------------------------------------------------------------

void ImprintMgr::OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo)
{
    if (!caster || !spellInfo)
        return;

    ItemAffixPlayerData* data = caster->CustomData.Get<ItemAffixPlayerData>("ItemAffixData");
    if (!data || data->activeImprints.empty())
        return;

    for (auto const& [guid, imprintId] : data->activeImprints)
    {
        auto it = _effects.find(imprintId);
        if (it != _effects.end())
            it->second->OnSpellAfterCast(caster, spellInfo);
    }
}

bool ImprintMgr::HasImprintEquipped(Player* player, uint32 imprintId) const
{
    ItemAffixPlayerData* data = player->CustomData.Get<ItemAffixPlayerData>("ItemAffixData");
    if (!data)
        return false;
    for (auto const& [guid, id] : data->activeImprints)
        if (id == imprintId)
            return true;
    return false;
}

// ---------------------------------------------------------------------------
// DB persistence helpers
// ---------------------------------------------------------------------------

void ImprintMgr::SaveInstance(uint64 itemGuid, uint32 imprintId, uint32 extractionsLeft)
{
    _instances[itemGuid] = ImprintInstance{ imprintId, extractionsLeft };
    CharacterDatabase.Execute(
        "REPLACE INTO item_imprint (item_guid, imprint_id, extractions_left) VALUES ({}, {}, {})",
        itemGuid, imprintId, extractionsLeft);
}

void ImprintMgr::DeleteInstance(uint64 itemGuid)
{
    _instances.erase(itemGuid);
    CharacterDatabase.Execute(
        "DELETE FROM item_imprint WHERE item_guid = {}", itemGuid);
}

// ---------------------------------------------------------------------------
// FindRuneInBags
// ---------------------------------------------------------------------------

std::pair<uint8,uint8> ImprintMgr::FindRuneInBags(Player* player, uint32& outImprintId)
{
    // Helper: check one item and return true if it's a loaded Rune.
    auto checkItem = [&](Item* item, uint8 bag, uint8 slot) -> bool
    {
        if (!item)
            return false;
        ImprintInstance const* inst = GetInstance(item->GetGUID().GetRawValue());
        if (!inst)
            return false;
        ImprintDef const* def = GetDef(inst->imprintId);
        if (!def || def->runeItemId != item->GetEntry())
            return false;
        outImprintId = inst->imprintId;
        return true;
    };

    // Backpack
    for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
    {
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (checkItem(item, INVENTORY_SLOT_BAG_0, slot))
            return { INVENTORY_SLOT_BAG_0, slot };
    }

    // Equipped bags
    for (uint8 bag = INVENTORY_SLOT_BAG_START; bag < INVENTORY_SLOT_BAG_END; ++bag)
    {
        Bag* bagPtr = player->GetBagByPos(bag);
        if (!bagPtr) continue;
        for (uint8 slot = 0; slot < static_cast<uint8>(bagPtr->GetBagSize()); ++slot)
        {
            Item* item = player->GetItemByPos(bag, slot);
            if (checkItem(item, bag, slot))
                return { bag, slot };
        }
    }

    return { 0xFE, 0xFE };  // not found — 0xFE avoids collision with INVENTORY_SLOT_BAG_0 (0xFF)
}

// ---------------------------------------------------------------------------
// IsRune — true when the item's template ID matches any ImprintDef's runeItemId.
// Used by SendItemStatus to flag rune items with |isRune for the Lua apply mechanic.
// ---------------------------------------------------------------------------

bool ImprintMgr::IsRune(Item const* item) const
{
    if (!item) return false;
    uint32 entry = item->GetEntry();
    for (auto const& [id, def] : _defs)
        if (def.runeItemId == entry)
            return true;
    return false;
}

// ---------------------------------------------------------------------------
// GrantRune — create a loaded Rune item and register it in item_imprint.
// Used by the .imprint grant GM command for testing.
// ---------------------------------------------------------------------------

bool ImprintMgr::GrantRune(Player* player, uint32 imprintId)
{
    ImprintDef const* def = GetDef(imprintId);
    if (!def)
    {
        ChatHandler(player->GetSession()).PSendSysMessage("Unknown imprint_id {}.", imprintId);
        return false;
    }

    if (!sObjectMgr->GetItemTemplate(def->runeItemId))
    {
        ChatHandler(player->GetSession()).PSendSysMessage(
            "Rune item template {} not found.", def->runeItemId);
        return false;
    }

    ItemPosCountVec dest;
    if (player->CanStoreNewItem(NULL_BAG, NULL_SLOT, dest, def->runeItemId, 1) != EQUIP_ERR_OK)
    {
        ChatHandler(player->GetSession()).SendSysMessage("Not enough bag space.");
        return false;
    }

    Item* runeItem = player->StoreNewItem(dest, def->runeItemId, true);
    if (!runeItem)
        return false;

    uint32 extractions = _extractionCount;
    SaveInstance(runeItem->GetGUID().GetRawValue(), imprintId, extractions);

    ChatHandler(player->GetSession()).PSendSysMessage(
        "Granted |cffA335EE{} Rune|r ({} extractions).", def->name, extractions);
    return true;
}

// ---------------------------------------------------------------------------
// ExtractImprint
// ---------------------------------------------------------------------------

bool ImprintMgr::ExtractImprint(Player* player, Item* sourceItem)
{
    if (!player || !sourceItem)
        return false;

    uint64 guid = sourceItem->GetGUID().GetRawValue();
    ImprintInstance const* inst = GetInstance(guid);
    if (!inst)
    {
        ChatHandler(player->GetSession()).SendSysMessage("This item has no Imprint to extract.");
        return false;
    }

    ImprintDef const* def = GetDef(inst->imprintId);
    if (!def)
    {
        ChatHandler(player->GetSession()).SendSysMessage("Unknown Imprint type — cannot extract.");
        return false;
    }

    if (inst->extractionsLeft == 0)
    {
        ChatHandler(player->GetSession()).PSendSysMessage(
            "This item's Imprint ({}) has no extractions remaining.", def->name);
        return false;
    }

    if (!def->runeItemId)
    {
        ChatHandler(player->GetSession()).SendSysMessage("No Rune item defined for this Imprint.");
        return false;
    }

    // Verify the item template exists
    if (!sObjectMgr->GetItemTemplate(def->runeItemId))
    {
        ChatHandler(player->GetSession()).PSendSysMessage(
            "Rune item template {} not found — contact an admin.", def->runeItemId);
        return false;
    }

    uint32 newExtractionsLeft = inst->extractionsLeft - 1;

    // Grant the Rune item
    ItemPosCountVec dest;
    InventoryResult result = player->CanStoreNewItem(NULL_BAG, NULL_SLOT, dest, def->runeItemId, 1);
    if (result != EQUIP_ERR_OK)
    {
        ChatHandler(player->GetSession()).SendSysMessage("Not enough bag space for the Imprint Rune.");
        return false;
    }

    // Remove source item from bag/equip slot before creating the rune.
    player->RemoveItem(sourceItem->GetBagSlot(), sourceItem->GetSlot(), true);

    // Create the Rune in bags
    Item* runeItem = player->StoreNewItem(dest, def->runeItemId, true);
    if (!runeItem)
    {
        ChatHandler(player->GetSession()).SendSysMessage("Failed to create Rune item.");
        return false;
    }

    // Record which Imprint this Rune holds (use the rune's GUID as key)
    uint64 runeGuid = runeItem->GetGUID().GetRawValue();
    SaveInstance(runeGuid, inst->imprintId, newExtractionsLeft);

    // Update the source item's extractions_left (item is destroyed — just delete the row)
    DeleteInstance(guid);
    player->DestroyItem(sourceItem->GetBagSlot(), sourceItem->GetSlot(), true);

    ChatHandler(player->GetSession()).PSendSysMessage(
        "Extracted: |cffA335EE{} Rune|r ({} extraction(s) remaining on this Rune).",
        def->name, newExtractionsLeft);

    return true;
}

// ---------------------------------------------------------------------------
// ApplyImprint
// ---------------------------------------------------------------------------

bool ImprintMgr::ApplyImprint(Player* player, Item* targetItem)
{
    if (!player || !targetItem)
        return false;

    uint64 targetGuid = targetItem->GetGUID().GetRawValue();

    // Target must not already have an Imprint
    if (GetInstance(targetGuid))
    {
        ChatHandler(player->GetSession()).SendSysMessage(
            "This item already has an Imprint. Extract it first.");
        return false;
    }

    // Find a Rune in bags
    uint32 imprintId = 0;
    auto [bagSlot, itemSlot] = FindRuneInBags(player, imprintId);
    if (bagSlot == 0xFE)
    {
        ChatHandler(player->GetSession()).SendSysMessage(
            "No Imprint Rune found in your bags.");
        return false;
    }

    Item* runeItem = player->GetItemByPos(bagSlot, itemSlot);
    if (!runeItem)
        return false;

    uint64 runeGuid = runeItem->GetGUID().GetRawValue();
    ImprintInstance const* runeInst = GetInstance(runeGuid);
    if (!runeInst)
        return false;

    ImprintDef const* def = GetDef(imprintId);
    if (!def)
        return false;

    uint32 extractionsLeft = runeInst->extractionsLeft;

    // Transfer: save new instance on target, delete rune instance, destroy rune
    SaveInstance(targetGuid, imprintId, extractionsLeft);
    DeleteInstance(runeGuid);
    player->DestroyItem(bagSlot, itemSlot, true);

    // If the target item is currently equipped, apply the effect immediately
    if (targetItem->IsEquipped())
    {
        ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");
        data->activeImprints[targetGuid] = imprintId;
        auto effIt = _effects.find(imprintId);
        if (effIt != _effects.end())
            effIt->second->OnEquip(player, targetGuid);
    }

    ChatHandler(player->GetSession()).PSendSysMessage(
        "Applied |cffA335EE{}|r to {} ({} extraction(s) remaining).",
        def->name,
        targetItem->GetTemplate()->Name1,
        extractionsLeft);

    return true;
}

// ---------------------------------------------------------------------------
// ApplyImprintDirect  — right-click-rune → click-target apply flow
// ---------------------------------------------------------------------------

bool ImprintMgr::ApplyImprintDirect(Player* player, Item* runeItem, Item* targetItem)
{
    if (!player || !runeItem || !targetItem)
        return false;

    uint64 runeGuid   = runeItem->GetGUID().GetRawValue();
    uint64 targetGuid = targetItem->GetGUID().GetRawValue();

    // Rune must carry an Imprint instance
    ImprintInstance const* runeInst = GetInstance(runeGuid);
    if (!runeInst)
    {
        ChatHandler(player->GetSession()).SendSysMessage("This item is not an Imprint Rune.");
        return false;
    }

    uint32 imprintId       = runeInst->imprintId;
    uint32 extractionsLeft = runeInst->extractionsLeft;

    ImprintDef const* def = GetDef(imprintId);
    if (!def)
        return false;

    // Rune's entry must match the def (sanity — prevents cross-applying wrong rune)
    if (runeItem->GetEntry() != def->runeItemId)
    {
        ChatHandler(player->GetSession()).SendSysMessage("Rune entry does not match its Imprint definition.");
        return false;
    }

    // Target must not already carry an Imprint
    if (GetInstance(targetGuid))
    {
        ChatHandler(player->GetSession()).SendSysMessage(
            "That item already has an Imprint. Extract it first.");
        return false;
    }

    // Target must be equippable
    if (targetItem->GetTemplate()->InventoryType == INVTYPE_NON_EQUIP)
    {
        ChatHandler(player->GetSession()).SendSysMessage(
            "Imprints can only be applied to equippable items.");
        return false;
    }

    // Transfer: save instance on target, delete rune instance, destroy rune item
    SaveInstance(targetGuid, imprintId, extractionsLeft);
    DeleteInstance(runeGuid);
    player->DestroyItem(runeItem->GetBagSlot(), runeItem->GetSlot(), true);

    // If the target is currently equipped, activate the effect immediately
    if (targetItem->IsEquipped())
    {
        ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");
        data->activeImprints[targetGuid] = imprintId;
        auto effIt = _effects.find(imprintId);
        if (effIt != _effects.end())
            effIt->second->OnEquip(player, targetGuid);
    }

    ChatHandler(player->GetSession()).PSendSysMessage(
        "Applied |cffA335EE{}|r to {} ({} extraction(s) remaining).",
        def->name,
        targetItem->GetTemplate()->Name1,
        extractionsLeft);

    return true;
}

// ---------------------------------------------------------------------------
// GetEligibleImprintForRoll  — pick a random class-eligible Imprint for a roll
// ---------------------------------------------------------------------------

ImprintDef const* ImprintMgr::GetEligibleImprintForRoll(Player* player, Item const* item, int8 spec)
{
    if (!player || !item)
        return nullptr;

    // Item must not already carry an Imprint.
    if (GetInstance(item->GetGUID().GetRawValue()))
        return nullptr;

    uint32 classBit = 1u << (player->getClass() - 1);
    std::vector<ImprintDef const*> eligible;
    for (auto const& [id, def] : _defs)
    {
        // Class filter: classMask=0 means any class.
        if (def.classMask != 0 && !(def.classMask & classBit))
            continue;
        // Spec filter: mirrors talent affix logic — only apply when both the Imprint
        // and the player's roll selection specify a tree.
        if (def.specTree != -1 && spec != -1 && def.specTree != spec)
            continue;
        eligible.push_back(&def);
    }

    if (eligible.empty())
        return nullptr;

    return eligible[urand(0, eligible.size() - 1)];
}

// ---------------------------------------------------------------------------
// ApplyImprintFromRoll  — attach an Imprint via roll (no rune consumed)
// ---------------------------------------------------------------------------

bool ImprintMgr::ApplyImprintFromRoll(Player* player, Item* item, uint32 imprintId)
{
    if (!player || !item)
        return false;

    ImprintDef const* def = GetDef(imprintId);
    if (!def)
        return false;

    uint64 guid = item->GetGUID().GetRawValue();

    // Guard: item must not already have an Imprint (race-condition safety).
    if (GetInstance(guid))
        return false;

    // Persist the Imprint instance on the item with full extractions.
    SaveInstance(guid, imprintId, def->extractionsMax);

    // If the item is currently equipped, activate the Imprint effect immediately.
    if (item->IsEquipped())
    {
        ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");
        data->activeImprints[guid] = imprintId;
        auto effIt = _effects.find(imprintId);
        if (effIt != _effects.end())
            effIt->second->OnEquip(player, guid);
    }

    ChatHandler(player->GetSession()).PSendSysMessage(
        "Imprinted |cffA335EE{}|r onto {}.",
        def->name, item->GetTemplate()->Name1);

    return true;
}

// ---------------------------------------------------------------------------
// OnItemDisenchanted  — called after a disenchant destroys an imprinted item
// ---------------------------------------------------------------------------

bool ImprintMgr::OnItemDisenchanted(Player* player, uint64 itemGuid)
{
    if (!player || !itemGuid)
        return false;

    // The item is already gone from the world; our item_imprint row survives.
    ImprintInstance const* inst = GetInstance(itemGuid);
    if (!inst)
        return false;  // item had no Imprint — nothing to do

    if (inst->extractionsLeft == 0)
    {
        // No extractions left: clean up the orphaned row but don't grant a rune.
        DeleteInstance(itemGuid);
        return false;
    }

    ImprintDef const* def = GetDef(inst->imprintId);
    if (!def)
    {
        DeleteInstance(itemGuid);
        return false;
    }

    uint32 newExtractions = inst->extractionsLeft - 1;

    // Grant rune to player's bags.
    ItemPosCountVec dest;
    if (player->CanStoreNewItem(NULL_BAG, NULL_SLOT, dest, def->runeItemId, 1) == EQUIP_ERR_OK)
    {
        Item* runeItem = player->StoreNewItem(dest, def->runeItemId, true);
        if (runeItem)
            SaveInstance(runeItem->GetGUID().GetRawValue(), inst->imprintId, newExtractions);
    }

    // Clean up the source item's row.
    DeleteInstance(itemGuid);

    ChatHandler(player->GetSession()).PSendSysMessage(
        "You recover a |cffA335EE{} Rune|r from the disenchanted item ({} extraction(s) remaining on rune).",
        def->name, newExtractions);

    return true;
}
