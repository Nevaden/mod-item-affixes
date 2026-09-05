#pragma once

#include "Player.h"
#include "PlayerProgressionNodes.h"
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

// ---------------------------------------------------------------------------
// AccountProgressionState — one account's meta-XP, mirroring a row in
// account_meta_progression (acore_auth). Runtime cache, keyed by account id,
// populated on login and dropped on logout. XP is earned account-wide by any
// character on the account.
// ---------------------------------------------------------------------------
struct AccountProgressionState
{
    uint64 xp = 0;  // lifetime meta-XP earned (trickle + per-affix); never decreases
};

// ---------------------------------------------------------------------------
// ActiveProgressionMod — one currently-applied permanent stat bonus, mirroring
// ItemAffix.h's ActiveStatMod. Tracked per character so removal always undoes
// exactly what was applied, never a recomputed guess.
// ---------------------------------------------------------------------------
struct ActiveProgressionMod
{
    uint8 statOp;
    int32 value;
};

// ---------------------------------------------------------------------------
// PlayerProgressionMgr — singleton owning the account-wide XP pool and the
// generic per-character node/rank state for the Player Progression system.
// ---------------------------------------------------------------------------
class PlayerProgressionMgr
{
public:
    static PlayerProgressionMgr* instance();

    // Called at world init. Populates the node registry (maxRank/valuePerRank
    // per node, all config-driven — see PlayerProgression.cpp for the blueprint list).
    void LoadConfig();

    // -----------------------------------------------------------------------
    // Runtime hooks — called from ItemAffixScripts.
    // -----------------------------------------------------------------------
    void OnPlayerLogin(Player* player);
    void OnPlayerLogout(Player* player);

    // Skims ItemAffixes.ProgressionTricklePct of characterXpAmount into the
    // account's meta-XP pool (after ApplyCharacterXpBonus below has already run,
    // so trickle is a % of the boosted amount — the character-XP boost and the
    // trickle skim compose naturally). Does not modify characterXpAmount.
    // Defaults to 0 (disabled) — meta-XP is meant to come from affix-system
    // actions (rolling/rerolling items), not passive character leveling; raise
    // this only if you deliberately want a passive trickle on top of that.
    void GrantTrickleXP(Player* player, uint32 characterXpAmount);

    // Grants per-quality meta-XP for a slot that just committed PENDING -> APPLIED
    // (manual roll pick, D3 auto-roll), or for a paid Reforge reroll.
    void GrantAffixXP(Player* player, uint32 itemQuality);

    // Applies the Character XP % node to a character's own kill/quest/explore/BG
    // XP gain. Called from OnPlayerGiveXP BEFORE GrantTrickleXP, so the trickle
    // skim sees the boosted amount too. Mutates amount in place.
    void ApplyCharacterXpBonus(Player* player, uint32& amount);

    // Spell Power's % component has no native "% of current spell power" aura
    // (unlike every other stat) — see ApplySpellPowerDynamicBonus's own comment
    // in PlayerProgression.cpp for why. Recomputed from gear/gem/enchant spell
    // power only (Player::GetBaseSpellPowerBonus never includes buffs), so a
    // player can't game it via buff stacking. Called from ItemAffixScripts'
    // OnPlayerEquip/OnPlayerUnequip — gear change is the only trigger, by design.
    void RecomputeSpellPowerBonus(Player* player);

    // -----------------------------------------------------------------------
    // Node accessors — used by ItemAffixMgr (roll generation, slot count,
    // crit roll chance, class-affix gating) to read this character's investment.
    // Both return 0 if the node/character is unknown.
    // -----------------------------------------------------------------------
    uint8 GetNodeRank(uint64 guid, uint16 nodeId) const;
    // bonus = rank * valuePerRank. Callers cast/interpret per node (int count,
    // float percent, etc.) — see call sites in ItemAffix.cpp.
    float GetNodeBonus(uint64 guid, uint16 nodeId) const;

    // -----------------------------------------------------------------------
    // Addon message protocol entry point. Called from
    // ItemAffixMgr::HandleAddonMessage when parts[0] == "PROG".
    // parts[1] is the sub-command: QUERY | INVEST | RESPEC.
    // INVEST takes a numeric node id (parts[2]), not a string literal.
    // -----------------------------------------------------------------------
    void HandleAddonMessage(Player* player, std::vector<std::string_view> const& parts);

    // -----------------------------------------------------------------------
    // GM/support helpers — used by ItemAffixCommands (.affix progression).
    // -----------------------------------------------------------------------
    AccountProgressionState GetAccountState(uint32 accountId);                 // loads if not cached
    std::unordered_map<uint16, uint8> GetCharacterNodeRanks(uint64 guid);       // loads if not cached
    void GrantXp(Player* player, uint64 amount);                               // raw XP grant, GM/testing only
    void ForceReset(Player* player);                                          // resets every node for THIS character, no gold cost

private:
    PlayerProgressionMgr() = default;

