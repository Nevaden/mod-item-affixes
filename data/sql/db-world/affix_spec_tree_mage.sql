-- Mage class affix spec_tree assignments.
-- Source: in-game trainer section / spellbook tab (P key).
-- 0=Arcane  1=Fire  2=Frost

-- Fire (1): Fireball, Scorch, Pyroblast, Fire Blast, Flamestrike, Blast Wave, Dragon's Breath
UPDATE `affix_template` SET `spec_tree` = 1
WHERE `id` IN (
    2000, 2001, 2002,                -- Fireball
    2003, 2004, 2005,                -- Scorch
    2006, 2007, 2008,                -- Pyroblast
    2009, 2010, 2011,                -- Fire Blast
    2012, 2013, 2014,                -- Flamestrike
    2015, 2016, 2017,                -- Blast Wave
    2018, 2019, 2020                 -- Dragon's Breath
);

-- Arcane (0): Arcane Missiles, Arcane Blast, Arcane Barrage, Arcane Explosion, Arcane Power, Polymorph, Blink
UPDATE `affix_template` SET `spec_tree` = 0
WHERE `id` IN (
    2021, 2022, 2023,                -- Arcane Missiles
    2024, 2025, 2026,                -- Arcane Blast
    2027, 2028, 2029,                -- Arcane Barrage
    2030, 2031,                      -- Arcane Explosion
    2032, 2033,                      -- Arcane Power
    2042, 2043,                      -- Polymorph
    2044, 2045                       -- Blink
);

-- Frost (2): Blizzard, Ice Lance, Ice Block, Icy Veins, Summon Water Elemental, Frostbolt
UPDATE `affix_template` SET `spec_tree` = 2
WHERE `id` IN (
    2034, 2035,                      -- Blizzard
    2036, 2037,                      -- Ice Lance
    2038, 2039,                      -- Ice Block
    2040, 2041,                      -- Icy Veins
    2046, 2047,                      -- Summon Water Elemental
    2048, 2049, 2050, 2051, 2052, 2053, 2054  -- Frostbolt
);
