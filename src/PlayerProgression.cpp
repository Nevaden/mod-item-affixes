#include "PlayerProgression.h"
#include "Config.h"
#include "DatabaseEnv.h"
#include "ItemAffix.h"
#include "ItemTemplate.h"
#include "Log.h"
#include "Opcodes.h"
#include "SpellMgr.h"
#include "StringConvert.h"
#include "StringFormat.h"
#include "WorldPacket.h"
#include "WorldSession.h"
#include <cmath>

// Custom spell (see imprints/custom_spells.json, patched into Spell.dbc by
// tools/patch_custom_spells.ps1) carrying a single SPELL_AURA_MOD_SPEED_ALWAYS
// effect. Applied via CastCustomSpell with the total percent as an override —
// this is a real, engine-tracked aura, not a raw SetSpeed() call, since raw
// SetSpeed is silently overwritten by Unit::UpdateSpeed() on any aura/mount/
// dismount recalculation. Routing through a real aura means the engine's own
// UpdateSpeed() includes it in every recalculation automatically and composes
// it correctly with mounts, sprint, and any other speed source, the same way
// it already does for real game content.
static constexpr uint32 SPELL_PROGRESSION_MOVE_SPEED = 699100;

// Percent-component custom spells (see imprints/custom_spells.json) for the
// stat nodes in this pass — same "real aura, not a raw setter" reasoning as
// Move Speed above, since there's no direct C++ API for percentage stat
// modifiers, only the aura system exposes them (SPELL_AURA_MOD_PERCENT_STAT,
// SPELL_AURA_MOD_ATTACK_POWER_PCT, SPELL_AURA_MOD_RESISTANCE_PCT).
static constexpr uint32 SPELL_PROGRESSION_STAMINA_PCT      = 699101;
static constexpr uint32 SPELL_PROGRESSION_STRENGTH_PCT     = 699102;
static constexpr uint32 SPELL_PROGRESSION_AGILITY_PCT      = 699103;
static constexpr uint32 SPELL_PROGRESSION_INTELLECT_PCT    = 699104;
static constexpr uint32 SPELL_PROGRESSION_SPIRIT_PCT       = 699105;
static constexpr uint32 SPELL_PROGRESSION_ATTACK_POWER_PCT = 699106; // SPELL_AURA_MOD_ATTACK_POWER_PCT — melee only
static constexpr uint32 SPELL_PROGRESSION_ARMOR_PCT        = 699107;

// Crit/Haste use DIRECT % chance/speed auras, not "% of rating" (no such aura
// exists) — verified via SpellAuraEffects.cpp before use, same as everything
// above. Each needs multiple spells since CastCustomSpell can't fan one spell
// out to several aura types: melee+spell crit, melee+ranged+casting haste.
static constexpr uint32 SPELL_PROGRESSION_CRIT_MELEE_PCT  = 699108;  // SPELL_AURA_MOD_WEAPON_CRIT_PERCENT
static constexpr uint32 SPELL_PROGRESSION_CRIT_SPELL_PCT  = 699109;  // SPELL_AURA_MOD_SPELL_CRIT_CHANCE
static constexpr uint32 SPELL_PROGRESSION_HASTE_MELEE_PCT  = 699110; // SPELL_AURA_MOD_MELEE_HASTE
static constexpr uint32 SPELL_PROGRESSION_HASTE_RANGED_PCT = 699111; // SPELL_AURA_MOD_RANGED_HASTE
static constexpr uint32 SPELL_PROGRESSION_HASTE_CAST_PCT   = 699112; // SPELL_AURA_HASTE_SPELLS

// Attack Power's % component needs a second spell for the same reason as Crit/Haste
// above: SPELL_AURA_MOD_ATTACK_POWER_PCT (melee) and SPELL_AURA_MOD_RANGED_ATTACK_POWER_PCT
// (ranged) are independent auras touching different UnitMods (UNIT_MOD_ATTACK_POWER vs
// UNIT_MOD_ATTACK_POWER_RANGED) — confirmed via SpellAuraEffects.cpp. Missed on the initial
// v3 pass since the flat component's explicit dual ApplyPlayerStat call (melee + GSTAT_RANGED_AP)
// made it easy to assume the % component composed the same way; it doesn't, auras don't share.
static constexpr uint32 SPELL_PROGRESSION_RANGED_AP_PCT    = 699113; // SPELL_AURA_MOD_RANGED_ATTACK_POWER_PCT


PlayerProgressionMgr* PlayerProgressionMgr::instance()
{
    static PlayerProgressionMgr inst;
    return &inst;
}

// Shared addon message transport (mirrors ItemAffixMgr::SendAddonMsg / ImprintMgr's copy).
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

// ---------------------------------------------------------------------------
// Node registry
// ---------------------------------------------------------------------------

