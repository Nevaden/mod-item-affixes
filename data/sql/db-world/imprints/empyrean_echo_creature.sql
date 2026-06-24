-- Empyrean Echo dummy creature (entry 601101).
-- Invisible, non-selectable, non-attackable trigger unit summoned at each echo
-- position. Its stats are overridden at spawn time to match the casting player
-- so that Divine Storm damage scales correctly from each echo point.
-- flags_extra = 0x82: TRIGGER (0x80) | CIVILIAN (0x02) — won't engage in combat.
-- unit_flags  = 0x02000002: NON_ATTACKABLE (0x2) | NOT_SELECTABLE (0x2000000).
DELETE FROM `creature_template`       WHERE `entry`      = 601101;
DELETE FROM `creature_template_model` WHERE `CreatureID` = 601101;
INSERT INTO `creature_template`
    (`entry`, `name`, `minlevel`, `maxlevel`, `faction`, `npcflag`,
     `unit_flags`, `unit_flags2`, `BaseAttackTime`, `RangeAttackTime`,
     `AIName`, `MovementType`, `flags_extra`, `VerifiedBuild`)
VALUES
    (601101, 'Empyrean Echo', 80, 80, 35, 0,
     0x02000002, 0, 2000, 0,
     '', 0, 0x82, 0);

-- Invisible Stalker display (11686) — renders nothing on the client.
INSERT INTO `creature_template_model` (`CreatureID`, `Idx`, `CreatureDisplayID`, `DisplayScale`, `Probability`)
VALUES (601101, 0, 11686, 1.0, 1.0);
