CREATE TABLE IF NOT EXISTS `item_affix` (
  `item_guid` BIGINT UNSIGNED NOT NULL,
  `affix_slot` TINYINT UNSIGNED NOT NULL COMMENT '0-2: up to 3 affixes per item',
  `affix_id` INT UNSIGNED NOT NULL,
  `rolled_value` INT NOT NULL DEFAULT 0
    COMMENT 'For AFFIX_TYPE_STAT: magnitude rolled at acquisition time. 0 for spellmod affixes.',
  `roll_state` TINYINT UNSIGNED NOT NULL DEFAULT 0
    COMMENT '0=UNROLLED, 1=PENDING (options sent, awaiting pick), 2=APPLIED',
  `pending_opts` VARCHAR(255) NOT NULL DEFAULT ''
    COMMENT 'Pending roll options as "id:rolledVal,id:rolledVal,..." — value rolled once at generation time',
  PRIMARY KEY (`item_guid`, `affix_slot`),
  INDEX (`affix_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Persistent ARPG-style affixes keyed by item GUID';

SET @add_rv = IF((SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='item_affix' AND COLUMN_NAME='rolled_value')=0,
    'ALTER TABLE `item_affix` ADD COLUMN `rolled_value` INT NOT NULL DEFAULT 0',
    'SELECT 1');
PREPARE _s FROM @add_rv; EXECUTE _s; DEALLOCATE PREPARE _s;

SET @add_rs = IF((SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='item_affix' AND COLUMN_NAME='roll_state')=0,
    'ALTER TABLE `item_affix` ADD COLUMN `roll_state` TINYINT UNSIGNED NOT NULL DEFAULT 0',
    'SELECT 1');
PREPARE _s FROM @add_rs; EXECUTE _s; DEALLOCATE PREPARE _s;

SET @add_po = IF((SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='item_affix' AND COLUMN_NAME='pending_opts')=0,
    'ALTER TABLE `item_affix` ADD COLUMN `pending_opts` VARCHAR(128) NOT NULL DEFAULT ''''',
    'SELECT 1');
PREPARE _s FROM @add_po; EXECUTE _s; DEALLOCATE PREPARE _s;

-- Widen pending_opts to 255 chars (now stores "id:val,id:val,..." pairs)
ALTER TABLE `item_affix` MODIFY COLUMN `pending_opts` VARCHAR(255) NOT NULL DEFAULT '';

-- Migrate existing applied affixes to roll_state=2
UPDATE `item_affix` SET `roll_state` = 2 WHERE `affix_id` != 0 AND `roll_state` = 0;

-- Clear legacy PERM_ENCHANTMENT_SLOT (positions 0-2 in the 36-value enchantments blob)
-- from any item that has affix rows.  Preserves real enchants (weapon enchants sit in
-- slot 2+; gems in slots 3-5) by only zeroing the first three space-separated tokens.
UPDATE `item_instance` ii
INNER JOIN `item_affix` ia ON ia.`item_guid` = ii.`guid`
SET ii.`enchantments` = CONCAT(
    '0 0 0 ',
    SUBSTRING_INDEX(ii.`enchantments`, ' ', -33)
)
WHERE CAST(SUBSTRING_INDEX(ii.`enchantments`, ' ', 1) AS UNSIGNED) != 0;
