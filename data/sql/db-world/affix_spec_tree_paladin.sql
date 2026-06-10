-- Paladin class affix spec_tree assignments.
-- Source: in-game trainer section / spellbook tab (P key).
-- 0=Holy  1=Protection  2=Retribution

-- Holy (0): Holy Shock, Exorcism, Consecration, Flash of Light, Holy Light
UPDATE `affix_template` SET `spec_tree` = 0
WHERE `id` IN (
    4008, 4009, 4010, 4011,          -- Holy Shock
    4012, 4013, 4014, 4015, 4016,    -- Exorcism
    4020, 4021, 4022,                 -- Consecration
    4027, 4028, 4029, 4030,          -- Flash of Light
    4031, 4032, 4033, 4034           -- Holy Light
);

-- Protection (1): Avenger's Shield, Shield of Righteousness, Hammer of the Righteous
UPDATE `affix_template` SET `spec_tree` = 1
WHERE `id` IN (
    4035, 4036, 4037,                 -- Avenger's Shield
    4038, 4039, 4040,                 -- Shield of Righteousness
    4041, 4042, 4043                  -- Hammer of the Righteous
);

-- Retribution (2): Crusader Strike, Divine Storm, Hammer of Wrath, Judgement
UPDATE `affix_template` SET `spec_tree` = 2
WHERE `id` IN (
    4000, 4001, 4002, 4003,          -- Crusader Strike
    4004, 4005, 4006, 4007,          -- Divine Storm
    4017, 4018, 4019,                 -- Hammer of Wrath
    4023, 4024, 4025, 4026           -- Judgement
);
