-- Per-item Imprint instance: which Imprint an item carries and how many extractions remain.
CREATE TABLE IF NOT EXISTS `item_imprint` (
  `item_guid`        BIGINT UNSIGNED  NOT NULL,
  `imprint_id`       INT UNSIGNED     NOT NULL,
  `extractions_left` TINYINT UNSIGNED NOT NULL DEFAULT 2,
  PRIMARY KEY (`item_guid`),
  INDEX (`imprint_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Imprint instances keyed by item GUID';
