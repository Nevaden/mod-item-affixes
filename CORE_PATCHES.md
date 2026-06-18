# Core Patches — mod-item-affixes

This document lists every change required in the AzerothCore source tree that cannot be applied automatically by the module system. The script `scripts/apply_core_patches.ps1` handles **Patch 1** and **Patch 2 (call site)** automatically. The three ScriptMgr edits for **Patch 2** must be made by hand (or are already present if you ran the script on a previous version that handled them).

---

## Patch 1 — `Player::ApplyModToSpell` null-guard

**File:** `src/server/game/Entities/Player/Player.cpp`  
**Applied by:** `apply_core_patches.ps1` automatically.

Adds a null-check for `mod->ownerAura` so that affix mods (which have no owning aura) don't crash the charge-tracking logic.

---

## Patch 2 — `OnPlayerSocketGem` hook

Fires a ScriptMgr event when a gem is socketed, so the module can grant gem-triggered affixes before the gem item is destroyed.

### 2a — Enum value

**File:** `src/server/game/Scripting/ScriptDefines/PlayerScript.h`

Inside the `PlayerHook` enum, add **after** `PLAYERHOOK_ON_UNEQUIP_ITEM`:

```cpp
PLAYERHOOK_ON_SOCKET_GEM,
```

### 2b — Virtual method

**File:** `src/server/game/Scripting/ScriptDefines/PlayerScript.h`

Add the virtual method to the `PlayerScript` class (put it near the other equipment-related hooks):

```cpp
// After a gem is socketed into an item (before the gem item is destroyed)
virtual void OnPlayerSocketGem(Player* /*player*/, Item* /*item*/, Item* /*gem*/, uint8 /*slot*/) { }
```

### 2c — Dispatcher

**File:** `src/server/game/Scripting/ScriptDefines/PlayerScript.cpp`

Add the dispatcher at the bottom of the file (before the closing of any namespace, if applicable):

```cpp
void ScriptMgr::OnPlayerSocketGem(Player* player, Item* item, Item* gem, uint8 slot)
{
    CALL_ENABLED_HOOKS(PlayerScript, PLAYERHOOK_ON_SOCKET_GEM, script->OnPlayerSocketGem(player, item, gem, slot));
}
```

### 2d — ScriptMgr declaration

**File:** `src/server/game/Scripting/ScriptMgr.h`

Inside the `ScriptMgr` class, add near the other `OnPlayer*` declarations:

```cpp
void OnPlayerSocketGem(Player* player, Item* item, Item* gem, uint8 slot);
```

### 2e — Call site in ItemHandler.cpp

**File:** `src/server/game/Handlers/ItemHandler.cpp`  
**Applied by:** `apply_core_patches.ps1` automatically.

Calls `sScriptMgr->OnPlayerSocketGem(...)` just before the gem item is destroyed inside `WorldSession::HandleSocketOpcode`.

---

## After applying patches

Rebuild the worldserver. See README.md → **Step 4: Build** for the command.
