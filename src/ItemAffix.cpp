#include "ItemAffix.h"
#include "Imprints/ImprintMgr.h"
#include "Bag.h"
#include "Chat.h"
#include "Config.h"
#include "DatabaseEnv.h"
#include "DBCStores.h"
#include "Item.h"
#include "ItemTemplate.h"
#include "Log.h"
#include "ObjectAccessor.h"
#include "ObjectGuid.h"
#include "Opcodes.h"
#include "Random.h"
#include "SpellMgr.h"
#include "StringConvert.h"
#include "StringFormat.h"
#include "Tokenize.h"
#include "WorldPacket.h"
#include <cstring>

ItemAffixMgr* ItemAffixMgr::instance()
{
    static ItemAffixMgr inst;
    return &inst;
}

// ---------------------------------------------------------------------------
// Item category helpers
// ---------------------------------------------------------------------------

static uint8 GetItemCategory(Item const* item)
{
    ItemTemplate const* proto = item->GetTemplate();
    if (!proto)
        return ITEM_CAT_ANY;

    switch (proto->InventoryType)
    {
        case INVTYPE_WEAPON:
        case INVTYPE_WEAPONMAINHAND:
        case INVTYPE_WEAPONOFFHAND:
        case INVTYPE_SHIELD:
            return (proto->SubClass == ITEM_SUBCLASS_WEAPON_DAGGER)
                ? ITEM_CAT_DAGGER
                : ITEM_CAT_WEAPON_1H;
        case INVTYPE_2HWEAPON:
        case INVTYPE_RANGED:
            return ITEM_CAT_WEAPON_2H;
        case INVTYPE_RANGEDRIGHT:
            return ITEM_CAT_WAND;
        case INVTYPE_NECK:
        case INVTYPE_FINGER:
        case INVTYPE_TRINKET:
            return ITEM_CAT_JEWELRY;
        case INVTYPE_FEET:
            return ITEM_CAT_BOOTS;
        case INVTYPE_HEAD:
        case INVTYPE_SHOULDERS:
        case INVTYPE_BODY:
        case INVTYPE_CHEST:
        case INVTYPE_ROBE:
        case INVTYPE_WAIST:
        case INVTYPE_LEGS:
        case INVTYPE_WRISTS:
        case INVTYPE_HANDS:
        case INVTYPE_CLOAK:
        case INVTYPE_HOLDABLE:
            return ITEM_CAT_ARMOR;
        default:
            return ITEM_CAT_ANY;
    }
}

static bool Is2HWeapon(Item const* item)
{
    return item && item->GetTemplate()->InventoryType == INVTYPE_2HWEAPON;
}

static bool ItemMatchesCategory(uint8 itemCat, uint8 required)
{
    if (required == ITEM_CAT_ANY)
        return true;
    if (required == ITEM_CAT_WEAPON)
        return itemCat == ITEM_CAT_WEAPON_1H || itemCat == ITEM_CAT_WEAPON_2H;
    // ARMOR requirement includes boots (boots are a subset of armor).
    // BOOTS requirement matches only boots.
    if (required == ITEM_CAT_ARMOR)
        return itemCat == ITEM_CAT_ARMOR || itemCat == ITEM_CAT_BOOTS;
    // DAGGER: allows daggers and all non-weapon items; blocks non-dagger weapons.
    if (required == ITEM_CAT_DAGGER)
        return itemCat == ITEM_CAT_DAGGER ||
               (itemCat != ITEM_CAT_WEAPON_1H && itemCat != ITEM_CAT_WEAPON_2H);
    return itemCat == required;
}

// Convert C++ bag/slot to WoW Lua bag/slot.
// Equipment slots (0-18): Lua uses bag=255, slot=cppSlot+1 (1-based).
//   Addon's SetInventoryItem hook calls AddAffixLines(self, 255, luaSlot).
// Backpack slots (23-38): Lua uses bag=0, slot=cppSlot-ITEM_START+1.
// Extra bags (INVENTORY_SLOT_BAG_0 with cppBag 19-22): Lua bag=1-4, slot=1-based.
static std::pair<uint8, uint8> GetLuaBagSlot(Item const* item)
{
    uint8 bagSlot  = item->GetBagSlot();
    uint8 itemSlot = item->GetSlot();
    if (bagSlot == INVENTORY_SLOT_BAG_0)
    {
        if (itemSlot < INVENTORY_SLOT_BAG_START)
            // Equipment slot: Lua sentinal bag=255, slot is 1-based
            return { 255, static_cast<uint8>(itemSlot + 1) };
        // Backpack: Lua bag=0, slot 1-based from ITEM_START
        return { 0, static_cast<uint8>(itemSlot - INVENTORY_SLOT_ITEM_START + 1) };
    }
    return { static_cast<uint8>(bagSlot - INVENTORY_SLOT_BAG_START + 1), static_cast<uint8>(itemSlot + 1) };
}

// Convert WoW Lua bag/slot to an Item* (returns null if position is empty or out of range)
static Item* GetItemByLuaBagSlot(Player* player, uint8 luaBag, uint8 luaSlot)
{
    if (luaBag == 255)  // equipment slot: Lua slot is 1-based equipment slot
    {
        if (luaSlot == 0 || luaSlot > EQUIPMENT_SLOT_END)
            return nullptr;
        return player->GetItemByPos(INVENTORY_SLOT_BAG_0, static_cast<uint8>(luaSlot - 1));
    }
    if (luaBag == 0)
    {
        uint8 cppSlot = static_cast<uint8>(INVENTORY_SLOT_ITEM_START + luaSlot - 1);
        if (cppSlot >= INVENTORY_SLOT_ITEM_END)
            return nullptr;
        return player->GetItemByPos(INVENTORY_SLOT_BAG_0, cppSlot);
    }
    uint8 cppBag = static_cast<uint8>(INVENTORY_SLOT_BAG_START + luaBag - 1);
    if (cppBag >= INVENTORY_SLOT_BAG_END)
        return nullptr;
    Bag* bag = player->GetBagByPos(cppBag);
    if (!bag || luaSlot == 0 || luaSlot > bag->GetBagSize())
        return nullptr;
    return bag->GetItemByPos(luaSlot - 1);
}

// ---------------------------------------------------------------------------
// WotLK item budget — stat value computation
// ---------------------------------------------------------------------------

// Piecewise linear approximation of Blizzard's item budget formula.
// Uses ItemLevel (gear score), NOT RequiredLevel.
static float ComputeItemBudget(uint32 itemLevel)
{
    float ilvl = static_cast<float>(itemLevel);
    if (itemLevel <= 66)
        return ilvl * 0.78f + 1.5f;
    if (itemLevel <= 114)
        return ilvl * 1.25f - 28.5f;
    return ilvl * 1.92f - 105.0f;
}

// Slot budget multipliers per WotLK itemization: Head/Chest/Legs/2H = 100%,
// Shoulders/Hands/Waist/Feet = 74%, everything else = 54%.
static float GetSlotBudgetMod(uint32 inventoryType)
{
    switch (inventoryType)
    {
        case INVTYPE_HEAD:
        case INVTYPE_CHEST:
        case INVTYPE_ROBE:
        case INVTYPE_LEGS:
        case INVTYPE_2HWEAPON:
        case INVTYPE_RANGED:   // hunter ranged weapons (bow/gun/crossbow) treated as 2H
            return 1.00f;
        case INVTYPE_SHOULDERS:
        case INVTYPE_WAIST:
        case INVTYPE_FEET:
        case INVTYPE_HANDS:
            return 0.74f;
        default:               // neck, cloak, wrists, rings, trinkets, 1H weapons, wand, off-hands
            return 0.54f;
    }
}

// WotLK stat exchange rates: AP is cheap (0.5), SP is slightly cheap (0.86),
// everything else costs 1.0 per point.
static float GetStatCost(uint8 statOp)
{
    switch (static_cast<GenericStatOp>(statOp))
    {
        case GSTAT_ATTACK_POWER:
        case GSTAT_RANGED_AP:
            return 0.5f;
        case GSTAT_SPELL_POWER:
            return 0.86f;
        default:
            return 1.0f;
    }
}

// Roll a stat value from the item's allocated budget slice.
// budget = totalItemBudget * qualityFraction (caller computes this).
// minRoll: fraction of max that forms the low end of the roll range (e.g. 0.75).
// MOVE_SPEED is a special case — it is a flat percentage bonus, not budget-based.
static int32 RollBudgetStatValue(uint8 statOp, float budget, float minRoll)
{
    if (statOp == static_cast<uint8>(GSTAT_MOVE_SPEED))
        return irand(3, 12);

    float cost   = GetStatCost(statOp);
    int32 maxVal = static_cast<int32>(std::floor(budget / cost));
    if (maxVal < 1) maxVal = 1;
    int32 minVal = static_cast<int32>(std::floor(budget * minRoll / cost));
    if (minVal < 1) minVal = 1;
    if (minVal > maxVal) minVal = maxVal;
    return irand(minVal, maxVal);
}

float ItemAffixMgr::GetQualityFraction(uint32 quality) const
{
    float base;
    if (quality >= 4) base = _budgetFractionPurple;
    else if (quality >= 3) base = _budgetFractionBlue;
    else base = _budgetFractionGreen;
    return base * _statMultiplier;
}

// ---------------------------------------------------------------------------
// Generic stat application
// ---------------------------------------------------------------------------

static void ApplyGenericStat(Player* player, uint8 statOp, int32 value, bool apply)
{
    float fval = static_cast<float>(value);
    switch (static_cast<GenericStatOp>(statOp))
    {
        case GSTAT_STAMINA:
            player->HandleStatFlatModifier(UNIT_MOD_STAT_STAMINA,        TOTAL_VALUE, fval, apply); break;
        case GSTAT_STRENGTH:
            player->HandleStatFlatModifier(UNIT_MOD_STAT_STRENGTH,       TOTAL_VALUE, fval, apply); break;
        case GSTAT_AGILITY:
            player->HandleStatFlatModifier(UNIT_MOD_STAT_AGILITY,        TOTAL_VALUE, fval, apply); break;
        case GSTAT_INTELLECT:
            player->HandleStatFlatModifier(UNIT_MOD_STAT_INTELLECT,      TOTAL_VALUE, fval, apply); break;
        case GSTAT_SPIRIT:
            player->HandleStatFlatModifier(UNIT_MOD_STAT_SPIRIT,         TOTAL_VALUE, fval, apply); break;
        case GSTAT_ATTACK_POWER:
            player->HandleStatFlatModifier(UNIT_MOD_ATTACK_POWER,        TOTAL_VALUE, fval, apply); break;
        case GSTAT_RANGED_AP:
            player->HandleStatFlatModifier(UNIT_MOD_ATTACK_POWER_RANGED, TOTAL_VALUE, fval, apply); break;
        case GSTAT_SPELL_POWER:
            player->ApplySpellPowerBonus(value, apply); break;
        case GSTAT_MP5:
            player->ApplyManaRegenBonus(value, apply); break;
        case GSTAT_ARMOR:
            player->HandleStatFlatModifier(UNIT_MOD_ARMOR,               TOTAL_VALUE, fval, apply); break;
        case GSTAT_CRIT_RATING:
            player->ApplyRatingMod(CR_CRIT_MELEE,        value, apply);
            player->ApplyRatingMod(CR_CRIT_RANGED,       value, apply);
            player->ApplyRatingMod(CR_CRIT_SPELL,        value, apply); break;
        case GSTAT_HASTE_RATING:
            player->ApplyRatingMod(CR_HASTE_MELEE,       value, apply);
            player->ApplyRatingMod(CR_HASTE_RANGED,      value, apply);
            player->ApplyRatingMod(CR_HASTE_SPELL,       value, apply); break;
        case GSTAT_HIT_RATING:
            player->ApplyRatingMod(CR_HIT_MELEE,         value, apply);
            player->ApplyRatingMod(CR_HIT_RANGED,        value, apply);
            player->ApplyRatingMod(CR_HIT_SPELL,         value, apply); break;
        case GSTAT_DODGE_RATING:
            player->ApplyRatingMod(CR_DODGE,             value, apply); break;
        case GSTAT_DEFENSE_RATING:
            player->ApplyRatingMod(CR_DEFENSE_SKILL,     value, apply); break;
        case GSTAT_PARRY_RATING:
            player->ApplyRatingMod(CR_PARRY,             value, apply); break;
        case GSTAT_EXPERTISE_RATING:
            player->ApplyRatingMod(CR_EXPERTISE,         value, apply); break;
        case GSTAT_ARMOR_PEN_RATING:
            player->ApplyRatingMod(CR_ARMOR_PENETRATION, value, apply); break;
        case GSTAT_MOVE_SPEED:
        {
            // value = percent bonus (e.g., 15 → +15% run speed).
            // WotLK 3.3.5a player base run speed rate is 1.0 (7.0 y/s absolute).
            // SetSpeed takes the rate; GetSpeed returns absolute (rate * 7.0).
            constexpr float BASE_RUN = 7.0f;
            float pct  = static_cast<float>(value) / 100.0f;
            float cur  = player->GetSpeed(MOVE_RUN);
            float newRate = apply
                ? (cur * (1.0f + pct)) / BASE_RUN
                : (cur / (1.0f + pct)) / BASE_RUN;
            player->SetSpeed(MOVE_RUN, newRate, true);
            break;
        }
        default:
            LOG_ERROR("module", "mod-item-affixes: unknown GenericStatOp {}", statOp); break;
    }
}

