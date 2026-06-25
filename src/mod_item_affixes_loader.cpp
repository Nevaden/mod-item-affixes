void AddSC_item_affix_scripts();
void AddSC_item_affix_commands();
void AddSC_item_imprint_commands();

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
