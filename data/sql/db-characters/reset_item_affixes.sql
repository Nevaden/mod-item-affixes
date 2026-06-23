-- reset_item_affixes.sql
-- Resets ALL player affix choices. Items retain their slot records but all selections
-- are cleared — players must Alt+Click each item to roll new affixes.
-- Talent affixes are also cleared; they will be re-generated when players make their picks.
-- Run this while the worldserver is stopped, then start it back up.

UPDATE `item_affix`
SET `roll_state`        = 0,
    `affix_id`          = 0,
    `rolled_value`      = 0,
    `pending_opts`      = '',
    `rerolls_remaining` = 0,
    `locked_mask`       = 0;

DELETE FROM `item_talent_affix`;
