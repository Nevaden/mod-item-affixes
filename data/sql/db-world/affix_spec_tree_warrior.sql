-- Warrior class affix spec_tree assignments.
-- Source: in-game trainer section / spellbook tab (P key).
-- 0=Arms  1=Fury  2=Protection  255=no restriction (General tab)
-- All warrior class affixes previously had spec_tree=255.

-- Arms (0): Mortal Strike, Heroic Strike, Overpower, Thunder Clap, Rend
UPDATE `affix_template` SET `spec_tree` = 0
WHERE `id` IN (
    3005, 3006, 3007, 3008,          -- Mortal Strike
    3009, 3010, 3011,                 -- Heroic Strike
    3019, 3020, 3021,                 -- Overpower
    3031, 3032, 3033, 3034,          -- Thunder Clap
    3038, 3039, 3040                  -- Rend
);

-- Fury (1): Bloodthirst, Execute, Whirlwind, Slam, Victory Rush
UPDATE `affix_template` SET `spec_tree` = 1
WHERE `id` IN (
    3000, 3001, 3002, 3003, 3004,    -- Bloodthirst
    3012, 3013, 3014,                 -- Execute
    3015, 3016, 3017, 3018,          -- Whirlwind
    3026, 3027, 3028, 3029, 3030,    -- Slam
    3044                              -- Victory Rush
);

-- Protection (2): Revenge, Devastate, Shield Slam
UPDATE `affix_template` SET `spec_tree` = 2
WHERE `id` IN (
    3022, 3023, 3024, 3025,          -- Revenge
    3035, 3036, 3037,                 -- Devastate
    3041, 3042, 3043                  -- Shield Slam
);
