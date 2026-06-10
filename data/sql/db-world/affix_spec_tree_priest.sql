-- Priest class affix spec_tree assignments.
-- Source: in-game trainer section / spellbook tab (P key).
-- 0=Discipline  1=Holy  2=Shadow

-- Discipline (0): Penance
UPDATE `affix_template` SET `spec_tree` = 0
WHERE `id` IN (
    1029, 1030, 1031                  -- Penance
);

-- Holy (1): Smite, Desperate Prayer, Holy Fire, Holy Nova, Lightwell,
--           Binding Heal, Circle of Healing, Flash Heal, Greater Heal,
--           Prayer of Mending, Renew, Divine Hymn
UPDATE `affix_template` SET `spec_tree` = 1
WHERE `id` IN (
    1000, 1001, 1002, 1003, 1004,    -- Smite
    1008, 1009, 1010,                 -- Desperate Prayer
    1011, 1012, 1013, 1014, 1015,    -- Holy Fire
    1016, 1017, 1018,                 -- Holy Nova
    1019, 1020,                       -- Lightwell
    1032, 1033, 1034, 1035,          -- Binding Heal
    1036, 1037, 1038, 1039,          -- Circle of Healing
    1040, 1041, 1042, 1043, 1044,    -- Flash Heal
    1045, 1046, 1047, 1048, 1049,    -- Greater Heal
    1050, 1051, 1052,                 -- Prayer of Mending
    1053, 1054, 1055, 1056,          -- Renew
    1057, 1058, 1059                  -- Divine Hymn
);

-- Shadow (2): Psychic Scream, Mind Blast, Mind Sear
UPDATE `affix_template` SET `spec_tree` = 2
WHERE `id` IN (
    1005, 1006, 1007,                 -- Psychic Scream
    1021, 1022, 1023, 1024, 1025,    -- Mind Blast
    1026, 1027, 1028                  -- Mind Sear
);
