CREATE TABLE IF NOT EXISTS `character_progression_nodes` (
  `guid`    BIGINT UNSIGNED NOT NULL,
  `node_id` SMALLINT UNSIGNED NOT NULL,
  `rank`    TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`guid`, `node_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='One row per invested Player Progression node per character (node ids: see ProgressionNodeId in PlayerProgressionNodes.h). Adding a node is a data change, not a schema change.';

-- One-time migration from the retired fixed-column character_meta_progression
-- table (reroll_tier -> node 1, options_tier -> node 2). Guarded so this is a
-- no-op on a fresh install where that table never existed.
SET @has_old_table = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='character_meta_progression');

SET @migrate_reroll = IF(@has_old_table <> 0,
    'INSERT INTO `character_progression_nodes` (guid, node_id, `rank`) '
    'SELECT guid, 1, reroll_tier FROM `character_meta_progression` WHERE reroll_tier > 0 '
    'ON DUPLICATE KEY UPDATE `rank` = VALUES(`rank`)',
    'SELECT 1');
PREPARE _s FROM @migrate_reroll; EXECUTE _s; DEALLOCATE PREPARE _s;

SET @migrate_options = IF(@has_old_table <> 0,
    'INSERT INTO `character_progression_nodes` (guid, node_id, `rank`) '
    'SELECT guid, 2, options_tier FROM `character_meta_progression` WHERE options_tier > 0 '
    'ON DUPLICATE KEY UPDATE `rank` = VALUES(`rank`)',
    'SELECT 1');
PREPARE _s FROM @migrate_options; EXECUTE _s; DEALLOCATE PREPARE _s;

-- character_meta_progression is fully retired now that its two columns have
-- migrated — drop it rather than leave a guid-only husk table behind.
SET @drop_old = IF(@has_old_table <> 0,
    'DROP TABLE `character_meta_progression`',
    'SELECT 1');
PREPARE _s FROM @drop_old; EXECUTE _s; DEALLOCATE PREPARE _s;
