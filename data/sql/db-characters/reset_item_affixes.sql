-- reset_item_affixes.sql
-- WARNING: Deletes ALL player affix data from item_affix.
-- Use for testing/maintenance only. Run update_affixes.bat afterwards to reapply the schema.
-- Items will re-initialize their UNROLLED slots on next pickup or login.

DELETE FROM `item_affix`;