// ---------------------------------------------------------------------------
// Spec detection
// ---------------------------------------------------------------------------

static int GetDominantTalentTree(Player* player)
{
    uint32 const* tabPages = GetTalentTabPages(player->getClass());
    if (!tabPages)
        return -1;

    int counts[3] = { 0, 0, 0 };
    for (auto const& [spellId, talent] : player->GetTalentMap())
    {
        if (!talent || talent->State == PLAYERSPELL_REMOVED)
            continue;
        if (!talent->IsInSpec(player->GetActiveSpec()))
            continue;
        TalentSpellPos const* pos = GetTalentSpellPos(spellId);
        if (!pos)
            continue;
        TalentEntry const* entry = sTalentStore.LookupEntry(pos->talent_id);
        if (!entry)
            continue;
        for (int t = 0; t < 3; ++t)
        {
            if (entry->TalentTab == tabPages[t])
            {
                counts[t] += pos->rank + 1;
                break;
            }
        }
    }

    int best = 0;
    for (int i = 1; i < 3; ++i)
        if (counts[i] > counts[best])
            best = i;

    return (counts[best] > 0) ? best : -1;
}

// ---------------------------------------------------------------------------
// Existing helpers
// ---------------------------------------------------------------------------

static uint8 SpellFamilyToClass(uint32 family)
{
    switch (family)
    {
        case 3:  return CLASS_MAGE;
        case 4:  return CLASS_WARRIOR;
        case 5:  return CLASS_WARLOCK;
        case 6:  return CLASS_PRIEST;
        case 7:  return CLASS_DRUID;
        case 8:  return CLASS_ROGUE;
        case 9:  return CLASS_HUNTER;
        case 10: return CLASS_PALADIN;
        case 11: return CLASS_SHAMAN;
        case 15: return CLASS_DEATH_KNIGHT;
        default: return 0;
    }
}

static bool PlayerKnowsCarrierSpell(Player* player, uint32 carrierSpellId)
{
    uint32 spell = sSpellMgr->GetFirstSpellInChain(carrierSpellId);
    if (!spell)
        spell = carrierSpellId;
    while (spell)
    {
        if (player->HasSpell(spell))
            return true;
        spell = sSpellMgr->GetNextSpellInChain(spell);
    }
    return false;
}

// ---------------------------------------------------------------------------
// LoadAffixTemplates
// ---------------------------------------------------------------------------

void ItemAffixMgr::LoadAffixTemplates()
{
    _defs.clear();
    _pool.clear();

    QueryResult result = WorldDatabase.Query(
        "SELECT id, name, weight, min_quality, spellmod_op, spellmod_type, spellmod_value, "
        "spell_family, spell_family_flags0, spell_family_flags1, spell_family_flags2, "
        "carrier_spell_id, "
        "spellmod_op2, spellmod_type2, spellmod_value2, "
        "spellmod_op3, spellmod_type3, spellmod_value3, "
        "spellmod_op4, spellmod_type4, spellmod_value4, "
        "affix_type, stat_op, stat_tiers, level_min, level_max, item_category, spec_tree, role_mask "
        "FROM affix_template WHERE weight > 0");

    if (!result)
    {
        LOG_INFO("module", "mod-item-affixes: affix_template is empty — no affixes will be generated.");
        return;
    }

    uint32 count = 0;
    do
    {
        Field* f = result->Fetch();
        AffixDefinition def;
        def.id                  = f[0].Get<uint32>();
        def.name                = f[1].Get<std::string>();
        def.weight              = f[2].Get<uint32>();
        def.minQuality          = f[3].Get<uint32>();
        def.spellFamily         = f[7].Get<uint32>();
        def.spellFamilyFlags[0] = f[8].Get<uint32>();
        def.spellFamilyFlags[1] = f[9].Get<uint32>();
        def.spellFamilyFlags[2] = f[10].Get<uint32>();
        def.carrierSpellId      = f[11].Get<uint32>();
        def.effects[0] = AffixEffect{ f[4].Get<uint8>(),  static_cast<SpellModType>(f[5].Get<uint32>()),  f[6].Get<int32>()  };
        def.effects[1] = AffixEffect{ f[12].Get<uint8>(), static_cast<SpellModType>(f[13].Get<uint32>()), f[14].Get<int32>() };
        def.effects[2] = AffixEffect{ f[15].Get<uint8>(), static_cast<SpellModType>(f[16].Get<uint32>()), f[17].Get<int32>() };
        def.effects[3] = AffixEffect{ f[18].Get<uint8>(), static_cast<SpellModType>(f[19].Get<uint32>()), f[20].Get<int32>() };
        def.affixType    = static_cast<AffixType>(f[21].Get<uint8>());
        def.statOp       = f[22].Get<uint8>();
        def.itemCategory = f[26].Get<uint8>();
        def.specTree     = f[27].Get<uint8>();
        def.roleMask     = f[28].Get<uint8>();
        // f[23]=stat_tiers, f[24]=level_min, f[25]=level_max are legacy columns, no longer used.

        if (def.affixType == AFFIX_TYPE_SPELLMOD)
        {
            if (!sSpellMgr->GetSpellInfo(def.carrierSpellId))
            {
                LOG_ERROR("module", "mod-item-affixes: affix {} has invalid carrier_spell_id {}, skipping.",
                    def.id, def.carrierSpellId);
                continue;
            }
        }

        _defs[def.id] = std::move(def);
        ++count;
    } while (result->NextRow());

    // Generic (family=0) affixes get 3x pool representation so they are
    // more common than class-specific affixes despite their lower raw count.
    for (auto const& [id, def] : _defs)
    {
        uint32 poolWeight = (def.spellFamily == 0) ? def.weight * 3 : def.weight;
        for (uint32 i = 0; i < poolWeight; ++i)
            _pool.push_back(id);
    }

    LOG_INFO("module", "mod-item-affixes: loaded {} affix template(s).", count);

    // Purge affix rows for items that no longer exist (deleted items leave orphans
    // because WoW does not call a server hook on item destruction).
    // item_affix.item_guid is BIGINT storing GetRawValue() (full 64-bit GUID with type bits).
    // item_instance.guid is INT UNSIGNED storing only the counter (low 32 bits).
    // Mask to lower 32 bits for the comparison.
    CharacterDatabase.Execute(
        "DELETE ia FROM item_affix ia "
        "LEFT JOIN item_instance ii ON (ia.item_guid & 0xFFFFFFFF) = ii.guid "
        "WHERE ii.guid IS NULL");
    CharacterDatabase.Execute(
        "DELETE ita FROM item_talent_affix ita "
        "LEFT JOIN item_instance ii ON (ita.item_guid & 0xFFFFFFFF) = ii.guid "
        "WHERE ii.guid IS NULL");
    LOG_INFO("module", "mod-item-affixes: purged orphaned affix rows.");

    _enableClassSkillAffixes = sConfigMgr->GetOption<bool> ("ItemAffixes.EnableClassSkillAffixes", true);
    _enableTalentAffixes     = sConfigMgr->GetOption<bool> ("ItemAffixes.EnableTalentAffixes",     true);
    _enableRoleSelection     = sConfigMgr->GetOption<bool> ("ItemAffixes.EnableRoleSelection",     true);
    _enableMainStatSelection = sConfigMgr->GetOption<bool> ("ItemAffixes.EnableMainStatSelection", true);
    _twoHanderBonusSlots     = sConfigMgr->GetOption<uint8>("ItemAffixes.TwoHanderBonusSlots",     1);
    _budgetFractionGreen     = sConfigMgr->GetOption<float>("ItemAffixes.BudgetFractionGreen",     0.18f);
    _budgetFractionBlue      = sConfigMgr->GetOption<float>("ItemAffixes.BudgetFractionBlue",      0.13f);
    _budgetFractionPurple    = sConfigMgr->GetOption<float>("ItemAffixes.BudgetFractionPurple",    0.10f);
    _budgetMinRoll           = std::clamp(sConfigMgr->GetOption<float>  ("ItemAffixes.BudgetMinRoll",      0.75f), 0.0f, 1.0f);
    _statMultiplier          = sConfigMgr->GetOption<float>  ("ItemAffixes.StatMultiplier",          1.0f);
    _imprintRollChance       = sConfigMgr->GetOption<uint32> ("ItemAffixes.ImprintRollChance",       30);

    LoadTalentAffixDefs();
}

// ---------------------------------------------------------------------------
// LoadTalentAffixDefs
// ---------------------------------------------------------------------------

void ItemAffixMgr::LoadTalentAffixDefs()
{
    _talentDefs.clear();

    QueryResult result = WorldDatabase.Query(
        "SELECT id, name, class_mask, spec_tree, max_rank, spell_family, "
        "family_flags0, family_flags1, family_flags2, carrier_spell, spellmod_op, spellmod_type, value_per_rank, "
        "COALESCE(item_category, 0) "
        "FROM talent_affix_def");

    if (!result)
    {
        LOG_INFO("module", "mod-item-affixes: talent_affix_def is empty — no talent affixes will roll.");
        return;
    }

    uint32 cnt = 0;
    do
    {
        Field* f = result->Fetch();
        TalentAffixDef def;
        def.id              = f[0].Get<uint32>();
        def.name            = f[1].Get<std::string>();
        def.classMask       = f[2].Get<uint32>();
        def.specTree        = f[3].Get<int8>();
        def.maxRank         = f[4].Get<uint8>();
        def.spellFamily     = f[5].Get<uint8>();
        def.familyFlags[0]  = f[6].Get<uint32>();
        def.familyFlags[1]  = f[7].Get<uint32>();
        def.familyFlags[2]  = f[8].Get<uint32>();
        def.carrierSpell    = f[9].Get<uint32>();
        def.spellmodOp      = f[10].Get<uint8>();
        def.spellmodType    = f[11].Get<uint8>();
        def.valuePerRank    = f[12].Get<int32>();
        def.itemCategory    = f[13].Get<uint8>();

        if (!sSpellMgr->GetSpellInfo(def.carrierSpell))
        {
            LOG_ERROR("module", "mod-item-affixes: talent affix {} has invalid carrier_spell {}, skipping.",
                def.id, def.carrierSpell);
            continue;
        }

        _talentDefs[def.id] = std::move(def);
        ++cnt;
    } while (result->NextRow());

    LOG_INFO("module", "mod-item-affixes: loaded {} talent affix def(s).", cnt);
}

// ---------------------------------------------------------------------------
// GetAffixDef
// ---------------------------------------------------------------------------

AffixDefinition const* ItemAffixMgr::GetAffixDef(uint32 id) const
{
    auto it = _defs.find(id);
    return (it != _defs.end()) ? &it->second : nullptr;
}

// ---------------------------------------------------------------------------
// GetEligibleTalentAffix  — picks a random talent def this player can roll
// ---------------------------------------------------------------------------

TalentAffixDef const* ItemAffixMgr::GetEligibleTalentAffix(Player* player, Item const* item, int8 specOverride)
{
    if (_talentDefs.empty())
        return nullptr;

    uint32 classBit = 1u << (static_cast<uint32>(player->getClass()) - 1u);
    int    specTree = (specOverride >= 0) ? specOverride : GetDominantTalentTree(player);
    uint8  itemCat  = item ? GetItemCategory(item) : ITEM_CAT_ANY;

    std::vector<TalentAffixDef const*> eligible;
    for (auto const& [id, def] : _talentDefs)
    {
        if (def.classMask != 0 && !(def.classMask & classBit))
            continue;
        if (def.specTree != -1 && def.specTree != static_cast<int8>(specTree))
            continue;
        if (def.itemCategory != ITEM_CAT_ANY && !ItemMatchesCategory(itemCat, def.itemCategory))
            continue;
        eligible.push_back(&def);
    }

    if (eligible.empty())
        return nullptr;

    return eligible[urand(0, static_cast<uint32>(eligible.size()) - 1)];
}

// ---------------------------------------------------------------------------
// InitTalentAffix  — auto-rolls talent affix for a newly acquired item
// ---------------------------------------------------------------------------

