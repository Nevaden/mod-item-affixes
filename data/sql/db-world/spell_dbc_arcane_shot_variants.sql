-- spell_dbc_arcane_shot_variants.sql
-- Server-side spell_dbc rows for the three Arcane Shot spell-swap variants.
-- These rows override / supplement the Spell.dbc binary for IDs 699001-699003.
-- The client receives matching records via patch_custom_spells.ps1 / patch-z.MPQ.
--
-- CastingTimeIndex=18  — Arcane Shot R10's instant-cast index in SpellCastTimes.dbc
-- Targets=0            — Arcane Shot R10's actual Targets field (effect target set via ImplicitTargetA)
-- Attributes=65538     — Inherits Arcane Shot R10 attribute flags (0x10002)
-- EffectChainAmplitude_1=1.0 — Must be 1.0; default 0.0 zeroes all SCHOOL_DAMAGE output
-- ManaCostPct=5        — Matches live Arcane Shot mana cost percentage
-- SpellClassMask_1=2048 — Keeps existing SpellMods (affix bonuses) targeting Arcane Shot

-- ============================================================
-- 699001 — Arcane Shot: Multi
--   SCHOOL_DAMAGE, EffectChainTargets_1 = 2, EffectMultipleValue_1 = 1.0
-- ============================================================
INSERT INTO spell_dbc
    (ID, CastingTimeIndex, RangeIndex, SpellIconID, ActiveIconID, SpellVisualID_1,
     SchoolMask, SpellClassSet, SpellClassMask_1, Targets, EquippedItemClass,
     Attributes,
     Effect_1, ImplicitTargetA_1, EffectBasePoints_1, EffectChainAmplitude_1,
     EffectChainTargets_1, EffectMultipleValue_1,
     PowerType, ManaCostPct,
     StartRecoveryCategory, StartRecoveryTime,
     Name_Lang_enUS, Name_Lang_Mask)
VALUES
    (699001, 18, 114, 216, 216, 3299,
     64, 9, 2048, 0, -1,
     65538,
     2, 6, 491, 1.0,
     2, 1.0,
     0, 5,
     133, 1500,
     'Arcane Shot: Multi', 1)
ON DUPLICATE KEY UPDATE
    CastingTimeIndex         = VALUES(CastingTimeIndex),
    RangeIndex               = VALUES(RangeIndex),
    SpellIconID              = VALUES(SpellIconID),
    ActiveIconID             = VALUES(ActiveIconID),
    SpellVisualID_1          = VALUES(SpellVisualID_1),
    SchoolMask               = VALUES(SchoolMask),
    SpellClassSet            = VALUES(SpellClassSet),
    SpellClassMask_1         = VALUES(SpellClassMask_1),
    Targets                  = VALUES(Targets),
    EquippedItemClass        = VALUES(EquippedItemClass),
    Attributes               = VALUES(Attributes),
    Effect_1                 = VALUES(Effect_1),
    ImplicitTargetA_1        = VALUES(ImplicitTargetA_1),
    EffectBasePoints_1       = VALUES(EffectBasePoints_1),
    EffectChainAmplitude_1   = VALUES(EffectChainAmplitude_1),
    EffectChainTargets_1     = VALUES(EffectChainTargets_1),
    EffectMultipleValue_1    = VALUES(EffectMultipleValue_1),
    PowerType                = VALUES(PowerType),
    ManaCostPct              = VALUES(ManaCostPct),
    StartRecoveryCategory    = VALUES(StartRecoveryCategory),
    StartRecoveryTime        = VALUES(StartRecoveryTime),
    Name_Lang_enUS           = VALUES(Name_Lang_enUS),
    Name_Lang_Mask           = VALUES(Name_Lang_Mask);

