-- Druid class affix spec_tree assignments.
-- Source: in-game trainer section / spellbook tab (P key).
-- 0=Balance  1=Feral Combat  2=Restoration

-- Balance (0): Wrath, Starfire, Moonfire, Starfall, Hurricane
UPDATE `affix_template` SET `spec_tree` = 0
WHERE `id` IN (
    7000, 7001, 7002, 7003,          -- Wrath
    7004, 7005, 7006, 7007,          -- Starfire
    7008, 7009, 7010,                 -- Moonfire
    7011, 7012, 7013,                 -- Starfall
    7014, 7015                        -- Hurricane
);

-- Feral Combat (1): Rip, Rake
UPDATE `affix_template` SET `spec_tree` = 1
WHERE `id` IN (
    7030, 7031, 7032,                 -- Rip
    7033, 7034                        -- Rake
);

-- Restoration (2): Healing Touch, Rejuvenation, Regrowth, Lifebloom
UPDATE `affix_template` SET `spec_tree` = 2
WHERE `id` IN (
    7016, 7017, 7018, 7019,          -- Healing Touch
    7020, 7021, 7022,                 -- Rejuvenation
    7023, 7024, 7025, 7026,          -- Regrowth
    7027, 7028, 7029                  -- Lifebloom
);
