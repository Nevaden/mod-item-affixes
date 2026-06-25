#include "ItemAffix.h"
#include "Imprints/ImprintMgr.h"
#include "GameTime.h"
#include "CellImpl.h"
#include "GridNotifiers.h"
#include "GridNotifiersImpl.h"
#include "Item.h"
#include "ItemTemplate.h"
#include "Log.h"
#include "ObjectAccessor.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "SpellAuraEffects.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "SpellScript.h"
#include "TemporarySummon.h"

// ============================================================================
// WorldScript — template loading
// ============================================================================

class ItemAffixWorldScript : public WorldScript
{
public:
    ItemAffixWorldScript() : WorldScript("ItemAffixWorldScript", {
        WORLDHOOK_ON_BEFORE_WORLD_INITIALIZED,
    }) {}

    void OnBeforeWorldInitialized() override
    {
        sItemAffixMgr->LoadAffixTemplates();
        sImprintMgr->LoadConfig();
        sImprintMgr->LoadDefs();

        // Arcane Missiles trigger spells have SPELL_ATTR3_IGNORE_CASTER_MODIFIERS set in the
        // binary DBC, which silently blocks all SpellMods (op != DURATION) before family-flag
        // matching even runs. This hook fires after LoadSpellInfoCorrections(), so the
        // const_cast patch applies on top of — not before — AzerothCore's own corrections.
        static constexpr uint32 arcaneMissileTriggers[] = { 7268, 7269, 7270, 25346, 27076, 38700, 42844 };
        for (uint32 spellId : arcaneMissileTriggers)
        {
            if (SpellInfo const* si = sSpellMgr->GetSpellInfo(spellId))
            {
                SpellInfo* msi = const_cast<SpellInfo*>(si);
                msi->AttributesEx3 &= ~uint32(SPELL_ATTR3_IGNORE_CASTER_MODIFIERS);
                msi->SpellFamilyName = SPELLFAMILY_MAGE;
                msi->SpellFamilyFlags[0] = 0x800; // matches channel spell 5143
            }
        }
    }
};

// ============================================================================
// PlayerScript — affix slot init, apply, remove, addon messaging
// ============================================================================

class ItemAffixPlayerScript : public PlayerScript
{
public:
    ItemAffixPlayerScript() : PlayerScript("ItemAffixPlayerScript", {
        PLAYERHOOK_ON_LOGIN,
        PLAYERHOOK_ON_BEFORE_LOGOUT,
        PLAYERHOOK_ON_STORE_NEW_ITEM,
        PLAYERHOOK_ON_AFTER_STORE_OR_EQUIP_NEW_ITEM,
        PLAYERHOOK_ON_EQUIP,
        PLAYERHOOK_ON_UNEQUIP_ITEM,
        PLAYERHOOK_ON_BEFORE_SEND_CHAT_MESSAGE,
    }) {}

    void OnPlayerLogin(Player* player) override
    {
        sItemAffixMgr->ClearLegacyEnchants(player);
        sItemAffixMgr->UpgradeAll2HSlots(player);
        sItemAffixMgr->ReapplyAllEquipped(player);
        sItemAffixMgr->SendConfig(player);
        // Reapply Imprints for all currently equipped items
        for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
        {
            Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
            if (item)
                sImprintMgr->OnItemEquipped(player, item);
        }
        sImprintMgr->SendImprintDescriptions(player);
    }

    void OnPlayerBeforeLogout(Player* player) override
    {
        sItemAffixMgr->ClearPendingReroll(player->GetGUID().GetRawValue());
        sItemAffixMgr->RemoveAllActiveMods(player);
        // Remove Imprint mods for all equipped items
        for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
        {
            Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
            if (item)
                sImprintMgr->OnItemUnequipped(player, item);
        }
    }

    void OnPlayerStoreNewItem(Player* player, Item* item, uint32 /*count*/) override
    {
        sItemAffixMgr->InitItemSlots(player, item);
    }

    void OnPlayerAfterStoreOrEquipNewItem(Player* player, uint32 /*vendorslot*/, Item* item,
        uint8 /*count*/, uint8 /*bag*/, uint8 /*slot*/, ItemTemplate const* /*proto*/,
        Creature* /*vendor*/, VendorItem const* /*crItem*/, bool /*bStore*/) override
    {
        sItemAffixMgr->InitItemSlots(player, item);
    }

