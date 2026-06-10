# Imprint System — Backlog

Recorded after completing the first four Imprints (Sanctuary Storm, Empyrean Echo,
Feral Spirit: Stampede, Feral Spirit: Alpha). Everything here needs to be implemented
before the next batch of Imprint abilities are created.

Items are roughly ordered by dependency — earlier items unblock later ones.

---

## 1. Separate Rune Items per Imprint

**Current state:** All Imprints share `rune_item_id = 601001` (a single generic rune).

**Required change:**
- Create a distinct `item_template` entry for each Imprint (e.g. 601101-rune, 601102-rune …
  or a clean dedicated range like 602001–602099).
- Update `imprint_def.rune_item_id` for each row to point to the correct item.
- Item properties:
  - `Quality` = Rare (blue) or Epic — visually matches the power level.
  - `ItemLevel` appropriate to WotLK 80 content.
  - `class` = 12 (Quest) **or** 9 (Recipe) — specifically NOT 7 (Trade Goods) so it
    doesn't accidentally vendor or stack with trade-good logic.
  - `maxcount = 0` (unlimited copies in inventory — each is a different item anyway).
  - `unique_equipped = 0` (not unique-equipped; you may carry spares).
  - **No** `ITEM_FLAG_HAS_LOOT` (was the bug that caused the "right-click opens loot
    window" problem; `Flags` must be 0).
  - Description line must show extractions remaining (see §3 below).

**Stacking decision:** Do **not** stack. Each rune is a different item (different entry ID)
so they cannot stack by default. No `stackable` override needed.

---

## 2. Imprints as Possible Class-Affix Rolls

**Goal:** During the class-affix roll flow a player may receive an Imprint option
alongside normal spell-mod affixes. Choosing an Imprint does **not** consume an
affix slot — it fills the dedicated Imprint slot instead.

### Roll rules
- An Imprint option may only appear when the item has no Imprint already
  (neither rolled nor manually applied).
- Once the Imprint slot is filled (any source), the Imprint option is permanently
  excluded from future rolls on that item.
- An Imprint option counts as one of the N roll options the player sees (e.g. 3 options
  could be 2 spell-mod affixes + 1 Imprint).
- Choosing a non-Imprint option does NOT fill the Imprint slot; the player keeps the
  option to apply one manually later.

### Implementation notes
- `ItemAffixMgr::HandleRollRequest` needs a new code path:
  randomly decide whether to include an Imprint candidate in the option list.
- Eligibility: `imprint_def.class_mask` must match the player's class (or be 0).
  Once class-mask enforcement is in place (see §7), the candidate must also be
  from the player's dominant talent tree.
- When the player picks an Imprint option (`HandlePickOption`):
  - Call `sImprintMgr->ApplyImprintFromRoll(player, item, imprintId)` — no rune
    consumed and no rune granted; the Imprint is applied directly to the item.

---

## 3. Extraction Count Display on Items

**Goal:** Players can see how many times they can still extract the Imprint from an item.

### On the rune item
- Use the item's `description` field (visible at the bottom of the tooltip) to show
  e.g. *"Extractions remaining: 2"*.
- Because the count decrements, we either:
  a. **Preferred:** Update the item's tooltip via the addon (add `IMPRINT_EXTRACTIONS`
     line in the AFXM message protocol alongside the existing AFFIX/TALENT lines).
  b. Alternatively, encode the count in `item_text` or a custom enchant — but the
     addon approach is cleaner and already has the infrastructure.

### On equipped gear
- The affix addon tooltip already shows AFFIX and TALENT lines; add an IMPRINT line
  showing the Imprint name + extractions left, e.g.:
  `[Imprint: Feral Spirit: Alpha — 2 extractions remaining]`

---

## 4. Imprint Destroy Spell (Extraction)

**Goal:** A general-purpose spell available to all players in their spellbook that lets
them destroy an item (equipped or in bags) to receive its Imprint rune — IF extractions
remain.

### Behaviour
1. Player casts the spell (or uses a UI button — see §5 for addon integration).
2. A targeting cursor appears; player clicks an equippable item (bag or equipped).
3. Server checks:
   - Item has an Imprint.
   - `extractionsLeft > 0`.
   - If yes: remove Imprint from item, decrement `extractions_left`, grant the
     corresponding rune item to player's bags. Send success message.
   - If no extractions left: show warning message
     *"[Item name] has no extractions remaining. Destroying it will only destroy
     the weapon — no Imprint Rune will be received. Continue?"*
     (Requires a confirmation step; could be a second click or a chat confirmation.)
   - If item has no Imprint: show error *"This item carries no Imprint."*

### Implementation options
- **Option A (simple):** GM-style `.imprint extract <slot>` command extended with
  a player-usable confirmation flow. Already partially implemented.
