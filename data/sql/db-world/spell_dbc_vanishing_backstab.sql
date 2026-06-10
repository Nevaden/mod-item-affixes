-- Vanishing Backstab — custom Rogue Combat imprint spell (ID 600003).
-- Instant cast, costs 60 energy, no cooldown, self-cast.
-- SPELL_EFFECT_DUMMY — all actual behavior is driven by the SpellScript
-- (spell_vanishing_backstab in ItemAffixScripts.cpp): Shadowstep + Backstab.
--
-- Self-cast design (Targets=0, ImplicitTargetA_1=1, RangeIndex=1):
--   The trigger spell never touches the enemy, so it cannot call EngageWithTarget.
--   The SpellScript reads the player's selected target via caster->GetTarget() instead.
--
-- Key DBC index values used here (verified from binary DBC / existing spells):
--   CastingTimeIndex  1  = instant (0 ms)
--   RangeIndex        1  = self (no range limit; Shadowstep closes the distance)
--   SpellIconID     243  = Backstab (SpellIcon.dbc entry — query Spell.dbc field 133 on spell 53)
--   ImplicitTargetA_1 1  = TARGET_UNIT_CASTER (self-cast, never hits enemy)
--   Targets           0  = no unit target required from client
--   SchoolMask        1  = SPELL_SCHOOL_MASK_NORMAL (physical)
--   PowerType         3  = energy
--   ManaCost         60  = 60 energy cost
--   StartRecoveryCategory 133 / StartRecoveryTime 1000 = Rogue GCD (1000ms, not 1500)
--   Effect_1          3  = SPELL_EFFECT_DUMMY

INSERT INTO `spell_dbc` (
    `ID`,
    `CastingTimeIndex`,
    `RangeIndex`,
    `SpellIconID`,
    `ActiveIconID`,
    `SchoolMask`,
    `SpellClassSet`,
    `Targets`,
    `EquippedItemClass`,
    `Effect_1`,
    `ImplicitTargetA_1`,
    `PowerType`,
    `ManaCost`,
    `StartRecoveryCategory`,
    `StartRecoveryTime`,
    `Name_Lang_enUS`,
    `Name_Lang_Mask`
) VALUES (
    600003,
    1,           -- instant
    34,          -- 25 yards (SpellRange.dbc index 34 = Shadowstep's exact range)
    243,         -- SpellIconID 243 = Backstab icon (SpellIcon.dbc entry, NOT texture file ID)
    243,
    1,           -- physical school
    8,           -- SPELLFAMILY_ROGUE
    2,           -- TARGET_FLAG_UNIT: client sends unit GUID and grays button when target >25 yards
    -1,          -- no item required (default 0 triggers SPELL_FAILED_EQUIPPED_ITEM_CLASS)
    3,           -- SPELL_EFFECT_DUMMY
    1,           -- TARGET_UNIT_CASTER (self); server resolves effect onto caster, not the enemy —
                 -- enemy is never hit, so EngageWithTarget is never called
    3,           -- energy
    60,          -- 60 energy cost
    133,         -- standard GCD category
    1000,        -- GCD duration ms (Rogue abilities use 1000ms, not 1500)
    'Vanishing Backstab',
    1            -- enUS locale flag
)
ON DUPLICATE KEY UPDATE
    `CastingTimeIndex`      = VALUES(`CastingTimeIndex`),
    `RangeIndex`            = VALUES(`RangeIndex`),
    `SpellIconID`           = VALUES(`SpellIconID`),
    `ActiveIconID`          = VALUES(`ActiveIconID`),
    `SchoolMask`            = VALUES(`SchoolMask`),
    `SpellClassSet`         = VALUES(`SpellClassSet`),
    `Targets`               = VALUES(`Targets`),
    `EquippedItemClass`     = VALUES(`EquippedItemClass`),
    `Effect_1`              = VALUES(`Effect_1`),
    `ImplicitTargetA_1`     = VALUES(`ImplicitTargetA_1`),
    `PowerType`             = VALUES(`PowerType`),
    `ManaCost`              = VALUES(`ManaCost`),
    `StartRecoveryCategory` = VALUES(`StartRecoveryCategory`),
    `StartRecoveryTime`     = VALUES(`StartRecoveryTime`),
    `Name_Lang_enUS`        = VALUES(`Name_Lang_enUS`),
    `Name_Lang_Mask`        = VALUES(`Name_Lang_Mask`);