    void OnPlayerEquip(Player* player, Item* it, uint8 /*bag*/, uint8 /*slot*/, bool /*update*/) override
    {
        sItemAffixMgr->SyncAffixes(player);
        if (it)
            sItemAffixMgr->SendItemStatus(player, it);
        sImprintMgr->SyncImprints(player);
    }

    void OnPlayerUnequip(Player* player, Item* it) override
    {
        // Pass the item GUID so Phase 1 skips it — the hook fires before the slot vacates,
        // so without the exclusion Phase 2 would immediately re-apply the variant we just removed.
        sItemAffixMgr->SyncAffixes(player, it ? it->GetGUID() : ObjectGuid::Empty);
        sImprintMgr->SyncImprints(player);
    }

    // Intercept AFXM addon messages sent as LANG_ADDON whispers from the client.
    void OnPlayerBeforeSendChatMessage(Player* player, uint32& type, uint32& lang,
                                       std::string& msg) override
    {
        if (lang != LANG_ADDON)
            return;
        if (msg.size() < 5 || msg.compare(0, 4, "AFXM") != 0)
            return;

        sItemAffixMgr->HandleAddonMessage(player, msg.substr(5));
        type = 0;  // suppress whisper delivery
    }
};

// ============================================================================
// SpellScripts — route casts to ImprintMgr for each imprint-bearing spell
// ============================================================================

class spell_divine_storm_imprint : public SpellScript
{
    PrepareSpellScript(spell_divine_storm_imprint);

    void HandleAfterCast()
    {
        Player* caster = GetCaster()->ToPlayer();
        if (!caster)
            return;
        sImprintMgr->OnSpellAfterCast(caster, GetSpellInfo());
    }

    void Register() override
    {
        AfterCast += SpellCastFn(spell_divine_storm_imprint::HandleAfterCast);
    }
};

class spell_feral_spirit_imprint : public SpellScript
{
    PrepareSpellScript(spell_feral_spirit_imprint);

    void HandleAfterCast()
    {
        Player* caster = GetCaster()->ToPlayer();
        if (!caster)
            return;
        sImprintMgr->OnSpellAfterCast(caster, GetSpellInfo());
    }

    void Register() override
    {
        AfterCast += SpellCastFn(spell_feral_spirit_imprint::HandleAfterCast);
    }
};

class spell_summon_water_elemental_imprint : public SpellScript
{
    PrepareSpellScript(spell_summon_water_elemental_imprint);

    void HandleAfterCast()
    {
        Player* caster = GetCaster()->ToPlayer();
        if (!caster)
            return;
        sImprintMgr->OnSpellAfterCast(caster, GetSpellInfo());
    }

    void Register() override
    {
        AfterCast += SpellCastFn(spell_summon_water_elemental_imprint::HandleAfterCast);
    }
};

class spell_hammer_righteous_imprint : public SpellScript
{
    PrepareSpellScript(spell_hammer_righteous_imprint);

    void HandleAfterCast()
    {
        Player* caster = GetCaster()->ToPlayer();
        if (!caster)
            return;
        sImprintMgr->OnSpellAfterCast(caster, GetSpellInfo());
    }

    void Register() override
    {
        AfterCast += SpellCastFn(spell_hammer_righteous_imprint::HandleAfterCast);
    }
};

// Druid: Mangle cat + bear (all ranks via spell_ranks) — Apex Mangle
class spell_mangle_imprint : public SpellScript
{
    PrepareSpellScript(spell_mangle_imprint);

    void HandleAfterCast()
    {
        Player* caster = GetCaster()->ToPlayer();
        if (!caster)
            return;
        sImprintMgr->OnSpellAfterCast(caster, GetSpellInfo());
    }

    void Register() override
    {
        AfterCast += SpellCastFn(spell_mangle_imprint::HandleAfterCast);
    }
};

// Druid: Tiger's Fury (all ranks via spell_ranks) — Ancient Tiger
class spell_tigers_fury_imprint : public SpellScript
{
    PrepareSpellScript(spell_tigers_fury_imprint);

    void HandleAfterCast()
    {
        Player* caster = GetCaster()->ToPlayer();
        if (!caster)
            return;
        sImprintMgr->OnSpellAfterCast(caster, GetSpellInfo());
    }

    void Register() override
    {
        AfterCast += SpellCastFn(spell_tigers_fury_imprint::HandleAfterCast);
    }
};

// ============================================================================
// AuraScript — Celestial Resonance (spell 600002)
// Fires every 1 s while the aura is active on a target.  Spawns an invisible
// beacon creature at the target's CURRENT position (so it tracks a moving
// enemy) and has it cast Holy Nova rank 9 attributed to the original caster.
// ============================================================================

