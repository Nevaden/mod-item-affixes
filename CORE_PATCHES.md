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

## Patch 3 — `Unit::DealDamage` counts player-owned summon damage as player damage

**File:** `src/server/game/Entities/Unit/Unit.cpp`
**Applied by:** `scripts/apply_core_patches.ps1`

`damagedByPlayer` (which gates loot and XP eligibility) was only set for
players, vehicles moved by players, and charmed units — player-owned
`TempSummons` (`SetOwnerGUID`) were excluded, so a summon soloing a kill
granted no loot or XP to the owning player. Adds `attacker->GetOwnerGUID().IsPlayer()`
to the eligibility check.

---

## Patch 4 — `Unit::EngageWithTarget` taps the mob for loot when a player-owned summon engages

**File:** `src/server/game/Entities/Unit/Unit.cpp`
**Applied by:** `scripts/apply_core_patches.ps1`

The tap-on-aggro block only ran for `IsPlayer()`, so a player-owned summon
initiating combat never set the mob's loot recipient. Adds
`IsControlledByPlayer()` to the check.

---

## Patch 6 — `OnPlayerBeforeQuestReward` hook

Fires a ScriptMgr event at the very top of `Player::RewardQuest`, before
either reward-item loop runs, so a module's `OnPlayerStoreNewItem`/
`OnPlayerAfterStoreOrEquipNewItem` handler can tell a quest-reward item
apart from any other newly-stored item. This module uses it for
`ItemAffixes.D3ExcludeQuestRewards`.

**Deliberately not the same as the native `OnPlayerBeforeQuestComplete`
hook** — that one fires from `Player::CompleteQuest`, a separate, often
much earlier step (the "complete quest" dialog) than `RewardQuest` (the
"pick a reward" step where items actually get stored) for any
non-auto-rewarded quest. Substituting `OnPlayerBeforeQuestComplete` here
sets/clears the exclusion flag around the wrong window entirely — it's a
real hook with a similar name and similar timing description, but not an
equivalent one for this purpose.

### 6a — Enum value (`PlayerScript.h`)
**Applied by:** `scripts/apply_core_patches.ps1` — adds `PLAYERHOOK_ON_BEFORE_QUEST_REWARD` after `PLAYERHOOK_ON_SOCKET_GEM`.

### 6b — Virtual method (`PlayerScript.h`)
**Applied by:** `scripts/apply_core_patches.ps1` — adds `virtual void OnPlayerBeforeQuestReward(...)` after `OnPlayerSocketGem`.

### 6c — Dispatcher (`PlayerScript.cpp`)
**Applied by:** `scripts/apply_core_patches.ps1` — adds `ScriptMgr::OnPlayerBeforeQuestReward` dispatcher at the bottom of the file.

### 6d — ScriptMgr declaration (`ScriptMgr.h`)
**Applied by:** `scripts/apply_core_patches.ps1` — adds `void OnPlayerBeforeQuestReward(...)` declaration inside the `ScriptMgr` class.

### 6e — Call site (`PlayerQuest.cpp`)
**Applied by:** `scripts/apply_core_patches.ps1`

Calls `sScriptMgr->OnPlayerBeforeQuestReward(this, quest)` at the very top of `Player::RewardQuest`, before `SetMustDelayTeleport` and both reward-item loops.

---

## Patch 5 — `ChatHandler` addon-message suppression-sentinel log spam

**File:** `src/server/game/Handlers/ChatHandler.cpp`
**Applied by:** `scripts/apply_core_patches.ps1`

This module (and potentially others) intercepts `LANG_ADDON` chat messages via
`OnPlayerBeforeSendChatMessage` and sets `type = 0` as a "message handled,
suppress delivery" sentinel after consuming the message server-side (see
`ItemAffixScripts.cpp`). Without this patch, that sentinel falls through to
the dispatch switch's `default` case and logs a spurious
`CHAT: unknown message type 0, lang: 4294967295` error on every single
addon-message exchange — which in practice means every tooltip fetch, every
roll, every imprint action, etc. This patch adds an early return immediately
after the `OnPlayerBeforeSendChatMessage` call to catch the sentinel cleanly.

---

## After applying patches

Rebuild the worldserver. See README.md → **Step 4: Build** for the command.
