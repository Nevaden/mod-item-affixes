CREATE TABLE IF NOT EXISTS `character_meta_progression` (
  `guid` BIGINT UNSIGNED NOT NULL,
  `reroll_tier` TINYINT UNSIGNED NOT NULL DEFAULT 0
    COMMENT 'Points invested in the reroll-count node; adds flat bonus to RerollsGreen/Blue/Purple/Legendary.',
  `options_tier` TINYINT UNSIGNED NOT NULL DEFAULT 0
    COMMENT 'Points invested in the options-count node; adds flat bonus to OptionsCountGreen/Blue/Purple/Legendary.',
  PRIMARY KEY (`guid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Per-character invested Player Progression tiers. The XP pool that funds these points stays account-wide in acore_auth.account_meta_progression.';
