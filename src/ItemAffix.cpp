#include "ItemAffix.h"
#include "Imprints/ImprintMgr.h"
#include "PlayerProgression.h"
#include "PlayerProgressionNodes.h"
#include "Bag.h"
#include "Pet.h"
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
#include <algorithm>
#include <cstring>
#include <sstream>

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

// Shared by BuildAffixDisplayString and BuildStatRangeDisplayString so the
// two display paths (single value vs. preview range) can never drift apart.
static const char* const kStatNames[] = {
    "Stamina", "Strength", "Agility", "Intellect", "Spirit",       // 0-4
    "Attack Power", "Ranged Attack Power", "Spell Power", "Mp5",   // 5-8
    "Armor", "Crit Rating", "Haste Rating", "Hit Rating",          // 9-12
    "Dodge Rating", "Defense Rating", "Parry Rating",              // 13-15
    "Expertise Rating", "Armor Pen Rating",                        // 16-17
    "Move Speed", "Life Leech", "Hp5", "Damage Reduction",        // 18-21
};

static char const* GetStatName(uint8 statOp)
{
    return (statOp < sizeof(kStatNames) / sizeof(kStatNames[0])) ? kStatNames[statOp] : "Unknown";
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
// MOVE_SPEED is a special case — not budget-based.
static int32 RollBudgetStatValue(uint8 statOp, float budget, float minRoll)
{
    if (statOp == static_cast<uint8>(GSTAT_MOVE_SPEED))
        return irand(3, 12);
    if (statOp == static_cast<uint8>(GSTAT_DAMAGE_REDUCTION_PCT))
        return irand(1, 3);
    if (statOp == static_cast<uint8>(GSTAT_PET_COOLDOWN_PCT))
        return irand(10, 25);
    if (statOp == static_cast<uint8>(GSTAT_PET_HEALTH_PCT))
        return irand(5, 15);
    if (statOp == static_cast<uint8>(GSTAT_PET_DAMAGE_PCT))
        return irand(5, 15);
    if (statOp == static_cast<uint8>(GSTAT_PET_DMGRED_PCT))
        return irand(1, 3);
    if (statOp == static_cast<uint8>(GSTAT_PET_ATTACKSPEED_PCT))
        return irand(3, 8);

    float cost   = GetStatCost(statOp);
    int32 maxVal = static_cast<int32>(std::floor(budget / cost));
    if (maxVal < 1) maxVal = 1;
    int32 minVal = static_cast<int32>(std::floor(budget * minRoll / cost));
    if (minVal < 1) minVal = 1;
    if (minVal > maxVal) minVal = maxVal;
    return irand(minVal, maxVal);
}

// Stage 5 preview panel: same logic as RollBudgetStatValue, but returns the
// [min, max] range instead of picking one random point in it.
struct StatValueRange { int32 minVal; int32 maxVal; };

static StatValueRange GetBudgetStatValueRange(uint8 statOp, float budget, float minRoll)
{
    if (statOp == static_cast<uint8>(GSTAT_MOVE_SPEED))           return {3, 12};
    if (statOp == static_cast<uint8>(GSTAT_DAMAGE_REDUCTION_PCT)) return {1, 3};
    if (statOp == static_cast<uint8>(GSTAT_PET_COOLDOWN_PCT))     return {10, 25};
    if (statOp == static_cast<uint8>(GSTAT_PET_HEALTH_PCT))       return {5, 15};
    if (statOp == static_cast<uint8>(GSTAT_PET_DAMAGE_PCT))       return {5, 15};
    if (statOp == static_cast<uint8>(GSTAT_PET_DMGRED_PCT))       return {1, 3};
    if (statOp == static_cast<uint8>(GSTAT_PET_ATTACKSPEED_PCT))  return {3, 8};

    float cost   = GetStatCost(statOp);
    int32 maxVal = static_cast<int32>(std::floor(budget / cost));
    if (maxVal < 1) maxVal = 1;
    int32 minVal = static_cast<int32>(std::floor(budget * minRoll / cost));
    if (minVal < 1) minVal = 1;
    if (minVal > maxVal) minVal = maxVal;
    return {minVal, maxVal};
}

// Mirrors BuildAffixDisplayString's STAT branch, but with a value range
// instead of one rolled number. Collapses to a single value when the range
// happens to be a single point, so a fixed-range stat (e.g. Move Speed)
// doesn't render as a redundant "12-12".
static std::string BuildStatRangeDisplayString(AffixDefinition const* def, int32 minVal, int32 maxVal)
{
    auto fmt = [minVal, maxVal](char const* single, char const* range) -> std::string
    {
        return minVal == maxVal ? Acore::StringFormat(single, minVal)
                                 : Acore::StringFormat(range, minVal, maxVal);
    };

    if (static_cast<GenericStatOp>(def->statOp) == GSTAT_MOVE_SPEED)
        return fmt("+{}% Move Speed", "+{}-{}% Move Speed");
    if (static_cast<GenericStatOp>(def->statOp) == GSTAT_DAMAGE_REDUCTION_PCT)
        return fmt("-{}% Damage Taken", "-{}-{}% Damage Taken");
    if (static_cast<GenericStatOp>(def->statOp) == GSTAT_PET_COOLDOWN_PCT)
        return fmt("-{}% Pet Cooldowns", "-{}-{}% Pet Cooldowns");
    if (static_cast<GenericStatOp>(def->statOp) == GSTAT_PET_HEALTH_PCT)
        return fmt("+{}% Pet Health", "+{}-{}% Pet Health");
    if (static_cast<GenericStatOp>(def->statOp) == GSTAT_PET_DAMAGE_PCT)
        return fmt("+{}% Pet Damage", "+{}-{}% Pet Damage");
    if (static_cast<GenericStatOp>(def->statOp) == GSTAT_PET_DMGRED_PCT)
        return fmt("-{}% Pet Dmg Taken", "-{}-{}% Pet Dmg Taken");
    if (static_cast<GenericStatOp>(def->statOp) == GSTAT_PET_ATTACKSPEED_PCT)
        return fmt("+{}% Pet Atk Speed", "+{}-{}% Pet Atk Speed");

    char const* statName = GetStatName(def->statOp);
    if (minVal == maxVal)
        return Acore::StringFormat("+{} {}", minVal, statName);
    return Acore::StringFormat("+{}-{} {}", minVal, maxVal, statName);
}

float ItemAffixMgr::GetQualityFraction(uint32 quality) const
{
    float base;
    if      (quality >= ITEM_QUALITY_LEGENDARY) base = _budgetFractionLegendary;
    else if (quality >= ITEM_QUALITY_EPIC)      base = _budgetFractionPurple;
    else if (quality >= ITEM_QUALITY_RARE)      base = _budgetFractionBlue;
    else                                        base = _budgetFractionGreen;
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
        case GSTAT_MAX_HEALTH:
            player->HandleStatFlatModifier(UNIT_MOD_HEALTH,              TOTAL_VALUE, fval, apply); break;
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
        case GSTAT_HP5:
            player->ApplyHealthRegenBonus(value, apply); break;
        case GSTAT_DAMAGE_REDUCTION_PCT:
            sItemAffixMgr->ApplyDamageReduction(player->GetGUID().GetRawValue(), value, apply);
            break;
        case GSTAT_PET_COOLDOWN_PCT:
        case GSTAT_PET_HEALTH_PCT:
        case GSTAT_PET_DAMAGE_PCT:
        case GSTAT_PET_DMGRED_PCT:
        case GSTAT_PET_ATTACKSPEED_PCT:
        {
            sItemAffixMgr->ApplyPetStatBuff(player->GetGUID().GetRawValue(), statOp, value, apply);
            if (Pet* pet = player->GetPet())
                sItemAffixMgr->ApplyPetStatDelta(pet, static_cast<GenericStatOp>(statOp), value, apply);
            break;
        }
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

void ItemAffixMgr::ApplyPlayerStat(Player* player, uint8 statOp, int32 value, bool apply)
{
    ApplyGenericStat(player, statOp, value, apply);
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
        "affix_type, stat_op, stat_tiers, level_min, level_max, item_category, spec_tree, role_mask, class_mask, "
        "loot_bucket "
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
        def.classMask    = f[29].Get<uint32>();
        def.lootBucket   = static_cast<AffixLootBucket>(f[30].Get<uint8>());
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
        else if (def.affixType == AFFIX_TYPE_SPELL_SWAP)
        {
            uint32 soloSpell  = static_cast<uint32>(def.effects[0].value);
            uint32 comboSpell = static_cast<uint32>(def.effects[1].value);
            if (!sSpellMgr->GetSpellInfo(def.carrierSpellId))
            {
                LOG_ERROR("module", "mod-item-affixes: SPELL_SWAP affix {} has invalid base spell {}, skipping.",
                    def.id, def.carrierSpellId);
                continue;
            }
            if (soloSpell && !sSpellMgr->GetSpellInfo(soloSpell))
            {
                LOG_ERROR("module", "mod-item-affixes: SPELL_SWAP affix {} has invalid solo_spell {}, skipping.",
                    def.id, soloSpell);
                continue;
            }
            if (comboSpell && !sSpellMgr->GetSpellInfo(comboSpell))
            {
                LOG_ERROR("module", "mod-item-affixes: SPELL_SWAP affix {} has invalid combo_spell {}, skipping.",
                    def.id, comboSpell);
                continue;
            }
        }

        _defs[def.id] = std::move(def);
        ++count;
    } while (result->NextRow());

    // Load per-chain-count spell pairs for SPELL_SWAP affixes (spell_swap_chain_spells table).
    if (QueryResult chainResult = WorldDatabase.Query(
        "SELECT affix_id, chain_count, solo_spell, combo_spell "
        "FROM spell_swap_chain_spells ORDER BY affix_id, chain_count"))
    {
        do
        {
            Field* f      = chainResult->Fetch();
            uint32 affId  = f[0].Get<uint32>();
            uint8  cnt    = f[1].Get<uint8>();
            uint32 solo   = f[2].Get<uint32>();
            uint32 combo  = f[3].Get<uint32>();
            auto it = _defs.find(affId);
            if (it == _defs.end() || it->second.affixType != AFFIX_TYPE_SPELL_SWAP || cnt == 0)
                continue;
            auto& v = it->second.chainSwapSpells;
            if (v.size() < static_cast<size_t>(cnt))
                v.resize(cnt, {0u, 0u});
            v[cnt - 1] = { solo, combo };
        } while (chainResult->NextRow());
    }

    // Generic (family=0, no class lock) affixes get 3x pool representation so they are
    // more common than class-specific affixes despite their lower raw count.
    for (auto const& [id, def] : _defs)
    {
        uint32 poolWeight = (def.spellFamily == 0 && def.classMask == 0) ? def.weight * 3 : def.weight;
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
    CharacterDatabase.Execute(
        "DELETE irs FROM item_reforge_state irs "
        "LEFT JOIN item_instance ii ON (irs.item_guid & 0xFFFFFFFF) = ii.guid "
        "WHERE ii.guid IS NULL");
    LOG_INFO("module", "mod-item-affixes: purged orphaned affix and reforge-state rows.");

    _enableClassSkillAffixes        = sConfigMgr->GetOption<bool>  ("ItemAffixes.EnableClassSkillAffixes",        true);
    _enableClassSkillAffixSelection = sConfigMgr->GetOption<bool>  ("ItemAffixes.EnableClassSkillAffixSelection", false);
    _progressionGateClassAffixes    = sConfigMgr->GetOption<bool>  ("ItemAffixes.ProgressionGateClassAffixes",    false);
    _classAffixMaxPerItem           = sConfigMgr->GetOption<uint32>("ItemAffixes.ClassAffixMaxPerItem",            0);
    _enableTalentAffixes            = sConfigMgr->GetOption<bool>  ("ItemAffixes.EnableTalentAffixes",            true);
    _enableTalentAffixSelection     = sConfigMgr->GetOption<bool>  ("ItemAffixes.EnableTalentAffixSelection",     false);
    _classAffixChance               = std::clamp(sConfigMgr->GetOption<uint32>("ItemAffixes.ClassAffixChance", 20u), 0u, 100u);
    _badLuckStreakProtection        = sConfigMgr->GetOption<uint32>("ItemAffixes.BadLuckStreakProtection", 0u);
    _talentAffixChanceGreen     = std::clamp(sConfigMgr->GetOption<uint32>("ItemAffixes.TalentAffixChanceGreen",     10u),  0u, 100u);
    _talentAffixChanceBlue      = std::clamp(sConfigMgr->GetOption<uint32>("ItemAffixes.TalentAffixChanceBlue",      50u),  0u, 100u);
    _talentAffixChancePurple    = std::clamp(sConfigMgr->GetOption<uint32>("ItemAffixes.TalentAffixChancePurple",    50u),  0u, 100u);
    _talentAffixChanceLegendary = std::clamp(sConfigMgr->GetOption<uint32>("ItemAffixes.TalentAffixChanceLegendary", 100u), 0u, 100u);
    _optionsCountLegendary = std::clamp(sConfigMgr->GetOption<uint8>("ItemAffixes.OptionsCountLegendary", 5), uint8(1), uint8(6));
    _rerollsLegendary      = sConfigMgr->GetOption<uint8>("ItemAffixes.RerollsLegendary", 7);
    _slotCountGreen        = std::clamp(sConfigMgr->GetOption<uint8>("ItemAffixes.SlotCountGreen",     1), uint8(1), uint8(6));
    _slotCountBlue         = std::clamp(sConfigMgr->GetOption<uint8>("ItemAffixes.SlotCountBlue",      2), uint8(1), uint8(6));
    _slotCountPurple       = std::clamp(sConfigMgr->GetOption<uint8>("ItemAffixes.SlotCountPurple",    3), uint8(1), uint8(6));
    _slotCountLegendary    = std::clamp(sConfigMgr->GetOption<uint8>("ItemAffixes.SlotCountLegendary", 4), uint8(1), uint8(6));
    _lootMode              = std::clamp(sConfigMgr->GetOption<uint8>("ItemAffixes.LootMode", 0), uint8(0), uint8(1));
    _d3DominantSpecWeight  = sConfigMgr->GetOption<uint32>("ItemAffixes.D3DominantSpecWeight", 0u);
    _d3ExcludeQuestRewards = sConfigMgr->GetOption<bool>("ItemAffixes.D3ExcludeQuestRewards", true);
    _d3OverrideClassAffixMaxPerItem = sConfigMgr->GetOption<bool>("ItemAffixes.D3OverrideClassAffixMaxPerItem", false);
    _reforgeBaseCostGreen     = sConfigMgr->GetOption<uint32>("ItemAffixes.ReforgeBaseCostGreen",     5000);
    _reforgeBaseCostBlue      = sConfigMgr->GetOption<uint32>("ItemAffixes.ReforgeBaseCostBlue",      20000);
    _reforgeBaseCostPurple    = sConfigMgr->GetOption<uint32>("ItemAffixes.ReforgeBaseCostPurple",    75000);
    _reforgeBaseCostLegendary = sConfigMgr->GetOption<uint32>("ItemAffixes.ReforgeBaseCostLegendary", 250000);
    _budgetFractionLegendary = sConfigMgr->GetOption<float>("ItemAffixes.BudgetFractionLegendary", 0.09f);
    _enableRoleSelection     = sConfigMgr->GetOption<bool> ("ItemAffixes.EnableRoleSelection",     false);
    _enableMainStatSelection = sConfigMgr->GetOption<uint8>("ItemAffixes.EnableMainStatSelection", 0);
    {
        _mainStatSelectorSpecs.clear();
        std::string raw = sConfigMgr->GetOption<std::string>("ItemAffixes.MainStatSelectorSpecs", "5:0,5:1,11:2,7:2");
        std::istringstream stream(raw);
        std::string token;
        while (std::getline(stream, token, ','))
        {
            auto colon = token.find(':');
            if (colon == std::string::npos) continue;
            auto cls  = Acore::StringTo<uint8>(token.substr(0, colon));
            auto spec = Acore::StringTo<uint8>(token.substr(colon + 1));
            if (cls && spec)
                _mainStatSelectorSpecs.insert({*cls, *spec});
        }
    }
    _twoHanderBonusSlots     = sConfigMgr->GetOption<uint8>("ItemAffixes.TwoHanderBonusSlots",     1);
    _budgetFractionGreen     = sConfigMgr->GetOption<float>("ItemAffixes.BudgetFractionGreen",     0.18f);
    _budgetFractionBlue      = sConfigMgr->GetOption<float>("ItemAffixes.BudgetFractionBlue",      0.13f);
    _budgetFractionPurple    = sConfigMgr->GetOption<float>("ItemAffixes.BudgetFractionPurple",    0.10f);
    _budgetMinRoll           = std::clamp(sConfigMgr->GetOption<float>  ("ItemAffixes.BudgetMinRoll",      0.75f), 0.0f, 1.0f);
    _statMultiplier          = sConfigMgr->GetOption<float>  ("ItemAffixes.StatMultiplier",          1.0f);
    _imprintRollChance       = sConfigMgr->GetOption<uint32> ("ItemAffixes.ImprintRollChance",       30);
    _critRollEnabled         = sConfigMgr->GetOption<bool>  ("ItemAffixes.EnableCritRolls",          true);
    _critRollChance          = std::clamp(sConfigMgr->GetOption<uint32>("ItemAffixes.CritRollChance", 10u), 0u, 100u);
    _optionsCountGreen  = std::clamp(sConfigMgr->GetOption<uint8>("ItemAffixes.OptionsCountGreen",  1), uint8(1), uint8(6));
    _optionsCountBlue   = std::clamp(sConfigMgr->GetOption<uint8>("ItemAffixes.OptionsCountBlue",   2), uint8(1), uint8(6));
    _optionsCountPurple = std::clamp(sConfigMgr->GetOption<uint8>("ItemAffixes.OptionsCountPurple", 3), uint8(1), uint8(6));
    _rerollsGreen       = sConfigMgr->GetOption<uint8>("ItemAffixes.RerollsGreen",  0);
    _rerollsBlue        = sConfigMgr->GetOption<uint8>("ItemAffixes.RerollsBlue",   2);
    _rerollsPurple      = sConfigMgr->GetOption<uint8>("ItemAffixes.RerollsPurple", 3);

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
// Spec-aware auto-detection helpers
//
// These determine the appropriate role and main stat for a player when the
// corresponding selector is either globally disabled or not needed for their
// spec.  Returning 0 (Any) is intentional for genuinely ambiguous cases where
// auto-detection would be wrong more often than right.
// ---------------------------------------------------------------------------

// Returns the role bitmask value that best fits this class/spec.
// Must match the bitmask encoding used in affix_template.role_mask and the addon UI:
// 0=Any, 1=Caster, 2=Physical, 4=Tank, 8=Healer, 16=Ranged
static uint8 GetAutoRole(uint8 playerClass, int specTree)
{
    switch (playerClass)
    {
        case CLASS_WARRIOR:      return (specTree == 2) ? 4 : 2;
        case CLASS_PALADIN:      return (specTree == 0) ? 8 : (specTree == 1) ? 4 : 2;
        case CLASS_HUNTER:       return 16;
        case CLASS_ROGUE:        return 2;
        case CLASS_PRIEST:       return (specTree == 2) ? 1 : 8;
        case CLASS_DEATH_KNIGHT: return (specTree == 0) ? 4 : 2;
        case CLASS_SHAMAN:       return (specTree == 0) ? 1 : (specTree == 1) ? 2 : 8;
        case CLASS_MAGE:         return 1;
        case CLASS_WARLOCK:      return 1;
        case CLASS_DRUID:        return (specTree == 0) ? 1 : (specTree == 1) ? 2 : 8;
        default:                 return 0;
    }
}

// Returns the main stat value that best fits this class/spec.
// 0=Any, 1=Str, 2=Agi, 3=Int, 4=Spirit
static uint8 GetAutoMainStat(uint8 playerClass, int specTree)
{
    switch (playerClass)
    {
        case CLASS_WARRIOR:      return 1;
        case CLASS_PALADIN:      return (specTree == 0) ? 3 : 1;
        case CLASS_HUNTER:       return 2;
        case CLASS_ROGUE:        return 2;
        case CLASS_PRIEST:       return (specTree == 2) ? 4 : 3;
        case CLASS_DEATH_KNIGHT: return 1;
        case CLASS_SHAMAN:       return (specTree == 1) ? 2 : 3;
        case CLASS_MAGE:         return 3;
        case CLASS_WARLOCK:      return 3;
        case CLASS_DRUID:        return (specTree == 1) ? 2 : 3;
        default:                 return 0;
    }
}

// Returns true when this spec has genuine role ambiguity that auto-detection
// cannot resolve — the role selector should be shown so the player can clarify.
// Feral Druid: could be bear tank or cat DPS; the dominant tree cannot tell them apart.
static bool NeedsRoleSelector(uint8 playerClass, int specTree)
{
    return (playerClass == CLASS_DRUID && specTree == 1);
}

// Returns true when this spec has genuine main-stat ambiguity that auto-detection
// cannot resolve — both Int and Spirit are valid primary stats depending on build.
// Disc/Holy Priest, Resto Druid, Resto Shaman all fall into this category.
static bool NeedsMainStatSelector(uint8 playerClass, int specTree)
{
    if (playerClass == CLASS_PRIEST && (specTree == 0 || specTree == 1)) return true;
    if (playerClass == CLASS_DRUID  && specTree == 2)                    return true;
    if (playerClass == CLASS_SHAMAN && specTree == 2)                    return true;
    return false;
}

// ---------------------------------------------------------------------------
// GetEligibleTalentAffix  — picks a random talent def this player can roll
// ---------------------------------------------------------------------------

TalentAffixDef const* ItemAffixMgr::GetEligibleTalentAffix(Player* player, Item const* item, int8 specOverride,
                                                             bool includeOtherSpecWeighted, uint32 ownSpecWeight)
{
    if (_talentDefs.empty())
        return nullptr;

    uint32 classBit = 1u << (static_cast<uint32>(player->getClass()) - 1u);
    int    specTree = (specOverride >= 0) ? specOverride : GetDominantTalentTree(player);
    uint8  itemCat  = item ? GetItemCategory(item) : ITEM_CAT_ANY;

    // Default (includeOtherSpecWeighted=false): identical to the old behavior --
    // other-spec talents are hard-excluded, only ownSpec ever gets populated.
    // D3 mode passes includeOtherSpecWeighted=true so a dominant-spec bias can be
    // applied without fully locking out the other two trees (see AutoRollD3Item).
    std::vector<TalentAffixDef const*> ownSpec, otherSpec;
    for (auto const& [id, def] : _talentDefs)
    {
        if (def.classMask != 0 && !(def.classMask & classBit))
            continue;
        if (def.itemCategory != ITEM_CAT_ANY && !ItemMatchesCategory(itemCat, def.itemCategory))
            continue;

        bool isOwnSpec = (def.specTree == -1) || (def.specTree == static_cast<int8>(specTree));
        if (isOwnSpec)
            ownSpec.push_back(&def);
        else if (includeOtherSpecWeighted)
            otherSpec.push_back(&def);
    }

    std::vector<TalentAffixDef const*> pool;
    for (uint32 i = 0; i < std::max(1u, ownSpecWeight); ++i)
        pool.insert(pool.end(), ownSpec.begin(), ownSpec.end());
    pool.insert(pool.end(), otherSpec.begin(), otherSpec.end());

    if (pool.empty())
        return nullptr;

    return pool[urand(0, static_cast<uint32>(pool.size()) - 1)];
}

// ---------------------------------------------------------------------------
// InitTalentAffix  — auto-rolls talent affix for a newly acquired item
// ---------------------------------------------------------------------------

void ItemAffixMgr::InitTalentAffix(Player* player, Item* item, int8 specOverride, uint8 affixSlot,
                                    bool includeOtherSpecWeighted, uint32 ownSpecWeight)
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

    // Roll by quality using configurable per-tier chances.
    uint32 chance = 0;
    if      (quality == ITEM_QUALITY_UNCOMMON)         chance = _talentAffixChanceGreen;
    else if (quality == ITEM_QUALITY_RARE)             chance = _talentAffixChanceBlue;
    else if (quality == ITEM_QUALITY_EPIC)             chance = _talentAffixChancePurple;
    else  /* ITEM_QUALITY_LEGENDARY+ */                chance = _talentAffixChanceLegendary;

    if (chance == 0 || urand(0, 99) >= chance)
    {
        LOG_DEBUG("module", "mod-item-affixes: InitTalentAffix — skipped: roll miss (quality={} chance={} guid={})",
            quality, chance, guid);
        return;
    }

    TalentAffixDef const* def = GetEligibleTalentAffix(player, item, specOverride,
                                                         includeOtherSpecWeighted, ownSpecWeight);
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
            continue;
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

// Player Progression integration (both default off — zero behavior change unless
// an admin opts in via config):
//  - ProgressionGateClassAffixes: class/spellmod affixes only roll for a character
//    that has invested the Unlock Class Affixes node.
//  - ClassAffixMaxPerItem: class/spellmod affixes stop rolling for an item once
//    it already has this many APPLIED (pending-but-unchosen doesn't count). 0 = unlimited.
bool ItemAffixMgr::IsClassAffixesBlocked(Player* player, Item* item, bool ignoreMaxPerItem)
{
    if (!player)
        return true;

    bool classAffixesBlocked = false;
    if (_progressionGateClassAffixes)
    {
        uint64 guid = player->GetGUID().GetRawValue();
        classAffixesBlocked = sPlayerProgressionMgr->GetNodeRank(guid, NODE_UNLOCK_CLASS_AFFIXES) == 0;
    }
    // ignoreMaxPerItem: D3 mode only. ClassAffixMaxPerItem exists to cap how many
    // class affixes a *manually rolled* item can accumulate across separate player
    // picks; in D3 mode the prefix/suffix slot split (see AutoRollD3Item) is
    // already the authoritative count of how many class affixes an item gets, so
    // this cap would just fight that split (observed: a purple 2H weapon capped
    // to 1 prefix instead of its intended 2, silently falling back to extra
    // suffixes). The Progression gate above still fully applies either way.
    if (!classAffixesBlocked && !ignoreMaxPerItem && _classAffixMaxPerItem > 0 && item)
    {
        uint32 appliedClassAffixCount = 0;
        for (AffixSlotInfo const& slot : LoadAffixSlots(item->GetGUID().GetRawValue()))
        {
            if (slot.rollState != AFFIX_ROLL_APPLIED || slot.affixId == 0)
                continue;
            auto const* appliedDef = GetAffixDef(slot.affixId);
            if (appliedDef && appliedDef->affixType != AFFIX_TYPE_STAT)
                ++appliedClassAffixCount;
        }
        if (appliedClassAffixCount >= _classAffixMaxPerItem)
            classAffixesBlocked = true;
    }
    return classAffixesBlocked;
}

EligibleAffixPools ItemAffixMgr::BuildEligibleAffixPools(uint32 itemQuality, Player* player, Item* item,
                                                          bool genericsOnly, bool classOnly,
                                                          uint8 preferredRole, uint8 preferredMainStat,
                                                          int8 resolvedSpec, bool classAffixesBlocked)
{
    EligibleAffixPools pools;

    uint8 playerClass = player->getClass();
    uint8 itemCat   = item ? GetItemCategory(item) : ITEM_CAT_ANY;
    // Pre-compute item budget for stat affix eligibility (avoid recomputing per affix).
    float itemBudgetBase = item
        ? ComputeItemBudget(item->GetTemplate()->ItemLevel) * GetSlotBudgetMod(item->GetTemplate()->InventoryType)
        : ComputeItemBudget(static_cast<uint32>(player->GetLevel()) * 5) * 0.74f;  // fallback
    float itemBudget = itemBudgetBase * GetQualityFraction(itemQuality);

    for (uint32 id : _pool)
    {
        auto const* def = GetAffixDef(id);
        if (!def || def->minQuality > itemQuality)
            continue;

        if (def->classMask != 0 && !(def->classMask & (1u << (playerClass - 1u))))
            continue;

        // Green items may only roll truly generic affixes (no class lock, no spell family).
        if (genericsOnly && (def->spellFamily != 0 || def->classMask != 0))
            continue;

        // Class skills only: skip generics, but keep class-locked stat affixes.
        if (classOnly && (def->spellFamily == 0 || def->affixType == AFFIX_TYPE_STAT) && def->classMask == 0)
            continue;

        if (def->itemCategory != ITEM_CAT_ANY && item)
            if (!ItemMatchesCategory(itemCat, def->itemCategory))
                continue;

        if (def->affixType == AFFIX_TYPE_STAT
            && def->statOp != static_cast<uint8>(GSTAT_MOVE_SPEED))
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
            // Class-family filter: skip affixes belonging to a different class entirely.
            if (affixClass != 0 && affixClass != playerClass)
                continue;

            // Spell knowledge gate: never offer an affix for a spell the player hasn't
            // learned yet. Other-spec affixes the player knows are still eligible as a
            // spec-fallback (bucketed separately below).
            if (!PlayerKnowsCarrierSpell(player, def->carrierSpellId))
                continue;
        }
        // Stat affixes: role mask gates by role; classMask gates by class.
        // Class-locked stat affixes (classMask != 0) go into the class bucket so they
        // respect ClassAffixChance and spec bucketing just like spellmod affixes.
        uint8 bucketClass = (def->classMask != 0)          ? playerClass
                          : (def->affixType == AFFIX_TYPE_STAT) ? 0
                          : affixClass;
        if (bucketClass != 0 && classAffixesBlocked)
            continue;
        if (bucketClass == 0)
        {
            pools.knownGeneric.push_back(id);
        }
        else
        {
            // Own-spec: unrestricted affixes (specTree=255) or those matching the
            // player's chosen/dominant spec.  Everything else is "other spec".
            bool isOwnSpec = (def->specTree == 255) ||
                             (resolvedSpec >= 0 && def->specTree == static_cast<uint8>(resolvedSpec));
            if (isOwnSpec)
                pools.knownSpecClass.push_back(id);
            else
                pools.knownOtherSpec.push_back(id);
        }
    }

    return pools;
}

uint32 ItemAffixMgr::RollAffixId(uint32 itemQuality, Player* player, Item* item,
                                  bool genericsOnly, uint8 classBoost,
                                  bool classOnly,
                                  uint8 preferredRole, uint8 preferredMainStat,
                                  int8 spec, uint32 ownSpecWeight, bool ignoreClassAffixMaxPerItem)
{
    // Resolve the player's active spec once — needed to bucket own-spec vs. other-spec.
    int8 resolvedSpec = (spec >= 0) ? spec : static_cast<int8>(GetDominantTalentTree(player));

    bool classAffixesBlocked = IsClassAffixesBlocked(player, item, ignoreClassAffixMaxPerItem);

    EligibleAffixPools pools = BuildEligibleAffixPools(itemQuality, player, item, genericsOnly, classOnly,
                                                        preferredRole, preferredMainStat,
                                                        resolvedSpec, classAffixesBlocked);
    std::vector<uint32>& knownSpecClass = pools.knownSpecClass;
    std::vector<uint32>& knownOtherSpec = pools.knownOtherSpec;
    std::vector<uint32>& knownGeneric   = pools.knownGeneric;

    // classBoost=2 (streak insurance): guarantee a class affix this slot.
    // Prefer own-spec; fall back to other-spec. If no class affixes known, fall through.
    if (classBoost >= 2 && (!knownSpecClass.empty() || !knownOtherSpec.empty()))
    {
        if (!knownSpecClass.empty())
            return knownSpecClass[urand(0, static_cast<uint32>(knownSpecClass.size()) - 1)];
        return knownOtherSpec[urand(0, static_cast<uint32>(knownOtherSpec.size()) - 1)];
    }

    // Pre-roll: decide class vs. generic at the configured ratio (_classAffixChance %).
    // If only one type has eligible affixes, use that type unconditionally.
    bool hasClass   = !knownSpecClass.empty() || !knownOtherSpec.empty();
    bool hasGeneric = !knownGeneric.empty();

    bool wantClass = hasClass && (!hasGeneric || urand(0, 99) < _classAffixChance);

    if (wantClass)
    {
        // Own-spec entries are doubled when classBoost >= 1 (nudge, not a guarantee).
        // ownSpecWeight adds further copies on top -- D3 mode only, default 1 = no
        // extra effect so every other call site keeps today's behavior unchanged.
        std::vector<uint32> classBucket;
        classBucket.insert(classBucket.end(), knownSpecClass.begin(), knownSpecClass.end());
        if (classBoost >= 1)
            classBucket.insert(classBucket.end(), knownSpecClass.begin(), knownSpecClass.end());
        for (uint32 i = 1; i < ownSpecWeight; ++i)
            classBucket.insert(classBucket.end(), knownSpecClass.begin(), knownSpecClass.end());
        classBucket.insert(classBucket.end(), knownOtherSpec.begin(), knownOtherSpec.end());
        if (!classBucket.empty())
            return classBucket[urand(0, static_cast<uint32>(classBucket.size()) - 1)];
    }

    if (!knownGeneric.empty())
        return knownGeneric[urand(0, static_cast<uint32>(knownGeneric.size()) - 1)];

    return 0;
}

std::vector<uint32> ItemAffixMgr::GetEligibleAffixesForPreview(Player* player, Item* item, bool wantPrefix)
{
    if (!player || !item || !item->GetTemplate())
        return {};

    uint32 quality = item->GetTemplate()->Quality;

    // Same resolution RollAffixId does internally when called with spec=-1
    // (as RollReforgeOptions always does) -- the preview has to reproduce
    // it independently since it calls BuildEligibleAffixPools directly
    // rather than going through RollAffixId.
    int8  resolvedSpec = static_cast<int8>(GetDominantTalentTree(player));
    // ignoreMaxPerItem=true matches RollReforgeOptions's own bypass: the
    // slot being previewed already holds a class affix and is already
    // counted toward the cap, so without the bypass the preview would
    // wrongly show an empty class bucket for exactly the slot being reforged.
    bool  classAffixesBlocked = IsClassAffixesBlocked(player, item, /*ignoreMaxPerItem*/true);
    uint8 playerClass    = player->getClass();
    uint8 roleForRoll     = GetAutoRole(playerClass, resolvedSpec);
    uint8 mainStatForRoll = GetAutoMainStat(playerClass, resolvedSpec);

    EligibleAffixPools pools = BuildEligibleAffixPools(quality, player, item,
        /*genericsOnly*/!wantPrefix, /*classOnly*/wantPrefix,
        roleForRoll, mainStatForRoll, resolvedSpec, classAffixesBlocked);

    std::vector<uint32> out;
    out.reserve(pools.knownSpecClass.size() + pools.knownOtherSpec.size() + pools.knownGeneric.size());
    std::unordered_set<uint32> seen;
    for (auto const* bucket : { &pools.knownSpecClass, &pools.knownOtherSpec, &pools.knownGeneric })
    {
        for (uint32 id : *bucket)
        {
            if (seen.insert(id).second)
                out.push_back(id);
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Database helpers
// ---------------------------------------------------------------------------

std::vector<AffixSlotInfo> ItemAffixMgr::LoadAffixSlots(uint64 itemGuid)
{
    QueryResult result = CharacterDatabase.Query(
        "SELECT affix_slot, roll_state, affix_id, rolled_value, pending_opts, "
        "rerolls_remaining, locked_mask, pending_spec, is_crit "
        "FROM item_affix WHERE item_guid = {} ORDER BY affix_slot",
        itemGuid);

    if (!result)
        return {};

    std::vector<AffixSlotInfo> slots;
    do
    {
        Field* f = result->Fetch();
        AffixSlotInfo s;
        s.rollState        = f[1].Get<uint8>();
        s.affixId          = f[2].Get<uint32>();
        s.rolledValue      = f[3].Get<int32>();
        s.rerollsRemaining = f[5].Get<uint8>();
        s.lockedMask       = f[6].Get<uint8>();
        s.pendingSpec      = f[7].Get<int8>();
        s.isCrit           = f[8].Get<uint8>() != 0;
        std::string opts   = f[4].Get<std::string>();
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

    std::vector<ItemAffixRecord> out;
    do
    {
        Field* f       = result->Fetch();
        uint32 affixId = f[1].Get<uint32>();
        int32  rolled  = f[2].Get<int32>();
        if (affixId)
            out.push_back(ItemAffixRecord{ affixId, rolled });
    } while (result->NextRow());
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

void ItemAffixMgr::ApplyDamageReduction(uint64 guid, int32 value, bool apply)
{
    auto& tracked = _damageReductionPct[guid];
    tracked = apply ? tracked + value : tracked - value;
    if (tracked <= 0)
        _damageReductionPct.erase(guid);
}

int32 ItemAffixMgr::GetDamageReductionPct(uint64 guid) const
{
    auto it = _damageReductionPct.find(guid);
    return (it != _damageReductionPct.end()) ? it->second : 0;
}

void ItemAffixMgr::ApplyPetStatBuff(uint64 ownerGuid, uint8 statOp, int32 value, bool apply)
{
    auto& buff = _petStatBuffs[ownerGuid];
    int32 delta = apply ? value : -value;
    switch (static_cast<GenericStatOp>(statOp))
    {
        case GSTAT_PET_COOLDOWN_PCT:     buff.cooldownPct    += delta; break;
        case GSTAT_PET_HEALTH_PCT:       buff.healthPct      += delta; break;
        case GSTAT_PET_DAMAGE_PCT:       buff.damagePct      += delta; break;
        case GSTAT_PET_DMGRED_PCT:       buff.dmgRedPct      += delta; break;
        case GSTAT_PET_ATTACKSPEED_PCT:  buff.attackSpeedPct += delta; break;
        default: break;
    }
    if (buff.cooldownPct == 0 && buff.healthPct == 0 && buff.damagePct == 0
        && buff.dmgRedPct == 0 && buff.attackSpeedPct == 0)
        _petStatBuffs.erase(ownerGuid);
}

void ItemAffixMgr::ApplyPetStatDelta(Creature* pet, GenericStatOp statOp, int32 value, bool apply)
{
    switch (statOp)
    {
        case GSTAT_PET_HEALTH_PCT:
        {
            uint32 curMax = pet->GetMaxHealth();
            uint32 newMax = apply ? (curMax * uint32(100 + value) / 100u)
                                  : (curMax * 100u / uint32(100 + value));
            if (newMax < 1) newMax = 1;
            pet->SetMaxHealth(newMax);
            if (pet->GetHealth() > newMax)
                pet->SetHealth(newMax);
            break;
        }
        case GSTAT_PET_ATTACKSPEED_PCT:
            pet->ApplyAttackTimePercentMod(BASE_ATTACK, float(value), apply);
            break;
        default: break;  // damagePct / dmgRedPct are handled via UnitScript hooks
    }
}

void ItemAffixMgr::ApplyBuffsToPet(Creature* pet, Player* owner)
{
    auto it = _petStatBuffs.find(owner->GetGUID().GetRawValue());
    if (it == _petStatBuffs.end()) return;
    const PetStatBuff& buff = it->second;

    if (buff.healthPct != 0)
    {
        uint32 newMax = pet->GetMaxHealth() * uint32(100 + buff.healthPct) / 100u;
        if (newMax < 1) newMax = 1;
        pet->SetMaxHealth(newMax);
        if (pet->GetHealth() > newMax)
            pet->SetHealth(newMax);
    }
    if (buff.attackSpeedPct != 0)
        pet->ApplyAttackTimePercentMod(BASE_ATTACK, float(buff.attackSpeedPct), true);
    // damagePct and dmgRedPct are applied dynamically via UnitScript hooks
}

int32 ItemAffixMgr::GetPetDamagePct(uint64 ownerGuid) const
{
    auto it = _petStatBuffs.find(ownerGuid);
    return (it != _petStatBuffs.end()) ? it->second.damagePct : 0;
}

int32 ItemAffixMgr::GetPetDmgRedPct(uint64 ownerGuid) const
{
    auto it = _petStatBuffs.find(ownerGuid);
    return (it != _petStatBuffs.end()) ? it->second.dmgRedPct : 0;
}

int32 ItemAffixMgr::GetPetCooldownPct(uint64 ownerGuid) const
{
    auto it = _petStatBuffs.find(ownerGuid);
    return (it != _petStatBuffs.end()) ? it->second.cooldownPct : 0;
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
        if      (proto->Quality >= ITEM_QUALITY_LEGENDARY) numSlots = _slotCountLegendary;
        else if (proto->Quality >= ITEM_QUALITY_EPIC)     numSlots = _slotCountPurple;
        else if (proto->Quality == ITEM_QUALITY_RARE)     numSlots = _slotCountBlue;
        else if (proto->Quality == ITEM_QUALITY_UNCOMMON) numSlots = _slotCountGreen;
        else return;  // white/grey: no affixes

        // 2H weapons get bonus slots to compensate for the dual-wield slot advantage.
        if (Is2HWeapon(item))
            numSlots += _twoHanderBonusSlots;

        // Player Progression: flat bonus from the Slot node, never a regression.
        numSlots += uint8(sPlayerProgressionMgr->GetNodeBonus(player->GetGUID().GetRawValue(), NODE_SLOT));
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

    bool skipAutoRollForQuestReward = _d3ExcludeQuestRewards &&
        IsQuestRewardInProgress(player->GetGUID().GetRawValue());

    if (_lootMode == LOOT_MODE_D3 && !skipAutoRollForQuestReward)
    {
        // D3 mode: roll and APPLY every new slot immediately, no picker UI.
        // See docs/D3_LOOT_MODE_PLAN.md for the full design.
        AutoRollD3Item(player, item, static_cast<uint8>(existingCount), numSlots, isGem);
        return;
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
    // Same check SendItemStatus uses -- without this, a brand-new item's very
    // first DATA message never carried this flag at all, so the addon's Class
    // Skills selector always started out clickable regardless of whether the
    // player could actually use it, only self-correcting after some later
    // event happened to trigger a SendItemStatus refresh for that item.
    if (!isGem && IsClassAffixesBlocked(player, item))
        msg += "|classSkillsBlocked";
    SendAddonMsg(player, msg);
}

// ---------------------------------------------------------------------------
// AutoRollD3Item — LootMode=1 only. Rolls and immediately APPLIES every new
// affix slot for an item the instant it's picked up: no PENDING state, no
// picker UI. Slots [0, prefixCount) roll from the class/SpellMod ("prefix")
// pool, the rest from the stat ("suffix") pool -- prefixCount = ceil(numSlots
// / 2), so display order (ascending affix_slot) naturally reads prefix(es)
// then suffix(es) with no separate sort step. Gems always get a single
// suffix (they can only roll stat affixes -- see InitItemSlots above).
// Talent affixes and Imprints still roll off their own independent settings,
// layered on top, same as manual mode. Full design: docs/D3_LOOT_MODE_PLAN.md.
//
// Uses DirectExecute (synchronous) for every write in this function because
// SyncAffixes/SendItemStatus at the end both immediately re-read item_affix
// via a synchronous Query -- same class of race documented elsewhere in this
// file for InitTalentAffix and HandlePickOption's APPLIED update.
// ---------------------------------------------------------------------------

void ItemAffixMgr::AutoRollD3Item(Player* player, Item* item, uint8 existingCount, uint8 numSlots, bool isGem)
{
    if (existingCount >= numSlots)
        return;

    uint64 itemGuid    = item->GetGUID().GetRawValue();
    uint8  quality     = static_cast<uint8>(item->GetTemplate()->Quality);
    uint8  playerClass = player->getClass();

    uint8 prefixCount = isGem ? 0 : static_cast<uint8>((numSlots + 1) / 2);

    int   resolvedSpec   = GetDominantTalentTree(player);
    uint8 roleForRoll     = GetAutoRole(playerClass, resolvedSpec);
    uint8 mainStatForRoll = GetAutoMainStat(playerClass, resolvedSpec);

    float itemBudget = ComputeItemBudget(item->GetTemplate()->ItemLevel)
                     * GetSlotBudgetMod(item->GetTemplate()->InventoryType)
                     * GetQualityFraction(quality);
    bool is2H = !isGem && Is2HWeapon(item);

    uint32 effectiveCritChance = std::min<uint32>(_critRollChance +
        uint32(sPlayerProgressionMgr->GetNodeBonus(player->GetGUID().GetRawValue(), NODE_CRIT_ROLL_CHANCE)), 100);

    // D3ROLL|bag|slot|!text / D3ROLL|bag|slot|~text -- purely a notification
    // for the optional ItemAffixesToast companion addon. Manual mode's
    // interactive OPTS message already gives that addon a crit/imprint event
    // to hook; D3 mode has no equivalent message at all since items arrive
    // pre-resolved with no picker step, so without this a drop that crits or
    // grants an Imprint toasts nothing. ItemAffixes.lua's own dispatcher
    // ignores unrecognized commands, so this is a no-op for anyone not
    // running the toast addon.
    auto [luaBag, luaSlot] = GetLuaBagSlot(item);

    for (uint8 slot = existingCount; slot < numSlots; ++slot)
    {
        bool wantPrefix = !isGem && (slot < prefixCount);

        // Imprint roll: only ever considered for a prefix slot (same rule as
        // manual mode -- Imprints are a super-version of a class ability, never
        // a substitute for a stat roll). Applies immediately if eligible, then
        // falls through to roll this same slot's real affix right after --
        // D3 mode never leaves a slot unrolled the way manual mode does.
        if (wantPrefix && urand(0, 99) < _imprintRollChance)
        {
            if (ImprintDef const* impDef = sImprintMgr->GetEligibleImprintForRoll(player, item, static_cast<int8>(resolvedSpec)))
            {
                sImprintMgr->ApplyImprintFromRoll(player, item, impDef->id);
                SendAddonMsg(player, Acore::StringFormat("D3ROLL|{}|{}|~{}",
                    uint32(luaBag), uint32(luaSlot), impDef->name));
            }
        }

        // D3OverrideClassAffixMaxPerItem controls whether ClassAffixMaxPerItem still
        // caps prefix rolls in D3 mode (default false = it does, same as manual
        // mode -- see the comment on IsClassAffixesBlocked and on the config
        // member itself). ProgressionGateClassAffixes always fully applies either
        // way (confirmed correct via live testing: with the Unlock Class Affixes
        // node unspent, every slot correctly falls back to suffix).
        uint32 id = wantPrefix
            ? RollAffixId(quality, player, item, /*genericsOnly*/false, /*classBoost*/0,
                           /*classOnly*/true, roleForRoll, mainStatForRoll, -1, _d3DominantSpecWeight + 1,
                           _d3OverrideClassAffixMaxPerItem)
            : 0;
        // Empty prefix pool (or a suffix slot to begin with): fall back to the
        // suffix/generic pool rather than leaving the slot unrolled.
        if (!id)
            id = RollAffixId(quality, player, item, /*genericsOnly*/true, /*classBoost*/0,
                              /*classOnly*/false, roleForRoll, mainStatForRoll, -1);

        if (!id)
        {
            // Truly nothing eligible -- leave UNROLLED so the row still exists
            // and the slot count invariant InitItemSlots checks stays correct.
            CharacterDatabase.DirectExecute(
                "INSERT INTO item_affix (item_guid, affix_slot, affix_id, rolled_value, roll_state, pending_opts) "
                "VALUES ({}, {}, 0, 0, {}, '')",
                itemGuid, slot, uint8(AFFIX_ROLL_UNROLLED));
            continue;
        }

        auto const* def = GetAffixDef(id);
        int32 rolledValue = (def && def->affixType == AFFIX_TYPE_STAT)
            ? RollBudgetStatValue(def->statOp, itemBudget, _budgetMinRoll)
            : 0;

        // 2H weapon bonus, same scaling as manual mode's option generation.
        if (is2H && def)
        {
            if (def->affixType == AFFIX_TYPE_STAT)
                rolledValue = (rolledValue * 3 + 1) / 2;
            else if (def->affixType == AFFIX_TYPE_SPELLMOD)
                rolledValue = 150;
        }

        // Crit roll, evaluated independently per slot, same chance/effect as manual mode.
        // Persisted via is_crit below -- STAT values have no reserved sentinel
        // the way SPELLMOD's 150/200/250 does, so without a real column a
        // crit-boosted stat would be visually indistinguishable from a normal
        // high roll (confirmed via temp logging: the roll was firing correctly
        // all along, it just never got the "!" -> gold-color treatment).
        bool critHit = def && _critRollEnabled && urand(0, 99) < effectiveCritChance;
        if (critHit)
        {
            if (def->affixType == AFFIX_TYPE_STAT)
                rolledValue = (rolledValue * 3 + 1) / 2;
            else if (def->affixType == AFFIX_TYPE_SPELLMOD)
                rolledValue = (rolledValue == 150) ? 250 : 200;

            SendAddonMsg(player, Acore::StringFormat("D3ROLL|{}|{}|!{}",
                uint32(luaBag), uint32(luaSlot), BuildAffixDisplayString(def, rolledValue)));
        }

        CharacterDatabase.DirectExecute(
            "INSERT INTO item_affix (item_guid, affix_slot, affix_id, rolled_value, roll_state, pending_opts, is_crit) "
            "VALUES ({}, {}, {}, {}, {}, '', {}) "
            "ON DUPLICATE KEY UPDATE affix_id = {}, rolled_value = {}, roll_state = {}, pending_opts = '', is_crit = {}",
            itemGuid, slot, id, rolledValue, uint8(AFFIX_ROLL_APPLIED), uint8(critHit),
            id, rolledValue, uint8(AFFIX_ROLL_APPLIED), uint8(critHit));

        sPlayerProgressionMgr->GrantAffixXP(player, quality);

        if (_enableTalentAffixes)
            InitTalentAffix(player, item, -1, slot, /*includeOtherSpecWeighted*/true, _d3DominantSpecWeight + 1);
    }

    // Sync immediately if the item is already equipped (e.g. bought-and-equipped
    // straight from a vendor, or an offhand auto-equipped after a 2H swap).
    uint8 bagSlot  = item->GetBagSlot();
    uint8 itemSlot = item->GetSlot();
    if (bagSlot == INVENTORY_SLOT_BAG_0 && itemSlot < EQUIPMENT_SLOT_END)
        SyncAffixes(player);

    SendItemStatus(player, item);
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
    if      (proto->Quality >= ITEM_QUALITY_LEGENDARY) expectedSlots = _slotCountLegendary + _twoHanderBonusSlots;
    else if (proto->Quality >= ITEM_QUALITY_EPIC)      expectedSlots = _slotCountPurple    + _twoHanderBonusSlots;
    else if (proto->Quality == ITEM_QUALITY_RARE)      expectedSlots = _slotCountBlue      + _twoHanderBonusSlots;
    else if (proto->Quality == ITEM_QUALITY_UNCOMMON)  expectedSlots = _slotCountGreen     + _twoHanderBonusSlots;
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
            // Dangling affix_id (its affix_template row was removed/renamed) --
            // silently grants nothing forever, with no way to reroll the slot.
            // No affix has ever been retired yet so this hasn't bitten anyone,
            // but if one ever is, the fix belongs here: detect the missing def
            // and revert this row to UNROLLED (state=0) instead of skipping,
            // so the slot becomes rollable again. See docs/ROADMAP.md.
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

void ItemAffixMgr::ReapplyAllEquipped(Player* player, ObjectGuid excludeGuid)
{
    if (!player)
        return;

    for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
    {
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (item && item->GetGUID() != excludeGuid)
        {
            ApplyAffixes(player, item);
            ApplyTalentAffixes(player, item);
            ApplyGemAffixes(player, item);
        }
    }

    // Post-pass: apply spell swaps after all items are visible so combo detection works.
    CollectAndApplySpellSwaps(player, excludeGuid);
}

// ---------------------------------------------------------------------------
// SyncAffixes
// ---------------------------------------------------------------------------

void ItemAffixMgr::SyncAffixes(Player* player, ObjectGuid excludeGuid)
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

    ReapplyAllEquipped(player, excludeGuid);
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

    // Intentionally NOT calling RemoveSpellSwaps here: variant spells are left in
    // character_spell so the Lua PLAYER_LOGOUT snapshot can see them on the action bar.
    // Phase 0 in CollectAndApplySpellSwaps removes all variants unconditionally on next login.

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
// CollectAndApplySpellSwaps
// ---------------------------------------------------------------------------

void ItemAffixMgr::CollectAndApplySpellSwaps(Player* player, ObjectGuid excludeGuid)
{
    if (!player)
        return;

    // Build variant→base map.  Used by Phase 2 (find stale variants) and by
    // ForceReapplySpellSwaps (full clear on demand via ".affix reapply").
    std::unordered_map<uint32, uint32> variantToBase; // variant spell id -> carrier (base) spell id
    for (auto const& [id, def] : _defs)
    {
        if (def.affixType != AFFIX_TYPE_SPELL_SWAP)
            continue;
        for (auto const& [solo, combo] : def.chainSwapSpells)
        {
            if (solo)  variantToBase[solo]  = def.carrierSpellId;
            if (combo) variantToBase[combo] = def.carrierSpellId;
        }
        uint32 soloSpell  = static_cast<uint32>(def.effects[0].value);
        uint32 comboSpell = static_cast<uint32>(def.effects[1].value);
        if (soloSpell)  variantToBase[soloSpell]  = def.carrierSpellId;
        if (comboSpell) variantToBase[comboSpell] = def.carrierSpellId;
    }

    // Phase 1: Collect SPELL_SWAP affixes from all currently equipped items.
    struct SwapState
    {
        AffixDefinition const* chainDef  = nullptr;
        uint32 markSoloSpell             = 0;
        uint32 chainCount                = 0;
        bool   markActive                = false;
    };
    std::unordered_map<uint32, SwapState> swapByBase;

    for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
    {
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (!item)
            continue;
        if (item->GetGUID() == excludeGuid)
            continue;

        for (ItemAffixRecord const& rec : LoadItemAffixes(item->GetGUID().GetRawValue()))
        {
            AffixDefinition const* def = GetAffixDef(rec.affixId);
            if (!def || def->affixType != AFFIX_TYPE_SPELL_SWAP)
                continue;

            uint32 baseSpell = def->carrierSpellId;
            uint32 soloSpell = static_cast<uint32>(def->effects[0].value);
            uint8  role      = def->statOp;  // 1=chain/multi, 2=sting

            SwapState& state = swapByBase[baseSpell];
            if (role == 1)
            {
                state.chainCount++;
                if (!state.chainDef)
                    state.chainDef = def;
            }
            else if (role == 2)
            {
                state.markActive = true;
                if (!state.markSoloSpell)
                    state.markSoloSpell = soloSpell;
            }
        }
    }

    ItemAffixPlayerData* data = player->CustomData.GetDefault<ItemAffixPlayerData>("ItemAffixData");

    // Phase 2: Apply the correct variant for each equipped base spell.
    // Key change from old design: if the player already has the correct variant, skip it entirely
    // (no SMSG_REMOVED_SPELL, no action bar disruption).  Only fire a spell change when the
    // variant actually needs to differ from what the player currently has.
    std::unordered_map<uint32, uint32> newActiveSwaps;

    for (auto const& [baseSpell, state] : swapByBase)
    {
        uint32 targetSpell = 0;

        if (state.chainCount > 0 && state.chainDef)
        {
            bool useCombo = state.markActive;
            auto const& csv = state.chainDef->chainSwapSpells;
            if (!csv.empty())
            {
                size_t idx = std::min(static_cast<size_t>(state.chainCount - 1), csv.size() - 1);
                targetSpell = useCombo ? csv[idx].second : csv[idx].first;
            }
            else
            {
                targetSpell = useCombo
                    ? static_cast<uint32>(state.chainDef->effects[1].value)
                    : static_cast<uint32>(state.chainDef->effects[0].value);
            }
        }
        else if (state.markActive && state.markSoloSpell)
        {
            targetSpell = state.markSoloSpell;
        }

        if (!targetSpell)
            continue;

        // Already correct — track it and move on with no spell changes.
        if (player->HasSpell(targetSpell))
        {
            newActiveSwaps[baseSpell] = targetSpell;
            continue;
        }

        // Find what the player currently has for this base spell so we know what to remove.
        // Priority: session tracking → base spell → full variant scan (handles persisted variants
        // on login when activeSpellSwaps is freshly empty).
        uint32 currentSpell = 0;
        auto activeIt = data->activeSpellSwaps.find(baseSpell);
        if (activeIt != data->activeSpellSwaps.end() && player->HasSpell(activeIt->second))
            currentSpell = activeIt->second;
        else if (player->HasSpell(baseSpell))
            currentSpell = baseSpell;
        else
        {
            for (auto const& [variant, vBase] : variantToBase)
            {
                if (vBase == baseSpell && player->HasSpell(variant))
                {
                    currentSpell = variant;
                    break;
                }
            }
        }

        if (currentSpell)
            player->removeSpell(currentSpell, SPEC_MASK_ALL, false);

        player->learnSpell(targetSpell);
        newActiveSwaps[baseSpell] = targetSpell;
        SendAddonMsg(player, Acore::StringFormat("SWAP|{}|{}", currentSpell ? currentSpell : baseSpell, targetSpell));
    }

    // Phase 3: Remove any variant the player has that is no longer needed.
    // Handles (a) affix removed while offline and (b) unequipping all swap affixes mid-session.
    // Skips variants that Phase 2 just set — those removes already happened above.
    for (auto const& [variant, base] : variantToBase)
    {
        if (!player->HasSpell(variant))
            continue;
        if (newActiveSwaps.find(base) != newActiveSwaps.end())
            continue;  // Phase 2 owns this base spell slot

        player->removeSpell(variant, SPEC_MASK_ALL, false);
        if (!player->HasSpell(base))
            player->learnSpell(base);
        SendAddonMsg(player, Acore::StringFormat("SWAP|{}|{}", variant, base));
    }

    data->activeSpellSwaps = std::move(newActiveSwaps);
}

// ---------------------------------------------------------------------------
// RemoveSpellSwaps
// ---------------------------------------------------------------------------

void ItemAffixMgr::RemoveSpellSwaps(Player* player, ItemAffixPlayerData* data)
{
    if (!data || data->activeSpellSwaps.empty())
        return;

    for (auto const& [baseSpell, variantSpell] : data->activeSpellSwaps)
    {
        if (!variantSpell)
            continue;
        if (player->HasSpell(variantSpell))
        {
            player->removeSpell(variantSpell, SPEC_MASK_ALL, false);
            player->learnSpell(baseSpell);
            SendAddonMsg(player, Acore::StringFormat("SWAP|{}|{}", variantSpell, baseSpell));
        }
    }
    data->activeSpellSwaps.clear();
}

// ---------------------------------------------------------------------------
// ForceReapplySpellSwaps
// ---------------------------------------------------------------------------
// Hard-reset: remove ALL known variants unconditionally, then re-run CollectAndApplySpellSwaps.
// Equivalent to the old Phase 0 behaviour.  Intended for the future ".affix reapply" command
// and for any situation where spell state may be inconsistent (e.g. after GM intervention).

void ItemAffixMgr::ForceReapplySpellSwaps(Player* player)
{
    if (!player)
        return;

    for (auto const& [id, def] : _defs)
    {
        if (def.affixType != AFFIX_TYPE_SPELL_SWAP)
            continue;
        for (auto const& [solo, combo] : def.chainSwapSpells)
        {
            if (solo  && player->HasSpell(solo))  { player->removeSpell(solo,  SPEC_MASK_ALL, false); }
            if (combo && player->HasSpell(combo))  { player->removeSpell(combo, SPEC_MASK_ALL, false); }
        }
        uint32 solo  = static_cast<uint32>(def.effects[0].value);
        uint32 combo = static_cast<uint32>(def.effects[1].value);
        if (solo  && player->HasSpell(solo))  { player->removeSpell(solo,  SPEC_MASK_ALL, false); if (!player->HasSpell(def.carrierSpellId)) player->learnSpell(def.carrierSpellId); }
        if (combo && player->HasSpell(combo)) { player->removeSpell(combo, SPEC_MASK_ALL, false); if (!player->HasSpell(def.carrierSpellId)) player->learnSpell(def.carrierSpellId); }
    }

    ItemAffixPlayerData* data = player->CustomData.Get<ItemAffixPlayerData>("ItemAffixData");
    if (data)
        data->activeSpellSwaps.clear();

    CollectAndApplySpellSwaps(player);
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
    int     specTree    = GetDominantTalentTree(player);
    uint8   playerClass = player->getClass();
    bool    showRole     = _enableRoleSelection     && NeedsRoleSelector(playerClass, specTree);
    bool    showMainStat = (_enableMainStatSelection == 2)
                        || (_enableMainStatSelection == 1 && specTree >= 0
                            && _mainStatSelectorSpecs.count({playerClass, (uint8)specTree}));

    bool showType = _enableClassSkillAffixes && _enableClassSkillAffixSelection;
    bool showSpec = showType || (_enableTalentAffixes && _enableTalentAffixSelection);

    SendAddonMsg(player, Acore::StringFormat("CONFIG|{}|{}|{}|{}|{}",
        showType     ? 1 : 0,
        showSpec     ? 1 : 0,
        showRole     ? 1 : 0,
        showMainStat ? 1 : 0,
        uint32(_lootMode)));
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
        if (static_cast<GenericStatOp>(def->statOp) == GSTAT_DAMAGE_REDUCTION_PCT)
            return Acore::StringFormat("-{}% Damage Taken", rolledValue);
        if (static_cast<GenericStatOp>(def->statOp) == GSTAT_PET_COOLDOWN_PCT)
            return Acore::StringFormat("-{}% Pet Cooldowns", rolledValue);
        if (static_cast<GenericStatOp>(def->statOp) == GSTAT_PET_HEALTH_PCT)
            return Acore::StringFormat("+{}% Pet Health", rolledValue);
        if (static_cast<GenericStatOp>(def->statOp) == GSTAT_PET_DAMAGE_PCT)
            return Acore::StringFormat("+{}% Pet Damage", rolledValue);
        if (static_cast<GenericStatOp>(def->statOp) == GSTAT_PET_DMGRED_PCT)
            return Acore::StringFormat("-{}% Pet Dmg Taken", rolledValue);
        if (static_cast<GenericStatOp>(def->statOp) == GSTAT_PET_ATTACKSPEED_PCT)
            return Acore::StringFormat("+{}% Pet Atk Speed", rolledValue);

        return Acore::StringFormat("+{} {}", rolledValue, GetStatName(def->statOp));
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
                                   std::vector<PendingOpt> const& opts,
                                   uint8 rerolls, uint8 lockedMask)
{
    auto [luaBag, luaSlot] = GetLuaBagSlot(item);
    std::string msg = Acore::StringFormat("OPTS|{}|{}|{}|{}|{}",
        uint32(luaBag), uint32(luaSlot), uint32(affixSlot), rerolls, lockedMask);

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
// RefreshAllItemStatus  — re-sends DATA for every affix-bearing item the
// player has equipped or in bags. See ItemAffix.h for why this exists.
// ---------------------------------------------------------------------------

void ItemAffixMgr::RefreshAllItemStatus(Player* player)
{
    if (!player)
        return;

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
}

// ---------------------------------------------------------------------------
// SendItemStatus  — sends DATA packet with full slot states for one item
// ---------------------------------------------------------------------------

void ItemAffixMgr::SendItemStatus(Player* player, Item* item, std::string const& extraTalentLine)
{
    if (!player || !item)
        return;

    uint64 rawGuid = item->GetGUID().GetRawValue();
    auto slots = LoadAffixSlots(rawGuid);

    // Skip items that have nothing to display — no affix slots, no imprint, no talent affix.
    // Items with only an imprint (slotCount=0) still deserve a DATA packet so the bag tooltip
    // shows the imprint even when the regular affix system hasn't assigned any slots.
    if (slots.empty())
    {
        bool hasImprint = sImprintMgr->GetInstance(rawGuid) != nullptr;
        bool hasTalent  = CharacterDatabase.Query(
            "SELECT 1 FROM item_talent_affix WHERE item_guid = {} LIMIT 1", rawGuid) != nullptr;
        if (!hasImprint && !hasTalent && extraTalentLine.empty())
            return;
    }

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
                    if (s.isCrit)
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

    // Flag rune items so the Lua apply mechanic enables right-click apply mode.
    if (sImprintMgr->IsRune(item))
        msg += "|isRune";

    // Tells the Lua Roll UI to disable the "Class Skills" selector for this item —
    // avoids the dead-end where picking it produces zero eligible options and the
    // roll menu just silently closes with nothing to show (same check RollAffixId
    // itself uses, see IsClassAffixesBlocked). Gems never offer Class Skills at all
    // (roll menu already forces stats-only for them), so skip the check there.
    if ((!proto || proto->Class != ITEM_CLASS_GEM) && IsClassAffixesBlocked(player, item))
        msg += "|classSkillsBlocked";

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
        SendRollOptions(player, item, affixSlot, slotInfo.pendingOpts,
                        slotInfo.rerollsRemaining, slotInfo.lockedMask);
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
        SendItemStatus(player, item);

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
        if      (quality >= ITEM_QUALITY_LEGENDARY) numOpts = _optionsCountLegendary;
        else if (quality >= ITEM_QUALITY_EPIC)     numOpts = _optionsCountPurple;
        else if (quality == ITEM_QUALITY_RARE)     numOpts = _optionsCountBlue;
        else { numOpts = _optionsCountGreen; genericsOnly = true; }

        // Player Progression: flat bonus from the Options Tier node, never a regression.
        uint8 optionsBonus = uint8(sPlayerProgressionMgr->GetNodeBonus(player->GetGUID().GetRawValue(), NODE_OPTIONS_TIER));
        numOpts = std::min<uint8>(numOpts + optionsBonus, 6);

        if (!_enableClassSkillAffixes)
        {
            genericsOnly = true;  // class skills globally disabled — stat affixes only
        }
        else
        {
            // Honor player type preference when class skills are available.
            if (type == 1) { genericsOnly = true; }
            // type=2 (Class Skills Only) is only respected when the selection UI is enabled.
            if (type == 2 && _enableClassSkillAffixSelection) { classOnly = true; genericsOnly = false; }
        }
    }

    int8  specForRoll    = (!isGem && spec >= 0) ? spec : -1;
    int   resolvedSpec   = (specForRoll >= 0) ? specForRoll : GetDominantTalentTree(player);
    uint8 playerClass    = player->getClass();
    // 255 = sentinel meaning the addon had no selector shown; always auto-detect in that case.
    uint8 roleForRoll     = (role == 255)     ? GetAutoRole(playerClass, resolvedSpec)     : role;
    uint8 mainStatForRoll = (mainStat == 255) ? GetAutoMainStat(playerClass, resolvedSpec) : mainStat;

    // Bad-luck streak protection: persistent counter of consecutive non-class options shown
    // across all rolls and rerolls for this item. Resets to 0 when a class option is generated.
    uint64 itemGuidForStreak = item->GetGUID().GetRawValue();
    uint32& optionStreak = _optionStreak[itemGuidForStreak];

    // Roll distinct affix IDs, pre-rolling the stat value for each so the
    // player sees exactly what they will get before they choose.
    float itemBudget = ComputeItemBudget(item->GetTemplate()->ItemLevel)
                     * GetSlotBudgetMod(item->GetTemplate()->InventoryType)
                     * GetQualityFraction(quality);
    std::vector<PendingOpt> opts;
    for (uint32 attempts = 0; opts.size() < numOpts && attempts < 100; ++attempts)
    {
        // Force class if the bad-luck streak has hit the protection threshold.
        uint8 effectiveBoost = 0;
        if (!genericsOnly && !classOnly && _badLuckStreakProtection > 0 && optionStreak >= _badLuckStreakProtection)
            effectiveBoost = 2;

        uint32 id = RollAffixId(quality, player, item, genericsOnly, effectiveBoost,
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

        // Update bad-luck streak: class option resets to 0, non-class increments.
        bool isClassOpt = newDef && newDef->affixType != AFFIX_TYPE_STAT && SpellFamilyToClass(newDef->spellFamily) != 0;
        if (isClassOpt) optionStreak = 0;
        else            ++optionStreak;
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

    // Crit roll: per-option chance (configurable via ItemAffixes.CritRollChance), applied after 2H bonus.
    // Player Progression: flat bonus from the Crit Roll Chance node, never a regression.
    // STAT: multiply rolledValue by 1.5 (ceiling). SPELLMOD: escalate flag value.
    uint32 effectiveCritChance = std::min<uint32>(_critRollChance +
        uint32(sPlayerProgressionMgr->GetNodeBonus(player->GetGUID().GetRawValue(), NODE_CRIT_ROLL_CHANCE)), 100);
    for (PendingOpt& opt : opts)
    {
        if (!_critRollEnabled || urand(0, 99) >= effectiveCritChance)
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
    {
        // Zero eligible options — most commonly type=2 (Class Skills) requested while
        // blocked (ProgressionGateClassAffixes not unlocked, or ClassAffixMaxPerItem
        // already reached). The addon normally disables that selector before this can
        // happen (see SendItemStatus's classSkillsBlocked flag), but its cache can go
        // briefly stale relative to live node investment (invest/respec doesn't proactively
        // push a fresh DATA packet) — this is the server-side safety net so a stale client
        // still gets a clear message instead of a roll menu that silently closes with
        // nothing shown. Slot stays UNROLLED; the player can just try again.
        auto [luaBag, luaSlot] = GetLuaBagSlot(item);
        std::string reason = classOnly
            ? "Class Skills isn't available for this item right now."
            : "No eligible affix options right now — try again.";
        SendAddonMsg(player, Acore::StringFormat("ERR|{}|{}|{}", luaBag, luaSlot, reason));
        return;
    }

    // Rerolls granted based on quality tier (gems always get 0)
    uint8 rerolls = 0;
    if (!isGem)
    {
        if      (quality >= ITEM_QUALITY_LEGENDARY) rerolls = _rerollsLegendary;
        else if (quality >= ITEM_QUALITY_EPIC)     rerolls = _rerollsPurple;
        else if (quality == ITEM_QUALITY_RARE)     rerolls = _rerollsBlue;
        else                                       rerolls = _rerollsGreen;

        // Player Progression: flat bonus from the Reroll Tier node, never a regression.
        uint8 rerollBonus = uint8(sPlayerProgressionMgr->GetNodeBonus(player->GetGUID().GetRawValue(), NODE_REROLL_TIER));
        rerolls = std::min<uint8>(rerolls + rerollBonus, 255);
    }

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
        "UPDATE item_affix SET roll_state = {}, pending_opts = '{}', rerolls_remaining = {}, locked_mask = 0, pending_spec = {} "
        "WHERE item_guid = {} AND affix_slot = {}",
        uint8(AFFIX_ROLL_PENDING), optsStr, rerolls, int8(specForRoll), itemGuid, uint32(affixSlot));

    SendRollOptions(player, item, affixSlot, opts, rerolls, 0);
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
            "UPDATE item_affix SET roll_state = {}, affix_id = 0, rolled_value = 0, pending_opts = '', is_crit = 0 "
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

    // DirectExecute (synchronous) — SyncAffixes and SendItemStatus below both
    // immediately re-read item_affix via CharacterDatabase.Query (also sync);
    // a plain async Execute here would race those reads, same class of bug
    // documented for InitTalentAffix elsewhere in this file.
    CharacterDatabase.DirectExecute(
        "UPDATE item_affix SET roll_state = {}, affix_id = {}, rolled_value = {}, pending_opts = '', is_crit = {} "
        "WHERE item_guid = {} AND affix_slot = {}",
        uint8(AFFIX_ROLL_APPLIED), chosen.affixId, rolledValue, uint8(chosen.isCrit), itemGuid, uint32(affixSlot));

    // Player Progression: PENDING -> APPLIED is the one-shot per-affix XP trigger.
    if (ItemTemplate const* proto = item->GetTemplate())
        sPlayerProgressionMgr->GrantAffixXP(player, proto->Quality);

    // Talent affix for this slot is committed now that the player has made their choice.
    // Must happen before SyncAffixes so the talent row is in the DB when sync reads it.
    // Use the spec the player selected in the addon UI; falls back to dominant tree if -1.
    if (_enableTalentAffixes)
        InitTalentAffix(player, item, slotInfo.pendingSpec, affixSlot);

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

    // APPLY above only patches this one slot's cached display text — it doesn't
    // touch classSkillsBlocked, so a class/spellmod pick here (which is exactly
    // what can push an item over ClassAffixMaxPerItem) left the addon's cached
    // hint stale until the next full DATA refresh. Push one now so the very next
    // Alt+Click on this item already shows the correct Class Skills grey-out
    // state instead of needing one failed roll attempt to self-correct.
    SendItemStatus(player, item);
}

// ---------------------------------------------------------------------------
// HandleRerollRequest  — re-rolls all unlocked options, decrements rerolls_remaining
// ---------------------------------------------------------------------------

void ItemAffixMgr::HandleRerollRequest(Player* player, Item* item, int8 spec,
                                        uint8 type, uint8 role, uint8 mainStat)
{
    if (!player || !item)
        return;

    uint64 itemGuid = item->GetGUID().GetRawValue();
    auto slots = LoadAffixSlots(itemGuid);

    for (uint8 i = 0; i < static_cast<uint8>(slots.size()); ++i)
    {
        AffixSlotInfo const& slotInfo = slots[i];
        if (slotInfo.rollState != AFFIX_ROLL_PENDING)
            continue;

        if (slotInfo.rerollsRemaining == 0)
            return;

        uint8 lockedMask = slotInfo.lockedMask;
        uint8 numOpts    = static_cast<uint8>(slotInfo.pendingOpts.size());
        if (numOpts == 0)
            return;

        // Reject if all options are locked (nothing to reroll)
        uint8 allBits = static_cast<uint8>((1u << numOpts) - 1u);
        if ((lockedMask & allBits) == allBits)
            return;

        ItemTemplate const* proto = item->GetTemplate();
        if (!proto)
            return;

        uint32 quality    = proto->Quality;
        float  itemBudget = ComputeItemBudget(proto->ItemLevel)
                          * GetSlotBudgetMod(proto->InventoryType)
                          * GetQualityFraction(quality);

        // Derive genericsOnly/classOnly from the player's type preference — same logic as HandleRollRequest.
        bool genericsOnly = false;
        bool classOnly    = false;
        if (!_enableClassSkillAffixes)
        {
            genericsOnly = true;
        }
        else
        {
            if (type == 1) { genericsOnly = true; }
            if (type == 2 && _enableClassSkillAffixSelection) { classOnly = true; genericsOnly = false; }
        }
        int   resolvedSpec2   = (spec >= 0) ? spec : GetDominantTalentTree(player);
        uint8 playerClass2    = player->getClass();
        // 255 = sentinel meaning the addon had no selector shown; always auto-detect in that case.
        uint8 roleForRoll     = (role == 255)     ? GetAutoRole(playerClass2, resolvedSpec2)     : role;
        uint8 mainStatForRoll = (mainStat == 255) ? GetAutoMainStat(playerClass2, resolvedSpec2) : mainStat;

        // Phase 1: collect locked options into a "chosen" set for dedup.
        std::vector<PendingOpt> finalOpts(slotInfo.pendingOpts);  // start as copy
        std::vector<PendingOpt> chosen;
        for (uint8 j = 0; j < numOpts; ++j)
            if (lockedMask & (1u << j))
                chosen.push_back(finalOpts[j]);

        // Bad-luck streak protection: same persistent counter as the initial roll.
        uint32& optionStreak = _optionStreak[itemGuid];

        // Phase 2: roll new options for each unlocked slot.
        // keptOriginal[j]=true means roll failed — keep the original value.
        bool keptOriginal[6] = {};
        for (uint8 j = 0; j < numOpts; ++j)
        {
            if (lockedMask & (1u << j))
                continue;  // locked — already in finalOpts

            PendingOpt newOpt{0, 0, false};
            for (uint32 attempts = 0; attempts < 100 && newOpt.affixId == 0; ++attempts)
            {
                // classBoost=1 doubles own-spec entries within the class bucket.
                // Escalate to 2 (force class) if the bad-luck streak hits the protection threshold.
                uint8 effectiveBoost = 1;
                if (!genericsOnly && !classOnly && _badLuckStreakProtection > 0 && optionStreak >= _badLuckStreakProtection)
                    effectiveBoost = 2;

                uint32 id = RollAffixId(quality, player, item, genericsOnly, effectiveBoost, classOnly,
                                        roleForRoll, mainStatForRoll, spec);
                if (!id)
                    continue;

                bool dup = false;
                for (PendingOpt const& ex : chosen)
                    if (ex.affixId == id) { dup = true; break; }
                if (dup)
                    continue;

                auto const* def = GetAffixDef(id);
                int32 val = 0;
                if (def && def->affixType == AFFIX_TYPE_STAT)
                    val = RollBudgetStatValue(def->statOp, itemBudget, _budgetMinRoll);

                newOpt = {id, val, false};

                // Update bad-luck streak on each accepted option.
                bool isClassOpt = def && def->affixType != AFFIX_TYPE_STAT && SpellFamilyToClass(def->spellFamily) != 0;
                if (isClassOpt) optionStreak = 0;
                else            ++optionStreak;
            }

            if (newOpt.affixId == 0)
            {
                // Roll completely failed — keep the original option untouched
                keptOriginal[j] = true;
            }
            else
            {
                finalOpts[j] = newOpt;
                chosen.push_back(newOpt);
            }
        }

        // Apply 2H bonus to genuinely new (not kept) unlocked options.
        if (Is2HWeapon(item))
        {
            for (uint8 j = 0; j < numOpts; ++j)
            {
                if ((lockedMask & (1u << j)) || keptOriginal[j])
                    continue;
                auto const* d = GetAffixDef(finalOpts[j].affixId);
                if (!d) continue;
                if (d->affixType == AFFIX_TYPE_STAT)
                    finalOpts[j].rolledValue = (finalOpts[j].rolledValue * 3 + 1) / 2;
                else if (d->affixType == AFFIX_TYPE_SPELLMOD)
                    finalOpts[j].rolledValue = 150;
            }
        }

        // Crit roll on genuinely new unlocked options.
        // Player Progression: flat bonus from the Crit Roll Chance node, never a regression.
        uint32 effectiveCritChance = std::min<uint32>(_critRollChance +
            uint32(sPlayerProgressionMgr->GetNodeBonus(player->GetGUID().GetRawValue(), NODE_CRIT_ROLL_CHANCE)), 100);
        for (uint8 j = 0; j < numOpts; ++j)
        {
            if ((lockedMask & (1u << j)) || keptOriginal[j])
                continue;
            if (!_critRollEnabled || urand(0, 99) >= effectiveCritChance)
                continue;
            finalOpts[j].isCrit = true;
            auto const* d = GetAffixDef(finalOpts[j].affixId);
            if (!d) continue;
            if (d->affixType == AFFIX_TYPE_STAT)
                finalOpts[j].rolledValue = (finalOpts[j].rolledValue * 3 + 1) / 2;
            else if (d->affixType == AFFIX_TYPE_SPELLMOD)
                finalOpts[j].rolledValue = (finalOpts[j].rolledValue == 150) ? 250 : 200;
        }

        // Imprint replacement: try to replace the last unlocked class spell-mod option.
        if (urand(0, 99) < _imprintRollChance)
        {
            int replaceIdx = -1;
            for (int j = static_cast<int>(numOpts) - 1; j >= 0; --j)
            {
                if ((lockedMask & (1u << j)) || keptOriginal[j])
                    continue;
                auto const* d = GetAffixDef(finalOpts[j].affixId);
                if (d && d->affixType == AFFIX_TYPE_SPELLMOD)
                {
                    replaceIdx = j;
                    break;
                }
            }
            if (replaceIdx >= 0)
            {
                ImprintDef const* impDef = sImprintMgr->GetEligibleImprintForRoll(player, item, spec);
                if (impDef)
                    finalOpts[replaceIdx] = {IMPRINT_OPT_OFFSET + impDef->id, 0, false};
            }
        }

        uint8 newRerolls = slotInfo.rerollsRemaining - 1;

        std::string optsStr;
        for (size_t k = 0; k < finalOpts.size(); ++k)
        {
            if (k > 0) optsStr += ',';
            optsStr += std::to_string(finalOpts[k].affixId) + ':'
                     + std::to_string(finalOpts[k].rolledValue) + ':'
                     + (finalOpts[k].isCrit ? '1' : '0');
        }

        CharacterDatabase.Execute(
            "UPDATE item_affix SET pending_opts = '{}', rerolls_remaining = {}, pending_spec = {} "
            "WHERE item_guid = {} AND affix_slot = {}",
            optsStr, newRerolls, int8(spec), itemGuid, uint32(i));

        SendRollOptions(player, item, i, finalOpts, newRerolls, lockedMask);
        return;
    }
}

// ---------------------------------------------------------------------------
// HandleLockToggle  — toggles lock state for one pending option, re-sends OPTS
// ---------------------------------------------------------------------------

void ItemAffixMgr::HandleLockToggle(Player* player, Item* item, uint8 optIdx, bool locked)
{
    if (!player || !item)
        return;

    uint64 itemGuid = item->GetGUID().GetRawValue();
    auto slots = LoadAffixSlots(itemGuid);

    for (uint8 i = 0; i < static_cast<uint8>(slots.size()); ++i)
    {
        AffixSlotInfo const& slotInfo = slots[i];
        if (slotInfo.rollState != AFFIX_ROLL_PENDING)
            continue;

        if (optIdx >= static_cast<uint8>(slotInfo.pendingOpts.size()))
            return;

        uint8 newMask = slotInfo.lockedMask;
        if (locked)
            newMask |= static_cast<uint8>(1u << optIdx);
        else
            newMask &= static_cast<uint8>(~(1u << optIdx));

        CharacterDatabase.Execute(
            "UPDATE item_affix SET locked_mask = {} WHERE item_guid = {} AND affix_slot = {}",
            newMask, itemGuid, uint32(i));

        SendRollOptions(player, item, i, slotInfo.pendingOpts, slotInfo.rerollsRemaining, newMask);
        return;
    }
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
// Reforge NPC (docs/REFORGE_PLAN.md) -- Stage 1: core engine only, no
// network protocol yet (that's Stage 2).
// ---------------------------------------------------------------------------

ReforgeState ItemAffixMgr::GetReforgeState(uint64 itemGuid) const
{
    ReforgeState state;
    QueryResult result = CharacterDatabase.Query(
        "SELECT locked_slot, reroll_count FROM item_reforge_state WHERE item_guid = {}", itemGuid);
    if (result)
    {
        Field* f = result->Fetch();
        state.exists      = true;
        state.lockedSlot  = f[0].Get<uint8>();
        state.rerollCount = f[1].Get<uint32>();
    }
    return state;
}

uint32 ItemAffixMgr::GetReforgeCost(uint32 itemQuality, uint32 timesAlreadyReforged) const
{
    uint32 baseCost;
    if      (itemQuality >= ITEM_QUALITY_LEGENDARY) baseCost = _reforgeBaseCostLegendary;
    else if (itemQuality >= ITEM_QUALITY_EPIC)      baseCost = _reforgeBaseCostPurple;
    else if (itemQuality == ITEM_QUALITY_RARE)      baseCost = _reforgeBaseCostBlue;
    else                                             baseCost = _reforgeBaseCostGreen;
    return static_cast<uint32>(baseCost * (1.0 + timesAlreadyReforged * 0.5));
}

// Serializes exactly like item_affix.pending_opts ("id:val:crit,..."), so a
// future shared helper is trivial if one ever gets factored out.
static std::string SerializeReforgeOpts(std::vector<PendingOpt> const& opts)
{
    std::string out;
    for (size_t i = 0; i < opts.size(); ++i)
    {
        if (i > 0) out += ',';
        out += std::to_string(opts[i].affixId) + ':'
             + std::to_string(opts[i].rolledValue) + ':'
             + (opts[i].isCrit ? '1' : '0');
    }
    return out;
}

static std::vector<PendingOpt> ParseReforgeOpts(std::string const& raw)
{
    std::vector<PendingOpt> opts;
    if (raw.empty())
        return opts;
    for (auto part : Acore::Tokenize(raw, ',', false))
    {
        auto colon = part.find(':');
        if (colon == std::string_view::npos)
            continue;
        auto id = Acore::StringTo<uint32>(part.substr(0, colon));
        if (!id)
            continue;
        auto rest   = part.substr(colon + 1);
        auto colon2 = rest.find(':');
        int32 val   = Acore::StringTo<int32>(
            colon2 != std::string_view::npos ? rest.substr(0, colon2) : rest
        ).value_or(0);
        bool isCrit = (colon2 != std::string_view::npos && rest.substr(colon2 + 1) == "1");
        opts.push_back({ *id, val, isCrit });
    }
    return opts;
}

ReforgeRollResult ItemAffixMgr::RollReforgeOptions(Player* player, Item* item, uint8 affixSlot,
                                                    std::vector<PendingOpt>* outOptions)
{
    if (!player || !item)
        return ReforgeRollResult::ERR_NOT_APPLIED;

    ItemTemplate const* proto = item->GetTemplate();
    if (!proto)
        return ReforgeRollResult::ERR_NOT_APPLIED;

    uint64 itemGuid = item->GetGUID().GetRawValue();
    auto slots = LoadAffixSlots(itemGuid);
    if (affixSlot >= slots.size() || slots[affixSlot].rollState != AFFIX_ROLL_APPLIED || slots[affixSlot].affixId == 0)
        return ReforgeRollResult::ERR_NOT_APPLIED;

    auto const* currentDef = GetAffixDef(slots[affixSlot].affixId);
    if (!currentDef)
        return ReforgeRollResult::ERR_NOT_APPLIED;

    ReforgeState state = GetReforgeState(itemGuid);
    if (state.exists && state.lockedSlot != affixSlot)
        return ReforgeRollResult::ERR_WRONG_SLOT;  // permanently locked to a different slot

    uint32 quality = proto->Quality;
    uint32 cost = GetReforgeCost(quality, state.exists ? state.rerollCount : 0);
    if (!player->HasEnoughMoney(cost))
        return ReforgeRollResult::ERR_INSUFFICIENT_GOLD;

    player->ModifyMoney(-int32(cost));

    uint32 newRerollCount = state.exists ? state.rerollCount + 1 : 1;
    CharacterDatabase.DirectExecute(
        "INSERT INTO item_reforge_state (item_guid, locked_slot, reroll_count, pending_opts) "
        "VALUES ({}, {}, {}, '') "
        "ON DUPLICATE KEY UPDATE reroll_count = {}, pending_opts = ''",
        itemGuid, uint32(affixSlot), newRerollCount, newRerollCount);

    // Candidate 0, always first: the item's current value, verbatim -- including
    // whether it was itself a crit, so picking "keep current" doesn't silently
    // erase an existing crit's is_crit flag.
    std::vector<PendingOpt> opts;
    opts.push_back({ slots[affixSlot].affixId, slots[affixSlot].rolledValue, slots[affixSlot].isCrit });

    // Bucket is whatever the *current* affix already is, not slot position --
    // this works uniformly for Manual-mode items (no inherent prefix/suffix
    // slot identity) and D3-mode items (slot position implies bucket, but
    // reading it off the current affix gives the same answer either way).
    bool wantPrefix = (currentDef->affixType != AFFIX_TYPE_STAT);

    uint8 numOpts;
    if      (quality >= ITEM_QUALITY_LEGENDARY) numOpts = _optionsCountLegendary;
    else if (quality >= ITEM_QUALITY_EPIC)      numOpts = _optionsCountPurple;
    else if (quality == ITEM_QUALITY_RARE)      numOpts = _optionsCountBlue;
    else                                         numOpts = _optionsCountGreen;
    uint8 optionsBonus = uint8(sPlayerProgressionMgr->GetNodeBonus(player->GetGUID().GetRawValue(), NODE_OPTIONS_TIER));
    numOpts = std::min<uint8>(numOpts + optionsBonus, 6);

    uint8 playerClass = player->getClass();
    int   resolvedSpec = GetDominantTalentTree(player);
    uint8 roleForRoll     = GetAutoRole(playerClass, resolvedSpec);
    uint8 mainStatForRoll = GetAutoMainStat(playerClass, resolvedSpec);
    float itemBudget = ComputeItemBudget(proto->ItemLevel) * GetSlotBudgetMod(proto->InventoryType)
                     * GetQualityFraction(quality);
    bool is2H = Is2HWeapon(item);

    // ClassAffixMaxPerItem is bypassed unconditionally here (independent of
    // ItemAffixes.D3OverrideClassAffixMaxPerItem, which only governs
    // AutoRollD3Item): this slot already holds a class affix, so it's
    // already counted toward the cap. Without the bypass, rerolling an
    // item's *only* class affix slot would be blocked by its own cap.
    for (uint8 i = 0; i < numOpts; ++i)
    {
        uint32 id = wantPrefix
            ? RollAffixId(quality, player, item, /*genericsOnly*/false, /*classBoost*/0,
                           /*classOnly*/true, roleForRoll, mainStatForRoll, -1, /*ownSpecWeight*/1,
                           /*ignoreClassAffixMaxPerItem*/true)
            : RollAffixId(quality, player, item, /*genericsOnly*/true, /*classBoost*/0,
                           /*classOnly*/false, roleForRoll, mainStatForRoll, -1, /*ownSpecWeight*/1,
                           /*ignoreClassAffixMaxPerItem*/true);
        if (!id)
            continue;

        auto const* def = GetAffixDef(id);
        int32 val = (def && def->affixType == AFFIX_TYPE_STAT)
            ? RollBudgetStatValue(def->statOp, itemBudget, _budgetMinRoll)
            : 0;
        if (is2H && def)
        {
            if (def->affixType == AFFIX_TYPE_STAT)
                val = (val * 3 + 1) / 2;
            else if (def->affixType == AFFIX_TYPE_SPELLMOD)
                val = 150;
        }
        opts.push_back({ id, val, false });
    }

    // Crit roll: same per-option chance/effect as HandleRollRequest and
    // AutoRollD3Item -- this was simply never ported here before, so a
    // Reforge reroll could never produce a crit option no matter how high
    // CritRollChance was configured. opts[0] (the current value) is
    // deliberately skipped -- it's never re-rolled, so it can't crit.
    uint32 effectiveCritChance = std::min<uint32>(_critRollChance +
        uint32(sPlayerProgressionMgr->GetNodeBonus(player->GetGUID().GetRawValue(), NODE_CRIT_ROLL_CHANCE)), 100);
    for (size_t i = 1; i < opts.size(); ++i)
    {
        if (!_critRollEnabled || urand(0, 99) >= effectiveCritChance)
            continue;
        PendingOpt& opt = opts[i];
        opt.isCrit = true;
        auto const* d = GetAffixDef(opt.affixId);
        if (!d) continue;
        if (d->affixType == AFFIX_TYPE_STAT)
            opt.rolledValue = (opt.rolledValue * 3 + 1) / 2;
        else if (d->affixType == AFFIX_TYPE_SPELLMOD)
            opt.rolledValue = (opt.rolledValue == 150) ? 250 : 200;
    }

    CharacterDatabase.DirectExecute(
        "UPDATE item_reforge_state SET pending_opts = '{}' WHERE item_guid = {}",
        SerializeReforgeOpts(opts), itemGuid);

    if (outOptions)
        *outOptions = opts;
    return ReforgeRollResult::OK;
}

ReforgePickResult ItemAffixMgr::CommitReforgePick(Player* player, Item* item, uint8 affixSlot, uint32 optIdx)
{
    if (!player || !item)
        return ReforgePickResult::ERR_NO_PENDING;

    uint64 itemGuid = item->GetGUID().GetRawValue();
    QueryResult result = CharacterDatabase.Query(
        "SELECT locked_slot, pending_opts FROM item_reforge_state WHERE item_guid = {}", itemGuid);
    if (!result)
        return ReforgePickResult::ERR_NO_PENDING;

    Field* f = result->Fetch();
    uint8 lockedSlot = f[0].Get<uint8>();
    std::string pendingOptsStr = f[1].Get<std::string>();
    if (lockedSlot != affixSlot)
        return ReforgePickResult::ERR_WRONG_SLOT;
    if (pendingOptsStr.empty())
        return ReforgePickResult::ERR_NO_PENDING;

    std::vector<PendingOpt> opts = ParseReforgeOpts(pendingOptsStr);
    if (optIdx >= opts.size())
        return ReforgePickResult::ERR_INVALID_INDEX;

    PendingOpt const& chosen = opts[optIdx];

    CharacterDatabase.DirectExecute(
        "UPDATE item_affix SET affix_id = {}, rolled_value = {}, is_crit = {} WHERE item_guid = {} AND affix_slot = {}",
        chosen.affixId, chosen.rolledValue, uint8(chosen.isCrit), itemGuid, uint32(affixSlot));
    CharacterDatabase.DirectExecute(
        "UPDATE item_reforge_state SET pending_opts = '' WHERE item_guid = {}", itemGuid);

    uint8 bagSlot  = item->GetBagSlot();
    uint8 itemSlot = item->GetSlot();
    if (bagSlot == INVENTORY_SLOT_BAG_0 && itemSlot < EQUIPMENT_SLOT_END)
        SyncAffixes(player);

    SendItemStatus(player, item);
    return ReforgePickResult::OK;
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
// Quest-reward-in-progress flag helpers -- see the comment on the header
// declaration for the core hooks that drive this.
// ---------------------------------------------------------------------------

void ItemAffixMgr::SetQuestRewardInProgress(uint64 playerGuid, bool inProgress)
{
    if (inProgress)
        _questRewardInProgress.insert(playerGuid);
    else
        _questRewardInProgress.erase(playerGuid);
}

bool ItemAffixMgr::IsQuestRewardInProgress(uint64 playerGuid) const
{
    return _questRewardInProgress.count(playerGuid) != 0;
}

// ---------------------------------------------------------------------------
// AppendAffixPayload  — shared serializer for all read-only item queries
// ---------------------------------------------------------------------------
// Appends |s{i}:{state}:{text} slot entries, |ta:+{rv} to {name} talent lines,
// and |imprint:{name}:{n} to msg for the item identified by rawGuid.
// slots must already be loaded by the caller (via LoadAffixSlots) so they can
// also use the count for their message prefix before calling this function.

void ItemAffixMgr::AppendAffixPayload(std::string& msg, uint64 rawGuid,
                                       std::vector<AffixSlotInfo> const& slots)
{
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
                    if (s.isCrit)
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

    ImprintInstance const* impInst = sImprintMgr->GetInstance(rawGuid);
    if (impInst)
    {
        ImprintDef const* impDef = sImprintMgr->GetDef(impInst->imprintId);
        std::string impName = impDef ? impDef->name : "Unknown Imprint";
        msg += Acore::StringFormat("|imprint:{}:{}", impName, impInst->extractionsLeft);
    }
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

    if (cmd == "PROG")
    {
        sPlayerProgressionMgr->HandleAddonMessage(player, parts);
        return;
    }

    if (cmd == "CONFIG")
    {
        SendConfig(player);
        return;
    }

    if (cmd == "ALLDATA")
    {
        RefreshAllItemStatus(player);
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
        AppendAffixPayload(msg, rawGuid, slots);

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
        AppendAffixPayload(msg, rawGuid, slots);

        LOG_DEBUG("module", "mod-item-affixes: PEEKUNIT sending: {}", msg);
        SendAddonMsg(player, msg);
        return;
    }

    // PEEKAUCTION — read affixes for an AH item by seller name + item template ID.
    // WoW 3.3.5a AH packet does not include item instance GUIDs, so the client sends
    // the seller's character name and item template ID extracted from GetAuctionItemInfo.
    // The client also sends auctionType and index (its own listing-slot identifiers) so
    // the server can echo them back.  The client keys auctionCache by auctionType:index,
    // giving each listing slot its own cache entry regardless of shared item template.
    // groupOffset is the 0-based position within the same (owner,itemId,buyout) group on
    // the current AH page; used as OFFSET in the SQL query so each listing returns a
    // different physical item instance (items ordered by ah.id ASC for stability).
    // Format: PEEKAUCTION|owner|itemId|buyout|auctionType|index|groupOffset
    // Response: AUCTIONDATA|owner|itemId|buyout|auctionType|index|slotCount|...
    if (cmd == "PEEKAUCTION")
    {
        if (parts.size() < 3)
            return;

        std::string ownerName(parts[1]);
        auto itemIdOpt = Acore::StringTo<uint32>(parts[2]);
        if (!itemIdOpt)
            return;
        uint32 itemId = *itemIdOpt;

        uint32 buyout = 0;
        if (parts.size() >= 4)
        {
            if (auto v = Acore::StringTo<uint32>(parts[3])) buyout = *v;
        }

        // Echoed back verbatim so the client can key its cache by listing slot.
        std::string auctionTypeStr = parts.size() >= 5 ? std::string(parts[4]) : "list";
        uint32      auctionIndex   = 0;
        if (parts.size() >= 6)
        {
            if (auto v = Acore::StringTo<uint32>(parts[5])) auctionIndex = *v;
        }
        // 0-based offset within same (owner,itemId,buyout) group; used for LIMIT/OFFSET.
        uint32 groupOffset = 0;
        if (parts.size() >= 7)
        {
            if (auto v = Acore::StringTo<uint32>(parts[6])) groupOffset = *v;
        }

        LOG_DEBUG("module", "mod-item-affixes: PEEKAUCTION from {} owner={} itemId={} buyout={} type={} idx={} offset={}",
            player->GetName(), ownerName, itemId, buyout, auctionTypeStr, auctionIndex, groupOffset);

        // Find the auction via item_instance.  When buyout > 0, filter by buyoutprice.
        QueryResult auctionResult;
        if (buyout > 0)
        {
            auctionResult = CharacterDatabase.Query(
                "SELECT ah.itemguid FROM auctionhouse ah "
                "INNER JOIN item_instance ii ON ii.guid = ah.itemguid "
                "INNER JOIN characters c ON c.guid = ah.itemowner "
                "WHERE c.name = '{}' AND ii.itemEntry = {} AND ah.buyoutprice = {} "
                "ORDER BY ah.id ASC LIMIT 1 OFFSET {}",
                ownerName, itemId, buyout, groupOffset);
        }
        else
        {
            auctionResult = CharacterDatabase.Query(
                "SELECT ah.itemguid FROM auctionhouse ah "
                "INNER JOIN item_instance ii ON ii.guid = ah.itemguid "
                "INNER JOIN characters c ON c.guid = ah.itemowner "
                "WHERE c.name = '{}' AND ii.itemEntry = {} "
                "ORDER BY ah.id ASC LIMIT 1 OFFSET {}",
                ownerName, itemId, groupOffset);
        }

        if (!auctionResult)
        {
            LOG_DEBUG("module", "mod-item-affixes: PEEKAUCTION no auction found for owner={} itemId={} buyout={}",
                ownerName, itemId, buyout);
            SendAddonMsg(player, Acore::StringFormat("AUCTIONDATA|{}|{}|{}|{}|{}|0",
                ownerName, itemId, buyout, auctionTypeStr, auctionIndex));
            return;
        }

        uint32 rawCounter = auctionResult->Fetch()[0].Get<uint32>();
        ObjectGuid itemGuid(HighGuid::Item, rawCounter);
        uint64 rawGuid = itemGuid.GetRawValue();

        LOG_DEBUG("module", "mod-item-affixes: PEEKAUCTION found itemguid={} rawGuid={}",
            rawCounter, rawGuid);

        auto slots = LoadAffixSlots(rawGuid);
        std::string msg = Acore::StringFormat("AUCTIONDATA|{}|{}|{}|{}|{}|{}",
            ownerName, itemId, buyout, auctionTypeStr, auctionIndex, slots.size());
        AppendAffixPayload(msg, rawGuid, slots);

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
            AppendAffixPayload(msg, rawGuid, slots);

            SendAddonMsg(player, msg);
        }

        LOG_DEBUG("module", "mod-item-affixes: PEEKUNITALL done for {}", targetName);
        return;
    }

    // Helper: build affix+talent+imprint payload for a trade-window item and send
    // it as TRADEGUID (partner) or MYTRADEGUID (own).  The counter is the low 32
    // bits of the item's raw GUID — identical to what ObjectGuid(HighGuid::Item, x)
    // uses and what the PEEK handler reconstructs from client messages.
    auto SendTradeGuidMsg = [&](const char* msgPrefix, uint8 luaSlot, Item* item)
    {
        uint64 rawGuid  = item->GetGUID().GetRawValue();
        uint32 counter  = static_cast<uint32>(rawGuid);   // low 32 bits = counter
        auto   slots    = LoadAffixSlots(rawGuid);

        std::string msg = Acore::StringFormat("{}|{}|{}|{}", msgPrefix, luaSlot, counter, slots.size());
        AppendAffixPayload(msg, rawGuid, slots);

        LOG_DEBUG("module", "mod-item-affixes: {} slot={} counter={} sending: {}", msgPrefix, luaSlot, counter, msg);
        SendAddonMsg(player, msg);
    };

    // TRADEPEEK — partner's item.  WoW 3.3.5a strips GUIDs from GetTradeTargetItemLink
    // (uid=0), so the client cannot identify the item.  Reply with TRADEGUID carrying
    // counter + full affix data so the client populates peekCache in one round trip.
    if (cmd == "TRADEPEEK")
    {
        if (parts.size() < 2)
            return;

        auto slotOpt = Acore::StringTo<uint8>(parts[1]);
        if (!slotOpt || *slotOpt < 1 || *slotOpt > TRADE_SLOT_TRADED_COUNT)
            return;

        uint8 luaSlot = *slotOpt;
        uint8 cppSlot = luaSlot - 1;

        TradeData* myTrade = player->GetTradeData();
        if (!myTrade) { SendAddonMsg(player, Acore::StringFormat("TRADEGUID|{}|0|0", luaSlot)); return; }

        TradeData* partnerTrade = myTrade->GetTraderData();
        if (!partnerTrade) { SendAddonMsg(player, Acore::StringFormat("TRADEGUID|{}|0|0", luaSlot)); return; }

        Item* item = partnerTrade->GetItem(TradeSlots(cppSlot));
        if (!item) { SendAddonMsg(player, Acore::StringFormat("TRADEGUID|{}|0|0", luaSlot)); return; }

        SendTradeGuidMsg("TRADEGUID", luaSlot, item);
        return;
    }

    // MYTRADEPEEK — own item.  GetTradePlayerItemLink may also carry uid=0 for
    // duplicate-template items.  Reply with MYTRADEGUID so the client can show the
    // correct affixes per slot even when two identical items are in the trade window.
    if (cmd == "MYTRADEPEEK")
    {
        if (parts.size() < 2)
            return;

        auto slotOpt = Acore::StringTo<uint8>(parts[1]);
        if (!slotOpt || *slotOpt < 1 || *slotOpt > TRADE_SLOT_TRADED_COUNT)
            return;

        uint8 luaSlot = *slotOpt;
        uint8 cppSlot = luaSlot - 1;

        TradeData* myTrade = player->GetTradeData();
        if (!myTrade) { SendAddonMsg(player, Acore::StringFormat("MYTRADEGUID|{}|0|0", luaSlot)); return; }

        Item* item = myTrade->GetItem(TradeSlots(cppSlot));
        if (!item) { SendAddonMsg(player, Acore::StringFormat("MYTRADEGUID|{}|0|0", luaSlot)); return; }

        SendTradeGuidMsg("MYTRADEGUID", luaSlot, item);
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
    else if (cmd == "REROLL" && parts.size() >= 3)
    {
        int8  spec    = -1;
        uint8 type    = 0;
        uint8 role    = 0;
        uint8 mainSt  = 0;
        if (parts.size() >= 4)
            if (auto sv = Acore::StringTo<uint8>(parts[3]))
                spec = (*sv == 255) ? -1 : static_cast<int8>(*sv);
        if (parts.size() >= 5)
            if (auto v = Acore::StringTo<uint8>(parts[4])) type   = *v;
        if (parts.size() >= 6)
            if (auto v = Acore::StringTo<uint8>(parts[5])) role   = *v;
        if (parts.size() >= 7)
            if (auto v = Acore::StringTo<uint8>(parts[6])) mainSt = *v;
        HandleRerollRequest(player, item, spec, type, role, mainSt);
    }
    else if (cmd == "LOCK" && parts.size() >= 5)
    {
        auto optIdxOpt = Acore::StringTo<uint8>(parts[3]);
        auto stateOpt  = Acore::StringTo<uint8>(parts[4]);
        if (!optIdxOpt || !stateOpt) return;
        HandleLockToggle(player, item, *optIdxOpt, *stateOpt == 1);
    }
    else if (cmd == "DATA")
    {
        // Always respond to an explicit client DATA request so the client's
        // "[Fetching affixes...]" placeholder is cleared even for items with nothing.
        // SendItemStatus has an early-return for items with no slots/imprint/talent,
        // so check that condition here and send an empty DATA|bag|slot|0 if needed.
        uint64 rawGuid = item->GetGUID().GetRawValue();
        auto   slots   = LoadAffixSlots(rawGuid);
        bool hasImprint = sImprintMgr->GetInstance(rawGuid) != nullptr;
        bool hasTalent  = CharacterDatabase.Query(
            "SELECT 1 FROM item_talent_affix WHERE item_guid = {} LIMIT 1", rawGuid) != nullptr;
        if (slots.empty() && !hasImprint && !hasTalent)
        {
            auto [luaBag, luaSlot] = GetLuaBagSlot(item);
            SendAddonMsg(player, Acore::StringFormat("DATA|{}|{}|0",
                uint32(luaBag), uint32(luaSlot)));
        }
        else
        {
            SendItemStatus(player, item);
        }
    }
    else if (cmd == "REFORGE_STATUS")
    {
        auto [luaBag, luaSlot] = GetLuaBagSlot(item);
        auto slots = LoadAffixSlots(item->GetGUID().GetRawValue());
        ReforgeState state = GetReforgeState(item->GetGUID().GetRawValue());

        // Cost doesn't depend on which slot ends up picked -- only on item
        // quality and how many times this item has already been reforged --
        // so one value up front covers the whole item; the UI needs to show
        // this before the player commits to a Reroll, not just after.
        ItemTemplate const* proto = item->GetTemplate();
        uint32 cost = proto ? GetReforgeCost(proto->Quality, state.exists ? state.rerollCount : 0) : 0;

        std::string msg = Acore::StringFormat("REFORGESTATUS|{}|{}|{}|{}|{}",
            uint32(luaBag), uint32(luaSlot), uint32(slots.size()),
            state.exists ? uint32(state.lockedSlot) : 255u, cost);
        for (uint8 i = 0; i < static_cast<uint8>(slots.size()); ++i)
        {
            std::string text;
            char stateChar = 'X';
            if (slots[i].rollState == AFFIX_ROLL_APPLIED && slots[i].affixId != 0)
            {
                if (auto const* def = GetAffixDef(slots[i].affixId))
                {
                    stateChar = 'A';
                    text = BuildAffixDisplayString(def, slots[i].rolledValue);
                }
            }
            msg += Acore::StringFormat("|s{}:{}:{}", i, stateChar, text);
        }
        SendAddonMsg(player, msg);
    }
    else if (cmd == "REFORGE_ROLL" && parts.size() >= 4)
    {
        auto affixSlotOpt = Acore::StringTo<uint8>(parts[3]);
        if (!affixSlotOpt) return;
        auto [luaBag, luaSlot] = GetLuaBagSlot(item);

        std::vector<PendingOpt> opts;
        ReforgeRollResult result = RollReforgeOptions(player, item, *affixSlotOpt, &opts);
        if (result != ReforgeRollResult::OK)
        {
            char const* reason = "Unable to reforge this item right now.";
            switch (result)
            {
                case ReforgeRollResult::ERR_NOT_APPLIED:        reason = "That line hasn't been rolled yet."; break;
                case ReforgeRollResult::ERR_WRONG_SLOT:         reason = "This item is already locked to a different line."; break;
                case ReforgeRollResult::ERR_INSUFFICIENT_GOLD:  reason = "You don't have enough gold."; break;
                default: break;
            }
            SendAddonMsg(player, Acore::StringFormat("ERR|{}|{}|{}", uint32(luaBag), uint32(luaSlot), reason));
            return;
        }

        std::string msg = Acore::StringFormat("REFORGEOPTS|{}|{}|{}",
            uint32(luaBag), uint32(luaSlot), uint32(*affixSlotOpt));
        for (PendingOpt const& opt : opts)
        {
            std::string text;
            if (auto const* def = GetAffixDef(opt.affixId))
                text = BuildAffixDisplayString(def, opt.rolledValue);
            // "!" prefix marks a crit option -- same convention SendRollOptions
            // uses, stripped and re-styled client-side.
            if (opt.isCrit)
                text = "!" + text;
            msg += "|" + text;
        }
        SendAddonMsg(player, msg);
    }
    else if (cmd == "REFORGE_PICK" && parts.size() >= 5)
    {
        auto affixSlotOpt = Acore::StringTo<uint8>(parts[3]);
        auto optIdxOpt     = Acore::StringTo<uint32>(parts[4]);
        if (!affixSlotOpt || !optIdxOpt) return;
        auto [luaBag, luaSlot] = GetLuaBagSlot(item);

        ReforgePickResult result = CommitReforgePick(player, item, *affixSlotOpt, *optIdxOpt);
        if (result != ReforgePickResult::OK)
        {
            char const* reason = "Unable to apply that choice.";
            switch (result)
            {
                case ReforgePickResult::ERR_NO_PENDING:    reason = "Nothing to pick -- roll first."; break;
                case ReforgePickResult::ERR_WRONG_SLOT:    reason = "This item is locked to a different line."; break;
                case ReforgePickResult::ERR_INVALID_INDEX: reason = "That option is no longer valid."; break;
                default: break;
            }
            SendAddonMsg(player, Acore::StringFormat("ERR|{}|{}|{}", uint32(luaBag), uint32(luaSlot), reason));
        }
        // On success, CommitReforgePick already called SendItemStatus.
    }
    else if (cmd == "REFORGE_PREVIEW" && parts.size() >= 4)
    {
        auto affixSlotOpt = Acore::StringTo<uint8>(parts[3]);
        if (!affixSlotOpt) return;
        auto [luaBag, luaSlot] = GetLuaBagSlot(item);

        auto slots = LoadAffixSlots(item->GetGUID().GetRawValue());
        if (*affixSlotOpt >= slots.size() || slots[*affixSlotOpt].rollState != AFFIX_ROLL_APPLIED
            || slots[*affixSlotOpt].affixId == 0)
        {
            SendAddonMsg(player, Acore::StringFormat("ERR|{}|{}|{}",
                uint32(luaBag), uint32(luaSlot), "That line hasn't been rolled yet."));
            return;
        }
        auto const* currentDef = GetAffixDef(slots[*affixSlotOpt].affixId);
        if (!currentDef)
            return;
        bool wantPrefix = (currentDef->affixType != AFFIX_TYPE_STAT);

        std::vector<uint32> ids = GetEligibleAffixesForPreview(player, item, wantPrefix);

        ItemTemplate const* proto = item->GetTemplate();
        float itemBudget = proto
            ? ComputeItemBudget(proto->ItemLevel) * GetSlotBudgetMod(proto->InventoryType) * GetQualityFraction(proto->Quality)
            : 0.0f;
        bool is2H = Is2HWeapon(item);

        std::vector<std::string> texts;
        texts.reserve(ids.size());
        for (uint32 id : ids)
        {
            auto const* def = GetAffixDef(id);
            if (!def)
                continue;
            if (def->affixType == AFFIX_TYPE_STAT)
            {
                StatValueRange range = GetBudgetStatValueRange(def->statOp, itemBudget, _budgetMinRoll);
                if (is2H)
                {
                    range.minVal = (range.minVal * 3 + 1) / 2;
                    range.maxVal = (range.maxVal * 3 + 1) / 2;
                }
                texts.push_back(BuildStatRangeDisplayString(def, range.minVal, range.maxVal));
            }
            else
            {
                // Base/plain value only -- not attempting the 2H/crit double-range
                // notation D3 uses for these, same as the existing roll-option UI.
                texts.push_back(BuildAffixDisplayString(def, 0));
            }
        }
        std::sort(texts.begin(), texts.end());

        // Same 255-char addon-message cap as everywhere else in this protocol
        // (see PlayerProgressionMgr::SendProgState) -- a full eligible pool can
        // easily run past that inline, so it's split into a tiny header plus
        // one or more REFORGEPREVIEWDATA chunks the client buffers and commits
        // once all have arrived.
        static constexpr size_t kChunkBudget = 180;
        std::vector<std::string> chunks;
        std::string current;
        for (std::string const& text : texts)
        {
            if (!current.empty() && current.size() + 1 + text.size() > kChunkBudget)
            {
                chunks.push_back(current);
                current.clear();
            }
            if (!current.empty())
                current += "|";
            current += text;
        }
        if (!current.empty())
            chunks.push_back(current);

        SendAddonMsg(player, Acore::StringFormat("REFORGEPREVIEW|{}|{}|{}|{}",
            uint32(luaBag), uint32(luaSlot), uint32(*affixSlotOpt), chunks.size()));
        for (size_t i = 0; i < chunks.size(); ++i)
            SendAddonMsg(player, Acore::StringFormat("REFORGEPREVIEWDATA|{}|{}|{}|{}|{}|{}",
                uint32(luaBag), uint32(luaSlot), uint32(*affixSlotOpt), i, chunks.size(), chunks[i]));
    }
}
