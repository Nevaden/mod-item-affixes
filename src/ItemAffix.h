#pragma once

#include "Common.h"
#include "DataMap.h"
#include "Player.h"     // SpellModifier, SpellModType (107=FLAT, 108=PCT), SpellModOp
#include "SpellDefines.h" // SpellModOp enum values
#include "Util.h"
#include <unordered_map>
#include <unordered_set>
#include <vector>

// SpellModOp: SPELLMOD_CASTING_TIME=10  (from SpellDefines.h)
// SpellModType: SPELLMOD_FLAT=107, SPELLMOD_PCT=108  (from Player.h — these equal aura type IDs)

enum AffixType : uint8
{
    AFFIX_TYPE_SPELLMOD = 0,   // existing: allocates SpellModifier*
    AFFIX_TYPE_STAT     = 1,   // new: calls HandleStatFlatModifier / ApplyRatingMod / etc.
};

// One talent affix definition loaded from talent_affix_def (world DB).
struct TalentAffixDef
{
    uint32      id;
    std::string name;
    uint32      classMask;      // bit (1 << (classId-1)); 0 = any class
    int8        specTree;       // -1 = any spec; 0/1/2 = required dominant tree
    uint8       maxRank;        // talent's max rank in the game
    uint8       spellFamily;    // SpellFamilyName enum value
    uint32      familyFlags[3]; // SpellClassOptions.SpellClassMask
    uint32      carrierSpell;   // a real spell from this family (for IsAffectedBySpellMod)
    uint8       spellmodOp;     // SpellModOp value
    uint8       spellmodType;   // SpellModType: 107=SPELLMOD_FLAT, 108=SPELLMOD_PCT
    int32       valuePerRank;   // spellmod magnitude per rolled rank (e.g. -100 ms)
    uint8       itemCategory;   // AffixItemCategory — 0=any; 8=DAGGER (daggers + non-weapons)
};

// Item category filter for stat affixes (determines which item types can roll the affix).
// ITEM_CAT_WEAPON covers both WEAPON_1H and WEAPON_2H in ItemMatchesCategory().
enum AffixRoleGroup : uint8
{
    AFFIX_ROLE_ANY      = 0,   // rolls for any role (default)
    AFFIX_ROLE_CASTER   = 1,
    AFFIX_ROLE_PHYSICAL = 2,
    AFFIX_ROLE_TANK     = 4,
    AFFIX_ROLE_HEALER   = 8,
    AFFIX_ROLE_RANGED   = 16,  // physical ranged (Hunter + custom ranged classes)
};

enum AffixItemCategory : uint8
{
    ITEM_CAT_ANY        = 0,  // rolls on any equippable item
    ITEM_CAT_WEAPON_1H  = 1,  // one-handed weapons (INVTYPE_WEAPON/WEAPONMAINHAND/WEAPONOFFHAND/SHIELD)
    ITEM_CAT_WEAPON_2H  = 2,  // two-handed weapons and ranged (INVTYPE_2HWEAPON/RANGED)
    ITEM_CAT_WEAPON     = 3,  // any weapon (1H or 2H — matched by ItemMatchesCategory)
    ITEM_CAT_ARMOR      = 4,  // head/shoulder/chest/waist/legs/feet/hands/wrist/back/cloak/holdable (includes boots)
    ITEM_CAT_JEWELRY    = 5,  // neck/finger/trinket
    ITEM_CAT_WAND       = 6,  // INVTYPE_RANGEDRIGHT (wand slot)
    ITEM_CAT_BOOTS      = 7,  // boots only (INVTYPE_FEET) — subset of ARMOR
    ITEM_CAT_DAGGER     = 8,  // daggers only when weapon; non-weapon items always pass through
};