static constexpr uint32 SPELL_CELESTIAL_RESONANCE  = 600002;
static constexpr uint32 SPELL_HOLY_NOVA_R9         = 48078;
static constexpr uint32 CREATURE_HOLY_NOVA_BEACON  = 601105;

class spell_celestial_resonance : public AuraScript
{
    PrepareAuraScript(spell_celestial_resonance);

    void HandlePeriodic(AuraEffect const* /*aurEff*/)
    {
        Unit* target = GetTarget();
        if (!target)
            return;

        // Identify the casting player.
        Unit* casterUnit = GetCaster();
        Player* player = casterUnit ? casterUnit->ToPlayer() : nullptr;
        if (!player)
            return;

        // Abort silently if the rune has been unequipped mid-duration.
        if (!sImprintMgr->HasImprintEquipped(player, IMPRINT_CELESTIAL_RESONANCE))
            return;

        // Spawn a 500 ms trigger at the target's current position.
        // The target may have moved since the aura was applied — this is intentional.
        TempSummon* beacon = player->SummonCreature(
            CREATURE_HOLY_NOVA_BEACON,
            target->GetPositionX(),
            target->GetPositionY(),
            target->GetPositionZ(),
            0.0f,
            TEMPSUMMON_TIMED_DESPAWN, 500);

        if (!beacon)
            return;

        beacon->SetFaction(player->GetFaction());

        // Cast Holy Nova from the beacon's position.
        // Player GUID as originalCaster → damage/healing attributed to the player,
        // not the invisible creature.
        // Creature (not Player) caster → ToPlayer() guard in other SpellScripts is safe.
        beacon->CastSpell(beacon, SPELL_HOLY_NOVA_R9,
            TriggerCastFlags(TRIGGERED_FULL_MASK),
            nullptr, nullptr, player->GetGUID());

        LOG_DEBUG("module",
            "mod-item-affixes: CelestialResonance tick — beacon cast Holy Nova for {}",
            player->GetName());
    }

    void Register() override
    {
        OnEffectPeriodic += AuraEffectPeriodicFn(
            spell_celestial_resonance::HandlePeriodic, EFFECT_0, SPELL_AURA_PERIODIC_DUMMY);
    }
};

// Intercepts the Disenchant spell (13262) to grant the Imprint rune when
// an item with an Imprint is disenchanted.  The item is destroyed before
// AfterCast fires, so we capture the GUID during OnCast.
class spell_disenchant_imprint : public SpellScript
{
    PrepareSpellScript(spell_disenchant_imprint);

    uint64 _targetGuid = 0;

    void CaptureTarget()
    {
        if (Item* target = GetExplTargetItem())
            _targetGuid = target->GetGUID().GetRawValue();
    }

    void HandleAfterCast()
    {
        if (!_targetGuid)
            return;
        Player* caster = GetCaster()->ToPlayer();
        if (!caster)
            return;
        sImprintMgr->OnItemDisenchanted(caster, _targetGuid);
    }

    void Register() override
    {
        OnCast += SpellCastFn(spell_disenchant_imprint::CaptureTarget);
        AfterCast += SpellCastFn(spell_disenchant_imprint::HandleAfterCast);
    }
};

// ============================================================================
// Vanishing Backstab — spell 600003
// Shadowsteps behind the target (without consuming the cooldown), then fires
// Backstab via a deferred event.
//
// WHY deferred:
//   For players, NearTeleportTo → Player::TeleportTo, which commits the
//   server-side position only after the client acks the teleport packet. If
//   Backstab fires inline the range check (Spell.cpp:5993, unconditional even
//   for TRIGGERED_FULL_MASK) still sees the pre-Shadowstep distance and returns
//   SPELL_FAILED_OUT_OF_RANGE. A 250ms delay covers the client round-trip.
//
// WHY SetOrientation:
//   The behind-target arc check (Spell.cpp:5851) is also unconditional. We
//   orient the target to face directly away from the player so the check always
//   passes, regardless of how the mob turned during the delay.
// ============================================================================

static constexpr uint32 SPELL_VANISHING_BACKSTAB_ID = 600003;
static constexpr uint32 SPELL_SHADOWSTEP_ID          = 36554;
static constexpr uint32 SPELL_BACKSTAB_CHAIN_START   = 53;

