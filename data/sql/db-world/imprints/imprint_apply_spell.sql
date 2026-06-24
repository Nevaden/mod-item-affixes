-- Custom spell for Imprint Rune on-use (right-click).
-- SPELL_EFFECT_SCRIPT_EFFECT (77) with self-target — succeeds silently on the server
-- without needing a SpellScript.  The addon intercepts via UseContainerItem hook.
-- RangeIndex=1 (self), CastingTimeIndex=1 (instant).
INSERT INTO `spell_dbc` (`ID`, `CastingTimeIndex`, `RangeIndex`, `Effect_1`, `ImplicitTargetA_1`)
VALUES (600001, 1, 1, 77, 1)
ON DUPLICATE KEY UPDATE
  `CastingTimeIndex` = 1,
  `RangeIndex`       = 1,
  `Effect_1`         = 77,
  `ImplicitTargetA_1`= 1;