- **Option B (ideal):** A custom spell with `SPELL_EFFECT_SCRIPT_EFFECT` that opens
  an item-selection interface; handled in a SpellScript.
  The actual extraction logic is already in `ImprintMgr::ExtractImprint`.

---

## 5. Improved Imprint Application (Right-Click Flow)

**Current state:** `.imprint apply mainhand` command only.

**Goal:** Right-click an Imprint Rune → cursor changes → click target equippable item
to apply.

### Rules
- Target must be an equippable item (bag item or equipped slot).
- **Duplicate-equipped guard:** If the Imprint is already active on another **equipped**
  item, block the application and warn the player.
  Exception: if the target item is currently in the player's **bags** (not equipped),
  allow it anyway — the player may be preparing the item to swap in later.
- **Overwrite guard:** If the target already has a different Imprint, warn:
  *"This item already has [Imprint name]. Applying [new Imprint name] will destroy
  the existing Imprint. Any extractions on the old Imprint will be lost."*
  Require confirmation before proceeding (similar to gem-overwrite behaviour).
- Consume the Rune item from bags on success.

### Implementation notes
- The Rune item needs `spellid_1` set to a custom "apply imprint" spell with
  `SPELL_EFFECT_SCRIPT_EFFECT`.
- The SpellScript identifies which Imprint the rune represents (via the item's entry
  matched to `imprint_def.rune_item_id`) and calls `sImprintMgr->ApplyImprint`.
- The item-click targeting could reuse the existing gem-socket UI flow or be
  handled as an item-on-item interaction.

---

## 6. Imprint Inspect via Addon Tooltip

**Current state:** `.imprint inspect` command only.

**Goal:** The Imprint name (and extractions remaining) appears directly in the item
tooltip, integrated with the existing `ItemAffixes` addon.

**Addon location:** `E:\servers\Wow\WoW HD\interface\addons\ItemAffixes`

### Server side
- Extend the AFXM message sent in `ItemAffixMgr::SendItemStatus` to include an
  `IMPRINT` field:  
  `IMPRINT:<imprintName>:<extractionsLeft>`
- If the item has no Imprint, omit the field or send `IMPRINT:none`.

### Addon side
- Parse the `IMPRINT` token in the existing message handler.
- Add a line to the tooltip renderer:
  `|cFF00CCFF[Imprint: Feral Spirit: Alpha — 2 extractions]|r`
  (or similar colour/format consistent with existing affix lines).

---

## 7. Ability Tooltip Updates (spell_dbc description overrides)

**Goal:** Spells modified by an Imprint show the new description, not the original
Blizzard text, so players understand what they actually do.

### Examples
| Imprint | Spell | Original text | New text |
|---|---|---|---|
| Sanctuary Storm | Divine Storm | "Unleashes a whirlwind of divine energy…" | "Calls down a righteous storm — 2× damage, 2 s cast time, leaves a free Consecration." |
| Empyrean Echo | Divine Storm | same | "Divine Storm echoes from 4 positions around you 0.5 s later." |
| Feral Spirit: Stampede | Feral Spirit | "Summons two Spirit Wolves…" | "Calls a stampede of 10 Spirit Rhinos to your side for 30 sec." |
| Feral Spirit: Alpha | Feral Spirit | "Summons two Spirit Wolves…" | "Summons an Alpha Spirit Wolf as your permanent companion." |

### Implementation
- The description shown in the spellbook tooltip comes from the spell's DBC data.
- Override per-character at display time via the **addon**: intercept the
  `GameTooltip:SetSpell` event and replace the description line when the player
  has the relevant Imprint equipped.
- Server side: when `SendItemStatus` (or a new `SendImprint` message) is sent,
  also push the spell ID → description override so the addon knows what to show.
- Alternatively use `spell_dbc` overrides (world DB) for global description changes —
  simpler but affects all players regardless of Imprint state.

**Recommended approach:** Addon-side per-player override, driven by the equipped-Imprint
data the server already sends.

---

## 8. Class Affixes Respect Talent Tree

**Current state:** Class affix rolls pull from any spell in the player's class, ignoring
which talent tree the player is specced into.

**Goal:** A class affix can only roll if its associated spell lives in the player's
dominant talent tree.

### Logic
- `TalentAffixDef` already has a `specTree` field (0/1/2 or -1 for any).
- `ItemAffixMgr::GetEligibleTalentAffix` already accepts a `specOverride` parameter.
- **Gap:** The dominant tree is not always being passed correctly; and the pool of
  eligible class affixes needs `specTree` populated for every definition row.

### Required work
- Populate `talent_affix_def.specTree` for all existing rows (currently many are -1).
  Map each spell to its talent tree:
  - Look at which tab the spell appears on in the talent UI (tab 0/1/2 maps to tree).
  - Cross-reference `TalentTab.dbc` to confirm tree indices per class.