void ItemAffixMgr::InitTalentAffix(Player* player, Item* item, int8 specOverride, uint8 affixSlot)
{
    if (_talentDefs.empty() || !player || !item)
    {
        LOG_DEBUG("module", "mod-item-affixes: InitTalentAffix — early exit: talentDefs.empty={} player={} item={}",
            _talentDefs.empty(), player == nullptr, item == nullptr);
        return;
    }

    uint32 entry   = item->GetEntry();
    uint8  quality = static_cast<uint8>(item->GetTemplate()->Quality);
    uint64 guid    = item->GetGUID().GetRawValue();

    LOG_DEBUG("module", "mod-item-affixes: InitTalentAffix entry={} quality={} guid={}", entry, quality, guid);

    if (quality < ITEM_QUALITY_UNCOMMON)
    {
        LOG_DEBUG("module", "mod-item-affixes: InitTalentAffix — skipped: quality {} < UNCOMMON(2)", quality);
        return;
    }

    // No-op if this slot already has a talent affix (re-entry guard).
    QueryResult check = CharacterDatabase.Query(
        "SELECT 1 FROM item_talent_affix WHERE item_guid = {} AND affix_slot = {}", guid, affixSlot);
    if (check)
    {
        LOG_DEBUG("module", "mod-item-affixes: InitTalentAffix — skipped: slot {} already has talent (guid={})", affixSlot, guid);
        return;
    }

    // Roll by quality: 10% green, 50% blue, 50% purple+
    if (quality == ITEM_QUALITY_UNCOMMON && urand(0, 9) != 0)
    {
        LOG_DEBUG("module", "mod-item-affixes: InitTalentAffix — skipped: green roll miss (guid={})", guid);
        return;
    }
    if (quality >= ITEM_QUALITY_RARE && urand(0, 1) == 0)
    {
        LOG_DEBUG("module", "mod-item-affixes: InitTalentAffix — skipped: blue/epic roll miss (guid={})", guid);
        return;
    }

    TalentAffixDef const* def = GetEligibleTalentAffix(player, item, specOverride);
    if (!def)
    {
        int usedTree = (specOverride >= 0) ? specOverride : GetDominantTalentTree(player);
        LOG_DEBUG("module", "mod-item-affixes: InitTalentAffix — no eligible def for class={} specTree={}",
            player->getClass(), usedTree);
        return;
    }

    // Roll range: blues/greens get 1..ceil(maxRank/2); purples+ get 1..maxRank
    uint8 maxVal = (quality >= ITEM_QUALITY_EPIC)
        ? def->maxRank
        : static_cast<uint8>((def->maxRank + 1) / 2);
    int32 rolledValue = static_cast<int32>(urand(1, static_cast<uint32>(maxVal)));

    LOG_DEBUG("module", "mod-item-affixes: InitTalentAffix — rolling defId={} value={} onto guid={}",
        def->id, rolledValue, guid);

    CharacterDatabase.DirectExecute(
        "INSERT INTO item_talent_affix (item_guid, affix_slot, affix_id, rolled_value) VALUES ({}, {}, {}, {})",
        guid, affixSlot, def->id, rolledValue);
}

// ---------------------------------------------------------------------------
// ApplyTalentAffixes  — apply SpellMods for talent affixes on equip
// ---------------------------------------------------------------------------

void ItemAffixMgr::ApplyTalentAffixes(Player* player, Item* item)
{
    if (!player || !item)
        return;

    uint64 guid = item->GetGUID().GetRawValue();
    QueryResult result = CharacterDatabase.Query(
        "SELECT affix_id, rolled_value FROM item_talent_affix WHERE item_guid = {}", guid);
    if (!result)
        return;

    ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");

    auto& mods = data->activeTalentMods[guid];
    // Clear any existing mods for this item (safety guard)
    for (SpellModifier* mod : mods)
        player->AddSpellMod(mod, false);
    mods.clear();

    do
    {
        Field* f        = result->Fetch();
        uint32 affixId  = f[0].Get<uint32>();
        int32  rolledVal = f[1].Get<int32>();

        auto it = _talentDefs.find(affixId);
        if (it == _talentDefs.end())
        {
                continue;
        }
        TalentAffixDef const& def = it->second;

        SpellModifier* mod = new SpellModifier(nullptr);
        mod->op      = static_cast<SpellModOp>(def.spellmodOp);
        mod->type    = static_cast<SpellModType>(def.spellmodType);
        mod->spellId = def.carrierSpell;
        mod->mask    = flag96(def.familyFlags[0], def.familyFlags[1], def.familyFlags[2]);
        mod->value   = def.valuePerRank * rolledVal;
        player->AddSpellMod(mod, true);
        mods.push_back(mod);

    } while (result->NextRow());
}

// ---------------------------------------------------------------------------
// RemoveTalentAffixes  — remove SpellMods for talent affixes on unequip
// ---------------------------------------------------------------------------

void ItemAffixMgr::RemoveTalentAffixes(Player* player, Item* item)
{
    if (!player || !item)
        return;

    uint64 guid = item->GetGUID().GetRawValue();
    ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");

    auto it = data->activeTalentMods.find(guid);
    if (it == data->activeTalentMods.end())
        return;

    for (SpellModifier* mod : it->second)
        player->AddSpellMod(mod, false);  // AddSpellMod(false) deletes the mod
    data->activeTalentMods.erase(it);
}

// ---------------------------------------------------------------------------
// RollAffixId
// ---------------------------------------------------------------------------

uint32 ItemAffixMgr::RollAffixId(uint32 itemQuality, Player* player, Item* item,
                                  bool genericsOnly, uint8 classBoost,
                                  bool classOnly,
                                  uint8 preferredRole, uint8 preferredMainStat,
                                  int8 spec)
{
    uint8 playerClass = player->getClass();
    uint8 itemCat   = item ? GetItemCategory(item) : ITEM_CAT_ANY;
    // Pre-compute item budget for stat affix eligibility (avoid recomputing per affix).
    float itemBudgetBase = item
        ? ComputeItemBudget(item->GetTemplate()->ItemLevel) * GetSlotBudgetMod(item->GetTemplate()->InventoryType)
        : ComputeItemBudget(static_cast<uint32>(player->GetLevel()) * 5) * 0.74f;  // fallback
    float itemBudget = itemBudgetBase * GetQualityFraction(itemQuality);

    std::vector<uint32> knownClass, knownGeneric, unknownClass, unknownGeneric;

    for (uint32 id : _pool)
    {
        auto const* def = GetAffixDef(id);
        if (!def || def->minQuality > itemQuality)
            continue;

        // Green items may only roll generic (family=0) affixes
        if (genericsOnly && def->spellFamily != 0)
            continue;

        // Class skills only: skip stat affixes and family=0 (generic) affixes
        if (classOnly && (def->spellFamily == 0 || def->affixType == AFFIX_TYPE_STAT))
            continue;

        if (def->itemCategory != ITEM_CAT_ANY && item)
            if (!ItemMatchesCategory(itemCat, def->itemCategory))
                continue;

        if (def->affixType == AFFIX_TYPE_STAT && def->statOp != static_cast<uint8>(GSTAT_MOVE_SPEED))
        {
            // Skip stat affixes whose budget would compute to zero for this item.
            if (static_cast<int32>(itemBudget / GetStatCost(def->statOp)) < 1)
                continue;
        }

        if (def->roleMask != 0 && preferredRole != 0)
        {
            if (!(def->roleMask & preferredRole))
                continue;
        }

        uint8 affixClass = SpellFamilyToClass(def->spellFamily);
        bool isMainStat = (def->affixType == AFFIX_TYPE_STAT &&
                           def->statOp >= GSTAT_STRENGTH && def->statOp <= GSTAT_SPIRIT);
        if (isMainStat && preferredMainStat != 0)
        {
            if (def->statOp != preferredMainStat)
                continue;
        }
        else if (def->affixType != AFFIX_TYPE_STAT)
        {
            // Class-family filter applies only to spellmod affixes.
            if (affixClass != 0 && affixClass != playerClass)
                continue;

            // Spec-tree filter: skip class affixes locked to a different tree.
            // specTree=255 means no restriction. Only applied to class-specific affixes.
            if (def->specTree != 255 && affixClass != 0)
            {
                int8 resolvedSpec = (spec >= 0) ? spec : static_cast<int8>(GetDominantTalentTree(player));
                if (def->specTree != static_cast<uint8>(resolvedSpec))
                    continue;
            }
        }
        // Stat affixes: role mask is the sole class gatekeeper; no family filter.

        bool known = (def->affixType == AFFIX_TYPE_SPELLMOD)
                   ? PlayerKnowsCarrierSpell(player, def->carrierSpellId)
                   : true;

        // Stat affixes bucket as generic — spellFamily on stat affixes is only used
        // for pool expansion (multiple DB rows per stat) and must not affect class weighting.
        uint8 bucketClass = (def->affixType == AFFIX_TYPE_STAT) ? 0 : affixClass;
        if (bucketClass == 0)
        {
            if (known) knownGeneric.push_back(id);
            else       unknownGeneric.push_back(id);
        }
        else
        {
            if (known) knownClass.push_back(id);
            else       unknownClass.push_back(id);
        }
    }

    // classBoost=2: guaranteed class affix — skip generics entirely if any class entry exists.
    if (classBoost >= 2)
    {
        if (!knownClass.empty())
            return knownClass[urand(0, static_cast<uint32>(knownClass.size()) - 1)];
        if (!unknownClass.empty())
            return unknownClass[urand(0, static_cast<uint32>(unknownClass.size()) - 1)];
        // No class affixes available for this player/item — fall through to normal selection.
    }

    // classBoost=1: add class entries a second time to give them ~2x weight vs generics.
    std::vector<uint32> primary;
    primary.insert(primary.end(), knownClass.begin(), knownClass.end());
    if (classBoost >= 1)
        primary.insert(primary.end(), knownClass.begin(), knownClass.end());
    primary.insert(primary.end(), knownGeneric.begin(), knownGeneric.end());
    if (!primary.empty())
        return primary[urand(0, static_cast<uint32>(primary.size()) - 1)];

    std::vector<uint32> fallback;
    fallback.insert(fallback.end(), unknownClass.begin(), unknownClass.end());
    if (classBoost >= 1)
        fallback.insert(fallback.end(), unknownClass.begin(), unknownClass.end());
    fallback.insert(fallback.end(), unknownGeneric.begin(), unknownGeneric.end());
    if (!fallback.empty())
        return fallback[urand(0, static_cast<uint32>(fallback.size()) - 1)];

    return 0;
}

// ---------------------------------------------------------------------------
// Database helpers
// ---------------------------------------------------------------------------

std::vector<AffixSlotInfo> ItemAffixMgr::LoadAffixSlots(uint64 itemGuid)
{
    QueryResult result = CharacterDatabase.Query(
        "SELECT affix_slot, roll_state, affix_id, rolled_value, pending_opts "
        "FROM item_affix WHERE item_guid = {} ORDER BY affix_slot",
        itemGuid);

    if (!result)
        return {};

    std::vector<AffixSlotInfo> slots;
    do
    {
        Field* f = result->Fetch();
        AffixSlotInfo s;
        s.rollState   = f[1].Get<uint8>();
        s.affixId     = f[2].Get<uint32>();
        s.rolledValue = f[3].Get<int32>();
        std::string opts = f[4].Get<std::string>();
        if (!opts.empty())
            for (auto part : Acore::Tokenize(opts, ',', false))
            {
                auto colon = part.find(':');
                if (colon != std::string_view::npos)
                {
                    if (auto id = Acore::StringTo<uint32>(part.substr(0, colon)))
                    {
                        auto rest    = part.substr(colon + 1);
                        auto colon2  = rest.find(':');
                        int32 val    = Acore::StringTo<int32>(
                            colon2 != std::string_view::npos ? rest.substr(0, colon2) : rest
                        ).value_or(0);
                        bool isCrit  = (colon2 != std::string_view::npos &&
                                        rest.substr(colon2 + 1) == "1");
                        s.pendingOpts.push_back({*id, val, isCrit});
                    }
                }
                else if (auto id = Acore::StringTo<uint32>(part))
                    s.pendingOpts.push_back({*id, 0, false});  // legacy: no stored value
            }
        slots.push_back(s);
    } while (result->NextRow());

    return slots;
}

std::vector<ItemAffixRecord> ItemAffixMgr::LoadItemAffixes(uint64 itemGuid)
{
    QueryResult result = CharacterDatabase.Query(
        "SELECT affix_slot, affix_id, rolled_value FROM item_affix "
        "WHERE item_guid = {} AND roll_state = {} ORDER BY affix_slot",
        itemGuid, uint8(AFFIX_ROLL_APPLIED));

    if (!result)
        return {};

    std::array<ItemAffixRecord, 3> slots{};
    do
    {
        Field* f    = result->Fetch();
        uint8  slot = f[0].Get<uint8>();
        if (slot < 3)
            slots[slot] = ItemAffixRecord{ f[1].Get<uint32>(), f[2].Get<int32>() };
    } while (result->NextRow());

    std::vector<ItemAffixRecord> out;
    for (auto const& rec : slots)
        if (rec.affixId)
            out.push_back(rec);
    return out;
}