struct VanishingBackstabEvent : public BasicEvent
{
    ObjectGuid _playerGuid;
    ObjectGuid _targetGuid;

    VanishingBackstabEvent(ObjectGuid playerGuid, ObjectGuid targetGuid)
        : _playerGuid(playerGuid), _targetGuid(targetGuid) {}

    bool Execute(uint64 /*e_time*/, uint32 /*p_time*/) override
    {
        Player* player = ObjectAccessor::FindPlayer(_playerGuid);
        if (!player || !player->IsAlive())
            return true;

        // Use stored GUID (captured at cast time from player's selected target).
        Unit* target = ObjectAccessor::GetUnit(*player, _targetGuid);
        if (!target || !target->IsAlive())
            return true;

        uint32 backstabId = SPELL_BACKSTAB_CHAIN_START;
        for (uint32 next = sSpellMgr->GetNextSpellInChain(backstabId);
             next && player->HasSpell(next);
             next = sSpellMgr->GetNextSpellInChain(backstabId))
            backstabId = next;

        if (!player->HasSpell(backstabId))
            return true;

        LOG_DEBUG("scripts", "VanishingBackstab::Execute - casting Backstab {}", backstabId);
        // Orient target away so the unconditional behind-arc check (Spell.cpp:5851) passes.
        target->SetOrientation(target->GetAngle(player) + float(M_PI));
        player->CastSpell(target, backstabId, TRIGGERED_FULL_MASK);
        return true;
    }
};

static constexpr float SHADOWSTEP_MAX_RANGE = 25.0f;

class spell_vanishing_backstab : public SpellScript
{
    PrepareSpellScript(spell_vanishing_backstab);

    // Enforce Shadowstep's 25-yard range so the button gives "Out of Range"
    // feedback instead of firing and silently doing nothing.  The trigger spell
    // is self-cast (no unit target in DBC) to avoid calling EngageWithTarget,
    // so the client cannot gray the button by range — this hook fills that gap.
    SpellCastResult CheckRange()
    {
        Player* caster = GetCaster()->ToPlayer();
        if (!caster)
            return SPELL_FAILED_DONT_REPORT;

        Unit* target = ObjectAccessor::GetUnit(*caster, caster->GetTarget());
        if (!target || !target->IsAlive())
            return SPELL_FAILED_BAD_TARGETS;

        if (!caster->IsWithinDistInMap(target, SHADOWSTEP_MAX_RANGE))
            return SPELL_FAILED_OUT_OF_RANGE;

        return SPELL_CAST_OK;
    }

    void HandleAfterCast()
    {
        Player* caster = GetCaster()->ToPlayer();
        if (!caster)
            return;

        if (!sImprintMgr->HasImprintEquipped(caster, IMPRINT_VANISHING_BACKSTAB))
            return;

        // Spell is self-cast; read the player's selected target directly so the
        // trigger spell never touches the enemy and cannot call EngageWithTarget.
        Unit* target = ObjectAccessor::GetUnit(*caster, caster->GetTarget());
        if (!target || !target->IsAlive())
            return;

        LOG_DEBUG("scripts", "VanishingBackstab::HandleAfterCast - caster={} target={}",
            caster->GetGUID().ToString(), target->GetGUID().ToString());

        caster->CastSpell(target, SPELL_SHADOWSTEP_ID, TRIGGERED_FULL_MASK);

        // Defer Backstab so the player's server-side position (committed on client ack
        // of the Shadowstep teleport) is in melee range when CheckRange fires.
        caster->m_Events.AddEventAtOffset(
            new VanishingBackstabEvent(caster->GetGUID(), target->GetGUID()),
            Milliseconds(250));
    }

    void Register() override
    {
        OnCheckCast += SpellCheckCastFn(spell_vanishing_backstab::CheckRange);
        AfterCast += SpellCastFn(spell_vanishing_backstab::HandleAfterCast);
    }
};

// ============================================================================
// UnitScript — incoming damage reduction from GSTAT_DAMAGE_REDUCTION_PCT affixes
// ============================================================================

class ItemAffixUnitScript : public UnitScript
{
public:
    ItemAffixUnitScript() : UnitScript("ItemAffixUnitScript", true, {
        UNITHOOK_MODIFY_MELEE_DAMAGE,
        UNITHOOK_MODIFY_SPELL_DAMAGE_TAKEN,
    }) {}