enum GenericStatOp : uint8
{
    GSTAT_STAMINA          = 0,
    GSTAT_STRENGTH         = 1,
    GSTAT_AGILITY          = 2,
    GSTAT_INTELLECT        = 3,
    GSTAT_SPIRIT           = 4,
    GSTAT_ATTACK_POWER     = 5,
    GSTAT_RANGED_AP        = 6,
    GSTAT_SPELL_POWER      = 7,
    GSTAT_MP5              = 8,
    GSTAT_ARMOR            = 9,
    GSTAT_CRIT_RATING      = 10,  // fans out to CR_CRIT_MELEE + RANGED + SPELL
    GSTAT_HASTE_RATING     = 11,  // fans out to CR_HASTE_MELEE + RANGED + SPELL
    GSTAT_HIT_RATING       = 12,  // fans out to CR_HIT_MELEE + RANGED + SPELL
    GSTAT_DODGE_RATING     = 13,
    GSTAT_DEFENSE_RATING   = 14,
    GSTAT_PARRY_RATING     = 15,
    GSTAT_EXPERTISE_RATING = 16,
    GSTAT_ARMOR_PEN_RATING = 17,
    GSTAT_MOVE_SPEED       = 18,  // flat percent bonus to run speed (value=10 → +10%)
};

enum AffixRollState : uint8
{
    AFFIX_ROLL_UNROLLED = 0,   // slot exists, not yet rolled
    AFFIX_ROLL_PENDING  = 1,   // options sent to client, awaiting pick
    AFFIX_ROLL_APPLIED  = 2,   // affix chosen and active
};

struct AffixEffect
{
    uint8        op;    // SpellModOp value; 255 = inactive slot
    SpellModType type;
    int32        value;
};

struct AffixDefinition
{
    uint32      id;
    std::string name;
    uint32      weight;
    uint32      minQuality;       // ITEM_QUALITY_NORMAL=1, ITEM_QUALITY_UNCOMMON=2, etc.
    uint32      spellFamily;      // SpellFamilyName enum value
    uint32      spellFamilyFlags[3];
    uint32      carrierSpellId;   // real spell so IsAffectedBySpellMod resolves family
    AffixEffect effects[4];       // [0]=primary; op==255 marks slot inactive
    // -- stat affix fields --
    AffixType   affixType;        // AFFIX_TYPE_SPELLMOD or AFFIX_TYPE_STAT
    uint8       statOp;           // GenericStatOp (only used when affixType==STAT)
    uint8       itemCategory;     // AffixItemCategory (ITEM_CAT_ANY=0 = rolls on anything)
    uint8       specTree;         // 255=no restriction; 0/1/2=dominant talent tree required
    uint8       roleMask;         // AffixRoleGroup bitmask; 0=any role
};

struct ActiveStatMod
{
    uint8 statOp;   // GenericStatOp — which stat
    int32 value;    // magnitude that was applied (needed for removal)
};

// Per-player transient state: tracks active SpellModifiers and stat mods keyed by item GUID.
// Cleared automatically when the DataMap is destroyed (session end).
struct ItemAffixPlayerData : public DataMap::Base
{
    // item GUID (GetGUID().GetRawValue()) -> SpellModifiers currently applied
    std::unordered_map<uint64, std::vector<SpellModifier*>> activeMods;
    // item GUID -> generic stat mods currently applied
    std::unordered_map<uint64, std::vector<ActiveStatMod>>  activeStatMods;
    // item GUID -> talent affix SpellModifiers currently applied
    std::unordered_map<uint64, std::vector<SpellModifier*>> activeTalentMods;
    // gear item GUID -> stat mods from socketed gem affixes
    std::unordered_map<uint64, std::vector<ActiveStatMod>>  activeGemStatMods;

    // --- Imprint system ---
    // item GUID -> imprintId for all currently equipped items that carry an Imprint
    std::unordered_map<uint64, uint32>                      activeImprints;
    // item GUID -> SpellModifiers allocated by an Imprint effect on equip
    std::unordered_map<uint64, std::vector<SpellModifier*>> activeImprintMods;

    // Feral Spirit: Alpha — GUID of the permanent alpha wolf, for cleanup on unequip
    ObjectGuid feralAlphaWolfGuid;
    // Eternal Elemental — GUID of the permanent Water Elemental, for cleanup on unequip
    ObjectGuid eternalElementalGuid;
};

// Persisted affix record: one row in item_affix table (applied affixes only)
struct ItemAffixRecord
{
    uint32 affixId;
    int32  rolledValue;  // 0 for spellmod affixes; rolled stat magnitude for AFFIX_TYPE_STAT
};

