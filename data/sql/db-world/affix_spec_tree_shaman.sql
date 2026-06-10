-- Shaman class affix spec_tree assignments.
-- Source: in-game trainer section / spellbook tab (P key).
-- 0=Elemental  1=Enhancement  2=Restoration

-- Elemental (0): Lightning Bolt, Chain Lightning, Lava Burst, Earth Shock, Flame Shock, Hex
UPDATE `affix_template` SET `spec_tree` = 0
WHERE `id` IN (
    8000, 8001, 8002, 8003,          -- Lightning Bolt
    8004, 8005, 8006, 8007,          -- Chain Lightning
    8008, 8009, 8010, 8011,          -- Lava Burst
    8012, 8013, 8014, 8015,          -- Earth Shock
    8016, 8017, 8018,                 -- Flame Shock
    8030, 8031, 8032                  -- Hex
);

-- Restoration (2): Chain Heal, Healing Wave, Riptide
UPDATE `affix_template` SET `spec_tree` = 2
WHERE `id` IN (
    8019, 8020, 8021, 8022,          -- Chain Heal
    8023, 8024, 8025, 8026,          -- Healing Wave
    8027, 8028, 8029                  -- Riptide
);
