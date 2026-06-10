# Core Patches — mod-item-affixes

This module requires small edits to AzerothCore core files that cannot be delivered as a module
alone. Each patch is documented here with the exact before/after change.

Run `apply_core_patches.ps1` from the module folder to apply all patches automatically, or
follow the manual steps below.

---

## Patch 1 — Player::ApplyModToSpell null-guard

**File:** `src/server/game/Entities/Player/Player.cpp`  
**Why:** This module creates `SpellModifier` objects without an owning aura (`ownerAura = nullptr`).
The stock engine dereferences `ownerAura` unconditionally inside `ApplyModToSpell`, crashing the
worldserver the first time a player casts a spell while an affix modifier is active.

### Before (stock AzerothCore)

```cpp
void Player::ApplyModToSpell(SpellModifier* mod, Spell* spell)
{
    if (!spell)
        return;

    // don't do anything with no charges
    if (mod->ownerAura->IsUsingCharges() && !mod->ownerAura->GetCharges())
        return;

    spell->m_appliedMods.insert(mod->ownerAura);
}
```

### After (patched)

```cpp
void Player::ApplyModToSpell(SpellModifier* mod, Spell* spell)
{
    if (!spell)
        return;

    // don't do anything with no charges (ownerAura is null for item-affix mods — skip charge logic)
    if (mod->ownerAura && mod->ownerAura->IsUsingCharges() && !mod->ownerAura->GetCharges())
        return;

    // register inside spell for charge tracking; skip if no ownerAura (item-affix mods have none)
    if (mod->ownerAura)
        spell->m_appliedMods.insert(mod->ownerAura);
}
```

**Detection string (already patched if found):** `ownerAura is null for item-affix mods`

---

## Patch 2 — WorldSession::HandleSocketOpcode gem hook

**File:** `src/server/game/Handlers/ItemHandler.cpp`  
**Why:** Gem affixes must transfer to the gear item at the moment of socketing, just before the
gem item is destroyed. There is no existing script hook for this event in AzerothCore, so a
callback is added here.

**Status:** IMPLEMENTED

### Before (stock AzerothCore)

```cpp
        if (Item* guidItem = _player->GetItemByGuid(packet.GemGuids[i]))
            _player->DestroyItem(guidItem->GetBagSlot(), guidItem->GetSlot(), true);
```

### After (patched)

```cpp
        if (Item* guidItem = _player->GetItemByGuid(packet.GemGuids[i]))
        {
            sScriptMgr->OnPlayerSocketGem(_player, itemTarget, guidItem, i);
            _player->DestroyItem(guidItem->GetBagSlot(), guidItem->GetSlot(), true);
        }
```

**Detection string (already patched if found):** `OnPlayerSocketGem`

### Additional files for Patch 2

**`src/server/game/Scripting/ScriptDefines/PlayerScript.h`** — add inside `class PlayerScript`:

```cpp
    // Called just before a gem item is consumed into a socketed gear item.
    // socketSlot: 0, 1, or 2 (gem socket index on the gear item).
    virtual void OnSocketGem(Player* /*player*/, Item* /*gearItem*/, Item* /*gemItem*/, uint8 /*socketSlot*/) { }
```

**`src/server/game/Scripting/ScriptMgr.h`** — add declaration (with other Player dispatcher declarations):

```cpp
    void OnPlayerSocketGem(Player* player, Item* gearItem, Item* gemItem, uint8 socketSlot);
```

**`src/server/game/Scripting/ScriptMgr.cpp`** — add dispatcher (with other Player dispatchers):

```cpp
void ScriptMgr::OnPlayerSocketGem(Player* player, Item* gearItem, Item* gemItem, uint8 socketSlot)
{
    ExecuteScript<PlayerScript>([&](PlayerScript* script)
    {
        script->OnSocketGem(player, gearItem, gemItem, socketSlot);
    });
}
```
