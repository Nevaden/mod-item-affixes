-- item_talent_affix.sql
-- Per-item talent affix storage (characters DB).
-- One row per affix slot per item; items may accumulate one talent affix per regular affix roll.
-- Created/updated by update_affixes.bat.

CREATE TABLE IF NOT EXISTS `item_talent_affix` (
    `item_guid`    BIGINT UNSIGNED    NOT NULL,
    `affix_slot`   TINYINT UNSIGNED   NOT NULL DEFAULT 0,
    `affix_id`     INT UNSIGNED       NOT NULL DEFAULT 0,
    `rolled_value` INT                NOT NULL DEFAULT 0,
    PRIMARY KEY (`item_guid`, `affix_slot`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