void ItemAffixMgr::PersistAffix(uint64 itemGuid, uint8 slot, uint32 affixId, int32 rolledValue)
{
    CharacterDatabase.Execute(
        "INSERT INTO item_affix (item_guid, affix_slot, affix_id, rolled_value, roll_state) "
        "VALUES ({}, {}, {}, {}, {}) "
        "ON DUPLICATE KEY UPDATE affix_id = {}, rolled_value = {}, roll_state = {}, pending_opts = ''",
        itemGuid, slot, affixId, rolledValue, uint8(AFFIX_ROLL_APPLIED),
        affixId, rolledValue, uint8(AFFIX_ROLL_APPLIED));
}

// ---------------------------------------------------------------------------
// InitItemSlots  (replaces RollAndAssignAffixes)
// ---------------------------------------------------------------------------

void ItemAffixMgr::InitItemSlots(Player* player, Item* item)
{
    if (_pool.empty() || !player || !item)
        return;

    ItemTemplate const* proto = item->GetTemplate();
    if (!proto)
        return;

    // Gems bypass the equippable check — they are INVTYPE_NON_EQUIP but still roll affixes.
    bool isGem = (proto->Class == ITEM_CLASS_GEM);

    // Only character-sheet gear (and gems) get affix slots. Exclude scrolls, food,
    // quest items, crafting mats, bags, ammo, and quivers.
    if (!isGem)
    {
        switch (proto->InventoryType)
        {
            case INVTYPE_NON_EQUIP: // 0 — scrolls, food, quest items, etc.
            case INVTYPE_BAG:       // 18
            case INVTYPE_AMMO:      // 24
            case INVTYPE_QUIVER:    // 27
                return;
            default:
                break;
        }
    }

    uint8 numSlots = 0;

    if (isGem)
    {
        // Gems: 1 affix slot for uncommon quality and above (stat affixes only, rolled before socketing).
        if (proto->Quality < ITEM_QUALITY_UNCOMMON)
            return;
        numSlots = 1;
    }
    else
    {
        if      (proto->Quality >= ITEM_QUALITY_EPIC)     numSlots = 3;
        else if (proto->Quality == ITEM_QUALITY_RARE)     numSlots = 2;
        else if (proto->Quality == ITEM_QUALITY_UNCOMMON) numSlots = 1;
        else return;  // white/grey: no affixes

        // 2H weapons get bonus slots to compensate for the dual-wield slot advantage.
        if (Is2HWeapon(item))
            numSlots += _twoHanderBonusSlots;
    }

    uint64 itemGuid = item->GetGUID().GetRawValue();

    QueryResult check = CharacterDatabase.Query(
        "SELECT COUNT(*) FROM item_affix WHERE item_guid = {}", itemGuid);
    uint32 existingCount = check ? check->Fetch()[0].Get<uint32>() : 0;

    if (existingCount == numSlots)
        return;  // already correctly initialized

    if (existingCount > numSlots)
    {
        // Too many slots (stale GUID reuse) — wipe and reinitialize from scratch.
        CharacterDatabase.Execute("DELETE FROM item_affix WHERE item_guid = {}", itemGuid);
        existingCount = 0;
    }

    // existingCount < numSlots: add only the missing slots so already-rolled affixes survive.
    for (uint8 slot = static_cast<uint8>(existingCount); slot < numSlots; ++slot)
        CharacterDatabase.Execute(
            "INSERT IGNORE INTO item_affix (item_guid, affix_slot, affix_id, rolled_value, roll_state, pending_opts) "
            "VALUES ({}, {}, 0, 0, {}, '')",
            itemGuid, slot, uint8(AFFIX_ROLL_UNROLLED));

    // Build DATA directly from known state — don't query DB, rows are async and may not be visible yet.
    auto [luaBag, luaSlot] = GetLuaBagSlot(item);
    std::string msg = Acore::StringFormat("DATA|{}|{}|{}",
        uint32(luaBag), uint32(luaSlot), uint32(numSlots));
    for (uint8 i = 0; i < numSlots; ++i)
        msg += Acore::StringFormat("|s{}:U:", i);
    if (isGem)
        msg += "|isGem";
    SendAddonMsg(player, msg);
}

// ---------------------------------------------------------------------------
// Upgrade2HSlots — retroactively grants the extra affix slot to 2H weapons that
// were initialized before the 2H bonus was introduced. Called from OnPlayerLogin
// for every item in the player's bags and equipment. Uses DirectExecute so the
// row is committed before SendItemStatus queries the DB.
// ---------------------------------------------------------------------------

void ItemAffixMgr::Upgrade2HSlots(Player* player, Item* item)
{
    if (_twoHanderBonusSlots == 0)
        return;  // no bonus configured — nothing to retroactively add

    if (!item || !Is2HWeapon(item))
        return;

    ItemTemplate const* proto = item->GetTemplate();
    if (!proto)
        return;

    uint8 expectedSlots = 0;
    if      (proto->Quality >= ITEM_QUALITY_EPIC)     expectedSlots = 3 + _twoHanderBonusSlots;
    else if (proto->Quality == ITEM_QUALITY_RARE)     expectedSlots = 2 + _twoHanderBonusSlots;
    else if (proto->Quality == ITEM_QUALITY_UNCOMMON) expectedSlots = 1 + _twoHanderBonusSlots;
    else return;

    uint64 itemGuid = item->GetGUID().GetRawValue();
    QueryResult check = CharacterDatabase.Query(
        "SELECT COUNT(*) FROM item_affix WHERE item_guid = {}", itemGuid);
    uint32 existingCount = check ? check->Fetch()[0].Get<uint32>() : 0;

    if (existingCount >= expectedSlots)
        return;  // already has the bonus slot (or more)

    // Add the missing slot(s) synchronously so SendItemStatus can see them.
    for (uint8 slot = static_cast<uint8>(existingCount); slot < expectedSlots; ++slot)
        CharacterDatabase.DirectExecute(
            "INSERT IGNORE INTO item_affix (item_guid, affix_slot, affix_id, rolled_value, roll_state, pending_opts) "
            "VALUES ({}, {}, 0, 0, {}, '')",
            itemGuid, slot, uint8(AFFIX_ROLL_UNROLLED));

    // Refresh client display with the corrected slot count.
    SendItemStatus(player, item);
}

// ---------------------------------------------------------------------------
// UpgradeAll2HSlots — called on login to add the extra slot to every 2H
// weapon that was initialized before the 2H bonus was introduced.
// ---------------------------------------------------------------------------

void ItemAffixMgr::UpgradeAll2HSlots(Player* player)
{
    if (!player)
        return;

    // Equipped slots
    for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
    {
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (item)
            Upgrade2HSlots(player, item);
    }

    // Backpack slots
    for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
    {
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (item)
            Upgrade2HSlots(player, item);
    }

    // Extra bag containers
    for (uint8 bagSlot = INVENTORY_SLOT_BAG_START; bagSlot < INVENTORY_SLOT_BAG_END; ++bagSlot)
    {
        Bag* bag = player->GetBagByPos(bagSlot);
        if (!bag)
            continue;
        for (uint32 i = 0; i < bag->GetBagSize(); ++i)
        {
            Item* item = bag->GetItemByPos(i);
            if (item)
                Upgrade2HSlots(player, item);
        }
    }
}

// ---------------------------------------------------------------------------
// ApplyAffixes
// ---------------------------------------------------------------------------

void ItemAffixMgr::ApplyAffixes(Player* player, Item* item)
{
    if (!player || !item)
        return;

    uint64 itemGuid = item->GetGUID().GetRawValue();
    std::vector<ItemAffixRecord> affixRecords = LoadItemAffixes(itemGuid);
    if (affixRecords.empty())
        return;

    ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");

    auto& mods = data->activeMods[itemGuid];
    for (SpellModifier* mod : mods)
        player->AddSpellMod(mod, false);
    mods.clear();

    auto& statMods = data->activeStatMods[itemGuid];
    for (ActiveStatMod const& sm : statMods)
        ApplyGenericStat(player, sm.statOp, sm.value, false);
    statMods.clear();

    for (ItemAffixRecord const& rec : affixRecords)
    {
        auto const* def = GetAffixDef(rec.affixId);
        if (!def)
            continue;

        if (def->affixType == AFFIX_TYPE_SPELLMOD)
        {
            for (int i = 0; i < 4; ++i)
            {
                AffixEffect const& eff = def->effects[i];
                if (eff.op == 255)
                    continue;
                SpellModifier* mod = new SpellModifier(nullptr);
                mod->op      = static_cast<SpellModOp>(eff.op);
                mod->type    = eff.type;
                // rolledValue encodes the scale: 0=plain, 150=2H(×1.5), 200=crit(×1.5), 250=2H+crit(×2.25).
                float spellmodScale = 1.0f;
                if (rec.rolledValue == 150 || rec.rolledValue == 200) spellmodScale = 1.5f;
                else if (rec.rolledValue == 250)                       spellmodScale = 2.25f;
                if (spellmodScale != 1.0f)
                {
                    float absVal = std::abs(static_cast<float>(eff.value));
                    float scaled = std::ceil(absVal * spellmodScale);
                    mod->value = (eff.value >= 0) ? static_cast<int32>(scaled) : -static_cast<int32>(scaled);
                }
                else
                    mod->value = eff.value;
                mod->mask    = flag96(def->spellFamilyFlags[0], def->spellFamilyFlags[1], def->spellFamilyFlags[2]);
                mod->spellId = def->carrierSpellId;
                player->AddSpellMod(mod, true);
                mods.push_back(mod);
            }
        }
        else if (def->affixType == AFFIX_TYPE_STAT)
        {
            int32 val = rec.rolledValue;
            if (val == 0)
                continue;
            ApplyGenericStat(player, def->statOp, val, true);
            data->activeStatMods[itemGuid].push_back(ActiveStatMod{ def->statOp, val });
        }
    }
}

// ---------------------------------------------------------------------------
// RemoveAffixes
// ---------------------------------------------------------------------------

void ItemAffixMgr::RemoveAffixes(Player* player, Item* item)
{
    if (!player || !item)
        return;

    uint64 itemGuid = item->GetGUID().GetRawValue();
    ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");

    auto it = data->activeMods.find(itemGuid);
    if (it != data->activeMods.end())
    {
        for (SpellModifier* mod : it->second)
            player->AddSpellMod(mod, false);
        data->activeMods.erase(it);
    }

    auto sit = data->activeStatMods.find(itemGuid);
    if (sit != data->activeStatMods.end())
    {
        for (ActiveStatMod const& sm : sit->second)
            ApplyGenericStat(player, sm.statOp, sm.value, false);
        data->activeStatMods.erase(sit);
    }
}

// ---------------------------------------------------------------------------
// ApplyGemAffixes / RemoveGemAffixes
// ---------------------------------------------------------------------------

void ItemAffixMgr::ApplyGemAffixes(Player* player, Item* gearItem)
{
    if (!player || !gearItem)
        return;

    uint64 gearGuid = gearItem->GetGUID().GetRawValue();

    QueryResult result = CharacterDatabase.Query(
        "SELECT affix_id, rolled_value FROM item_gem_affix WHERE gear_guid = {}",
        gearGuid);
    if (!result)
        return;

    ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");
    auto& gemMods = data->activeGemStatMods[gearGuid];

    do
    {
        Field* f       = result->Fetch();
        uint32 affixId = f[0].Get<uint32>();
        int32  val     = f[1].Get<int32>();
        auto const* def = GetAffixDef(affixId);
        if (!def || def->affixType != AFFIX_TYPE_STAT || val == 0)
            continue;
        ApplyGenericStat(player, def->statOp, val, true);
        gemMods.push_back(ActiveStatMod{ def->statOp, val });
    } while (result->NextRow());
}

void ItemAffixMgr::RemoveGemAffixes(Player* player, Item* gearItem)
{
    if (!player || !gearItem)
        return;

    uint64 gearGuid = gearItem->GetGUID().GetRawValue();
    ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");

    auto it = data->activeGemStatMods.find(gearGuid);
    if (it != data->activeGemStatMods.end())
    {
        for (ActiveStatMod const& sm : it->second)
            ApplyGenericStat(player, sm.statOp, sm.value, false);
        data->activeGemStatMods.erase(it);
    }
}

// ---------------------------------------------------------------------------
// OnSocketGem  — transfers gem affix to gear at socket time
// ---------------------------------------------------------------------------

