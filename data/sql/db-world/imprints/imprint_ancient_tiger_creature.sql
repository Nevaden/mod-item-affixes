-- Ancient Tiger (entry 601106) — permanent spirit tiger for the Ancient Tiger imprint.
-- Spawned once on Tiger's Fury cast; persists until slain (TEMPSUMMON_DEAD_DESPAWN).
-- Display 28871 = Gondria (spectral blue-white spirit cat, WotLK spirit beast).
-- ScriptName = "npc_ancient_tiger": C++ CreatureScript mirrors owner target every tick,
--   casts Rake (48574) every 6–9 s and Shred (48572) every 8–12 s.
-- unit_flags2 = 2048 (0x800) → REGENERATE_POWER, consistent with spirit guardians.
DELETE FROM `creature_template`       WHERE `entry`      = 601106;
DELETE FROM `creature_template_model` WHERE `CreatureID` = 601106;

INSERT INTO `creature_template`
    (`entry`, `name`, `minlevel`, `maxlevel`, `faction`, `npcflag`,
     `unit_flags`, `unit_flags2`, `CreatureImmunitiesId`,
     `BaseAttackTime`, `RangeAttackTime`,
     `AIName`, `ScriptName`, `MovementType`, `flags_extra`, `VerifiedBuild`)
VALUES
    (601106, 'Ancient Tiger', 80, 80, 35, 0,
     0, 2048, 0,
     2000, 0,
     '', 'npc_ancient_tiger', 0, 0, 0);

-- Gondria display (spectral spirit cat, displayed at 1.5x scale via C++ SetObjectScale).
INSERT INTO `creature_template_model` (`CreatureID`, `Idx`, `CreatureDisplayID`, `DisplayScale`, `Probability`)
VALUES (601106, 0, 28871, 1.0, 1.0);