- Ensure `GetEligibleTalentAffix` correctly uses the player's dominant tree when
  `specOverride = -1`.
- Test edge cases: dual-spec, no talents allocated, pure class skills that appear in
  multiple trees (should use `specTree = -1`).

### Example (Shaman)
| Spell | Tree | specTree |
|---|---|---|
| Feral Spirit | Enhancement (1) | 1 |
| Heroism | Enhancement (1) | 1 |
| Tremor Totem | Restoration (2) | 2 |
| Chain Lightning | Elemental (0) | 0 |
| Healing Wave | Restoration (2) | 2 |

---

## 9. Roll Option Visual Tiering (Addon)

**Goal:** Each roll option in the selection UI conveys its rarity tier visually so the
player instantly knows the value of what they are choosing.

| Tier | Trigger condition | Visual |
|---|---|---|
| 1 — Normal | Standard roll | Plain icon, white/green text `|cffffffff` / `|cff00ff00` |
| 2 — Rare | Double modifier (2 effects) | Static glowing border, rare-blue tint `|cff0070dd` |
| 3 — Crit | Any stat boosted +50% (`isCrit = true` from server) | Pulsing alpha glow animation (AnimationGroup, BOUNCE) |
| 4 — Imprint | Option IS an Imprint roll | Full golden proc glow: `ActionButton_ShowOverlayGlow(frame)` |

### Server side
- `PendingOpt.isCrit` already exists and is sent in the OPTS message.
- Add a `isImprint bool` field to `PendingOpt` (or encode it as a special `affixId`
  range / prefix in the OPTS string) so the addon knows which option is an Imprint.
- Tier 2 (double modifier): the addon can detect this from the number of stat lines
  in the option text, OR the server can set a `isDouble bool` in `PendingOpt`.

### Addon side (ItemAffixes addon)
Location: `E:\servers\Wow\WoW HD\interface\addons\ItemAffixes`

**Tier 2 static border:**
```lua
local rareBorder = optionFrame:CreateTexture(nil, "OVERLAY")
rareBorder:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
rareBorder:SetBlendMode("ADD")
rareBorder:SetVertexColor(0, 0.44, 0.87)  -- rare blue
rareBorder:SetAllPoints(optionFrame)
```

**Tier 3 crit pulse:**
```lua
local animGroup = optionFrame:CreateAnimationGroup()
local pulse = animGroup:CreateAnimation("Alpha")
pulse:SetFromAlpha(0.3)
pulse:SetToAlpha(1.0)
pulse:SetDuration(0.8)
pulse:SetSmoothing("IN_OUT")
animGroup:SetLooping("BOUNCE")
animGroup:Play()
```

**Tier 4 Imprint golden glow:**
```lua
ActionButton_ShowOverlayGlow(optionFrame)
```

---

## 10. Configurable Max Equipped Imprints

**Goal:** Server admin sets a cap on how many Imprint-bearing items a player may have
equipped simultaneously. Default 1 (current behaviour). Raising it unlocks multi-Imprint
builds.

**Config key (proposed):** `ItemAffixes.MaxEquippedImprints = 1` in `mod_item_affixes.conf`

**Enforcement — three distinct points:**

1. **Applying to a bag item** → no cap check. The player is preparing the item;
   they may swap out another imprinted item before equipping it. Always allowed.

2. **Applying to an already-equipped item** → check: would this exceed the cap?
   Count equipped items that already carry any Imprint. If count >= cap, block:
   *"You already have [N] Imprint(s) equipped. The current limit is [cap]."*

3. **Equipping an item that already has an imprint** → check at equip time
   (hook `OnPlayerEquip`): if equipping this item would push the equipped-imprint
   count over the cap, block the equip and notify the player. This is the primary
   enforcement point — mirrors how WoW unique-equipped items work.

- The duplicate-equipped guard from §5 (same Imprint cannot be active twice) is
  a separate rule that still applies at any cap level.

---

## Implementation order (suggested)

1. §1 — Separate rune items (prerequisite for everything involving runes)
2. §8 — Talent tree enforcement for class affixes (standalone, low risk)
3. §7 — Tooltip overrides via addon (standalone, purely addon-side)
4. §9 — Roll option visual tiering in addon (standalone, purely addon-side)
5. §3 — Extraction count display (depends on §1 for rune items)
6. §4 — Destroy/Extract spell (depends on §1, §3)
7. §5 — Right-click apply flow (depends on §1; references §4 confirmation logic)
8. §6 — Addon inspect integration (depends on §3 server message)
9. §2 — Imprints as affix rolls (depends on §1, §5, §8, §9)
