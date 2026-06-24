-- Spirit Rhino (entry 601104) — custom guardian for Feral Spirit: Stampede.
-- Spawned 10 at a time, 50 % scale, 30 s duration.
-- CreatureImmunitiesId = 95  → existing 'Immune to Fear' row (MechanicsMask=32, bit MECHANIC_FEAR).
-- unit_flags2 = 2048 (0x800) → REGENERATE_POWER, matching the Spirit Wolf.
-- ScriptName = "npc_spirit_rhino": C++ CreatureScript owns all spell casting with proper cooldowns.
--   Stomp (51493)  — 8–10 s    Deafening Roar (55663) — 12–15 s    Rhino Charge (55193) — 20–25 s
DELETE FROM `creature_template`       WHERE `entry`      = 601104;
DELETE FROM `creature_template_model` WHERE `CreatureID` = 601104;
DELETE FROM `creature_template_spell` WHERE `CreatureID` = 601104;

INSERT INTO `creature_template`
    (`entry`, `name`, `minlevel`, `maxlevel`, `faction`, `npcflag`,
     `unit_flags`, `unit_flags2`, `CreatureImmunitiesId`,
     `BaseAttackTime`, `RangeAttackTime`,
     `AIName`, `ScriptName`, `MovementType`, `flags_extra`, `VerifiedBuild`)
VALUES
    (601104, 'Spirit Rhino', 80, 80, 35, 0,
     0, 2048, 95,
     2000, 0,
     '', 'npc_spirit_rhino', 0, 0, 0);

-- Rhino Spirit display from Zul'Drak (entry 29791).
INSERT INTO `creature_template_model` (`CreatureID`, `Idx`, `CreatureDisplayID`, `DisplayScale`, `Probability`)
VALUES (601104, 0, 26535, 1.0, 1.0);
