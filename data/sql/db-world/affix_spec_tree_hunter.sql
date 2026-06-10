-- Hunter class affix spec_tree assignments.
-- Source: in-game trainer section / spellbook tab (P key).
-- 0=Beast Mastery  1=Marksmanship  2=Survival

-- Marksmanship (1): Arcane Shot, Multi-Shot, Steady Shot, Aimed Shot, Kill Shot, Serpent Sting
UPDATE `affix_template` SET `spec_tree` = 1
WHERE `id` IN (
    5000, 5001, 5002, 5003,          -- Arcane Shot
    5004, 5005, 5006, 5007,          -- Multi-Shot
    5008, 5009, 5010, 5011, 5012,    -- Steady Shot
    5013, 5014,                       -- Aimed Shot
    5018, 5019, 5020,                 -- Kill Shot
    5025, 5026, 5027                  -- Serpent Sting
);

-- Survival (2): Explosive Shot, Black Arrow, Raptor Strike
UPDATE `affix_template` SET `spec_tree` = 2
WHERE `id` IN (
    5021, 5022, 5023, 5024,          -- Explosive Shot
    5028, 5029, 5030,                 -- Black Arrow
    5031, 5032, 5033                  -- Raptor Strike
);
