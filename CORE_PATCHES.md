# Core Patches — mod-item-affixes

This document lists every change required in the AzerothCore source tree that cannot be applied automatically by the module system. **All patches below are applied automatically by `scripts/apply_core_patches.ps1`** — no manual edits are required. This file exists for reference only.

---

## Patch 1 — `Player::ApplyModToSpell` null-guard

**File:** `src/server/game/Entities/Player/Player.cpp`  
**Applied by:** `scripts/apply_core_patches.ps1`

Adds a null-check for `mod->ownerAura` so that affix mods (which have no owning aura) don't crash the charge-tracking logic.

---

## Patch 2 — `OnPlayerSocketGem` hook

Fires a ScriptMgr event when a gem is socketed, so the module can grant gem-triggered affixes before the gem item is destroyed.

### 2a — Enum value (`PlayerScript.h`)
**Applied by:** `scripts/apply_core_patches.ps1` — adds `PLAYERHOOK_ON_SOCKET_GEM` after `PLAYERHOOK_ON_UNEQUIP_ITEM`.

### 2b — Virtual method (`PlayerScript.h`)
**Applied by:** `scripts/apply_core_patches.ps1` — adds `virtual void OnPlayerSocketGem(...)` near the other equipment hooks.

### 2c — Dispatcher (`PlayerScript.cpp`)
**Applied by:** `scripts/apply_core_patches.ps1` — adds `ScriptMgr::OnPlayerSocketGem` dispatcher at the bottom of the file.

### 2d — ScriptMgr declaration (`ScriptMgr.h`)
**Applied by:** `scripts/apply_core_patches.ps1` — adds `void OnPlayerSocketGem(...)` declaration inside the `ScriptMgr` class.

### 2e — Call site (`ItemHandler.cpp`)
**Applied by:** `scripts/apply_core_patches.ps1`

Calls `sScriptMgr->OnPlayerSocketGem(...)` just before the gem item is destroyed inside `WorldSession::HandleSocketOpcode`.

---

## After applying patches

Rebuild the worldserver. See README.md → **Step 4: Build** for the command.
