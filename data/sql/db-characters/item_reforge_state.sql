CREATE TABLE IF NOT EXISTS `item_reforge_state` (
  `item_guid` BIGINT UNSIGNED NOT NULL,
  `locked_slot` TINYINT UNSIGNED NOT NULL
    COMMENT 'affix_slot this item is permanently locked to reforging; set on first reforge, never changes after',
  `reroll_count` INT UNSIGNED NOT NULL DEFAULT 1
    COMMENT 'Incremented on every successful reforge of this item; drives escalating cost. Never resets.',
  `pending_opts` VARCHAR(255) NOT NULL DEFAULT ''
    COMMENT 'Server-generated candidates awaiting REFORGE_PICK, "id:val,id:val,..." (same format as item_affix.pending_opts). Cleared once picked. Never trust a client-supplied affix_id/value -- only an index into this.',
  PRIMARY KEY (`item_guid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Reforge NPC lock-in state, one row per item ever reforged';

SET @add_po = IF((SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='item_reforge_state' AND COLUMN_NAME='pending_opts')=0,
    'ALTER TABLE `item_reforge_state` ADD COLUMN `pending_opts` VARCHAR(255) NOT NULL DEFAULT ''''',
    'SELECT 1');
PREPARE _s FROM @add_po; EXECUTE _s; DEALLOCATE PREPARE _s;