// affixId values >= IMPRINT_OPT_OFFSET encode an Imprint roll option rather than a normal affix.
// Real affix IDs are small sequential integers that will never reach this value.
static constexpr uint32 IMPRINT_OPT_OFFSET = 100000u;

// One option in a pending roll — id + the value already rolled for it.
// Stored as "id:val:crit,..." in pending_opts so the exact value is
// displayed to the player and applied without re-rolling.
struct PendingOpt
{
    uint32 affixId;
    int32  rolledValue;  // STAT: magnitude; SPELLMOD: 0=plain, 150=2H, 200=crit, 250=2H+crit
    bool   isCrit;       // true if this option landed a crit roll (drives ! prefix in OPTS)

    bool   IsImprint()    const { return affixId >= IMPRINT_OPT_OFFSET; }
    uint32 GetImprintId() const { return affixId - IMPRINT_OPT_OFFSET; }
};

// Full per-slot state including unrolled/pending slots
struct AffixSlotInfo
{
    uint8                  rollState;    // AffixRollState
    uint32                 affixId;      // 0 if not yet applied
    int32                  rolledValue;
    std::vector<PendingOpt> pendingOpts; // populated when PENDING
};

class ItemAffixMgr
{
public:
    static ItemAffixMgr* instance();

    void LoadAffixTemplates();

    // Initialize affix slots for a newly acquired item (all start UNROLLED).  No-op if already initialized.
    void InitItemSlots(Player* player, Item* item);
    void Upgrade2HSlots(Player* player, Item* item);     // adds the extra 2H slot to one pre-existing item
    void UpgradeAll2HSlots(Player* player);              // iterates all player items and calls Upgrade2HSlots

    // Roll a talent affix at first-roll time.  specOverride: 0/1/2=explicit tree, -1=use dominant.
    // No-op if item quality < rare, talent affix already assigned, or no eligible defs exist.
    // Blues: 50% chance.  Purple+: 100% chance.
    void InitTalentAffix(Player* player, Item* item, int8 specOverride = -1, uint8 affixSlot = 0);

    // Send CONFIG message to client with server-side feature toggle flags.
    void SendConfig(Player* player);

    // Apply talent affix SpellMods for this item.  Called on equip (via ReapplyAllEquipped).
    void ApplyTalentAffixes(Player* player, Item* item);

    // Remove talent affix SpellMods for this item.  Called on unequip (via SyncAffixes).
    void RemoveTalentAffixes(Player* player, Item* item);

    // Apply SpellMods/stats for all affixes on this item.  Called on equip.
    void ApplyAffixes(Player* player, Item* item);

    // Remove and free SpellMods/stats for this item.  Called on unequip.
    void RemoveAffixes(Player* player, Item* item);

    // Apply/remove gem-transferred stat bonuses for a gear item.  Called on equip/unequip
    // and immediately after gem socketing.
    void ApplyGemAffixes(Player* player, Item* gearItem);
    void RemoveGemAffixes(Player* player, Item* gearItem);

    // Called by the OnPlayerSocketGem script hook just before the gem item is destroyed.
    void OnSocketGem(Player* player, Item* gearItem, Item* gemItem, uint8 socketSlot);

    // Reapply mods for every currently equipped item.  Called on login.
    void ReapplyAllEquipped(Player* player);

    // Remove all active mods for a player.  Called before logout.
    void RemoveAllActiveMods(Player* player);

    // Remove ALL active mods then reapply for every currently equipped item.
    void SyncAffixes(Player* player);

    AffixDefinition const* GetAffixDef(uint32 id) const;

    // Addon message protocol entry point.  Called from OnPlayerBeforeSendChatMessage.
    void HandleAddonMessage(Player* player, std::string const& payload);

    // Push current affix slot state for one item to the client.
    void SendItemStatus(Player* player, Item* item, std::string const& extraTalentLine = "");

    // Reset all affix rows for an item and re-initialize with UNROLLED slots.
    // Clears any old PERM_ENCHANTMENT_SLOT data.  Called by .affix reroll command.
    void RerollItem(Player* player, Item* item);