namespace
{
    struct NodeBlueprint
    {
        uint16               id;
        char const*          configName;
        ProgressionCategory  category;
        uint8                unlockTier;
        int16                statOp;             // GenericStatOp, or -1 for bespoke logic
        uint8                defaultMaxRank;
        float                defaultValuePerRank;
        std::vector<uint32>  pctSpellIds;            // empty = no % component
        float                defaultValuePerRankPct = 0.0f;
        uint32               teachSpellId = 0;       // non-zero = grant via learnSpell/removeSpell, not an aura
    };

    // Tier 1 node set. Adding a future node is a new row here (plus, for stat-reuse
    // nodes, nothing else) — not a schema change and not a new hardcoded field.
    NodeBlueprint const kNodeBlueprints[] =
    {
        { NODE_REROLL_TIER,          "RerollTier",         ProgressionCategory::PROG_CAT_AFFIXES, 0, -1,                                 3, 1.0f },
        { NODE_OPTIONS_TIER,         "OptionsTier",        ProgressionCategory::PROG_CAT_AFFIXES, 0, -1,                                 3, 1.0f },
        { NODE_SLOT,                 "Slot",               ProgressionCategory::PROG_CAT_AFFIXES, 0, -1,                                 1, 1.0f },
        { NODE_CRIT_ROLL_CHANCE,     "CritRollChance",     ProgressionCategory::PROG_CAT_AFFIXES, 0, -1,                                 5, 2.0f },
        { NODE_UNLOCK_CLASS_AFFIXES, "UnlockClassAffixes", ProgressionCategory::PROG_CAT_AFFIXES, 0, -1,                                 1, 1.0f },
        { NODE_META_XP_PCT,          "MetaXpPct",          ProgressionCategory::PROG_CAT_AFFIXES, 0, -1,                                 5, 10.0f },

        { NODE_STAMINA,      "Stamina",      ProgressionCategory::PROG_CAT_PLAYER, 0, int16(GSTAT_STAMINA),      5, 5.0f, { SPELL_PROGRESSION_STAMINA_PCT },      2.0f },
        { NODE_STRENGTH,     "Strength",     ProgressionCategory::PROG_CAT_PLAYER, 0, int16(GSTAT_STRENGTH),     5, 3.0f, { SPELL_PROGRESSION_STRENGTH_PCT },     2.0f },
        { NODE_AGILITY,      "Agility",      ProgressionCategory::PROG_CAT_PLAYER, 0, int16(GSTAT_AGILITY),      5, 3.0f, { SPELL_PROGRESSION_AGILITY_PCT },      2.0f },
        { NODE_INTELLECT,    "Intellect",    ProgressionCategory::PROG_CAT_PLAYER, 0, int16(GSTAT_INTELLECT),    5, 3.0f, { SPELL_PROGRESSION_INTELLECT_PCT },    2.0f },
        { NODE_SPIRIT,       "Spirit",       ProgressionCategory::PROG_CAT_PLAYER, 0, int16(GSTAT_SPIRIT),       5, 3.0f, { SPELL_PROGRESSION_SPIRIT_PCT },       2.0f },
        { NODE_ATTACK_POWER, "AttackPower",  ProgressionCategory::PROG_CAT_PLAYER, 0, int16(GSTAT_ATTACK_POWER), 5, 6.0f, { SPELL_PROGRESSION_ATTACK_POWER_PCT, SPELL_PROGRESSION_RANGED_AP_PCT }, 2.0f },
        // % component is NOT the generic aura channel (pctSpellIds stays empty) — there is
        // no native aura that multiplies existing spell power, unlike every other stat. See
        // ApplySpellPowerDynamicBonus: recomputed on equip/unequip from Player::GetBaseSpell
        // PowerBonus() (gear + gems/enchants/ScalingStatValue only, buffs never included).
        { NODE_SPELL_POWER,  "SpellPower",   ProgressionCategory::PROG_CAT_PLAYER, 0, int16(GSTAT_SPELL_POWER),  5, 4.0f, {}, 2.0f },
        { NODE_CRIT_RATING,  "CritRating",   ProgressionCategory::PROG_CAT_PLAYER, 0, int16(GSTAT_CRIT_RATING),  5, 3.0f, { SPELL_PROGRESSION_CRIT_MELEE_PCT, SPELL_PROGRESSION_CRIT_SPELL_PCT }, 1.0f },
        { NODE_HASTE_RATING, "HasteRating",  ProgressionCategory::PROG_CAT_PLAYER, 0, int16(GSTAT_HASTE_RATING), 5, 3.0f, { SPELL_PROGRESSION_HASTE_MELEE_PCT, SPELL_PROGRESSION_HASTE_RANGED_PCT, SPELL_PROGRESSION_HASTE_CAST_PCT }, 1.0f },
        { NODE_MP5,          "Mp5",          ProgressionCategory::PROG_CAT_PLAYER, 0, int16(GSTAT_MP5),          5, 4.0f },  // flat-only — same as Spell Power, no clean % mechanism sought yet

        { NODE_MOVE_SPEED,           "MoveSpeed",           ProgressionCategory::PROG_CAT_MISC, 0, -1,                                5, 10.0f },
        { NODE_ARMOR,                "Armor",               ProgressionCategory::PROG_CAT_MISC, 0, int16(GSTAT_ARMOR),                5, 10.0f, { SPELL_PROGRESSION_ARMOR_PCT }, 2.0f },
        { NODE_DAMAGE_REDUCTION_PCT, "DamageReductionPct",  ProgressionCategory::PROG_CAT_MISC, 0, int16(GSTAT_DAMAGE_REDUCTION_PCT), 3, 1.0f },
        { NODE_CHARACTER_XP_PCT,     "CharacterXpPct",      ProgressionCategory::PROG_CAT_MISC, 0, -1,                                5, 5.0f },
        { NODE_BOSS_DROPS,           "BossDrops",           ProgressionCategory::PROG_CAT_MISC, 0, -1,                                2, 1.0f },
        // valuePerRank is percent (4%/rank); 5 ranks = 20% lifesteal max, matching
        // the live server's tuned Leech.Amount=0.20 (mod-leech itself removed in
        // favor of this node) — see PlayerProgressionLifesteal.cpp.
        { NODE_LIFESTEAL,            "Lifesteal",           ProgressionCategory::PROG_CAT_MISC, 0, -1,                                5, 4.0f },
    };
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

void PlayerProgressionMgr::LoadConfig()
{
    _enabled              = sConfigMgr->GetOption<bool>("ItemAffixes.ProgressionEnabled", true);
    _tricklePct           = sConfigMgr->GetOption<uint32>("ItemAffixes.ProgressionTricklePct", 2);
    _xpGreen              = sConfigMgr->GetOption<uint32>("ItemAffixes.ProgressionXpGreen", 1);
    _xpBlue               = sConfigMgr->GetOption<uint32>("ItemAffixes.ProgressionXpBlue", 10);
    _xpPurple             = sConfigMgr->GetOption<uint32>("ItemAffixes.ProgressionXpPurple", 25);
    _xpLegendary          = sConfigMgr->GetOption<uint32>("ItemAffixes.ProgressionXpLegendary", 50);
    _xpPerPoint           = sConfigMgr->GetOption<uint32>("ItemAffixes.ProgressionXpPerPoint", 500);
    _respecBaseCopper     = sConfigMgr->GetOption<uint32>("ItemAffixes.ProgressionRespecBaseCopper", 10000);
    _respecPerLevelCopper = sConfigMgr->GetOption<uint32>("ItemAffixes.ProgressionRespecPerLevelCopper", 500);

    // No Tier 2+ nodes exist yet (see PlayerProgressionNodes.h) — left empty on
    // purpose. When one ships, add its threshold here, e.g.:
    //   _tierThresholds.push_back(sConfigMgr->GetOption<uint32>("ItemAffixes.ProgressionTier2Threshold", 15));
    _tierThresholds.clear();

    _nodeDefs.clear();
    for (NodeBlueprint const& bp : kNodeBlueprints)
    {
        ProgressionNodeDef def;
        def.id         = bp.id;
        def.configName = bp.configName;
        def.category   = bp.category;
        def.unlockTier = bp.unlockTier;
        def.statOp     = bp.statOp;
        def.maxRank = sConfigMgr->GetOption<uint8>(
            "ItemAffixes.Progression" + def.configName + "MaxRank", bp.defaultMaxRank);
        def.valuePerRank = sConfigMgr->GetOption<float>(
            "ItemAffixes.Progression" + def.configName + "ValuePerRank", bp.defaultValuePerRank);

        def.pctSpellIds = bp.pctSpellIds;
        // Gate on "this node has a % component at all" (pctSpellIds non-empty, the aura
        // channel) OR a nonzero default (a node using valuePerRankPct outside that channel —
        // currently only Spell Power's dynamic-recompute bonus, see ApplySpellPowerDynamicBonus).
        if (!bp.pctSpellIds.empty() || bp.defaultValuePerRankPct > 0.0f)
        {
            def.valuePerRankPct = sConfigMgr->GetOption<float>(
                "ItemAffixes.Progression" + def.configName + "ValuePerRankPct", bp.defaultValuePerRankPct);
        }

        def.teachSpellId = bp.teachSpellId;

        _nodeDefs.emplace(def.id, def);
    }

    LOG_INFO("module",
        "mod-item-affixes: Player Progression enabled={} tricklePct={} xpPerPoint={} nodeCount={}",
        _enabled, _tricklePct, _xpPerPoint, _nodeDefs.size());
}

// ---------------------------------------------------------------------------
// Account XP cache (acore_auth.account_meta_progression)
// ---------------------------------------------------------------------------

AccountProgressionState& PlayerProgressionMgr::GetOrLoadAccount(uint32 accountId)
{
    auto it = _accountCache.find(accountId);
    if (it != _accountCache.end())
        return it->second;

    QueryResult result = LoginDatabase.Query(
        "SELECT xp FROM account_meta_progression WHERE account_id = {}", accountId);

    AccountProgressionState state;
    if (result)
    {
        state.xp = result->Fetch()[0].Get<uint64>();
    }
    else
    {
        LoginDatabase.Execute(
            "INSERT INTO account_meta_progression (account_id, xp) VALUES ({}, 0)", accountId);
    }

    auto emplaced = _accountCache.emplace(accountId, state);
    return emplaced.first->second;
}

void PlayerProgressionMgr::SaveAccountState(uint32 accountId, AccountProgressionState const& state)
{
    LoginDatabase.Execute(
        "UPDATE account_meta_progression SET xp = {} WHERE account_id = {}", state.xp, accountId);
}

// ---------------------------------------------------------------------------
// Character node/rank cache (acore_characters.character_progression_nodes)
// ---------------------------------------------------------------------------

std::unordered_map<uint16, uint8>& PlayerProgressionMgr::GetOrLoadCharacterNodes(uint64 guid)
{
    auto it = _characterCache.find(guid);
    if (it != _characterCache.end())
        return it->second;

    std::unordered_map<uint16, uint8> nodes;
    QueryResult result = CharacterDatabase.Query(
        "SELECT node_id, `rank` FROM character_progression_nodes WHERE guid = {}", guid);
    if (result)
    {
        do
        {
            Field* f = result->Fetch();
            nodes[f[0].Get<uint16>()] = f[1].Get<uint8>();
        } while (result->NextRow());
    }

    auto emplaced = _characterCache.emplace(guid, std::move(nodes));
    return emplaced.first->second;
}

void PlayerProgressionMgr::SaveNodeRank(uint64 guid, uint16 nodeId, uint8 rank)
{
    CharacterDatabase.Execute(
        "REPLACE INTO character_progression_nodes (guid, node_id, `rank`) VALUES ({}, {}, {})",
        guid, nodeId, rank);
}

uint32 PlayerProgressionMgr::XpToPoints(uint64 xp) const
{
    if (_xpPerPoint == 0)
        return 0;
    return uint32(xp / _xpPerPoint);
}

uint32 PlayerProgressionMgr::RespecCostCopper(uint8 level) const
{
    return _respecBaseCopper + _respecPerLevelCopper * uint32(level);
}

uint32 PlayerProgressionMgr::TotalRanksSpent(uint64 guid) const
{
    auto it = _characterCache.find(guid);
    if (it == _characterCache.end())
        return 0;

    uint32 total = 0;
    for (auto const& [nodeId, rank] : it->second)
        total += rank;
    return total;
}

uint8 PlayerProgressionMgr::CurrentUnlockedTier(uint32 totalRanksSpent) const
{
    uint8 tier = 1;
    for (size_t i = 0; i < _tierThresholds.size(); ++i)
        if (totalRanksSpent >= _tierThresholds[i])
            tier = uint8(i + 2);  // _tierThresholds[0] gates Tier 2, [1] gates Tier 3, ...
    return tier;
}

// ---------------------------------------------------------------------------
// Runtime hooks
// ---------------------------------------------------------------------------

void PlayerProgressionMgr::OnPlayerLogin(Player* player)
{
    if (!_enabled || !player || !player->GetSession())
        return;

    GetOrLoadAccount(player->GetSession()->GetAccountId());
    GetOrLoadCharacterNodes(player->GetGUID().GetRawValue());
    ApplyProgressionStats(player);
    SendProgState(player);
}

void PlayerProgressionMgr::OnPlayerLogout(Player* player)
{
    if (!player || !player->GetSession())
        return;

    RemoveProgressionStats(player);
    _accountCache.erase(player->GetSession()->GetAccountId());
    _characterCache.erase(player->GetGUID().GetRawValue());
}

void PlayerProgressionMgr::GrantTrickleXP(Player* player, uint32 characterXpAmount)
{
    if (!_enabled || !player || !player->GetSession() || characterXpAmount == 0)
        return;

    uint64 gained = (uint64(characterXpAmount) * _tricklePct) / 100;
    if (gained == 0)
        return;

    uint64 guid = player->GetGUID().GetRawValue();
    float metaXpBonusPct = GetNodeBonus(guid, NODE_META_XP_PCT);
    gained = uint64(float(gained) * (1.0f + metaXpBonusPct / 100.0f));

    uint32 accountId = player->GetSession()->GetAccountId();
    AccountProgressionState& state = GetOrLoadAccount(accountId);
    state.xp += gained;
    SaveAccountState(accountId, state);
}

void PlayerProgressionMgr::GrantAffixXP(Player* player, uint32 itemQuality)
{
    if (!_enabled || !player || !player->GetSession())
        return;

    uint32 xpAmount;
    if      (itemQuality >= ITEM_QUALITY_LEGENDARY) xpAmount = _xpLegendary;
    else if (itemQuality >= ITEM_QUALITY_EPIC)      xpAmount = _xpPurple;
    else if (itemQuality == ITEM_QUALITY_RARE)      xpAmount = _xpBlue;
    else                                             xpAmount = _xpGreen;

    uint64 guid = player->GetGUID().GetRawValue();
    float metaXpBonusPct = GetNodeBonus(guid, NODE_META_XP_PCT);
    uint64 gained = uint64(float(xpAmount) * (1.0f + metaXpBonusPct / 100.0f));

    uint32 accountId = player->GetSession()->GetAccountId();
    AccountProgressionState& state = GetOrLoadAccount(accountId);
    state.xp += gained;
    SaveAccountState(accountId, state);

    SendProgState(player);
}

void PlayerProgressionMgr::ApplyCharacterXpBonus(Player* player, uint32& amount)
{
    if (!_enabled || !player || !player->GetSession() || amount == 0)
        return;

    float bonusPct = GetNodeBonus(player->GetGUID().GetRawValue(), NODE_CHARACTER_XP_PCT);
    if (bonusPct <= 0.0f)
        return;

    amount = uint32(float(amount) * (1.0f + bonusPct / 100.0f));
}

// ---------------------------------------------------------------------------
// Node accessors
// ---------------------------------------------------------------------------

uint8 PlayerProgressionMgr::GetNodeRank(uint64 guid, uint16 nodeId) const
{
    auto charIt = _characterCache.find(guid);
    if (charIt == _characterCache.end())
        return 0;
    auto nodeIt = charIt->second.find(nodeId);
    return nodeIt != charIt->second.end() ? nodeIt->second : 0;
}

float PlayerProgressionMgr::GetNodeBonus(uint64 guid, uint16 nodeId) const
{
    uint8 rank = GetNodeRank(guid, nodeId);
    if (rank == 0)
        return 0.0f;

    auto defIt = _nodeDefs.find(nodeId);
    if (defIt == _nodeDefs.end())
        return 0.0f;

    return float(rank) * defIt->second.valuePerRank;
}

// ---------------------------------------------------------------------------
// Permanent stat application. Always call as a matched Remove-then-Apply
// pair on any state change; both guard against being called while already applied.
// ---------------------------------------------------------------------------

// Grants one node's % component as a real spell aura. Never a raw setter (e.g.
// SetSpeed) — see the header comment on ApplyProgressionStats for why. Logs
// diagnostics since a missing spell (DBC not patched/server not restarted since)
// is the single most common failure mode here, per the Move Speed incident.
static bool CastProgressionPercentAura(Player* player, uint32 spellId, int32 magnitude)
{
    if (!sSpellMgr->GetSpellInfo(spellId))
    {
        LOG_ERROR("module",
            "mod-item-affixes: progression % spell {} not found in SpellMgr — "
            "did you run tools/patch_custom_spells.ps1 and restart the worldserver since?",
            spellId);
        return false;
    }

    int32 bp0 = magnitude;
    SpellCastResult result = player->CastCustomSpell(player, spellId, &bp0, nullptr, nullptr, true);
    if (result != SPELL_CAST_OK)
    {
        LOG_ERROR("module",
            "mod-item-affixes: progression % spell {} cast failed, result={}", spellId, uint32(result));
        return false;
    }
    return true;
}

void PlayerProgressionMgr::ApplyProgressionStats(Player* player)
{
    if (!player)
        return;

    uint64 guid = player->GetGUID().GetRawValue();
    if (_activeMods.find(guid) != _activeMods.end() || _activePctSpells.find(guid) != _activePctSpells.end()
        || _activeTaughtSpells.find(guid) != _activeTaughtSpells.end()
        || _activeSpellPowerPctBonus.find(guid) != _activeSpellPowerPctBonus.end())
    {
        LOG_ERROR("module", "mod-item-affixes: ApplyProgressionStats called while already applied for guid {}", guid);
        return;
    }

    std::vector<ActiveProgressionMod> appliedFlat;
    std::vector<uint32> appliedPctSpells;
    std::vector<uint32> appliedTaughtSpells;

    for (auto const& [nodeId, def] : _nodeDefs)
    {
        uint8 rank = GetNodeRank(guid, nodeId);
        if (rank == 0)
            continue;

        if (nodeId == NODE_MOVE_SPEED)
        {
            // Pure-% bespoke node — valuePerRank IS the percent, no separate flat channel.
            int32 pct = int32(float(rank) * def.valuePerRank);
            if (pct > 0 && CastProgressionPercentAura(player, SPELL_PROGRESSION_MOVE_SPEED, pct))
                appliedPctSpells.push_back(SPELL_PROGRESSION_MOVE_SPEED);
            continue;
        }

        // Flat component (stat-op nodes only — Slot/CritRollChance/UnlockClassAffixes/
        // MetaXpPct/CharacterXpPct are bespoke, read directly via GetNodeBonus elsewhere).
        if (def.statOp >= 0)
        {
            int32 ival = int32(float(rank) * def.valuePerRank);
            sItemAffixMgr->ApplyPlayerStat(player, uint8(def.statOp), ival, true);
            appliedFlat.push_back({ uint8(def.statOp), ival });

            if (nodeId == NODE_ATTACK_POWER)
            {
                // Attack Power grants both melee and ranged AP from the same node.
                sItemAffixMgr->ApplyPlayerStat(player, uint8(GSTAT_RANGED_AP), ival, true);
                appliedFlat.push_back({ uint8(GSTAT_RANGED_AP), ival });
            }
        }

        // % component (any node with pctSpellIds configured — independent of statOp).
        // Multiple ids (Crit/Haste) all get the same magnitude, one spell per aura type.
        if (!def.pctSpellIds.empty())
        {
            int32 pct = int32(float(rank) * def.valuePerRankPct);
            if (pct > 0)
            {
                for (uint32 spellId : def.pctSpellIds)
                    if (CastProgressionPercentAura(player, spellId, pct))
                        appliedPctSpells.push_back(spellId);
            }
        }

        // Taught spell (real spellbook entry) — distinct channel from pctSpellIds,
        // learnSpell/removeSpell rather than CastCustomSpell/RemoveAurasDueToSpell.
        if (def.teachSpellId != 0)
        {
            player->learnSpell(def.teachSpellId);
            appliedTaughtSpells.push_back(def.teachSpellId);
        }
    }

    _activeMods.emplace(guid, std::move(appliedFlat));
    _activePctSpells.emplace(guid, std::move(appliedPctSpells));
    _activeTaughtSpells.emplace(guid, std::move(appliedTaughtSpells));

    // Runs after the loop above so this node's own flat component (applied via
    // the generic statOp branch, same as every other stat) is already in place —
    // see ApplySpellPowerDynamicBonus's own comment for why that ordering matters.
    ApplySpellPowerDynamicBonus(player);
}

void PlayerProgressionMgr::RemoveProgressionStats(Player* player)
{
    if (!player)
        return;

    uint64 guid = player->GetGUID().GetRawValue();

    auto modIt = _activeMods.find(guid);
    if (modIt != _activeMods.end())
    {
        for (ActiveProgressionMod const& mod : modIt->second)
            sItemAffixMgr->ApplyPlayerStat(player, mod.statOp, mod.value, false);
        _activeMods.erase(modIt);
    }

    auto pctIt = _activePctSpells.find(guid);
    if (pctIt != _activePctSpells.end())
    {
        for (uint32 spellId : pctIt->second)
            player->RemoveAurasDueToSpell(spellId);
        _activePctSpells.erase(pctIt);
    }

    auto taughtIt = _activeTaughtSpells.find(guid);
    if (taughtIt != _activeTaughtSpells.end())
    {
        for (uint32 spellId : taughtIt->second)
            player->removeSpell(spellId, SPEC_MASK_ALL, false);
        _activeTaughtSpells.erase(taughtIt);
    }

    auto spPctIt = _activeSpellPowerPctBonus.find(guid);
    if (spPctIt != _activeSpellPowerPctBonus.end())
    {
        player->ApplySpellPowerBonus(spPctIt->second, false);
        _activeSpellPowerPctBonus.erase(spPctIt);
    }
}

// ---------------------------------------------------------------------------
// Spell Power's dynamic % — see the "Three... Four channels" comment on
// ApplyProgressionStats/RemoveProgressionStats in PlayerProgression.h for the
// full rationale. Short version: unlike every other stat, there is no native
// aura that multiplies EXISTING spell power (SPELL_AURA_MOD_DAMAGE_DONE, the
// aura backing spell power, is purely additive — confirmed via
// Unit::SpellBaseDamageBonusDone in Unit.cpp before building this). So the %
// component is computed here in C++ instead of granted as a static aura, and
// deliberately recomputed ONLY on gear equip/unequip (never on a timer, never
// on buff gain/loss) per explicit design decision: including buffs would let
// players game the node via buff-stacking, and the player explicitly said
// gear+spec-only is fine — buffs never need to move this number live.
//
// Player::GetBaseSpellPowerBonus() is the key primitive this whole mechanism
// leans on: it's incremented ONLY by ITEM_MOD_SPELL_POWER (gear stats),
// ScalingStatValue (heirlooms), and gem/enchant spellpower bonuses — buffs
// apply via a completely separate path (real SPELL_AURA_MOD_DAMAGE_DONE
// auras) and never touch it. That's what makes "gear-only, buff-immune"
// achievable without tracking sources ourselves.
// ---------------------------------------------------------------------------

void PlayerProgressionMgr::ApplySpellPowerDynamicBonus(Player* player)
{
    // Assumes no dynamic bonus is currently applied for this guid — callers
    // (ApplyProgressionStats, RecomputeSpellPowerBonus) are responsible for
    // that precondition, same discipline as every other channel here.
    if (!player)
        return;

    uint64 guid = player->GetGUID().GetRawValue();
    uint8 rank = GetNodeRank(guid, NODE_SPELL_POWER);
    if (rank == 0)
        return;

    auto defIt = _nodeDefs.find(NODE_SPELL_POWER);
    if (defIt == _nodeDefs.end() || defIt->second.valuePerRankPct <= 0.0f)
        return;

    // At this point Spell Power's own flat component is already applied (either
    // by the ApplyProgressionStats loop just above, or because RecomputeSpellPowerBonus
    // only ever runs while the player is fully logged in with progression stats
    // already applied) — so GetBaseSpellPowerBonus() here is exactly "gear + our
    // own flat", with no risk of double-counting our own contribution.
    float pct = float(rank) * defIt->second.valuePerRankPct;
    int32 baseForPct = int32(player->GetBaseSpellPowerBonus());
    int32 dynamicBonus = int32(std::lround(double(baseForPct) * double(pct) / 100.0));
    if (dynamicBonus <= 0)
        return;

    player->ApplySpellPowerBonus(dynamicBonus, true);
    _activeSpellPowerPctBonus[guid] = dynamicBonus;
}

void PlayerProgressionMgr::RecomputeSpellPowerBonus(Player* player)
{
    if (!player)
        return;

    uint64 guid = player->GetGUID().GetRawValue();
    auto it = _activeSpellPowerPctBonus.find(guid);
    if (it != _activeSpellPowerPctBonus.end())
    {
        player->ApplySpellPowerBonus(it->second, false);
        _activeSpellPowerPctBonus.erase(it);
    }

    ApplySpellPowerDynamicBonus(player);
}

// ---------------------------------------------------------------------------
// GM/support helpers
// ---------------------------------------------------------------------------

AccountProgressionState PlayerProgressionMgr::GetAccountState(uint32 accountId)
{
    return GetOrLoadAccount(accountId);
}

std::unordered_map<uint16, uint8> PlayerProgressionMgr::GetCharacterNodeRanks(uint64 guid)
{
    return GetOrLoadCharacterNodes(guid);
}

void PlayerProgressionMgr::GrantXp(Player* player, uint64 amount)
{
    if (!player || !player->GetSession())
        return;

    uint32 accountId = player->GetSession()->GetAccountId();
    AccountProgressionState& state = GetOrLoadAccount(accountId);
    state.xp += amount;
    SaveAccountState(accountId, state);
    SendProgState(player);
}

void PlayerProgressionMgr::ForceReset(Player* player)
{
    if (!player || !player->GetSession())
        return;

    uint64 guid = player->GetGUID().GetRawValue();

    RemoveProgressionStats(player);
    CharacterDatabase.Execute("DELETE FROM character_progression_nodes WHERE guid = {}", guid);
    GetOrLoadCharacterNodes(guid).clear();
    ApplyProgressionStats(player);  // no-op: every node is 0 now, but keeps the pairing uniform

    SendProgState(player);
}

// ---------------------------------------------------------------------------
// Addon protocol
// ---------------------------------------------------------------------------

void PlayerProgressionMgr::SendProgState(Player* player)
{
    if (!player || !player->GetSession())
        return;

    uint32 accountId = player->GetSession()->GetAccountId();
    uint64 guid      = player->GetGUID().GetRawValue();
    AccountProgressionState& account = GetOrLoadAccount(accountId);
    auto& nodes = GetOrLoadCharacterNodes(guid);

    uint32 pointsTotal     = XpToPoints(account.xp);
    uint32 pointsSpent     = TotalRanksSpent(guid);
    uint32 pointsAvailable = pointsTotal > pointsSpent ? pointsTotal - pointsSpent : 0;
    uint32 respecCost      = RespecCostCopper(player->GetLevel());
    uint8  currentTier     = CurrentUnlockedTier(pointsSpent);

    // WotLK's chat protocol (which SendAddonMsg's packets masquerade as, via
    // CHAT_MSG_WHISPER) hard-caps a single message at 255 chars (see
    // ChatHandler.cpp's own `msg.length() > 255` check). A single PROG|STATE
    // message with every node inline would blow past that once the node count
    // grows large enough — any node past the cutoff silently never reaches the
    // client. Node data is split across multiple PROG|NODES chunks instead,
    // each kept comfortably under the limit; the header (xp/points/cost/tier)
    // always fits alone.
    std::vector<std::string> segments;
    segments.reserve(_nodeDefs.size());
    for (auto const& [nodeId, def] : _nodeDefs)
    {
        auto rankIt = nodes.find(nodeId);
        uint8 rank = rankIt != nodes.end() ? rankIt->second : 0;
        segments.push_back(Acore::StringFormat("{}:{}:{}:{}:{}:{}",
            nodeId, rank, def.maxRank, def.unlockTier, def.valuePerRank, def.valuePerRankPct));
    }

    static constexpr size_t kChunkBudget = 180; // leaves headroom under 255 for "AFXM\t" + PROG|NODES|i|n| framing
    std::vector<std::string> chunks;
    std::string current;
    for (std::string const& seg : segments)
    {
        if (!current.empty() && current.size() + 1 + seg.size() > kChunkBudget)
        {
            chunks.push_back(current);
            current.clear();
        }
        if (!current.empty())
            current += "|";
        current += seg;
    }
    if (!current.empty())
        chunks.push_back(current);

    // PROG|STATE|xp|pointsAvailable|respecCostCopper|currentTier|totalNodeChunks
    SendAddonMsg(player, Acore::StringFormat("PROG|STATE|{}|{}|{}|{}|{}",
        account.xp, pointsAvailable, respecCost, currentTier, chunks.size()));

    // PROG|NODES|chunkIndex|totalChunks|id:rank:maxRank:unlockTier:valuePerRank:valuePerRankPct|...
    for (size_t i = 0; i < chunks.size(); ++i)
        SendAddonMsg(player, Acore::StringFormat("PROG|NODES|{}|{}|{}", i, chunks.size(), chunks[i]));
}

void PlayerProgressionMgr::HandleAddonMessage(Player* player, std::vector<std::string_view> const& parts)
{
    if (!_enabled || !player || !player->GetSession() || parts.size() < 2)
        return;

    std::string sub(parts[1]);

    if (sub == "QUERY")
    {
        SendProgState(player);
        return;
    }

    uint64 guid       = player->GetGUID().GetRawValue();
    uint32 accountId  = player->GetSession()->GetAccountId();
    AccountProgressionState& account = GetOrLoadAccount(accountId);
    auto& nodes = GetOrLoadCharacterNodes(guid);

    if (sub == "INVEST")
    {
        if (parts.size() < 3)
            return;

        auto nodeIdOpt = Acore::StringTo<uint16>(parts[2]);
        if (!nodeIdOpt)
            return;
        uint16 nodeId = *nodeIdOpt;

        auto defIt = _nodeDefs.find(nodeId);
        if (defIt == _nodeDefs.end())
            return;
        ProgressionNodeDef const& def = defIt->second;

        auto rankIt = nodes.find(nodeId);
        uint8 currentRank = rankIt != nodes.end() ? rankIt->second : 0;
        if (currentRank >= def.maxRank)
        {
            SendProgState(player);
            return;
        }

        uint32 pointsTotal = XpToPoints(account.xp);
        uint32 pointsSpent = TotalRanksSpent(guid);
        if (pointsSpent >= pointsTotal)
        {
            SendProgState(player);
            return;
        }

        if (def.unlockTier > CurrentUnlockedTier(pointsSpent))
        {
            SendProgState(player);
            return;
        }

        uint8 newRank = currentRank + 1;
        nodes[nodeId] = newRank;
        SaveNodeRank(guid, nodeId, newRank);

        RemoveProgressionStats(player);
        ApplyProgressionStats(player);

        // NODE_UNLOCK_CLASS_AFFIXES gates ItemAffixMgr's own roll logic (see
        // IsClassAffixesBlocked in ItemAffix.cpp) — the addon caches a per-item
        // "classSkillsBlocked" hint from the last DATA packet, which otherwise
        // wouldn't refresh until next login. Push a fresh one now so the roll
        // menu's Class Skills button updates live instead of going stale.
        if (nodeId == NODE_UNLOCK_CLASS_AFFIXES)
            sItemAffixMgr->RefreshAllItemStatus(player);

        SendProgState(player);
        return;
    }

    if (sub == "RESPEC")
    {
        uint32 cost = RespecCostCopper(player->GetLevel());
        if (!player->HasEnoughMoney(cost))
        {
            SendAddonMsg(player, "PROG|ERR|Not enough gold");
            return;
        }

        player->ModifyMoney(-int32(cost));

        RemoveProgressionStats(player);
        CharacterDatabase.Execute("DELETE FROM character_progression_nodes WHERE guid = {}", guid);
        nodes.clear();
        ApplyProgressionStats(player);  // no-op: every node is 0 now, but keeps the pairing uniform

        // Respec can reset NODE_UNLOCK_CLASS_AFFIXES among everything else — same
        // live-refresh reasoning as the INVEST branch above.
        sItemAffixMgr->RefreshAllItemStatus(player);

        SendProgState(player);
        return;
    }
}