void ItemAffixMgr::OnSocketGem(Player* player, Item* gearItem, Item* gemItem, uint8 socketSlot)
{
    if (!player || !gearItem || !gemItem)
        return;

    uint64 gemGuid  = gemItem->GetGUID().GetRawValue();
    uint64 gearGuid = gearItem->GetGUID().GetRawValue();

    // Look up the gem's applied affix (if the player rolled it).
    QueryResult gemAffix = CharacterDatabase.Query(
        "SELECT affix_id, rolled_value FROM item_affix "
        "WHERE item_guid = {} AND roll_state = {} LIMIT 1",
        gemGuid, uint8(AFFIX_ROLL_APPLIED));

    // Remove currently active gem stat bonuses before modifying the DB record.
    if (gearItem->IsEquipped())
        RemoveGemAffixes(player, gearItem);

    if (gemAffix)
    {
        Field* f       = gemAffix->Fetch();
        uint32 affixId = f[0].Get<uint32>();
        int32  val     = f[1].Get<int32>();

        // Upsert: handles first insert and gem replacement in one atomic write.
        // DirectExecute so ApplyGemAffixes can query the new row immediately.
        CharacterDatabase.DirectExecute(
            "INSERT INTO item_gem_affix (gear_guid, socket_slot, affix_id, rolled_value) "
            "VALUES ({}, {}, {}, {}) "
            "ON DUPLICATE KEY UPDATE affix_id = VALUES(affix_id), rolled_value = VALUES(rolled_value)",
            gearGuid, uint32(socketSlot), affixId, val);

        if (gearItem->IsEquipped())
            ApplyGemAffixes(player, gearItem);
    }
    else
    {
        // Gem had no applied affix — clear any stale row for this socket slot.
        CharacterDatabase.Execute(
            "DELETE FROM item_gem_affix WHERE gear_guid = {} AND socket_slot = {}",
            gearGuid, uint32(socketSlot));
    }

    // Gem is about to be destroyed — clean up its affix rows.
    CharacterDatabase.Execute("DELETE FROM item_affix WHERE item_guid = {}", gemGuid);
    CharacterDatabase.Execute("DELETE FROM item_talent_affix WHERE item_guid = {}", gemGuid);

    // Update the gear item's tooltip so the new gem affix line appears.
    SendItemStatus(player, gearItem);
}

// ---------------------------------------------------------------------------
// ReapplyAllEquipped
// ---------------------------------------------------------------------------

void ItemAffixMgr::ReapplyAllEquipped(Player* player)
{
    if (!player)
        return;

    for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
    {
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (item)
        {
            ApplyAffixes(player, item);
            ApplyTalentAffixes(player, item);
            ApplyGemAffixes(player, item);
        }
    }
}

// ---------------------------------------------------------------------------
// SyncAffixes
// ---------------------------------------------------------------------------

void ItemAffixMgr::SyncAffixes(Player* player)
{
    if (!player)
        return;

    ItemAffixPlayerData* data = player->CustomData.Get<ItemAffixPlayerData>("ItemAffixData");
    if (data)
    {
        for (auto& [guid, mods] : data->activeMods)
            for (SpellModifier* mod : mods)
                player->AddSpellMod(mod, false);
        data->activeMods.clear();

        for (auto& [guid, statMods] : data->activeStatMods)
            for (ActiveStatMod const& sm : statMods)
                ApplyGenericStat(player, sm.statOp, sm.value, false);
        data->activeStatMods.clear();

        for (auto& [guid, mods] : data->activeTalentMods)
            for (SpellModifier* mod : mods)
                player->AddSpellMod(mod, false);
        data->activeTalentMods.clear();

        for (auto& [guid, statMods] : data->activeGemStatMods)
            for (ActiveStatMod const& sm : statMods)
                ApplyGenericStat(player, sm.statOp, sm.value, false);
        data->activeGemStatMods.clear();
    }

    ReapplyAllEquipped(player);
}

// ---------------------------------------------------------------------------
// RemoveAllActiveMods
// ---------------------------------------------------------------------------

void ItemAffixMgr::RemoveAllActiveMods(Player* player)
{
    if (!player)
        return;

    ItemAffixPlayerData* data = player->CustomData.Get<ItemAffixPlayerData>("ItemAffixData");
    if (!data)
        return;

    for (auto& [guid, mods] : data->activeMods)
        for (SpellModifier* mod : mods)
            player->AddSpellMod(mod, false);
    data->activeMods.clear();

    for (auto& [guid, statMods] : data->activeStatMods)
        for (ActiveStatMod const& sm : statMods)
            ApplyGenericStat(player, sm.statOp, sm.value, false);
    data->activeStatMods.clear();

    for (auto& [guid, mods] : data->activeTalentMods)
        for (SpellModifier* mod : mods)
            player->AddSpellMod(mod, false);
    data->activeTalentMods.clear();
}

// ---------------------------------------------------------------------------
// Addon message transport
// ---------------------------------------------------------------------------

