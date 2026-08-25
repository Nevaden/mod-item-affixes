#pragma once

#include "Common.h"
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// ProgressionCategory — which /prog tab a node belongs to.
// ---------------------------------------------------------------------------
enum class ProgressionCategory : uint8
{
    PROG_CAT_AFFIXES = 0,
    PROG_CAT_PLAYER  = 1,
    PROG_CAT_MISC    = 2,
};

// ---------------------------------------------------------------------------
// ProgressionNodeId — stable ids persisted in character_progression_nodes.node_id.
// NEVER renumber or reuse an id once shipped; retire a node by leaving its id
// unused rather than reassigning it. Gaps between ranges are intentional room
// for future nodes within a category without renumbering anything.
// ---------------------------------------------------------------------------
enum ProgressionNodeId : uint16
{
    NODE_REROLL_TIER          = 1,
    NODE_OPTIONS_TIER         = 2,
    NODE_SLOT                 = 3,
    NODE_CRIT_ROLL_CHANCE     = 4,
    NODE_UNLOCK_CLASS_AFFIXES = 5,
    NODE_META_XP_PCT          = 6,  // % bonus to meta-progression XP itself (trickle + per-affix)

    NODE_STAMINA      = 10,
    NODE_STRENGTH     = 11,
    NODE_AGILITY      = 12,
    NODE_INTELLECT    = 13,
    NODE_SPIRIT       = 14,
    NODE_ATTACK_POWER = 15,  // applies to both melee and ranged AP
    NODE_SPELL_POWER  = 16,
    NODE_CRIT_RATING  = 17,
    NODE_HASTE_RATING = 18,
    NODE_MP5          = 19,

    NODE_MOVE_SPEED           = 20,
    NODE_ARMOR                = 21,
    NODE_DAMAGE_REDUCTION_PCT = 22,
    // 23 (Flat HP) retired — overlapped almost entirely with Stamina, which
    // already converts to HP natively. Never reuse this id.
    NODE_CHARACTER_XP_PCT     = 24,  // % bonus to the character's own kill/quest/explore/BG XP
    // 25 (Heal Ability / "Emergency Mend") retired — built, but the taught spell never
    // rendered in the client spellbook despite an extensive debugging pass (mechanism
    // itself proven working via a First Aid test). See "Retired: Heal Ability" in
    // docs/PLAYER_PROGRESSION_PLAN.md's backlog for the full writeup before trying again.
    // Never reuse this id.

    // Bespoke — read directly via GetNodeBonus, not applied through
    // ApplyProgressionStats (no flat/pct/teach channel; see PlayerProgressionBossDrops.cpp).
    NODE_BOSS_DROPS = 26,  // +N extra item rolls (summed across the group) from a boss's own loot table per kill
};

// ---------------------------------------------------------------------------
// ProgressionNodeDef — one node's shape. maxRank/valuePerRank are config-driven
// (populated by PlayerProgressionMgr::LoadConfig, see PlayerProgression.cpp);
// everything else here is fixed at compile time.
// ---------------------------------------------------------------------------
struct ProgressionNodeDef
{
    uint16              id;
    std::string         configName;    // e.g. "Stamina" -> ItemAffixes.ProgressionStaminaMaxRank
    ProgressionCategory category;
    uint8               unlockTier = 0;   // 0 = always available (Tier 1)
    uint8               maxRank    = 1;    // config-driven default
    float               valuePerRank = 0.0f; // config-driven; flat bonus = rank * valuePerRank
    int16               statOp     = -1;     // GenericStatOp for stat-reuse nodes; -1 = bespoke logic

    // Optional % component, granted as (one or more) real spell auras rather than a
    // flat stat modifier — necessary because there's no direct C++ API for percentage
    // stat/rating modifiers, only the aura system exposes them. Most nodes need exactly
    // one spell; Crit/Haste need several (melee+spell crit; melee+ranged+cast haste) since
    // CastCustomSpell can't fan one spell out to multiple aura types. Empty = no % component.
    std::vector<uint32> pctSpellIds;             // custom spell ids (see imprints/custom_spells.json)
    float               valuePerRankPct = 0.0f;   // config-driven; % bonus = rank * valuePerRankPct, same magnitude sent to every id in pctSpellIds

    // Optional: this node teaches a real, player-visible spell (spellbook entry, own
    // cast bar/cooldown) rather than a hidden stat/aura — e.g. Emergency Mend. Distinct
    // channel from pctSpellIds because teach/untaught uses Player::learnSpell/removeSpell,
    // not CastCustomSpell/RemoveAurasDueToSpell. 0 = this node doesn't teach anything.
    uint32              teachSpellId = 0;
};