-- ============================================================
-- 699002 — Arcane Shot: Sting
--   SCHOOL_DAMAGE (eff 1) + TRIGGER_SPELL → 49001 (Serpent Sting R11) (eff 2)
-- ============================================================
INSERT INTO spell_dbc
    (ID, CastingTimeIndex, RangeIndex, SpellIconID, ActiveIconID, SpellVisualID_1,
     SchoolMask, SpellClassSet, SpellClassMask_1, Targets, EquippedItemClass,
     Attributes,
     Effect_1, ImplicitTargetA_1, EffectBasePoints_1, EffectChainAmplitude_1,
     Effect_2, ImplicitTargetA_2, EffectTriggerSpell_2,
     PowerType, ManaCostPct,
     StartRecoveryCategory, StartRecoveryTime,
     Name_Lang_enUS, Name_Lang_Mask)
VALUES
    (699002, 18, 114, 216, 216, 3299,
     64, 9, 2048, 0, -1,
     65538,
     2, 6, 491, 1.0,
     64, 6, 49001,
     0, 5,
     133, 1500,
     'Arcane Shot: Sting', 1)
ON DUPLICATE KEY UPDATE
    CastingTimeIndex         = VALUES(CastingTimeIndex),
    RangeIndex               = VALUES(RangeIndex),
    SpellIconID              = VALUES(SpellIconID),
    ActiveIconID             = VALUES(ActiveIconID),
    SpellVisualID_1          = VALUES(SpellVisualID_1),
    SchoolMask               = VALUES(SchoolMask),
    SpellClassSet            = VALUES(SpellClassSet),
    SpellClassMask_1         = VALUES(SpellClassMask_1),
    Targets                  = VALUES(Targets),
    EquippedItemClass        = VALUES(EquippedItemClass),
    Attributes               = VALUES(Attributes),
    Effect_1                 = VALUES(Effect_1),
    ImplicitTargetA_1        = VALUES(ImplicitTargetA_1),
    EffectBasePoints_1       = VALUES(EffectBasePoints_1),
    EffectChainAmplitude_1   = VALUES(EffectChainAmplitude_1),
    Effect_2                 = VALUES(Effect_2),
    ImplicitTargetA_2        = VALUES(ImplicitTargetA_2),
    EffectTriggerSpell_2     = VALUES(EffectTriggerSpell_2),
    PowerType                = VALUES(PowerType),
    ManaCostPct              = VALUES(ManaCostPct),
    StartRecoveryCategory    = VALUES(StartRecoveryCategory),
    StartRecoveryTime        = VALUES(StartRecoveryTime),
    Name_Lang_enUS           = VALUES(Name_Lang_enUS),
    Name_Lang_Mask           = VALUES(Name_Lang_Mask);

-- ============================================================
-- 699004..699019 — Arcane Shot: Multi / Multi Sting, chain counts 2-9
-- EffectChainTargets_1 = chain_count + 1 (total targets including primary)
-- Multi Sting variants also set EffectChainTargets_2 so Serpent Sting chains.
-- ============================================================
INSERT INTO spell_dbc
    (ID, CastingTimeIndex, RangeIndex, SpellIconID, ActiveIconID, SpellVisualID_1,
     SchoolMask, SpellClassSet, SpellClassMask_1, Targets, EquippedItemClass,
     Attributes,
     Effect_1, ImplicitTargetA_1, EffectBasePoints_1, EffectChainAmplitude_1,
     EffectChainTargets_1, EffectMultipleValue_1,
     PowerType, ManaCostPct,
     StartRecoveryCategory, StartRecoveryTime,
     Name_Lang_enUS, Name_Lang_Mask)