    void ModifyMeleeDamage(Unit* target, Unit* attacker, uint32& damage) override
    {
        // Player damage reduction
        if (target && target->IsPlayer())
        {
            int32 pct = std::min(sItemAffixMgr->GetDamageReductionPct(target->GetGUID().GetRawValue()), 75);
            if (pct > 0)
                damage = damage * uint32(100 - pct) / 100;
        }
        // Pet damage reduction (target is a player-owned pet)
        if (target && !target->IsPlayer() && target->GetOwnerGUID().IsPlayer())
        {
            int32 pct = std::min(sItemAffixMgr->GetPetDmgRedPct(target->GetOwnerGUID().GetRawValue()), 75);
            if (pct > 0)
                damage = damage * uint32(100 - pct) / 100;
        }
        // Pet damage boost (attacker is a player-owned pet)
        if (attacker && !attacker->IsPlayer() && attacker->GetOwnerGUID().IsPlayer())
        {
            int32 pct = sItemAffixMgr->GetPetDamagePct(attacker->GetOwnerGUID().GetRawValue());
            if (pct > 0)
                damage = damage * uint32(100 + pct) / 100;
        }
    }

    void ModifySpellDamageTaken(Unit* target, Unit* attacker, int32& damage, SpellInfo const* /*spellInfo*/) override
    {
        // Player damage reduction
        if (target && target->IsPlayer())
        {
            int32 pct = std::min(sItemAffixMgr->GetDamageReductionPct(target->GetGUID().GetRawValue()), 75);
            if (pct > 0)
                damage = damage * (100 - pct) / 100;
        }
        // Pet damage reduction (target is a player-owned pet)
        if (target && !target->IsPlayer() && target->GetOwnerGUID().IsPlayer())
        {
            int32 pct = std::min(sItemAffixMgr->GetPetDmgRedPct(target->GetOwnerGUID().GetRawValue()), 75);
            if (pct > 0)
                damage = damage * (100 - pct) / 100;
        }
        // Pet spell damage boost (attacker is a player-owned pet — e.g., Imp Firebolt)
        if (attacker && !attacker->IsPlayer() && attacker->GetOwnerGUID().IsPlayer())
        {
            int32 pct = sItemAffixMgr->GetPetDamagePct(attacker->GetOwnerGUID().GetRawValue());
            if (pct > 0)
                damage = damage * (100 + pct) / 100;
        }
    }
};

// ============================================================================
// AllCreatureScript — apply pet stat buffs when a player's pet enters the world
// ============================================================================

class ItemAffixPetScript : public AllCreatureScript
{
public:
    ItemAffixPetScript() : AllCreatureScript("ItemAffixPetScript") {}

    void OnCreatureAddWorld(Creature* creature) override
    {
        if (!creature || !creature->GetOwnerGUID().IsPlayer())
            return;
        Unit* owner = creature->GetOwner();
        if (!owner || !owner->IsPlayer())
            return;
        sItemAffixMgr->ApplyBuffsToPet(creature, owner->ToPlayer());
    }

    void OnAllCreatureUpdate(Creature* creature, uint32 diff) override
    {
        if (!creature->GetOwnerGUID().IsPlayer()) return;
        int32 pct = sItemAffixMgr->GetPetCooldownPct(creature->GetOwnerGUID().GetRawValue());
        if (pct <= 0) return;

        uint32 extraMs = uint32(diff) * uint32(pct) / 100;
        if (extraMs == 0) return;

        uint32 now = uint32(GameTime::GetGameTimeMS().count());
        for (auto& [spellId, cooldown] : creature->m_CreatureSpellCooldowns)
        {
            if (cooldown.end > now)
                cooldown.end = (cooldown.end > now + extraMs) ? (cooldown.end - extraMs) : now;
        }
    }
};

// ============================================================================
// Registration
// ============================================================================

void AddSC_item_affix_scripts()
{
    new ItemAffixWorldScript();
    new ItemAffixPlayerScript();
    new ItemAffixUnitScript();
    new ItemAffixPetScript();
    RegisterSpellScript(spell_divine_storm_imprint);
    RegisterSpellScript(spell_feral_spirit_imprint);
    RegisterSpellScript(spell_summon_water_elemental_imprint);
    RegisterSpellScript(spell_hammer_righteous_imprint);
    RegisterSpellScript(spell_mangle_imprint);
    RegisterSpellScript(spell_tigers_fury_imprint);
    RegisterSpellScript(spell_disenchant_imprint);
    RegisterSpellScript(spell_celestial_resonance);
    RegisterSpellScript(spell_vanishing_backstab);
}
