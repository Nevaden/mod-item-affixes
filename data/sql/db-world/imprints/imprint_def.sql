-- Imprint type definitions.
CREATE TABLE IF NOT EXISTS `imprint_def` (
  `id`              INT UNSIGNED     NOT NULL,
  `name`            VARCHAR(64)      NOT NULL DEFAULT '',
  `rune_item_id`    INT UNSIGNED     NOT NULL DEFAULT 0,   -- item_template entry for the Rune
  `extractions_max` TINYINT UNSIGNED NOT NULL DEFAULT 2,   -- overridden by config at grant time
  `class_mask`      INT UNSIGNED     NOT NULL DEFAULT 0,   -- 0 = any class; bit = (1 << (classId-1))
  `spec_tree`       TINYINT          NOT NULL DEFAULT -1,  -- -1 = any spec; 0/1/2 = required dominant tree
  `required_spell`  INT UNSIGNED     NOT NULL DEFAULT 0,   -- 0 = no check; player must know any rank of this spell
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Imprint type definitions loaded by ImprintMgr';

-- Add spec_tree column to existing installations (no-op if it already exists).
SET @_db = DATABASE();
SET @_stmt = (
    SELECT IF(
        (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_SCHEMA = @_db AND TABLE_NAME = 'imprint_def' AND COLUMN_NAME = 'spec_tree') > 0,
        'SELECT 1',
        'ALTER TABLE `imprint_def` ADD COLUMN `spec_tree` TINYINT NOT NULL DEFAULT -1'
    )
);
PREPARE _alter FROM @_stmt;
EXECUTE _alter;
DEALLOCATE PREPARE _alter;

-- Add required_spell column to existing installations (no-op if it already exists).
SET @_stmt2 = (
    SELECT IF(
        (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_SCHEMA = @_db AND TABLE_NAME = 'imprint_def' AND COLUMN_NAME = 'required_spell') > 0,
        'SELECT 1',
        'ALTER TABLE `imprint_def` ADD COLUMN `required_spell` INT UNSIGNED NOT NULL DEFAULT 0'
    )
);
PREPARE _alter2 FROM @_stmt2;
EXECUTE _alter2;
DEALLOCATE PREPARE _alter2;

-- class_mask bit values (1 << (classId-1)):
--   CLASS_PALADIN=2  → bit 2   (mask = 2)
--   CLASS_SHAMAN=7   → bit 64  (mask = 64)
--   0 = any class
--
-- spec_tree values match talent tab indices (0/1/2) or -1 for any:
--   Paladin: 0=Holy  1=Protection  2=Retribution
--   Shaman:  0=Elemental  1=Enhancement  2=Restoration
--
-- required_spell: player must know any rank of this spell to be offered the Imprint.
--   53595 = Hammer of the Righteous  (Paladin Prot talent, deep tier)
--   53385 = Divine Storm             (Paladin Ret talent, deep tier)
--   51533 = Feral Spirit             (Shaman Enhancement talent, deep tier)
--   15237 = Holy Nova                (Priest baseline, learned at level 20)
--      53 = Backstab                 (Rogue baseline, learned at level 1)
--   31687 = Summon Water Elemental   (Mage Frost talent, deep tier)
INSERT INTO `imprint_def` (`id`, `name`, `rune_item_id`, `extractions_max`, `class_mask`, `spec_tree`, `required_spell`)
VALUES
  (1, 'Righteous Sanctuary',    602001, 2,  2,  1, 53595),  -- Paladin Protection / Hammer of the Righteous
  (2, 'Empyrean Echo',          602002, 2,  2,  2, 53385),  -- Paladin Retribution / Divine Storm
  (3, 'Feral Spirit: Stampede', 602003, 2, 64,  1, 51533),  -- Shaman Enhancement  / Feral Spirit
  (4, 'Feral Spirit: Alpha',    602004, 2, 64,  1, 51533),  -- Shaman Enhancement  / Feral Spirit
  (5, 'Celestial Resonance',    602005, 2, 16,  1, 15237),  -- Priest Holy         / Holy Nova (level 20)
  (6, 'Vanishing Backstab',     602006, 2,  8,  1,    53),  -- Rogue Combat        / Backstab  (level 1)
  (7, 'Eternal Elemental',      602007, 2, 128,  2, 31687),  -- Mage Frost          / Summon Water Elemental
  (8, 'Apex Maul',              602008, 2, 1024, 1,  6807),  -- Druid Feral         / Maul
  (9, 'Ancient Tiger',          602009, 2, 1024, 1,  5217)   -- Druid Feral         / Tiger's Fury
ON DUPLICATE KEY UPDATE
  `name`            = VALUES(`name`),
  `rune_item_id`    = VALUES(`rune_item_id`),
  `extractions_max` = VALUES(`extractions_max`),
  `class_mask`      = VALUES(`class_mask`),
  `spec_tree`       = VALUES(`spec_tree`),
  `required_spell`  = VALUES(`required_spell`);
