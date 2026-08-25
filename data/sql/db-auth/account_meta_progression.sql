CREATE TABLE IF NOT EXISTS `account_meta_progression` (
  `account_id` INT UNSIGNED NOT NULL,
  `xp` BIGINT UNSIGNED NOT NULL DEFAULT 0
    COMMENT 'Lifetime meta-progression XP earned (trickle + per-affix); never decreases.',
  PRIMARY KEY (`account_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Account-wide meta-progression XP pool for mod-item-affixes. Invested tiers moved to acore_characters.character_meta_progression — spend is per-character.';

-- Invested tiers moved to a per-character table (see character_meta_progression);
-- drop them here if this table was already created with the old (v1) schema.
SET @drop_rt = IF((SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='account_meta_progression' AND COLUMN_NAME='reroll_tier')<>0,
    'ALTER TABLE `account_meta_progression` DROP COLUMN `reroll_tier`',
    'SELECT 1');
PREPARE _s FROM @drop_rt; EXECUTE _s; DEALLOCATE PREPARE _s;

SET @drop_ot = IF((SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='account_meta_progression' AND COLUMN_NAME='options_tier')<>0,
    'ALTER TABLE `account_meta_progression` DROP COLUMN `options_tier`',
    'SELECT 1');
PREPARE _s FROM @drop_ot; EXECUTE _s; DEALLOCATE PREPARE _s;