    AccountProgressionState& GetOrLoadAccount(uint32 accountId);
    void SaveAccountState(uint32 accountId, AccountProgressionState const& state);

    // guid -> (node id -> rank). Loads every invested row for a character at once.
    // A node with no row is implicitly rank 0 — no need to pre-create rows.
    std::unordered_map<uint16, uint8>& GetOrLoadCharacterNodes(uint64 guid);
    void SaveNodeRank(uint64 guid, uint16 nodeId, uint8 rank);

    uint32 XpToPoints(uint64 xp) const;
    uint32 RespecCostCopper(uint8 level) const;
    uint32 TotalRanksSpent(uint64 guid) const;             // sum of every node's rank for this character
    uint8  CurrentUnlockedTier(uint32 totalRanksSpent) const; // which unlock-Tier group is currently open

    void SendProgState(Player* player);

    // -----------------------------------------------------------------------
    // Permanent stat application. ALWAYS call as a matched pair (Remove then
    // Apply) on any state change — never Apply without an immediately-preceding
    // Remove. Both guard defensively against being called while already applied.
    //
    // Three channels per node, independent of each other:
    //  - Flat: statOp nodes go through ItemAffixMgr::ApplyPlayerStat, tracked in
    //    _activeMods (mirrors ItemAffix.h's ActiveStatMod pattern).
    //  - %: any node with a pctSpellId grants a real spell aura via
    //    CastCustomSpell/RemoveAurasDueToSpell, tracked in _activePctSpells.
    //    Never a raw setter (e.g. SetSpeed) — the engine's own recalculation
    //    silently overwrites those. Move Speed is a pure-% bespoke node (no
    //    statOp) that goes through this same channel.
    //  - Taught spell: a node with a teachSpellId grants a real, player-visible
    //    spellbook entry via Player::learnSpell/removeSpell (not an aura),
    //    tracked in _activeTaughtSpells. No node currently uses this channel.
    //  - Dynamic recompute (Spell Power only): no native aura multiplies existing
    //    spell power, so the % component is a flat Player::ApplySpellPowerBonus
    //    amount recomputed from Player::GetBaseSpellPowerBonus() (gear/gems/
    //    enchants only) rather than granted via a static aura. Tracked in
    //    _activeSpellPowerPctBonus. ApplyProgressionStats computes it fresh
    //    AFTER the main per-node loop below (so this node's own flat component
    //    is already applied and counted); RemoveProgressionStats strips it like
    //    every other channel; RecomputeSpellPowerBonus (public, called on
    //    equip/unequip) does its own strip-then-recompute independently of a
    //    full Remove/Apply cycle — see ApplySpellPowerDynamicBonus in the .cpp.
    // -----------------------------------------------------------------------
    void ApplyProgressionStats(Player* player);
    void RemoveProgressionStats(Player* player);
    void ApplySpellPowerDynamicBonus(Player* player); // assumes no dynamic bonus is currently applied

    bool   _enabled               = true;
    uint32 _tricklePct            = 0;
    uint32 _xpGreen                = 10;
    uint32 _xpBlue                 = 30;
    uint32 _xpPurple                 = 60;
    uint32 _xpLegendary               = 200;
    uint32 _xpPerPoint               = 500;
    uint32 _respecBaseCopper          = 10000;
    uint32 _respecPerLevelCopper       = 500;
    // Cumulative total ranks spent (across every node) required to unlock each
    // Tier past the first. _tierThresholds[0] = requirement for Tier 2, etc.
    // Empty in this pass — no Tier 2+ nodes exist yet; scaffolding for later.
    std::vector<uint32> _tierThresholds;

    std::unordered_map<uint16, ProgressionNodeDef> _nodeDefs; // node id -> def

    std::unordered_map<uint32, AccountProgressionState>           _accountCache;    // accountId -> xp state
    std::unordered_map<uint64, std::unordered_map<uint16, uint8>> _characterCache;  // guid -> (node id -> rank)
    std::unordered_map<uint64, std::vector<ActiveProgressionMod>> _activeMods;      // guid -> currently-applied flat stat mods
    std::unordered_map<uint64, std::vector<uint32>>                _activePctSpells; // guid -> currently-applied % aura spell ids
    std::unordered_map<uint64, std::vector<uint32>>                _activeTaughtSpells; // guid -> currently-taught spell ids
    std::unordered_map<uint64, int32>                               _activeSpellPowerPctBonus; // guid -> currently-applied dynamic SP bonus (0/absent = none)
};

#define sPlayerProgressionMgr PlayerProgressionMgr::instance()
