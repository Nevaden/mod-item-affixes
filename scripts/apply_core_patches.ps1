#Requires -Version 5.1
<#
.SYNOPSIS
    Applies required AzerothCore core patches for mod-item-affixes.

.DESCRIPTION
    Edits core source files that the module cannot modify via the module system alone.
    Each patch is idempotent - running the script twice is safe.

.PARAMETER AzerothCoreRoot
    Path to the root of the azerothcore-wotlk source tree.
    Defaults to two levels above this script (modules/../..).

.EXAMPLE
    .\apply_core_patches.ps1
    .\apply_core_patches.ps1 -AzerothCoreRoot "C:\dev\azerothcore-wotlk"
#>
param(
    [string]$AzerothCoreRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Status($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)     { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Skip($msg)   { Write-Host "  [--]  $msg (already applied)" -ForegroundColor DarkGray }
function Write-Err($msg)    { Write-Host "  [FAIL] $msg" -ForegroundColor Red; exit 1 }

function ApplyPatch($Description, $FilePath, $DetectString, $SearchText, $ReplaceText) {
    Write-Status $Description

    if (-not (Test-Path $FilePath)) {
        Write-Err "File not found: $FilePath"
    }

    $raw = Get-Content $FilePath -Raw -Encoding UTF8
    $useCrlf = $raw.Contains("`r`n")

    # Normalize to LF for comparison so here-strings (CRLF) match LF source files
    $content  = $raw         -replace "`r`n", "`n"
    $detect   = $DetectString -replace "`r`n", "`n"
    $search   = $SearchText   -replace "`r`n", "`n"
    $replace  = $ReplaceText  -replace "`r`n", "`n"

    if ($content.Contains($detect)) {
        Write-Skip $Description
        return
    }

    if (-not $content.Contains($search)) {
        Write-Err ("Search text not found in " + $FilePath + "`n" +
            "  The file may have changed upstream. Apply the patch manually - see CORE_PATCHES.md.")
    }

    $patched = $content.Replace($search, $replace)
    if ($useCrlf) { $patched = $patched -replace "`n", "`r`n" }
    [System.IO.File]::WriteAllText($FilePath, $patched, [System.Text.UTF8Encoding]::new($false))
    Write-Ok $Description
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "mod-item-affixes - Core Patch Installer" -ForegroundColor White
Write-Host "AzerothCore root: $AzerothCoreRoot"
Write-Host ""

# ---------------------------------------------------------------------------
# Patch 1: Player::ApplyModToSpell null-guard
# File: src/server/game/Entities/Player/Player.cpp
# ---------------------------------------------------------------------------

$p1_file   = Join-Path $AzerothCoreRoot "src\server\game\Entities\Player\Player.cpp"
$p1_detect = "ownerAura is null for item-affix mods"
$p1_search = @'
    // don't do anything with no charges
    if (mod->ownerAura->IsUsingCharges() && !mod->ownerAura->GetCharges())
        return;

    // register inside spell, proc system uses this to drop charges
    spell->m_appliedMods.insert(mod->ownerAura);
'@
$p1_replace = @'
    // don't do anything with no charges (ownerAura is null for item-affix mods - skip charge logic)
    if (mod->ownerAura && mod->ownerAura->IsUsingCharges() && !mod->ownerAura->GetCharges())
        return;

    // register inside spell, proc system uses this to drop charges; skip if no ownerAura (item-affix mods have none)
    if (mod->ownerAura)
        spell->m_appliedMods.insert(mod->ownerAura);
'@

ApplyPatch "Patch 1: Player::ApplyModToSpell null-guard (ownerAura)" `
           $p1_file $p1_detect $p1_search $p1_replace

# ---------------------------------------------------------------------------
# Patch 2a: PlayerHook enum value
# File: src/server/game/Scripting/ScriptDefines/PlayerScript.h
# ---------------------------------------------------------------------------

$p2a_file   = Join-Path $AzerothCoreRoot "src\server\game\Scripting\ScriptDefines\PlayerScript.h"
$p2a_detect = "PLAYERHOOK_ON_SOCKET_GEM"
$p2a_search = @'
    PLAYERHOOK_ON_UNEQUIP_ITEM,
'@
$p2a_replace = @'
    PLAYERHOOK_ON_UNEQUIP_ITEM,
    PLAYERHOOK_ON_SOCKET_GEM,
'@

ApplyPatch "Patch 2a: PlayerHook enum value PLAYERHOOK_ON_SOCKET_GEM" `
           $p2a_file $p2a_detect $p2a_search $p2a_replace

# ---------------------------------------------------------------------------
# Patch 2b: PlayerScript virtual method
# File: src/server/game/Scripting/ScriptDefines/PlayerScript.h
# ---------------------------------------------------------------------------

$p2b_detect = "virtual void OnPlayerSocketGem"
$p2b_search = @'
    // After an item has been unequipped
    virtual void OnPlayerUnequip(Player* /*player*/, Item* /*it*/) { }
'@
$p2b_replace = @'
    // After an item has been unequipped
    virtual void OnPlayerUnequip(Player* /*player*/, Item* /*it*/) { }

    // After a gem is socketed into an item (before the gem item is destroyed)
    virtual void OnPlayerSocketGem(Player* /*player*/, Item* /*item*/, Item* /*gem*/, uint8 /*slot*/) { }
'@

ApplyPatch "Patch 2b: PlayerScript virtual OnPlayerSocketGem method" `
           $p2a_file $p2b_detect $p2b_search $p2b_replace

# ---------------------------------------------------------------------------
# Patch 2c: ScriptMgr dispatcher
# File: src/server/game/Scripting/ScriptDefines/PlayerScript.cpp
# ---------------------------------------------------------------------------

$p2c_file   = Join-Path $AzerothCoreRoot "src\server\game\Scripting\ScriptDefines\PlayerScript.cpp"
$p2c_detect = "ScriptMgr::OnPlayerSocketGem"
$p2c_search = "template class AC_GAME_API ScriptRegistry<PlayerScript>;"
$p2c_replace = @'
void ScriptMgr::OnPlayerSocketGem(Player* player, Item* item, Item* gem, uint8 slot)
{
    CALL_ENABLED_HOOKS(PlayerScript, PLAYERHOOK_ON_SOCKET_GEM, script->OnPlayerSocketGem(player, item, gem, slot));
}

template class AC_GAME_API ScriptRegistry<PlayerScript>;
'@

ApplyPatch "Patch 2c: ScriptMgr OnPlayerSocketGem dispatcher" `
           $p2c_file $p2c_detect $p2c_search $p2c_replace

# ---------------------------------------------------------------------------
# Patch 2d: ScriptMgr declaration
# File: src/server/game/Scripting/ScriptMgr.h
# ---------------------------------------------------------------------------

$p2d_file   = Join-Path $AzerothCoreRoot "src\server\game\Scripting\ScriptMgr.h"
$p2d_detect = "void OnPlayerSocketGem("  # match any parameter-name variant
$p2d_search = "    void OnPlayerUnequip(Player* player, Item* it);"
$p2d_replace = @'
    void OnPlayerUnequip(Player* player, Item* it);
    void OnPlayerSocketGem(Player* player, Item* item, Item* gem, uint8 slot);
'@

ApplyPatch "Patch 2d: ScriptMgr.h OnPlayerSocketGem declaration" `
           $p2d_file $p2d_detect $p2d_search $p2d_replace

# ---------------------------------------------------------------------------
# Patch 2e: WorldSession::HandleSocketOpcode gem hook call site
# File: src/server/game/Handlers/ItemHandler.cpp
# ---------------------------------------------------------------------------

$p2e_file   = Join-Path $AzerothCoreRoot "src\server\game\Handlers\ItemHandler.cpp"
$p2e_detect = "OnPlayerSocketGem"
$p2e_search = @'
            if (Item* guidItem = _player->GetItemByGuid(packet.GemGuids[i]))
                _player->DestroyItem(guidItem->GetBagSlot(), guidItem->GetSlot(), true);
'@
$p2e_replace = @'
            if (Item* guidItem = _player->GetItemByGuid(packet.GemGuids[i]))
            {
                sScriptMgr->OnPlayerSocketGem(_player, itemTarget, guidItem, i);
                _player->DestroyItem(guidItem->GetBagSlot(), guidItem->GetSlot(), true);
            }
'@

ApplyPatch "Patch 2e: HandleSocketOpcode OnPlayerSocketGem callback (gem affixes)" `
           $p2e_file $p2e_detect $p2e_search $p2e_replace

# ---------------------------------------------------------------------------
# Patch 3: Unit::DealDamage - count player-owned summon damage as player damage
# File: src/server/game/Entities/Unit/Unit.cpp
#
# Without this, the damagedByPlayer flag (which gates loot and XP eligibility)
# is only set for players, vehicles moved by players, and charmed units.
# Player-owned TempSummons (SetOwnerGUID) were excluded, so their solo kills
# granted no loot or XP to the owning player.
# ---------------------------------------------------------------------------

$p3_file   = Join-Path $AzerothCoreRoot "src\server\game\Entities\Unit\Unit.cpp"
$p3_detect = "attacker->GetOwnerGUID().IsPlayer()"
$p3_search = @'
            bool damagedByPlayer = unDamage && attacker && (attacker->IsPlayer() || attacker->m_movedByPlayer != nullptr
                || attacker->GetCharmerGUID().IsPlayer());
'@
$p3_replace = @'
            bool damagedByPlayer = unDamage && attacker && (attacker->IsPlayer() || attacker->m_movedByPlayer != nullptr
                || attacker->GetCharmerGUID().IsPlayer() || attacker->GetOwnerGUID().IsPlayer());
'@

ApplyPatch "Patch 3: Unit::DealDamage - player-owned summon damage counts as player damage (loot/XP)" `
           $p3_file $p3_detect $p3_search $p3_replace

# ---------------------------------------------------------------------------
# Patch 4: Unit::EngageWithTarget - tap mob for loot when player-owned summon engages
# File: src/server/game/Entities/Unit/Unit.cpp
#
# The 3.0.8 tap-on-aggro block only ran when IsPlayer(). Player-owned summons
# (IsControlledByPlayer()) were excluded, so the mob's loot recipient was never
# set at combat start for summon-initiated combat.
# ---------------------------------------------------------------------------

$p4_detect = "IsPlayer() || IsControlledByPlayer()"
$p4_search = @'
    if (Creature* creature = target->ToCreature())
        if (!creature->hasLootRecipient() && IsPlayer())
            creature->SetLootRecipient(this);
'@
$p4_replace = @'
    if (Creature* creature = target->ToCreature())
        if (!creature->hasLootRecipient() && (IsPlayer() || IsControlledByPlayer()))
            creature->SetLootRecipient(this);
'@

ApplyPatch "Patch 4: Unit::EngageWithTarget - player-owned summons tap mob on engage (loot recipient)" `
           $p3_file $p4_detect $p4_search $p4_replace

# ---------------------------------------------------------------------------
# Patch 5: ChatHandler - suppress spurious "unknown message type" log spam
# File: src/server/game/Handlers/ChatHandler.cpp
#
# Modules that intercept LANG_ADDON chat messages via OnPlayerBeforeSendChatMessage
# (this module included - see ItemAffixScripts.cpp) commonly set type=0 as a
# "message handled, suppress delivery" sentinel after consuming the message.
# Without this patch, that sentinel falls through to the dispatch switch's
# default case and logs an "unknown message type" error on every single
# addon-message exchange (e.g. every tooltip fetch, every roll, etc).
# ---------------------------------------------------------------------------

$p5_file   = Join-Path $AzerothCoreRoot "src\server\game\Handlers\ChatHandler.cpp"
$p5_detect = "message handled, suppress delivery"
$p5_search = @'
    sScriptMgr->OnPlayerBeforeSendChatMessage(_player, type, lang, msg);

    switch (type)
'@
$p5_replace = @'
    sScriptMgr->OnPlayerBeforeSendChatMessage(_player, type, lang, msg);

    // Some modules (e.g. mod-item-affixes) use type=0 + lang=LANG_ADDON as a
    // "message handled, suppress delivery" sentinel via OnPlayerBeforeSendChatMessage.
    // Catch it here rather than falling through to the switch's default case, which
    // would otherwise log a spurious "unknown message type" error every time.
    if (type == 0 && lang == LANG_ADDON)
    {
        return;
    }

    switch (type)
'@

ApplyPatch "Patch 5: ChatHandler - suppress addon-message suppression-sentinel log spam" `
           $p5_file $p5_detect $p5_search $p5_replace

# ---------------------------------------------------------------------------
# Patch 6: OnPlayerBeforeQuestReward hook
#
# Fires a ScriptMgr event at the very top of Player::RewardQuest, before either
# reward-item loop runs, so a module's OnPlayerStoreNewItem/
# OnPlayerAfterStoreOrEquipNewItem handler can tell a quest-reward item apart
# from any other newly-stored item (this module uses it for
# ItemAffixes.D3ExcludeQuestRewards). Deliberately NOT the same as the native
# OnPlayerBeforeQuestComplete hook -- that one fires from Player::CompleteQuest,
# a separate, often much earlier step (the "complete quest" dialog) than
# RewardQuest (the "pick a reward" step where items actually get stored) for
# any non-auto-rewarded quest. Substituting OnPlayerBeforeQuestComplete here
# would set/clear the exclusion flag around the wrong window entirely.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Patch 6a: PlayerHook enum value
# File: src/server/game/Scripting/ScriptDefines/PlayerScript.h
# ---------------------------------------------------------------------------

$p6a_file   = Join-Path $AzerothCoreRoot "src\server\game\Scripting\ScriptDefines\PlayerScript.h"
$p6a_detect = "PLAYERHOOK_ON_BEFORE_QUEST_REWARD"
$p6a_search = @'
    PLAYERHOOK_ON_SOCKET_GEM,
'@
$p6a_replace = @'
    PLAYERHOOK_ON_SOCKET_GEM,
    PLAYERHOOK_ON_BEFORE_QUEST_REWARD,
'@

ApplyPatch "Patch 6a: PlayerHook enum value PLAYERHOOK_ON_BEFORE_QUEST_REWARD" `
           $p6a_file $p6a_detect $p6a_search $p6a_replace

# ---------------------------------------------------------------------------
# Patch 6b: PlayerScript virtual method
# File: src/server/game/Scripting/ScriptDefines/PlayerScript.h
# ---------------------------------------------------------------------------

$p6b_detect = "virtual void OnPlayerBeforeQuestReward"
$p6b_search = @'
    // After a gem is socketed into an item (before the gem item is destroyed)
    virtual void OnPlayerSocketGem(Player* /*player*/, Item* /*item*/, Item* /*gem*/, uint8 /*slot*/) { }
'@
$p6b_replace = @'
    // After a gem is socketed into an item (before the gem item is destroyed)
    virtual void OnPlayerSocketGem(Player* /*player*/, Item* /*item*/, Item* /*gem*/, uint8 /*slot*/) { }

    // Just before RewardQuest stores any reward item(s) -- fires once per quest
    // turn-in, before both reward-item loops run. Lets a module distinguish a
    // quest-reward item from any other newly-stored item at the point its own
    // OnPlayerStoreNewItem/OnPlayerAfterStoreOrEquipNewItem hook fires for it.
    virtual void OnPlayerBeforeQuestReward(Player* /*player*/, Quest const* /*quest*/) { }
'@

ApplyPatch "Patch 6b: PlayerScript virtual OnPlayerBeforeQuestReward method" `
           $p6a_file $p6b_detect $p6b_search $p6b_replace

# ---------------------------------------------------------------------------
# Patch 6c: ScriptMgr dispatcher
# File: src/server/game/Scripting/ScriptDefines/PlayerScript.cpp
# ---------------------------------------------------------------------------

$p6c_file   = Join-Path $AzerothCoreRoot "src\server\game\Scripting\ScriptDefines\PlayerScript.cpp"
$p6c_detect = "ScriptMgr::OnPlayerBeforeQuestReward"
$p6c_search = "template class AC_GAME_API ScriptRegistry<PlayerScript>;"
$p6c_replace = @'
void ScriptMgr::OnPlayerBeforeQuestReward(Player* player, Quest const* quest)
{
    CALL_ENABLED_HOOKS(PlayerScript, PLAYERHOOK_ON_BEFORE_QUEST_REWARD, script->OnPlayerBeforeQuestReward(player, quest));
}

template class AC_GAME_API ScriptRegistry<PlayerScript>;
'@

ApplyPatch "Patch 6c: ScriptMgr OnPlayerBeforeQuestReward dispatcher" `
           $p6c_file $p6c_detect $p6c_search $p6c_replace

# ---------------------------------------------------------------------------
# Patch 6d: ScriptMgr declaration
# File: src/server/game/Scripting/ScriptMgr.h
# ---------------------------------------------------------------------------

$p6d_file   = Join-Path $AzerothCoreRoot "src\server\game\Scripting\ScriptMgr.h"
$p6d_detect = "void OnPlayerBeforeQuestReward("
$p6d_search = "    void OnPlayerSocketGem(Player* player, Item* item, Item* gem, uint8 slot);"
$p6d_replace = @'
    void OnPlayerSocketGem(Player* player, Item* item, Item* gem, uint8 slot);
    void OnPlayerBeforeQuestReward(Player* player, Quest const* quest);
'@

ApplyPatch "Patch 6d: ScriptMgr.h OnPlayerBeforeQuestReward declaration" `
           $p6d_file $p6d_detect $p6d_search $p6d_replace

# ---------------------------------------------------------------------------
# Patch 6e: Player::RewardQuest call site
# File: src/server/game/Entities/Player/PlayerQuest.cpp
# ---------------------------------------------------------------------------

$p6e_file   = Join-Path $AzerothCoreRoot "src\server\game\Entities\Player\PlayerQuest.cpp"
$p6e_detect = "OnPlayerBeforeQuestReward"
$p6e_search = @'
void Player::RewardQuest(Quest const* quest, uint32 reward, Object* questGiver, bool announce, bool isLFGReward)
{
    //this THING should be here to protect code from quest, which cast on player far teleport as a reward
    //should work fine, cause far teleport will be executed in Player::Update()
    SetMustDelayTeleport(true);
'@
$p6e_replace = @'
void Player::RewardQuest(Quest const* quest, uint32 reward, Object* questGiver, bool announce, bool isLFGReward)
{
    //this THING should be here to protect code from quest, which cast on player far teleport as a reward
    //should work fine, cause far teleport will be executed in Player::Update()
    SetMustDelayTeleport(true);

    // Fires before any reward item is stored, so a module's own
    // OnPlayerStoreNewItem/OnPlayerAfterStoreOrEquipNewItem handler can tell
    // a quest-reward item apart from any other newly-stored item.
    sScriptMgr->OnPlayerBeforeQuestReward(this, quest);
'@

ApplyPatch "Patch 6e: Player::RewardQuest OnPlayerBeforeQuestReward call site" `
           $p6e_file $p6e_detect $p6e_search $p6e_replace

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "All patches applied. Rebuild the worldserver:" -ForegroundColor White
Write-Host "  cd `"<YOUR_BUILD_DIR>`""
Write-Host "  cmake --build . --config RelWithDebInfo"
Write-Host ""
