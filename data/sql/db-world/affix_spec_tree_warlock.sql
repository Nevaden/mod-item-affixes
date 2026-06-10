-- Warlock class affix spec_tree assignments.
-- Source: in-game trainer section / spellbook tab (P key).
-- 0=Affliction  1=Demonology  2=Destruction

-- Affliction (0): Corruption, Curse of Agony, Haunt, Unstable Affliction
UPDATE `affix_template` SET `spec_tree` = 0
WHERE `id` IN (
    9008, 9009, 9010,                -- Corruption
    9014, 9015, 9016,                -- Curse of Agony
    9017, 9018, 9019,                -- Haunt
    9020, 9021, 9022                 -- Unstable Affliction
);

-- Destruction (2): Shadow Bolt, Incinerate, Immolate, Conflagrate, Soul Fire
UPDATE `affix_template` SET `spec_tree` = 2
WHERE `id` IN (
    9000, 9001, 9002, 9003,          -- Shadow Bolt
    9004, 9005, 9006, 9007,          -- Incinerate
    9011, 9012, 9013,                -- Immolate
    9023, 9024, 9025, 9026,          -- Conflagrate
    9027, 9028, 9029                 -- Soul Fire
);
