-- Celestial Resonance — custom Priest aura spell (ID 600002).
-- Applied to any unit; ticks every 1 s for 8 s, firing Holy Nova from the
-- target's current position attributed to the original caster.
-- The AuraScript (spell_celestial_resonance) handles all effect logic.
--
-- Key DBC index values (verified from binary DBC files):
--   CastingTimeIndex 16  = 1500 ms
--   DurationIndex    31  = 8000 ms (fixed, no scaling)
--   RangeIndex        5  = 40 yards "Long Range"
--   SpellIconID    1874  = Spell_Holy_HolyNova
--   EffectAura_1    226  = SPELL_AURA_PERIODIC_DUMMY
--   ImplicitTargetA_1 25 = TARGET_UNIT_TARGET_ANY
--   Targets           2  = TARGET_FLAG_UNIT
--   SchoolMask        2  = SPELL_SCHOOL_MASK_HOLY
--   StartRecoveryCategory 133 / StartRecoveryTime 1500 = standard 1.5 s GCD

INSERT INTO `spell_dbc` (
    `ID`,
    `CastingTimeIndex`,
    `DurationIndex`,
    `RangeIndex`,
    `SpellIconID`,
    `ActiveIconID`,
    `SchoolMask`,
    `SpellClassSet`,
    `Targets`,
    `EquippedItemClass`,
    `Effect_1`,
    `EffectAura_1`,
    `EffectAuraPeriod_1`,
    `ImplicitTargetA_1`,
    `StartRecoveryCategory`,
    `StartRecoveryTime`,
    `PreventionType`,
    `Name_Lang_enUS`,
    `Name_Lang_Mask`,
    `AuraDescription_Lang_enUS`,
    `AuraDescription_Lang_Mask`
) VALUES (
    600002,
    16,          -- 1500 ms cast time
    31,          -- 8000 ms duration
    5,           -- 40 yards
    1874,        -- Holy Nova icon
    1874,
    2,           -- Holy school
    6,           -- SPELLFAMILY_PRIEST
    2,           -- TARGET_FLAG_UNIT
    -1,          -- no item required (default 0 triggers SPELL_FAILED_EQUIPPED_ITEM_CLASS)
    6,           -- SPELL_EFFECT_APPLY_AURA
    226,         -- SPELL_AURA_PERIODIC_DUMMY
    1000,        -- tick every 1000 ms
    25,          -- TARGET_UNIT_TARGET_ANY
    133,         -- standard GCD category
    1500,        -- GCD duration ms
    1,           -- SPELL_PREVENTION_TYPE_SILENCE
    'Celestial Resonance',
    1,
    'Radiating Holy Nova once per second.',
    1
)
ON DUPLICATE KEY UPDATE
    `CastingTimeIndex`          = VALUES(`CastingTimeIndex`),
    `DurationIndex`             = VALUES(`DurationIndex`),
    `RangeIndex`                = VALUES(`RangeIndex`),
    `SpellIconID`               = VALUES(`SpellIconID`),
    `ActiveIconID`              = VALUES(`ActiveIconID`),
    `SchoolMask`                = VALUES(`SchoolMask`),
    `SpellClassSet`             = VALUES(`SpellClassSet`),
    `Targets`                   = VALUES(`Targets`),
    `EquippedItemClass`         = VALUES(`EquippedItemClass`),
    `Effect_1`                  = VALUES(`Effect_1`),
    `EffectAura_1`              = VALUES(`EffectAura_1`),
    `EffectAuraPeriod_1`        = VALUES(`EffectAuraPeriod_1`),
    `ImplicitTargetA_1`         = VALUES(`ImplicitTargetA_1`),
    `StartRecoveryCategory`     = VALUES(`StartRecoveryCategory`),
    `StartRecoveryTime`         = VALUES(`StartRecoveryTime`),
    `PreventionType`            = VALUES(`PreventionType`),
    `Name_Lang_enUS`            = VALUES(`Name_Lang_enUS`),
    `Name_Lang_Mask`            = VALUES(`Name_Lang_Mask`),
    `AuraDescription_Lang_enUS` = VALUES(`AuraDescription_Lang_enUS`),
    `AuraDescription_Lang_Mask` = VALUES(`AuraDescription_Lang_Mask`);