    // Clear stale PERM_ENCHANTMENT_SLOT from all bag+equipped items that have affix rows.
    // Called on login to eliminate leftovers from the pre-addon enchant-slot display system.
    void ClearLegacyEnchants(Player* player);

    // Mark/clear "pending reroll" mode: next ROLL message rerolls the item instead of rolling.
    void  SetPendingReroll(uint64 playerGuid);
    bool  IsPendingReroll(uint64 playerGuid) const;
    void  ClearPendingReroll(uint64 playerGuid);

private:
    // Roll N distinct affix IDs for a pending slot; sets row to PENDING and sends OPTS.
    void HandleRollRequest(Player* player, Item* item, uint8 affixSlot,
                           uint8 type = 0, int8 spec = -1, uint8 role = 0, uint8 mainStat = 0);

    // Apply a chosen option from a PENDING slot; sets row to APPLIED.
    void HandlePickOption(Player* player, Item* item, uint8 affixSlot, uint8 optIdx);

    uint32 RollAffixId(uint32 itemQuality, Player* player, Item* item,
                       bool genericsOnly = false, uint8 classBoost = 0,
                       bool classOnly = false,
                       uint8 preferredRole = 0, uint8 preferredMainStat = 0,
                       int8 spec = -1);
    float GetQualityFraction(uint32 quality) const;
    std::vector<AffixSlotInfo>  LoadAffixSlots(uint64 itemGuid);
    std::vector<ItemAffixRecord> LoadItemAffixes(uint64 itemGuid);
    void PersistAffix(uint64 itemGuid, uint8 slot, uint32 affixId, int32 rolledValue);

    void SendAddonMsg(Player* player, std::string const& payload);
    std::string BuildAffixDisplayString(AffixDefinition const* def, int32 rolledValue);
    void SendRollOptions(Player* player, Item* item, uint8 affixSlot, std::vector<PendingOpt> const& opts);

    // Appends slot entries, talent affix lines, and imprint to msg for any read-only
    // affix query (PEEK / PEEKUNIT / PEEKAUCTION / PEEKUNITALL / TRADEGUID).
    // slots must already be loaded via LoadAffixSlots(rawGuid).
    void AppendAffixPayload(std::string& msg, uint64 rawGuid,
                            std::vector<AffixSlotInfo> const& slots);

    void LoadTalentAffixDefs();
    TalentAffixDef const* GetEligibleTalentAffix(Player* player, Item const* item, int8 specOverride = -1);

    std::unordered_map<uint32, AffixDefinition>  _defs;
    std::unordered_map<uint32, TalentAffixDef>   _talentDefs;
    std::vector<uint32> _pool;
    std::unordered_set<uint64> _pendingReroll;  // player GUIDs awaiting a reroll on next ROLL msg

    bool  _enableClassSkillAffixes  = true;  // when false, only stat affixes roll; type selector hidden
    bool  _enableTalentAffixes      = true;  // when false, talent affix rows never roll; spec selector hidden if class skills also off
    bool  _enableRoleSelection      = true;
    bool  _enableMainStatSelection  = true;
    uint8 _twoHanderBonusSlots      = 1;     // extra affix slots granted to 2H weapons (0 = no bonus)
    // WotLK item budget fractions — share of total item budget allocated to one affix roll
    float _budgetFractionGreen  = 0.18f;  // green quality  (1 affix)
    float _budgetFractionBlue   = 0.13f;  // blue quality   (2 affixes)
    float _budgetFractionPurple = 0.10f;  // purple quality (3 affixes)
    float  _budgetMinRoll        = 0.75f;  // minimum roll as fraction of max (variance floor)
    float  _statMultiplier       = 1.0f;   // global stat scaler (>1 = power fantasy, <1 = conservative)
    uint32 _imprintRollChance    = 30;     // % chance an Imprint option replaces the last roll option
    bool   _critRollEnabled      = true;   // whether crit rolls can fire at all
    uint32 _critRollChance       = 10;     // % chance each roll option lands a crit (0–100)
};

#define sItemAffixMgr ItemAffixMgr::instance()
