-- Bind module SpellScripts/AuraScripts to their spells.
INSERT INTO `spell_script_names` (`spell_id`, `ScriptName`)
VALUES
  (53385,  'spell_divine_storm_imprint'),       -- Paladin: Divine Storm (Empyrean Echo)
  (53595,  'spell_hammer_righteous_imprint'),   -- Paladin: Hammer of the Righteous (Righteous Sanctuary)
  (51533,  'spell_feral_spirit_imprint'),        -- Shaman:  Feral Spirit
  (31687,  'spell_summon_water_elemental_imprint'), -- Mage:    Summon Water Elemental (Eternal Elemental)
  (13262,  'spell_disenchant_imprint'),          -- All:     Disenchant (Imprint rune recovery)
  -- Priest: Celestial Resonance aura (custom spell 600002)
  (600002, 'spell_celestial_resonance'),
  -- Rogue: Vanishing Backstab (custom spell 600003)
  (600003, 'spell_vanishing_backstab')
ON DUPLICATE KEY UPDATE `ScriptName` = VALUES(`ScriptName`);

-- Druid: Rake (all ranks) → spell_rake_imprint
INSERT INTO `spell_script_names` (`spell_id`, `ScriptName`)
SELECT `spell_id`, 'spell_rake_imprint'
FROM `spell_ranks`
WHERE `first_spell_id` = 1822
ON DUPLICATE KEY UPDATE `ScriptName` = VALUES(`ScriptName`);

-- Druid: Tiger's Fury (single rank 5217) → spell_tigers_fury_imprint
INSERT INTO `spell_script_names` (`spell_id`, `ScriptName`)
VALUES (5217, 'spell_tigers_fury_imprint')
ON DUPLICATE KEY UPDATE `ScriptName` = VALUES(`ScriptName`);

-- Druid: Moonfire (all ranks) → spell_moonfire_imprint
INSERT INTO `spell_script_names` (`spell_id`, `ScriptName`)
SELECT `spell_id`, 'spell_moonfire_imprint'
FROM `spell_ranks`
WHERE `first_spell_id` = 8921
ON DUPLICATE KEY UPDATE `ScriptName` = VALUES(`ScriptName`);
