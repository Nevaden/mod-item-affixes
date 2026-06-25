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
# Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "All patches applied. Rebuild the worldserver:" -ForegroundColor White
Write-Host "  cd `"<YOUR_BUILD_DIR>`""
Write-Host "  cmake --build . --config RelWithDebInfo"
Write-Host ""
