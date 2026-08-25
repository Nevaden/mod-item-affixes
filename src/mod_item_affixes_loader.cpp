void AddSC_item_affix_scripts();
void AddSC_item_affix_commands();
void AddSC_item_imprint_commands();
void AddSC_progression_boss_drops();
void AddSC_progression_lifesteal();

// Registers each concrete ImprintEffect with ImprintMgr.
// Add a call here for every new Imprint type.
void RegisterSanctuaryStormImprint();
void RegisterEmpyreanEchoImprint();
void RegisterFeralStampedeImprint();
void RegisterFeralAlphaImprint();
void RegisterCelestialResonanceImprint();
void RegisterVanishingBackstabImprint();
void RegisterEternalElementalImprint();
void RegisterApexMangleImprint();
void RegisterAncientTigerImprint();

void Addmod_item_affixesScripts()
{
    // --- existing affix system ---
    AddSC_item_affix_scripts();
    AddSC_item_affix_commands();

    // --- Imprint command script ---
    AddSC_item_imprint_commands();

    // --- Player Progression: Boss Drops node ---
    AddSC_progression_boss_drops();

    // --- Player Progression: Lifesteal node ---
    AddSC_progression_lifesteal();

    // --- Register all Imprint effect handlers ---
    RegisterSanctuaryStormImprint();
    RegisterEmpyreanEchoImprint();
    RegisterFeralStampedeImprint();
    RegisterFeralAlphaImprint();
    RegisterCelestialResonanceImprint();
    RegisterVanishingBackstabImprint();
    RegisterEternalElementalImprint();
    RegisterApexMangleImprint();
    RegisterAncientTigerImprint();
}
