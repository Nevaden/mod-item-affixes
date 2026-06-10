-- Rogue class affix spec_tree assignments.
-- Source: in-game trainer section / spellbook tab (P key).
-- 0=Assassination  1=Combat  2=Subtlety

-- Assassination (0): Ambush, Mutilate, Eviscerate, Envenom, Rupture, Garrote
UPDATE `affix_template` SET `spec_tree` = 0
WHERE `id` IN (
    6010, 6011, 6012, 6013, 6014,    -- Ambush
    6015, 6016, 6017, 6018,          -- Mutilate
    6019, 6020, 6021, 6022, 6023,    -- Eviscerate
    6024, 6025, 6026,                 -- Envenom
    6032,                             -- Rupture
    6033                              -- Garrote
);

-- Combat (1): Sinister Strike, Backstab, Fan of Knives
UPDATE `affix_template` SET `spec_tree` = 1
WHERE `id` IN (
    6000, 6001, 6002, 6003, 6004,    -- Sinister Strike
    6005, 6006, 6007, 6008, 6009,    -- Backstab
    6027, 6028, 6029                  -- Fan of Knives
);

-- Subtlety (2): Hemorrhage
UPDATE `affix_template` SET `spec_tree` = 2
WHERE `id` IN (
    6030, 6031                        -- Hemorrhage
);
