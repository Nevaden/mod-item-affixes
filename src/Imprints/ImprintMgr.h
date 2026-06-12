#pragma once

#include "Player.h"
#include "SpellInfo.h"
#include <string>
#include <unordered_map>
#include <vector>

// ---------------------------------------------------------------------------
// ImprintId — unique ID for each Imprint type. Add new entries here.
// ---------------------------------------------------------------------------
enum ImprintId : uint32
{
    IMPRINT_RIGHTEOUS_SANCTUARY  = 1,
    IMPRINT_EMPYREAN_ECHO        = 2,
    IMPRINT_FERAL_STAMPEDE       = 3,
    IMPRINT_FERAL_ALPHA          = 4,
    IMPRINT_CELESTIAL_RESONANCE  = 5,
    IMPRINT_VANISHING_BACKSTAB   = 6,
    IMPRINT_ETERNAL_ELEMENTAL    = 7,
};

// ---------------------------------------------------------------------------
// ImprintDef — one row from imprint_def (world DB)
// ---------------------------------------------------------------------------
struct ImprintDef
{
    uint32      id;
    std::string name;
    uint32      runeItemId;
    uint32      extractionsMax;
    uint32      classMask;      // 0 = any class; bit = (1 << (classId-1))
    int8        specTree;       // -1 = any spec; 0/1/2 = required dominant tree
};

// ---------------------------------------------------------------------------
// ImprintInstance — one row from item_imprint (characters DB), runtime cache
// ---------------------------------------------------------------------------
struct ImprintInstance
{
    uint32 imprintId;
    uint32 extractionsLeft;
};

// ---------------------------------------------------------------------------
// ImprintEffect — abstract base class for all Imprint behaviour.
// One concrete subclass per Imprint type, registered with ImprintMgr at startup.
// ---------------------------------------------------------------------------
class ImprintEffect
{
public:
    virtual ~ImprintEffect() = default;

    virtual uint32             ImprintId()  const = 0;
    virtual std::string const& Name()       const = 0;

    // Called when the item carrying this Imprint is equipped or unequipped.
    // Use these to add/remove SpellModifiers.
    virtual void OnEquip  (Player* player, uint64 itemGuid) {}
    virtual void OnUnequip(Player* player, uint64 itemGuid) {}

    // Called once per cast of the relevant spell, after all targets have been hit.
    virtual void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo) {}

    // If true, the cast time added by this Imprint interrupts on player movement.
    // Default false (melee abilities may be cast while moving).
    virtual bool RequiresStandingStill() const { return false; }

    // Returns {spellId, tooltipLine} pairs to append to the spell's tooltip.
    // Called by ImprintMgr::SendImprintDescriptions when syncing to the client.
    // Descriptions must not contain the '|' character (used as message delimiter).
    virtual std::vector<std::pair<uint32, std::string>> SpellTooltipOverrides() const { return {}; }
};

// ---------------------------------------------------------------------------
// ImprintMgr — singleton that owns definitions, instances, and effect routing
// ---------------------------------------------------------------------------
class ImprintMgr
{
public:
    static ImprintMgr* instance();

    // Called at world init.
    void LoadConfig();
    void LoadDefs();

    // Register a concrete effect handler.  Called once per handler at startup.
    void RegisterEffect(ImprintEffect* effect);

    // -----------------------------------------------------------------------
    // Runtime equip/unequip hooks — called from ItemAffixScripts.
    // -----------------------------------------------------------------------
    void OnItemEquipped  (Player* player, Item* item);
    void OnItemUnequipped(Player* player, Item* item);

    // Mirror of SyncAffixes for Imprints: removes mods for unequipped items,
    // adds mods for newly equipped items.  Call on every equip/unequip event.
    void SyncImprints(Player* player);

    // Called from the Divine Storm SpellScript (and future scripts) once per cast.
    void OnSpellAfterCast(Player* caster, SpellInfo const* spellInfo);

    // True if any equipped item on this player carries the given Imprint.
    bool HasImprintEquipped(Player* player, uint32 imprintId) const;

    // Send IMPRINT_DESC_CLEAR + IMPRINT_DESC messages for all active imprints.
    // Called from SyncImprints and OnPlayerLogin so the addon always has current overrides.
    void SendImprintDescriptions(Player* player);

    // -----------------------------------------------------------------------
    // Command support
    // -----------------------------------------------------------------------

    // True if this item is an imprint rune (its GetEntry() matches the def's runeItemId).
    bool IsRune(Item const* item) const;

    // Grant a pre-loaded Rune directly into the player's bags (GM/testing use).
    bool GrantRune(Player* player, uint32 imprintId);

    // Extract: remove Imprint from item, decrement extractions_left, grant Rune.
    // Returns false and sends the player an error if not possible.
    bool ExtractImprint(Player* player, Item* sourceItem);

    // Apply: consume a Rune from the player's bags and attach its Imprint to targetItem.
    // Returns false and sends an error if not possible.
    bool ApplyImprint(Player* player, Item* targetItem);

    // Direct apply: consume the given runeItem and attach its Imprint to targetItem.
    // Used by the right-click-rune → click-target flow.  Both items must already be resolved.
    bool ApplyImprintDirect(Player* player, Item* runeItem, Item* targetItem);

    // Roll integration: returns a random class/spec-eligible Imprint or nullptr.
    // Returns nullptr if the item already has an Imprint, class doesn't match, or no
    // eligible Imprint exists for the given spec (-1 = any, matches the roll UI selection).
    ImprintDef const* GetEligibleImprintForRoll(Player* player, Item const* item, int8 spec);

    // Roll integration: applies imprintId to item directly (no rune consumed).
    // Called when the player picks the Imprint roll option.
    bool ApplyImprintFromRoll(Player* player, Item* item, uint32 imprintId);

    // Disenchant integration: called after a disenchant completes for itemGuid.
    // Grants the Imprint rune (decrementing extractions) and cleans up the DB row.
    // Returns true if a rune was granted.
    bool OnItemDisenchanted(Player* player, uint64 itemGuid);

    // -----------------------------------------------------------------------
    // Accessors
    // -----------------------------------------------------------------------
    ImprintDef const*      GetDef     (uint32 imprintId) const;
    // GetInstance: checks cache first, then lazy-loads from characters DB.
    ImprintInstance const* GetInstance(uint64 itemGuid);
    uint32                 ExtractionCount() const { return _extractionCount; }

    // Save SpellModifiers owned by an Imprint effect so they can be cleaned up.
    void TrackImprintMod(Player* player, uint64 itemGuid, SpellModifier* mod);
    void RemoveImprintMods(Player* player, uint64 itemGuid);

private:
    ImprintMgr() = default;

    // Persist a new instance row (INSERT) or update extractions_left (UPDATE).
    void SaveInstance(uint64 itemGuid, uint32 imprintId, uint32 extractionsLeft);
    void DeleteInstance(uint64 itemGuid);

    // Find the first Rune item in the player's bags by checking GetInstance on every item.
    // Returns {bag, slot} and imprint_id via out-param; {0xFF, 0xFF} if none found.
    std::pair<uint8,uint8> FindRuneInBags(Player* player, uint32& outImprintId);

    uint32 _extractionCount = 2;   // ItemAffixes.ImprintExtractionCount

    std::unordered_map<uint32, ImprintDef>      _defs;      // imprintId -> def
    std::unordered_map<uint32, ImprintEffect*>  _effects;   // imprintId -> handler (not owned)
    std::unordered_map<uint64, ImprintInstance> _instances; // itemGuid  -> instance (cache)
};

#define sImprintMgr ImprintMgr::instance()
