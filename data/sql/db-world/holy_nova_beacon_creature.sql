-- Holy Nova Beacon — invisible trigger creature for Celestial Resonance imprint.
-- Spawned for 500 ms at the target's position; casts Holy Nova rank 9 (48078)
-- attributed to the original caster player, then despawns.
-- No combat AI needed: the spell is cast from C++ code in the AuraScript.

DELETE FROM `creature_template`       WHERE `entry` = 601105;
DELETE FROM `creature_template_model` WHERE `CreatureID` = 601105;

INSERT INTO `creature_template`
    (`entry`, `name`, `minlevel`, `maxlevel`, `faction`, `npcflag`,
     `unit_flags`, `unit_flags2`,
     `AIName`, `ScriptName`, `MovementType`, `flags_extra`, `VerifiedBuild`)
VALUES
    (601105, 'Holy Nova Beacon', 80, 80, 35, 0,
     0x02000002,  -- NON_ATTACKABLE | NOT_SELECTABLE
     0,
     '', '', 0,
     0x82,        -- TRIGGER (0x80) | CIVILIAN (0x02) — will not engage combat
     0);

INSERT INTO `creature_template_model` (`CreatureID`, `Idx`, `CreatureDisplayID`, `DisplayScale`, `Probability`)
VALUES (601105, 0, 11686, 1.0, 1.0);   -- 11686 = Invisible Stalker display
