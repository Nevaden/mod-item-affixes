-- mod-item-affixes: gem affix transfer table
-- One row per gem socket per gear item.  Written by OnSocketGem when a gem with
-- a rolled affix is socketed.  Cleared when the gem is replaced.

CREATE TABLE IF NOT EXISTS `item_gem_affix` (
    `gear_guid`    BIGINT UNSIGNED NOT NULL        COMMENT 'Raw GUID of the gear item',
    `socket_slot`  TINYINT UNSIGNED NOT NULL       COMMENT '0, 1, or 2 (gem socket index)',
    `affix_id`     INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'ID from affix_template (stat affixes only)',
    `rolled_value` INT NOT NULL DEFAULT 0          COMMENT 'Rolled stat magnitude',
    PRIMARY KEY (`gear_guid`, `socket_slot`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
