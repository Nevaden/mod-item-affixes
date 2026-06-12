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

    $content = Get-Content $FilePath -Raw -Encoding UTF8

    if ($content.Contains($DetectString)) {
        Write-Skip $Description
        return
    }

    if (-not $content.Contains($SearchText)) {
        Write-Err ("Search text not found in " + $FilePath + "`n" +
            "  The file may have changed upstream. Apply the patch manually - see CORE_PATCHES.md.")
    }

    $patched = $content.Replace($SearchText, $ReplaceText)
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

    spell->m_appliedMods.insert(mod->ownerAura);
'@
$p1_replace = @'
    // don't do anything with no charges (ownerAura is null for item-affix mods - skip charge logic)
    if (mod->ownerAura && mod->ownerAura->IsUsingCharges() && !mod->ownerAura->GetCharges())
        return;

    // register inside spell for charge tracking; skip if no ownerAura (item-affix mods have none)
    if (mod->ownerAura)
        spell->m_appliedMods.insert(mod->ownerAura);
'@

ApplyPatch "Patch 1: Player::ApplyModToSpell null-guard (ownerAura)" `
           $p1_file $p1_detect $p1_search $p1_replace

# ---------------------------------------------------------------------------
# Patch 2: WorldSession::HandleSocketOpcode gem hook (gem affixes)
# Also requires manual edits to PlayerScript.h and ScriptMgr.h/cpp
# (see CORE_PATCHES.md Patch 2 for the exact virtual + dispatcher code).
# ---------------------------------------------------------------------------

$p2_file   = Join-Path $AzerothCoreRoot "src\server\game\Handlers\ItemHandler.cpp"
$p2_detect = "OnPlayerSocketGem"
$p2_search = @'
            if (Item* guidItem = _player->GetItemByGuid(packet.GemGuids[i]))
                _player->DestroyItem(guidItem->GetBagSlot(), guidItem->GetSlot(), true);
'@
$p2_replace = @'
            if (Item* guidItem = _player->GetItemByGuid(packet.GemGuids[i]))
            {
                sScriptMgr->OnPlayerSocketGem(_player, itemTarget, guidItem, i);
                _player->DestroyItem(guidItem->GetBagSlot(), guidItem->GetSlot(), true);
            }
'@

ApplyPatch "Patch 2: HandleSocketOpcode OnPlayerSocketGem callback (gem affixes)" `
           $p2_file $p2_detect $p2_search $p2_replace

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "All patches applied. Rebuild the worldserver:" -ForegroundColor White
Write-Host "  cd `"<YOUR_BUILD_DIR>`""
Write-Host "  cmake --build . --config RelWithDebInfo"
Write-Host ""