void ItemAffixMgr::SendAddonMsg(Player* player, std::string const& payload)
{
    if (!player || !player->GetSession())
        return;

    // Full on-wire message: prefix + tab + body.  Client fires CHAT_MSG_ADDON(prefix, body).
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

void ItemAffixMgr::SendConfig(Player* player)
{
    SendAddonMsg(player, Acore::StringFormat("CONFIG|{}|{}|{}|{}",
        _enableClassSkillAffixes                              ? 1 : 0,  // AFX_CFG_TYPE: show type selector
        (_enableClassSkillAffixes || _enableTalentAffixes)    ? 1 : 0,  // AFX_CFG_SPEC: show spec selector
        _enableRoleSelection                                  ? 1 : 0,
        _enableMainStatSelection                              ? 1 : 0));
}

// ---------------------------------------------------------------------------
// Display string helpers
// ---------------------------------------------------------------------------

// Scales all embedded integer values in a SpellMod affix name by factor (ceiling).
// E.g. "Fireball: +15% Damage" * 1.5 → "Fireball: +23% Damage".
// Class JSON spell names contain no digits, so scanning all digit runs is safe.
static std::string ScaleNameNumerics(std::string const& name, float factor)
{
    std::string result;
    size_t i = 0;
    while (i < name.size())
    {
        if (std::isdigit(static_cast<unsigned char>(name[i])))
        {
            size_t start = i;
            while (i < name.size() && std::isdigit(static_cast<unsigned char>(name[i]))) ++i;
            int val    = std::stoi(name.substr(start, i - start));
            int scaled = static_cast<int>(std::ceil(val * factor));
            result += std::to_string(scaled);
        }
        else
            result += name[i++];
    }
    return result;
}

std::string ItemAffixMgr::BuildAffixDisplayString(AffixDefinition const* def, int32 rolledValue)
{
    if (!def)
        return "";

    if (def->affixType == AFFIX_TYPE_STAT)
    {
        if (static_cast<GenericStatOp>(def->statOp) == GSTAT_MOVE_SPEED)
            return Acore::StringFormat("+{}% Move Speed", rolledValue);

        static const char* statNames[] = {
            "Stamina", "Strength", "Agility", "Intellect", "Spirit",
            "Attack Power", "Ranged Attack Power", "Spell Power", "Mp5",
            "Armor", "Crit Rating", "Haste Rating", "Hit Rating",
            "Dodge Rating", "Defense Rating", "Parry Rating",
            "Expertise Rating", "Armor Pen Rating"
        };
        const char* statName = (def->statOp < sizeof(statNames) / sizeof(statNames[0]))
                             ? statNames[def->statOp] : "Unknown";
        return Acore::StringFormat("+{} {}", rolledValue, statName);
    }

    // Spellmod affix: name is human-readable; scale numeric values for 2H/crit boost.
    if (rolledValue == 150 || rolledValue == 200)
        return ScaleNameNumerics(def->name, 1.5f);
    if (rolledValue == 250)
        return ScaleNameNumerics(def->name, 2.25f);
    return def->name;
}

// ---------------------------------------------------------------------------
// SendRollOptions  — sends OPTS packet to client for a pending slot
// ---------------------------------------------------------------------------

void ItemAffixMgr::SendRollOptions(Player* player, Item* item, uint8 affixSlot,
                                   std::vector<PendingOpt> const& opts)
{
    auto [luaBag, luaSlot] = GetLuaBagSlot(item);
    std::string msg = Acore::StringFormat("OPTS|{}|{}|{}",
        uint32(luaBag), uint32(luaSlot), uint32(affixSlot));

    for (PendingOpt const& opt : opts)
    {
        msg += "|";
        if (opt.IsImprint())
        {
            // ~ prefix tells the addon this option is an Imprint, not a normal affix.
            ImprintDef const* impDef = sImprintMgr->GetDef(opt.GetImprintId());
            msg += "~";
            msg += impDef ? impDef->name : "Imprint";
        }
        else
        {
            auto const* def = GetAffixDef(opt.affixId);
            if (!def) continue;

            if (opt.isCrit)
                msg += "!";   // crit marker — Lua strips this and shows gold glow
            msg += BuildAffixDisplayString(def, opt.rolledValue);
        }
    }

    SendAddonMsg(player, msg);
}

// ---------------------------------------------------------------------------
// SendItemStatus  — sends DATA packet with full slot states for one item
// ---------------------------------------------------------------------------

void ItemAffixMgr::SendItemStatus(Player* player, Item* item, std::string const& extraTalentLine)
{
    if (!player || !item)
        return;

    auto slots = LoadAffixSlots(item->GetGUID().GetRawValue());
    if (slots.empty())
        return;

    auto [luaBag, luaSlot] = GetLuaBagSlot(item);
    std::string msg = Acore::StringFormat("DATA|{}|{}|{}",
        uint32(luaBag), uint32(luaSlot), uint32(slots.size()));

    for (size_t i = 0; i < slots.size(); ++i)
    {
        AffixSlotInfo const& s = slots[i];
        char stateChar;
        std::string text;

        switch (s.rollState)
        {
            case AFFIX_ROLL_UNROLLED: stateChar = 'U'; break;
            case AFFIX_ROLL_PENDING:  stateChar = 'P'; break;
            case AFFIX_ROLL_APPLIED:
                stateChar = 'A';
                if (auto const* def = GetAffixDef(s.affixId))
                {
                    text = BuildAffixDisplayString(def, s.rolledValue);
                    if (def->affixType == AFFIX_TYPE_SPELLMOD && (s.rolledValue == 200 || s.rolledValue == 250))
                        text = "!" + text;
                }
                break;
            default: stateChar = '-'; break;
        }

        msg += Acore::StringFormat("|s{}:{}:{}", i, stateChar, text);
    }

    // Flag gem items so the Lua Roll UI can hide irrelevant selectors.
    ItemTemplate const* proto = item->GetTemplate();
    if (proto && proto->Class == ITEM_CLASS_GEM)
        msg += "|isGem";

    // Append talent affix segments.
    // extraTalentLine is passed by InitTalentAffix immediately after an async INSERT
    // so the just-queued row may not be committed yet; we use the pre-built string instead.
    QueryResult talentResult = CharacterDatabase.Query(
        "SELECT affix_id, rolled_value FROM item_talent_affix WHERE item_guid = {}",
        item->GetGUID().GetRawValue());
    if (talentResult)
    {
        do
        {
            Field* f         = talentResult->Fetch();
            uint32 affixId   = f[0].Get<uint32>();
            int32  rolledVal  = f[1].Get<int32>();
            auto it = _talentDefs.find(affixId);
            if (it != _talentDefs.end())
                msg += Acore::StringFormat("|ta:+{} to {}", rolledVal, it->second.name);
        } while (talentResult->NextRow());
    }
    else if (!extraTalentLine.empty())
    {
        msg += "|ta:" + extraTalentLine;
    }

    // Append gem affix lines for gear items (not for gem items themselves).
    if (!proto || proto->Class != ITEM_CLASS_GEM)
    {
        QueryResult gemResult = CharacterDatabase.Query(
            "SELECT affix_id, rolled_value FROM item_gem_affix WHERE gear_guid = {} ORDER BY socket_slot",
            item->GetGUID().GetRawValue());
        if (gemResult)
        {
            do
            {
                Field* gf      = gemResult->Fetch();
                uint32 affixId = gf[0].Get<uint32>();
                int32  val     = gf[1].Get<int32>();
                auto const* def = GetAffixDef(affixId);
                if (def)
                {
                    std::string gemText = BuildAffixDisplayString(def, val);
                    if (!gemText.empty())
                        msg += "|gem:" + gemText;
                }
            } while (gemResult->NextRow());
        }
    }

    // Append Imprint line if the item carries one.
    ImprintInstance const* impInst = sImprintMgr->GetInstance(item->GetGUID().GetRawValue());
    if (impInst)
    {
        ImprintDef const* impDef = sImprintMgr->GetDef(impInst->imprintId);
        std::string impName = impDef ? impDef->name : "Unknown Imprint";
        msg += Acore::StringFormat("|imprint:{}:{}", impName, impInst->extractionsLeft);
    }

    SendAddonMsg(player, msg);
}

// ---------------------------------------------------------------------------
// HandleRollRequest  — rolls options for next unrolled slot (or re-sends pending)
// ---------------------------------------------------------------------------

void ItemAffixMgr::HandleRollRequest(Player* player, Item* item, uint8 affixSlot,
                                      uint8 type, int8 spec, uint8 role, uint8 mainStat)
{
    if (!player || !item)
        return;

    uint64 itemGuid = item->GetGUID().GetRawValue();
    auto slots = LoadAffixSlots(itemGuid);
    if (affixSlot >= slots.size())
        return;

    AffixSlotInfo const& slotInfo = slots[affixSlot];

    if (slotInfo.rollState == AFFIX_ROLL_PENDING)
    {
        SendRollOptions(player, item, affixSlot, slotInfo.pendingOpts);
        return;
    }

    if (slotInfo.rollState != AFFIX_ROLL_UNROLLED)
        return;

    ItemTemplate const* proto = item->GetTemplate();
    if (!proto)
        return;

    bool isGem = (proto->Class == ITEM_CLASS_GEM);

    // Gems: stat-only, 2 options, no talent roll.
    // Non-gems: roll talent affix for this slot, then send DATA so the client
    // sees the talent line before the option picker appears.
    if (!isGem)
    {
        if (_enableTalentAffixes)
        {
            int8 talentSpec = (spec >= 0) ? spec : -1;
            InitTalentAffix(player, item, talentSpec, affixSlot);
        }
        SendItemStatus(player, item);
    }

    uint32 quality = proto->Quality;
    uint8  numOpts;
    bool   genericsOnly = false;
    bool   classOnly    = false;

    if (isGem)
    {
        numOpts      = 2;
        genericsOnly = true;
    }
    else
    {
        if      (quality >= ITEM_QUALITY_EPIC)     numOpts = 3;
        else if (quality == ITEM_QUALITY_RARE)     numOpts = 2;
        else { numOpts = 1; genericsOnly = true; }

        if (!_enableClassSkillAffixes)
        {
            genericsOnly = true;  // class skills globally disabled — stat affixes only
        }
        else
        {
            // Honor player type preference when class skills are available.
            if (type == 1) { genericsOnly = true; }
            if (type == 2) { classOnly = true; genericsOnly = false; }
        }
    }

    int8  specForRoll     = (!isGem && spec >= 0) ? spec : -1;
    uint8 roleForRoll     = _enableRoleSelection ? role : 0;
    uint8 mainStatForRoll = _enableMainStatSelection ? mainStat : 0;

    // Progressive class-affix insurance (non-gems only).
    uint8 nonClassStreak = 0;
    if (!isGem && !classOnly && !genericsOnly)
    {
        for (auto const& s : slots)
        {
            if (s.rollState != AFFIX_ROLL_APPLIED)
                continue;
            auto const* appliedDef = GetAffixDef(s.affixId);
            if (!appliedDef)
                continue;
            // Only class-specific spellmod affixes reset the streak; stat affixes do not.
            bool isClassSpellmod = (appliedDef->affixType == AFFIX_TYPE_SPELLMOD &&
                                    SpellFamilyToClass(appliedDef->spellFamily) != 0);
            if (isClassSpellmod)
                nonClassStreak = 0;
            else
                ++nonClassStreak;
        }
    }
    uint8 classBoost = (genericsOnly || classOnly) ? 0 : (nonClassStreak >= 2 ? 2 : nonClassStreak);

    // Roll distinct affix IDs, pre-rolling the stat value for each so the
    // player sees exactly what they will get before they choose.
    float itemBudget = ComputeItemBudget(item->GetTemplate()->ItemLevel)
                     * GetSlotBudgetMod(item->GetTemplate()->InventoryType)
                     * GetQualityFraction(quality);
    std::vector<PendingOpt> opts;
    for (uint32 attempts = 0; opts.size() < numOpts && attempts < 100; ++attempts)
    {
        uint32 id = RollAffixId(quality, player, item, genericsOnly, classBoost,
                                classOnly, roleForRoll, mainStatForRoll, specForRoll);
        if (!id)
            continue;

        // Pre-roll stat value before dup check so we can compare tier magnitudes.
        int32 val = 0;
        auto const* newDef = GetAffixDef(id);
        if (newDef && newDef->affixType == AFFIX_TYPE_STAT)
            val = RollBudgetStatValue(newDef->statOp, itemBudget, _budgetMinRoll);

        bool dup = false;
        for (PendingOpt const& ex : opts)
        {
            if (ex.affixId == id) { dup = true; break; }
            // Same stat type: reject unless this roll landed a strictly higher value (higher tier).
            if (newDef && newDef->affixType == AFFIX_TYPE_STAT)
            {
                auto const* exDef = GetAffixDef(ex.affixId);
                if (exDef && exDef->affixType == AFFIX_TYPE_STAT && exDef->statOp == newDef->statOp)
                    if (val <= ex.rolledValue) { dup = true; break; }
            }
        }
        if (dup)
            continue;

        opts.push_back({id, val, false});
    }

    // 2H weapon bonus: +50% to all affix values, applied after dedup so the
    // dup check compared unscaled values (keeps the higher raw tier, drops lower).
    if (Is2HWeapon(item))
    {
        for (PendingOpt& opt : opts)
        {
            auto const* d = GetAffixDef(opt.affixId);
            if (!d) continue;
            if (d->affixType == AFFIX_TYPE_STAT)
            {
                // Ceiling of val * 1.5 using integer arithmetic: (val * 3 + 1) / 2
                opt.rolledValue = (opt.rolledValue * 3 + 1) / 2;
            }
            else if (d->affixType == AFFIX_TYPE_SPELLMOD)
            {
                // Store boost flag in rolledValue (normally 0 for spellmod affixes).
                // Value 150 = apply ×1.5 at ApplyAffixes and BuildAffixDisplayString.
                opt.rolledValue = 150;
            }
        }
    }

    // Crit roll: 10% chance per option, applied after 2H bonus.
    // STAT: multiply rolledValue by 1.5 (ceiling). SPELLMOD: escalate flag value.
    for (PendingOpt& opt : opts)
    {
        if (urand(0, 9) != 0)
            continue;
        opt.isCrit = true;
        auto const* d = GetAffixDef(opt.affixId);
        if (!d) continue;
        if (d->affixType == AFFIX_TYPE_STAT)
            opt.rolledValue = (opt.rolledValue * 3 + 1) / 2;
        else if (d->affixType == AFFIX_TYPE_SPELLMOD)
            opt.rolledValue = (opt.rolledValue == 150) ? 250 : 200;
    }

    // Imprint roll: replace the last class spell-mod option with an Imprint option.
    // Never displaces a generic stat affix — Imprints are a super-version of class
    // abilities, not a substitute for stats.  Skipped entirely if the item already
    // has an Imprint (GetEligibleImprintForRoll returns nullptr in that case).
    if (!opts.empty() && urand(0, 99) < _imprintRollChance)
    {
        int replaceIdx = -1;
        for (int i = static_cast<int>(opts.size()) - 1; i >= 0; --i)
        {
            auto const* d = GetAffixDef(opts[i].affixId);
            if (d && d->affixType == AFFIX_TYPE_SPELLMOD)
            {
                replaceIdx = i;
                break;
            }
        }
        if (replaceIdx >= 0)
        {
            ImprintDef const* impDef = sImprintMgr->GetEligibleImprintForRoll(player, item, specForRoll);
            if (impDef)
                opts[replaceIdx] = { IMPRINT_OPT_OFFSET + impDef->id, 0, false };
        }
    }

    if (opts.empty())
        return;

    // Serialize as "id:val:crit,..." so crit state survives logout/relog
    std::string optsStr;
    for (size_t i = 0; i < opts.size(); ++i)
    {
        if (i > 0) optsStr += ',';
        optsStr += std::to_string(opts[i].affixId) + ':'
                 + std::to_string(opts[i].rolledValue) + ':'
                 + (opts[i].isCrit ? '1' : '0');
    }

    CharacterDatabase.Execute(
        "UPDATE item_affix SET roll_state = {}, pending_opts = '{}' "
        "WHERE item_guid = {} AND affix_slot = {}",
        uint8(AFFIX_ROLL_PENDING), optsStr, itemGuid, uint32(affixSlot));

    SendRollOptions(player, item, affixSlot, opts);
}

// ---------------------------------------------------------------------------
// HandlePickOption  — applies a chosen option from a pending slot
// ---------------------------------------------------------------------------

void ItemAffixMgr::HandlePickOption(Player* player, Item* item, uint8 affixSlot, uint8 optIdx)
{
    if (!player || !item)
        return;

    uint64 itemGuid = item->GetGUID().GetRawValue();
    auto slots = LoadAffixSlots(itemGuid);
    if (affixSlot >= slots.size())
        return;

    AffixSlotInfo const& slotInfo = slots[affixSlot];
    if (slotInfo.rollState != AFFIX_ROLL_PENDING)
        return;
    if (optIdx >= slotInfo.pendingOpts.size())
        return;

    PendingOpt const& chosen = slotInfo.pendingOpts[optIdx];

    // Imprint pick: the roll grants the Imprint for free; the affix slot goes
    // back to UNROLLED so it can still be filled with a normal affix later.
    if (chosen.IsImprint())
    {
        sImprintMgr->ApplyImprintFromRoll(player, item, chosen.GetImprintId());

        CharacterDatabase.Execute(
            "UPDATE item_affix SET roll_state = {}, affix_id = 0, rolled_value = 0, pending_opts = '' "
            "WHERE item_guid = {} AND affix_slot = {}",
            uint8(AFFIX_ROLL_UNROLLED), itemGuid, uint32(affixSlot));

        SendItemStatus(player, item);
        return;
    }

    auto const* def = GetAffixDef(chosen.affixId);
    if (!def)
        return;

    // Use the value that was rolled when options were generated — no second roll.
    int32 rolledValue = chosen.rolledValue;

    CharacterDatabase.Execute(
        "UPDATE item_affix SET roll_state = {}, affix_id = {}, rolled_value = {}, pending_opts = '' "
        "WHERE item_guid = {} AND affix_slot = {}",
        uint8(AFFIX_ROLL_APPLIED), chosen.affixId, rolledValue, itemGuid, uint32(affixSlot));

    // Sync immediately if the item is currently equipped
    uint8 bagSlot  = item->GetBagSlot();
    uint8 itemSlot = item->GetSlot();
    if (bagSlot == INVENTORY_SLOT_BAG_0 && itemSlot < EQUIPMENT_SLOT_END)
        SyncAffixes(player);

    // Count unrolled slots remaining (excluding the one we just applied)
    int unrolledLeft = 0;
    for (size_t i = 0; i < slots.size(); ++i)
        if (static_cast<uint8>(i) != affixSlot && slots[i].rollState == AFFIX_ROLL_UNROLLED)
            ++unrolledLeft;

    auto [luaBag, luaSlot] = GetLuaBagSlot(item);
    std::string displayText = BuildAffixDisplayString(def, rolledValue);
    if (def->affixType == AFFIX_TYPE_SPELLMOD && (rolledValue == 200 || rolledValue == 250))
        displayText = "!" + displayText;
    SendAddonMsg(player, Acore::StringFormat("APPLY|{}|{}|{}|{}|{}",
        uint32(luaBag), uint32(luaSlot), uint32(affixSlot), displayText, unrolledLeft));
}

// ---------------------------------------------------------------------------
// RerollItem  — wipes and re-initializes all affix slots (GM command support)
// ---------------------------------------------------------------------------

void ItemAffixMgr::RerollItem(Player* player, Item* item)
{
    if (!player || !item)
        return;

    uint64 itemGuid = item->GetGUID().GetRawValue();

    // Remove active mods if the item is equipped
    uint8 bagSlot  = item->GetBagSlot();
    uint8 itemSlot = item->GetSlot();
    bool equipped  = (bagSlot == INVENTORY_SLOT_BAG_0 && itemSlot < EQUIPMENT_SLOT_END);
    if (equipped)
        RemoveAffixes(player, item);

    // Clear any legacy PERM_ENCHANTMENT_SLOT that the old system may have set.
    // ClearEnchantment marks the item dirty; it will be written on the next character save.
    if (item->GetEnchantmentId(PERM_ENCHANTMENT_SLOT))
        item->ClearEnchantment(PERM_ENCHANTMENT_SLOT);

    // Wipe existing affix rows
    CharacterDatabase.Execute(
        "DELETE FROM item_affix WHERE item_guid = {}", itemGuid);

    // Re-initialize with UNROLLED slots (will no-op if quality is too low)
    InitItemSlots(player, item);

    // Re-apply affixes from the fresh (empty) state if equipped
    if (equipped)
        SyncAffixes(player);
}

// ---------------------------------------------------------------------------
// ClearLegacyEnchants  — strips PERM_ENCHANTMENT_SLOT from every item with affix rows
// ---------------------------------------------------------------------------

void ItemAffixMgr::ClearLegacyEnchants(Player* player)
{
    if (!player)
        return;

    auto clearIfNeeded = [&](Item* item)
    {
        if (!item || !item->GetEnchantmentId(PERM_ENCHANTMENT_SLOT))
            return;
        uint64 guid = item->GetGUID().GetRawValue();
        QueryResult r = CharacterDatabase.Query(
            "SELECT 1 FROM item_affix WHERE item_guid = {} LIMIT 1", guid);
        if (r)
            item->ClearEnchantment(PERM_ENCHANTMENT_SLOT);
    };

    // Equipped items
    for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
        clearIfNeeded(player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot));

    // Backpack
    for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
        clearIfNeeded(player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot));

    // Extra bags
    for (uint8 bagSlot = INVENTORY_SLOT_BAG_START; bagSlot < INVENTORY_SLOT_BAG_END; ++bagSlot)
    {
        Bag* bag = player->GetBagByPos(bagSlot);
        if (!bag) continue;
        for (uint32 s = 0; s < bag->GetBagSize(); ++s)
            clearIfNeeded(bag->GetItemByPos(s));
    }
}