VALUES
    (699004, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 3, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi', 1),
    (699006, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 4, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi', 1),
    (699008, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 5, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi', 1),
    (699010, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 6, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi', 1),
    (699012, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 7, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi', 1),
    (699014, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 8, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi', 1),
    (699016, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 9, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi', 1),
    (699018, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 10, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi', 1)
ON DUPLICATE KEY UPDATE
    CastingTimeIndex = VALUES(CastingTimeIndex), RangeIndex = VALUES(RangeIndex),
    SpellIconID = VALUES(SpellIconID), ActiveIconID = VALUES(ActiveIconID),
    SpellVisualID_1 = VALUES(SpellVisualID_1), SchoolMask = VALUES(SchoolMask),
    SpellClassSet = VALUES(SpellClassSet), SpellClassMask_1 = VALUES(SpellClassMask_1),
    Targets = VALUES(Targets), EquippedItemClass = VALUES(EquippedItemClass),
    Attributes = VALUES(Attributes), Effect_1 = VALUES(Effect_1),
    ImplicitTargetA_1 = VALUES(ImplicitTargetA_1), EffectBasePoints_1 = VALUES(EffectBasePoints_1),
    EffectChainAmplitude_1 = VALUES(EffectChainAmplitude_1),
    EffectChainTargets_1 = VALUES(EffectChainTargets_1),
    EffectMultipleValue_1 = VALUES(EffectMultipleValue_1),
    PowerType = VALUES(PowerType), ManaCostPct = VALUES(ManaCostPct),
    StartRecoveryCategory = VALUES(StartRecoveryCategory),
    StartRecoveryTime = VALUES(StartRecoveryTime),
    Name_Lang_enUS = VALUES(Name_Lang_enUS), Name_Lang_Mask = VALUES(Name_Lang_Mask);

INSERT INTO spell_dbc
    (ID, CastingTimeIndex, RangeIndex, SpellIconID, ActiveIconID, SpellVisualID_1,
     SchoolMask, SpellClassSet, SpellClassMask_1, Targets, EquippedItemClass,
     Attributes,
     Effect_1, ImplicitTargetA_1, EffectBasePoints_1, EffectChainAmplitude_1,
     EffectChainTargets_1, EffectMultipleValue_1,
     Effect_2, ImplicitTargetA_2, EffectTriggerSpell_2, EffectChainTargets_2, EffectChainAmplitude_2,
     PowerType, ManaCostPct,
     StartRecoveryCategory, StartRecoveryTime,
     Name_Lang_enUS, Name_Lang_Mask)
VALUES
    (699005, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 3, 1.0, 64, 6, 49001, 3, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi Sting', 1),
    (699007, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 4, 1.0, 64, 6, 49001, 4, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi Sting', 1),
    (699009, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 5, 1.0, 64, 6, 49001, 5, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi Sting', 1),
    (699011, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 6, 1.0, 64, 6, 49001, 6, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi Sting', 1),
    (699013, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 7, 1.0, 64, 6, 49001, 7, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi Sting', 1),
    (699015, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 8, 1.0, 64, 6, 49001, 8, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi Sting', 1),
    (699017, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 9, 1.0, 64, 6, 49001, 9, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi Sting', 1),
    (699019, 18, 114, 216, 216, 3299, 64, 9, 2048, 0, -1, 65538, 2, 6, 491, 1.0, 10, 1.0, 64, 6, 49001, 10, 1.0, 0, 5, 133, 1500, 'Arcane Shot: Multi Sting', 1)
ON DUPLICATE KEY UPDATE
    CastingTimeIndex = VALUES(CastingTimeIndex), RangeIndex = VALUES(RangeIndex),
    SpellIconID = VALUES(SpellIconID), ActiveIconID = VALUES(ActiveIconID),
    SpellVisualID_1 = VALUES(SpellVisualID_1), SchoolMask = VALUES(SchoolMask),
    SpellClassSet = VALUES(SpellClassSet), SpellClassMask_1 = VALUES(SpellClassMask_1),
    Targets = VALUES(Targets), EquippedItemClass = VALUES(EquippedItemClass),
    Attributes = VALUES(Attributes), Effect_1 = VALUES(Effect_1),
    ImplicitTargetA_1 = VALUES(ImplicitTargetA_1), EffectBasePoints_1 = VALUES(EffectBasePoints_1),
    EffectChainAmplitude_1 = VALUES(EffectChainAmplitude_1),
    EffectChainTargets_1 = VALUES(EffectChainTargets_1),
    EffectMultipleValue_1 = VALUES(EffectMultipleValue_1),
    Effect_2 = VALUES(Effect_2), ImplicitTargetA_2 = VALUES(ImplicitTargetA_2),
    EffectTriggerSpell_2 = VALUES(EffectTriggerSpell_2),
    EffectChainTargets_2 = VALUES(EffectChainTargets_2),
    EffectChainAmplitude_2 = VALUES(EffectChainAmplitude_2),
    PowerType = VALUES(PowerType), ManaCostPct = VALUES(ManaCostPct),
    StartRecoveryCategory = VALUES(StartRecoveryCategory),
    StartRecoveryTime = VALUES(StartRecoveryTime),
    Name_Lang_enUS = VALUES(Name_Lang_enUS), Name_Lang_Mask = VALUES(Name_Lang_Mask);

-- ============================================================
-- 699003 — Arcane Shot: Multi Sting (combo)
--   SCHOOL_DAMAGE + chain (eff 1), TRIGGER_SPELL → 49001 with chain (eff 2)
--   EffectChainTargets_2=2 ensures Serpent Sting applies to ALL targets hit, not just primary.
-- ============================================================
INSERT INTO spell_dbc
    (ID, CastingTimeIndex, RangeIndex, SpellIconID, ActiveIconID, SpellVisualID_1,
     SchoolMask, SpellClassSet, SpellClassMask_1, Targets, EquippedItemClass,
     Attributes,
     Effect_1, ImplicitTargetA_1, EffectBasePoints_1, EffectChainAmplitude_1,
     EffectChainTargets_1, EffectMultipleValue_1,
     Effect_2, ImplicitTargetA_2, EffectTriggerSpell_2, EffectChainTargets_2, EffectChainAmplitude_2,
     PowerType, ManaCostPct,
     StartRecoveryCategory, StartRecoveryTime,
     Name_Lang_enUS, Name_Lang_Mask)
VALUES
    (699003, 18, 114, 216, 216, 3299,
     64, 9, 2048, 0, -1,
     65538,
     2, 6, 491, 1.0,
     2, 1.0,
     64, 6, 49001, 2, 1.0,
     0, 5,
     133, 1500,
     'Arcane Shot: Multi Sting', 1)
ON DUPLICATE KEY UPDATE
    CastingTimeIndex         = VALUES(CastingTimeIndex),
    RangeIndex               = VALUES(RangeIndex),
    SpellIconID              = VALUES(SpellIconID),
    ActiveIconID             = VALUES(ActiveIconID),
    SpellVisualID_1          = VALUES(SpellVisualID_1),
    SchoolMask               = VALUES(SchoolMask),
    SpellClassSet            = VALUES(SpellClassSet),
    SpellClassMask_1         = VALUES(SpellClassMask_1),
    Targets                  = VALUES(Targets),
    EquippedItemClass        = VALUES(EquippedItemClass),
    Attributes               = VALUES(Attributes),
    Effect_1                 = VALUES(Effect_1),
    ImplicitTargetA_1        = VALUES(ImplicitTargetA_1),
    EffectBasePoints_1       = VALUES(EffectBasePoints_1),
    EffectChainAmplitude_1   = VALUES(EffectChainAmplitude_1),
    EffectChainTargets_1     = VALUES(EffectChainTargets_1),
    EffectMultipleValue_1    = VALUES(EffectMultipleValue_1),
    Effect_2                 = VALUES(Effect_2),
    ImplicitTargetA_2        = VALUES(ImplicitTargetA_2),
    EffectTriggerSpell_2     = VALUES(EffectTriggerSpell_2),
    EffectChainTargets_2     = VALUES(EffectChainTargets_2),
    EffectChainAmplitude_2   = VALUES(EffectChainAmplitude_2),
    PowerType                = VALUES(PowerType),
    ManaCostPct              = VALUES(ManaCostPct),
    StartRecoveryCategory    = VALUES(StartRecoveryCategory),
    StartRecoveryTime        = VALUES(StartRecoveryTime),
    Name_Lang_enUS           = VALUES(Name_Lang_enUS),
    Name_Lang_Mask           = VALUES(Name_Lang_Mask);
