-- ============================================================================
-- Reforge Master NPC (docs/REFORGE_PLAN.md, Stage 3)
-- Appearance cloned from an existing enchanting trainer (entry 19252) --
-- "use any NPC for now" per design notes; not a final visual choice.
-- Dev/test via `.npc add 601107`. Fixed town spawns come later, before
-- shipping -- no creature_addon/spawn (creature table) rows here yet.
-- ============================================================================

DELETE FROM `creature_template`       WHERE `entry`      = 601107;
DELETE FROM `creature_template_model` WHERE `CreatureID` = 601107;
DELETE FROM `npc_text`                WHERE `ID`         = 601107;
DELETE FROM `gossip_menu`             WHERE `MenuID`     = 601107;

INSERT INTO `creature_template`
    (`entry`, `name`, `subname`, `gossip_menu_id`, `minlevel`, `maxlevel`, `exp`,
     `faction`, `npcflag`, `speed_walk`, `speed_run`, `speed_swim`, `speed_flight`,
     `detection_range`, `unit_class`, `unit_flags`, `unit_flags2`, `type`,
     `HealthModifier`, `ManaModifier`, `ArmorModifier`, `ExperienceModifier`,
     `RegenHealth`, `flags_extra`, `ScriptName`)
VALUES
    (601107, 'Reforge Master', 'Affix Reforging', 601107, 80, 80, 0,
     35, 1, 1, 1.14286, 1, 1,
     20, 8, 33024, 2048, 7,
     1, 1, 1, 1,
     1, 2, 'npc_reforge_master');

INSERT INTO `creature_template_model`
    (`CreatureID`, `Idx`, `CreatureDisplayID`, `DisplayScale`, `Probability`)
VALUES
    (601107, 0, 18773, 1, 1);

INSERT INTO `npc_text` (`ID`, `text0_0`, `text0_1`, `Probability0`)
VALUES
    (601107,
     'Hello Adventurer, if you have some items with affixes you would like to try to reforge into something that benefits you, bring them to me and for a fee I will let you once again see new possibilities.',
     'Hello Adventurer, if you have some items with affixes you would like to try to reforge into something that benefits you, bring them to me and for a fee I will let you once again see new possibilities.',
     1);

INSERT INTO `gossip_menu` (`MenuID`, `TextID`)
VALUES
    (601107, 601107);