// ---------------------------------------------------------------------------
// Pending-reroll flag helpers
// ---------------------------------------------------------------------------

void ItemAffixMgr::SetPendingReroll(uint64 playerGuid)
{
    _pendingReroll.insert(playerGuid);
}

bool ItemAffixMgr::IsPendingReroll(uint64 playerGuid) const
{
    return _pendingReroll.count(playerGuid) != 0;
}

void ItemAffixMgr::ClearPendingReroll(uint64 playerGuid)
{
    _pendingReroll.erase(playerGuid);
}

// ---------------------------------------------------------------------------
// HandleAddonMessage  — dispatches AFXM commands from client
// ---------------------------------------------------------------------------

void ItemAffixMgr::HandleAddonMessage(Player* player, std::string const& payload)
{
    if (!player || payload.empty())
        return;

    auto parts = Acore::Tokenize(payload, '|', false);
    if (parts.empty())
        return;

    std::string cmd(parts[0]);

    if (cmd == "CONFIG")
    {
        SendConfig(player);
        return;
    }

    if (cmd == "ALLDATA")
    {
        // Equipped items (slot 0-18 in INVENTORY_SLOT_BAG_0)
        for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
        {
            if (Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot))
                if (!LoadAffixSlots(item->GetGUID().GetRawValue()).empty())
                    SendItemStatus(player, item);
        }
        // Backpack (slots 23-38 in INVENTORY_SLOT_BAG_0)
        for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
        {
            if (Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot))
                if (!LoadAffixSlots(item->GetGUID().GetRawValue()).empty())
                    SendItemStatus(player, item);
        }
        // Extra bags (bag slots 19-22)
        for (uint8 bagSlot = INVENTORY_SLOT_BAG_START; bagSlot < INVENTORY_SLOT_BAG_END; ++bagSlot)
        {
            Bag* bag = player->GetBagByPos(bagSlot);
            if (!bag) continue;
            for (uint32 s = 0; s < bag->GetBagSize(); ++s)
                if (Item* item = bag->GetItemByPos(s))
                    if (!LoadAffixSlots(item->GetGUID().GetRawValue()).empty())
                        SendItemStatus(player, item);
        }
        // Re-send imprint spell descriptions so the addon has them after every /reload.
        sImprintMgr->SendImprintDescriptions(player);
        return;
    }

    // PEEK — read-only affix lookup for any item GUID, used by inspect and auction tooltips.
    // Client sends the low-32 unique ID extracted from the item link; server reconstructs the
    // full 64-bit GUID and returns PEEKDATA (same slot/talent format as DATA, no bag/slot key).
    if (cmd == "PEEK")
    {
        if (parts.size() < 2)
            return;
        auto uidOpt = Acore::StringTo<uint32>(parts[1]);
        if (!uidOpt)
            return;

        uint32 uniqueId = *uidOpt;
        // Item GUIDs in WotLK: (HighGuid::Item << 48) | counter.
        // The item link embeds the counter in its uniqueId field.
        ObjectGuid itemGuid(HighGuid::Item, uniqueId);
        uint64 rawGuid = itemGuid.GetRawValue();

        LOG_DEBUG("module", "mod-item-affixes: PEEK from {} uniqueId={} rawGuid={}",
            player->GetName(), uniqueId, rawGuid);

        auto slots = LoadAffixSlots(rawGuid);

        LOG_DEBUG("module", "mod-item-affixes: PEEK uniqueId={} slots found={}",
            uniqueId, slots.size());

        // Always reply — even empty (0 slots) — so the client stops retrying for non-affixed items.
        std::string msg = Acore::StringFormat("PEEKDATA|{}|{}", uniqueId, slots.size());

        for (size_t i = 0; i < slots.size(); ++i)
        {
            AffixSlotInfo const& s = slots[i];
            char stateChar;
            std::string text;
            switch (s.rollState)
            {
                case AFFIX_ROLL_UNROLLED: stateChar = 'U'; break;
                case AFFIX_ROLL_PENDING:  stateChar = 'P'; break;
                case AFFIX_ROLL_APPLIED:
                    stateChar = 'A';
                    if (auto const* def = GetAffixDef(s.affixId))
                    {
                        text = BuildAffixDisplayString(def, s.rolledValue);
                        if (def->affixType == AFFIX_TYPE_SPELLMOD && (s.rolledValue == 200 || s.rolledValue == 250))
                            text = "!" + text;
                    }
                    break;
                default: stateChar = '-'; break;
            }
            msg += Acore::StringFormat("|s{}:{}:{}", i, stateChar, text);
        }

        QueryResult talentResult = CharacterDatabase.Query(
            "SELECT affix_id, rolled_value FROM item_talent_affix WHERE item_guid = {}",
            rawGuid);
        if (talentResult)
        {
            do
            {
                Field* f       = talentResult->Fetch();
                uint32 affixId = f[0].Get<uint32>();
                int32  rv      = f[1].Get<int32>();
                auto it = _talentDefs.find(affixId);
                if (it != _talentDefs.end())
                    msg += Acore::StringFormat("|ta:+{} to {}", rv, it->second.name);
            } while (talentResult->NextRow());
        }

        LOG_DEBUG("module", "mod-item-affixes: PEEK sending: {}", msg);
        SendAddonMsg(player, msg);
        return;
    }

    // PEEKUNIT — inspect by player name + equip slot.
    // GetInventoryItemLink("target", slot) always returns uniqueId=0 in WoW 3.3.5a because
    // the inspect protocol does not transmit item instance GUIDs to other clients.
    // The client sends PEEKUNIT|playerName|luaSlot; we find the online player by name,
    // read the item from their equip slot, and reply with INSPECTDATA.
    if (cmd == "PEEKUNIT")
    {
        if (parts.size() < 3)
            return;

        std::string targetName(parts[1]);
        auto slotOpt = Acore::StringTo<uint8>(parts[2]);
        if (!slotOpt || *slotOpt == 0 || *slotOpt > EQUIPMENT_SLOT_END)
            return;

        uint8 luaSlot = *slotOpt;
        uint8 cppSlot = luaSlot - 1;  // Lua equip slots are 1-based, C++ are 0-based

        Player* target = ObjectAccessor::FindPlayerByName(targetName);

        LOG_DEBUG("module", "mod-item-affixes: PEEKUNIT from {} target={} luaSlot={} found={}",
            player->GetName(), targetName, luaSlot, target != nullptr);

        if (!target || !target->IsInWorld())
        {
            // Not online — empty reply so the client stops retrying.
            SendAddonMsg(player, Acore::StringFormat("INSPECTDATA|{}|{}|0", targetName, luaSlot));
            return;
        }

        Item* targetItem = target->GetItemByPos(INVENTORY_SLOT_BAG_0, cppSlot);
        if (!targetItem)
        {
            SendAddonMsg(player, Acore::StringFormat("INSPECTDATA|{}|{}|0", targetName, luaSlot));
            return;
        }

        uint64 rawGuid = targetItem->GetGUID().GetRawValue();
        auto slots = LoadAffixSlots(rawGuid);

        LOG_DEBUG("module", "mod-item-affixes: PEEKUNIT target={} slot={} guid={} affixSlots={}",
            targetName, luaSlot, rawGuid, slots.size());

        std::string msg = Acore::StringFormat("INSPECTDATA|{}|{}|{}", targetName, luaSlot, slots.size());

        for (size_t i = 0; i < slots.size(); ++i)
        {
            AffixSlotInfo const& s = slots[i];
            char stateChar;
            std::string text;
            switch (s.rollState)
            {
                case AFFIX_ROLL_UNROLLED: stateChar = 'U'; break;
                case AFFIX_ROLL_PENDING:  stateChar = 'P'; break;
                case AFFIX_ROLL_APPLIED:
                    stateChar = 'A';
                    if (auto const* def = GetAffixDef(s.affixId))
                    {
                        text = BuildAffixDisplayString(def, s.rolledValue);
                        if (def->affixType == AFFIX_TYPE_SPELLMOD && (s.rolledValue == 200 || s.rolledValue == 250))
                            text = "!" + text;
                    }
                    break;
                default: stateChar = '-'; break;
            }
            msg += Acore::StringFormat("|s{}:{}:{}", i, stateChar, text);
        }

        QueryResult talentResult = CharacterDatabase.Query(
            "SELECT affix_id, rolled_value FROM item_talent_affix WHERE item_guid = {}",
            rawGuid);
        if (talentResult)
        {
            do
            {
                Field* f       = talentResult->Fetch();
                uint32 affixId = f[0].Get<uint32>();
                int32  rv      = f[1].Get<int32>();
                auto it = _talentDefs.find(affixId);
                if (it != _talentDefs.end())
                    msg += Acore::StringFormat("|ta:+{} to {}", rv, it->second.name);
            } while (talentResult->NextRow());
        }

        LOG_DEBUG("module", "mod-item-affixes: PEEKUNIT sending: {}", msg);
        SendAddonMsg(player, msg);
        return;
    }

    // PEEKAUCTION — read affixes for an AH item by seller name + item template ID.
    // WoW 3.3.5a AH packet does not include item instance GUIDs, so the client sends
    // the seller's character name and item template ID extracted from GetAuctionItemInfo.
    // Server finds the auction in auctionhouse + characters tables and responds with
    // AUCTIONDATA|ownerName|itemId|slotCount|... (same slot format as PEEKDATA).
    if (cmd == "PEEKAUCTION")
    {
        if (parts.size() < 3)
            return;

        std::string ownerName(parts[1]);
        auto itemIdOpt = Acore::StringTo<uint32>(parts[2]);
        if (!itemIdOpt)
            return;
        uint32 itemId = *itemIdOpt;

        LOG_DEBUG("module", "mod-item-affixes: PEEKAUCTION from {} owner={} itemId={}",
            player->GetName(), ownerName, itemId);

        // Find the auction via item_instance to avoid relying on auctionhouse.item_template
        // (column name varies across AzerothCore DB versions).
        QueryResult auctionResult = CharacterDatabase.Query(
            "SELECT ah.itemguid FROM auctionhouse ah "
            "INNER JOIN item_instance ii ON ii.guid = ah.itemguid "
            "INNER JOIN characters c ON c.guid = ah.itemowner "
            "WHERE c.name = '{}' AND ii.itemEntry = {} LIMIT 1",
            ownerName, itemId);

        if (!auctionResult)
        {
            LOG_DEBUG("module", "mod-item-affixes: PEEKAUCTION no auction found for owner={} itemId={}",
                ownerName, itemId);
            SendAddonMsg(player, Acore::StringFormat("AUCTIONDATA|{}|{}|0", ownerName, itemId));
            return;
        }

        uint32 rawCounter = auctionResult->Fetch()[0].Get<uint32>();
        ObjectGuid itemGuid(HighGuid::Item, rawCounter);
        uint64 rawGuid = itemGuid.GetRawValue();

        LOG_DEBUG("module", "mod-item-affixes: PEEKAUCTION found itemguid={} rawGuid={}",
            rawCounter, rawGuid);

        auto slots = LoadAffixSlots(rawGuid);
        std::string msg = Acore::StringFormat("AUCTIONDATA|{}|{}|{}", ownerName, itemId, slots.size());

        for (size_t i = 0; i < slots.size(); ++i)
        {
            AffixSlotInfo const& s = slots[i];
            char stateChar;
            std::string text;
            switch (s.rollState)
            {
                case AFFIX_ROLL_UNROLLED: stateChar = 'U'; break;
                case AFFIX_ROLL_PENDING:  stateChar = 'P'; break;
                case AFFIX_ROLL_APPLIED:
                    stateChar = 'A';
                    if (auto const* def = GetAffixDef(s.affixId))
                    {
                        text = BuildAffixDisplayString(def, s.rolledValue);
                        if (def->affixType == AFFIX_TYPE_SPELLMOD && (s.rolledValue == 200 || s.rolledValue == 250))
                            text = "!" + text;
                    }
                    break;
                default: stateChar = '-'; break;
            }
            msg += Acore::StringFormat("|s{}:{}:{}", i, stateChar, text);
        }

        QueryResult talentResult = CharacterDatabase.Query(
            "SELECT affix_id, rolled_value FROM item_talent_affix WHERE item_guid = {}",
            rawGuid);
        if (talentResult)
        {
            do
            {
                Field* f       = talentResult->Fetch();
                uint32 affixId = f[0].Get<uint32>();
                int32  rv      = f[1].Get<int32>();
                auto it = _talentDefs.find(affixId);
                if (it != _talentDefs.end())
                    msg += Acore::StringFormat("|ta:+{} to {}", rv, it->second.name);
            } while (talentResult->NextRow());
        }

        LOG_DEBUG("module", "mod-item-affixes: PEEKAUCTION sending: {}", msg);
        SendAddonMsg(player, msg);
        return;
    }

    // PEEKUNITALL — bulk prefetch for inspect window open.
    // Client sends PEEKUNITALL|playerName when the inspect window opens (INSPECT_READY event).
    // Server iterates all equipment slots of the named player and sends one INSPECTDATA message
    // per occupied slot (slotCount=0 for items with no affix rows, so client caches the miss).
    // After this, every hover on the inspected player's items is a pure cache read — no flicker.
    if (cmd == "PEEKUNITALL")
    {
        if (parts.size() < 2)
            return;

        std::string targetName(parts[1]);
        Player* target = ObjectAccessor::FindPlayerByName(targetName);

        LOG_DEBUG("module", "mod-item-affixes: PEEKUNITALL from {} target={} found={}",
            player->GetName(), targetName, target != nullptr);

        if (!target || !target->IsInWorld())
            return;

        for (uint8 cppSlot = EQUIPMENT_SLOT_START; cppSlot < EQUIPMENT_SLOT_END; ++cppSlot)
        {
            Item* targetItem = target->GetItemByPos(INVENTORY_SLOT_BAG_0, cppSlot);
            if (!targetItem)
                continue;

            uint64 rawGuid = targetItem->GetGUID().GetRawValue();
            auto slots = LoadAffixSlots(rawGuid);
            uint8 luaSlot = cppSlot + 1;  // Lua slots are 1-based

            std::string msg = Acore::StringFormat("INSPECTDATA|{}|{}|{}", targetName, luaSlot, slots.size());

            for (size_t i = 0; i < slots.size(); ++i)
            {
                AffixSlotInfo const& s = slots[i];
                char stateChar;
                std::string text;
                switch (s.rollState)
                {
                    case AFFIX_ROLL_UNROLLED: stateChar = 'U'; break;
                    case AFFIX_ROLL_PENDING:  stateChar = 'P'; break;
                    case AFFIX_ROLL_APPLIED:
                        stateChar = 'A';
                        if (auto const* def = GetAffixDef(s.affixId))
                        {
                            text = BuildAffixDisplayString(def, s.rolledValue);
                            if (def->affixType == AFFIX_TYPE_SPELLMOD && (s.rolledValue == 200 || s.rolledValue == 250))
                                text = "!" + text;
                        }
                        break;
                    default: stateChar = '-'; break;
                }
                msg += Acore::StringFormat("|s{}:{}:{}", i, stateChar, text);
            }

            QueryResult talentResult = CharacterDatabase.Query(
                "SELECT affix_id, rolled_value FROM item_talent_affix WHERE item_guid = {}",
                rawGuid);
            if (talentResult)
            {
                do
                {
                    Field* f       = talentResult->Fetch();
                    uint32 affixId = f[0].Get<uint32>();
                    int32  rv      = f[1].Get<int32>();
                    auto it = _talentDefs.find(affixId);
                    if (it != _talentDefs.end())
                        msg += Acore::StringFormat("|ta:+{} to {}", rv, it->second.name);
                } while (talentResult->NextRow());
            }

            SendAddonMsg(player, msg);
        }

        LOG_DEBUG("module", "mod-item-affixes: PEEKUNITALL done for {}", targetName);
        return;
    }

    // TRADEPEEK — read-only affix lookup for an item in the trade partner's trade window.
    // WoW 3.3.5a trade protocol strips item GUIDs (uid=0), so PEEK cannot be used.
    // Client sends TRADEPEEK|slot (1-based Lua slot 1-6); server reads the partner's
    // TradeData, loads affix rows for that item, and replies with TRADEDATA|slot|...
    if (cmd == "TRADEPEEK")
    {
        if (parts.size() < 2)
            return;

        auto slotOpt = Acore::StringTo<uint8>(parts[1]);
        if (!slotOpt || *slotOpt < 1 || *slotOpt > TRADE_SLOT_TRADED_COUNT)
            return;

        uint8 luaSlot  = *slotOpt;
        uint8 cppSlot  = luaSlot - 1;  // Lua slots are 1-based, TradeSlots are 0-based

        TradeData* myTrade = player->GetTradeData();
        if (!myTrade)
        {
            SendAddonMsg(player, Acore::StringFormat("TRADEDATA|{}|0", luaSlot));
            return;
        }

        TradeData* partnerTrade = myTrade->GetTraderData();
        if (!partnerTrade)
        {
            SendAddonMsg(player, Acore::StringFormat("TRADEDATA|{}|0", luaSlot));
            return;
        }

        Item* item = partnerTrade->GetItem(TradeSlots(cppSlot));
        if (!item)
        {
            SendAddonMsg(player, Acore::StringFormat("TRADEDATA|{}|0", luaSlot));
            return;
        }

        uint64 rawGuid = item->GetGUID().GetRawValue();
        auto slots = LoadAffixSlots(rawGuid);

        LOG_DEBUG("module", "mod-item-affixes: TRADEPEEK from {} luaSlot={} guid={} affixSlots={}",
            player->GetName(), luaSlot, rawGuid, slots.size());

        std::string msg = Acore::StringFormat("TRADEDATA|{}|{}", luaSlot, slots.size());

        for (size_t i = 0; i < slots.size(); ++i)
        {
            AffixSlotInfo const& s = slots[i];
            char stateChar;
            std::string text;
            switch (s.rollState)
            {
                case AFFIX_ROLL_UNROLLED: stateChar = 'U'; break;
                case AFFIX_ROLL_PENDING:  stateChar = 'P'; break;
                case AFFIX_ROLL_APPLIED:
                    stateChar = 'A';
                    if (auto const* def = GetAffixDef(s.affixId))
                    {
                        text = BuildAffixDisplayString(def, s.rolledValue);
                        if (def->affixType == AFFIX_TYPE_SPELLMOD && (s.rolledValue == 200 || s.rolledValue == 250))
                            text = "!" + text;
                    }
                    break;
                default: stateChar = '-'; break;
            }
            msg += Acore::StringFormat("|s{}:{}:{}", i, stateChar, text);
        }

        QueryResult talentResult = CharacterDatabase.Query(
            "SELECT affix_id, rolled_value FROM item_talent_affix WHERE item_guid = {}",
            rawGuid);
        if (talentResult)
        {
            do
            {
                Field* f       = talentResult->Fetch();
                uint32 affixId = f[0].Get<uint32>();
                int32  rv      = f[1].Get<int32>();
                auto it = _talentDefs.find(affixId);
                if (it != _talentDefs.end())
                    msg += Acore::StringFormat("|ta:+{} to {}", rv, it->second.name);
            } while (talentResult->NextRow());
        }

        LOG_DEBUG("module", "mod-item-affixes: TRADEPEEK sending: {}", msg);
        SendAddonMsg(player, msg);
        return;
    }

    if (cmd == "IMPRINT_APPLY")
    {
        if (parts.size() < 5)
            return;
        auto rBagOpt  = Acore::StringTo<uint8>(parts[1]);
        auto rSlotOpt = Acore::StringTo<uint8>(parts[2]);
        auto tBagOpt  = Acore::StringTo<uint8>(parts[3]);
        auto tSlotOpt = Acore::StringTo<uint8>(parts[4]);
        if (!rBagOpt || !rSlotOpt || !tBagOpt || !tSlotOpt)
            return;
        Item* runeItem   = GetItemByLuaBagSlot(player, *rBagOpt, *rSlotOpt);
        Item* targetItem = GetItemByLuaBagSlot(player, *tBagOpt, *tSlotOpt);
        if (!runeItem || !targetItem)
        {
            LOG_DEBUG("module", "mod-item-affixes: IMPRINT_APPLY — item not found "
                "runeBag={} runeSlot={} targetBag={} targetSlot={}",
                *rBagOpt, *rSlotOpt, *tBagOpt, *tSlotOpt);
            return;
        }
        if (sImprintMgr->ApplyImprintDirect(player, runeItem, targetItem))
            SendItemStatus(player, targetItem);
        return;
    }

    if (parts.size() < 3)
        return;

    auto luaBagOpt  = Acore::StringTo<uint8>(parts[1]);
    auto luaSlotOpt = Acore::StringTo<uint8>(parts[2]);
    if (!luaBagOpt || !luaSlotOpt)
        return;

    Item* item = GetItemByLuaBagSlot(player, *luaBagOpt, *luaSlotOpt);
    if (!item)
    {
        LOG_DEBUG("module", "mod-item-affixes: {} — no item at bag={} slot={} (already moved?)",
            cmd, *luaBagOpt, *luaSlotOpt);
        return;
    }

    if (cmd == "ROLL")
    {
        LOG_DEBUG("module", "ItemAffixes: ROLL received from {} for bag={} slot={} item={}",
            player->GetName(), *luaBagOpt, *luaSlotOpt, item->GetEntry());

        uint64 pguid = player->GetGUID().GetRawValue();
        if (IsPendingReroll(pguid))
        {
            ClearPendingReroll(pguid);
            RerollItem(player, item);
            SendAddonMsg(player, "ERR|0|0|Affixes rerolled.");
            return;
        }

        // Parse optional preference params (backward compat: old clients send 3-part ROLL)
        uint8 type     = 0;
        int8  spec     = -1;
        uint8 role     = 0;
        uint8 mainStat = 0;
        if (parts.size() >= 6)
        {
            if (auto v = Acore::StringTo<uint8>(parts[3])) type = *v;
            if (auto sv = Acore::StringTo<uint8>(parts[4])) spec = (*sv == 255) ? -1 : static_cast<int8>(*sv);
            if (auto v = Acore::StringTo<uint8>(parts[5])) role = *v;
        }
        if (parts.size() >= 7)
        {
            if (auto v = Acore::StringTo<uint8>(parts[6])) mainStat = *v;
        }

        auto slots = LoadAffixSlots(item->GetGUID().GetRawValue());
        if (slots.empty())
        {
            SendAddonMsg(player, "ERR|0|0|Item has no affix slots.");
            return;
        }
        // Find first UNROLLED slot; fall back to first PENDING (logout recovery)
        for (uint8 i = 0; i < static_cast<uint8>(slots.size()); ++i)
            if (slots[i].rollState == AFFIX_ROLL_UNROLLED)
            {
                HandleRollRequest(player, item, i, type, spec, role, mainStat);
                return;
            }
        for (uint8 i = 0; i < static_cast<uint8>(slots.size()); ++i)
            if (slots[i].rollState == AFFIX_ROLL_PENDING)
            {
                HandleRollRequest(player, item, i);
                return;
            }
        SendAddonMsg(player, "ERR|0|0|All affix slots already applied.");
    }
    else if (cmd == "PICK" && parts.size() >= 4)
    {
        auto optIdxOpt = Acore::StringTo<uint8>(parts[3]);
        if (!optIdxOpt) return;
        auto slots = LoadAffixSlots(item->GetGUID().GetRawValue());
        for (uint8 i = 0; i < static_cast<uint8>(slots.size()); ++i)
            if (slots[i].rollState == AFFIX_ROLL_PENDING)
            {
                HandlePickOption(player, item, i, *optIdxOpt);
                return;
            }
    }
    else if (cmd == "DATA")
    {
        SendItemStatus(player, item);
    }
}
