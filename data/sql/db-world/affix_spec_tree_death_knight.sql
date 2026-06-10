-- Death Knight class affix spec_tree assignments.
-- Source: in-game trainer section / spellbook tab (P key).
-- 0=Blood  1=Frost  2=Unholy

-- Frost (1): Icy Touch, Obliterate, Howling Blast, Frost Strike
UPDATE `affix_template` SET `spec_tree` = 1
WHERE `id` IN (
    10000, 10001, 10002,             -- Icy Touch
    10006, 10007, 10008,             -- Obliterate
    10009, 10010, 10011, 10012,      -- Howling Blast
    10016, 10017, 10018              -- Frost Strike
);

-- Unholy (2): Death Coil, Death and Decay, Scourge Strike
UPDATE `affix_template` SET `spec_tree` = 2
WHERE `id` IN (
    10003, 10004, 10005,             -- Death Coil
    10013, 10014, 10015,             -- Death and Decay
    10019, 10020, 10021              -- Scourge Strike
);
