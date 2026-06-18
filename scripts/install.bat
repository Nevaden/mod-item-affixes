@echo off
setlocal
set SCRIPT_DIR=%~dp0
set MODULE_ROOT=%SCRIPT_DIR%..
set SQL_WORLD=%MODULE_ROOT%\data\sql\db-world
set SQL_CHARS=%MODULE_ROOT%\data\sql\db-characters

echo ============================================================
echo  mod-item-affixes -- INSTALL
echo.
echo  What this script does:
echo    1. Validates your db_config.bat settings
echo    2. Creates schema tables in the characters and world DBs
echo    3. Generates and applies all affix/imprint/spell data SQL
echo    4. Patches SpellItemEnchantment.dbc and Spell.dbc
echo    5. Rebuilds client MPQ patch files
echo.
echo  Complete these steps BEFORE running install.bat:
echo    a) Copy scripts\db_config.bat.example to scripts\db_config.bat
echo       and fill in all values
echo    b) Run scripts\apply_core_patches.ps1 to patch the engine
echo    c) Build the worldserver (cmake --build then --install)
echo    d) Install the client addon: addon\ItemAffixes\ to WoW\Interface\AddOns\
echo ============================================================
echo.
echo Press Ctrl+C to cancel, or any key to continue...
pause > nul

REM ── Load config ─────────────────────────────────────────────────────────────
if exist "%SCRIPT_DIR%local_config.bat" call "%SCRIPT_DIR%local_config.bat"
if not exist "%SCRIPT_DIR%db_config.bat" (
    echo ERROR: scripts\db_config.bat not found.
    echo        Copy scripts\db_config.bat.example to scripts\db_config.bat and fill it in.
    pause & exit /b 1
)
call "%SCRIPT_DIR%db_config.bat"

REM ── Step 1: Validate config ──────────────────────────────────────────────────
echo [1/5] Checking configuration...
call "%SCRIPT_DIR%test_config.bat"
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Fix the configuration issues above, then re-run install.bat.
    pause & exit /b 1
)
echo.

REM ── Step 2: Copy module conf ─────────────────────────────────────────────────
echo [2/5] Setting up module config file...
REM Derive conf location from SERVER_DBC_DIR (env\dist\data\dbc -> env\dist\configs\modules)
set CONF_MODULES=%SERVER_DBC_DIR%\..\..\..\configs\modules
set CONF_DIST=%CONF_MODULES%\mod_item_affixes.conf.dist
set CONF=%CONF_MODULES%\mod_item_affixes.conf
if exist "%CONF%" (
    echo   mod_item_affixes.conf already exists -- skipping.
) else if exist "%CONF_DIST%" (
    copy "%CONF_DIST%" "%CONF%" > nul
    echo   Copied mod_item_affixes.conf.dist -> mod_item_affixes.conf
    echo   Edit %CONF% to tune module settings.
) else (
    echo   NOTE: mod_item_affixes.conf.dist not found at:
    echo   %CONF_DIST%
    echo   Make sure cmake install has been run, then copy .conf.dist to .conf manually.
    echo   The module still works with hardcoded defaults without the conf file.
)
echo.

REM ── Step 3: Create DB schema ─────────────────────────────────────────────────
echo [3/5] Creating database schema tables...
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_CHARS%\item_affix.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: item_affix.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_CHARS%\item_talent_affix.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: item_talent_affix.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_CHARS%\item_imprint.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: item_imprint.sql failed & pause & exit /b 1 )
echo   Characters DB schema ready.
echo.

REM ── Step 4: Generate and apply data SQL ──────────────────────────────────────
echo [4/5] Generating and applying affix, imprint, and spell data...

powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_affixes.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: build_affixes.ps1 failed & pause & exit /b 1 )
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_talent_affixes.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: build_talent_affixes.ps1 failed & pause & exit /b 1 )

%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\affix_template.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: affix_template.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\talent_affix_def.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: talent_affix_def.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\imprint_def.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: imprint_def.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\imprint_rune_items.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: imprint_rune_items.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\spell_script_names_imprint.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_script_names_imprint.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\spell_dbc_celestial_resonance.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_dbc_celestial_resonance.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\spell_dbc_vanishing_backstab.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_dbc_vanishing_backstab.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\spell_dbc_arcane_shot_variants.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_dbc_arcane_shot_variants.sql failed & pause & exit /b 1 )
echo   All data SQL applied.
echo.

REM ── Step 5: Rebuild client DBC and MPQ ───────────────────────────────────────
echo [5/5] Patching client DBC files and rebuilding MPQ patches...
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%patch_dbc.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_dbc.ps1 failed & pause & exit /b 1 )
powershell -ExecutionPolicy Bypass -File "%MODULE_ROOT%\tools\patch_custom_spells.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_custom_spells.ps1 failed & pause & exit /b 1 )
echo.

echo ============================================================
echo  Installation complete!
echo.
echo  Start the worldserver. You should see:
echo    mod-item-affixes: loaded NNN affix template(s).
echo    mod-item-affixes: loaded NNN talent affix def(s).
echo    mod-item-affixes: Loaded N Imprint definition(s).
echo.
echo  If the client is on a separate machine, copy the MPQ files
echo  from your WoW Data folder to that machine.
echo ============================================================
echo.
pause
endlocal
