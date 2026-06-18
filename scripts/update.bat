@echo off
setlocal

set SCRIPT_DIR=%~dp0
set MODULE_ROOT=%SCRIPT_DIR%..
set SQL_WORLD=%MODULE_ROOT%\data\sql\db-world
set SQL_CHARS=%MODULE_ROOT%\data\sql\db-characters

if exist "%SCRIPT_DIR%local_config.bat" call "%SCRIPT_DIR%local_config.bat"
if not exist "%SCRIPT_DIR%db_config.bat" (
    echo ERROR: scripts\db_config.bat not found.
    echo Copy scripts\db_config.bat.example to scripts\db_config.bat and fill in your local MySQL credentials.
    pause & exit /b 1
)
call "%SCRIPT_DIR%db_config.bat"

echo ============================================================
echo  mod-item-affixes -- FULL UPDATE
echo.
echo  Applies: affixes, talent affixes, imprints, custom spells,
echo           spell-swap variants, DBC patches, and MPQ rebuild.
echo ============================================================
echo.

REM ── Step 1: Regenerate SQL from JSON ────────────────────────────────────────
echo [1/5] Generating SQL from JSON files...
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_affixes.ps1"
if %ERRORLEVEL% neq 0 (
    echo ERROR: build_affixes.ps1 failed. Check affixes JSON for syntax errors.
    pause & exit /b 1
)
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_talent_affixes.ps1"
if %ERRORLEVEL% neq 0 (
    echo ERROR: build_talent_affixes.ps1 failed. Check talent_affixes.json for syntax errors.
    pause & exit /b 1
)
echo.

REM ── Step 2: Apply character-DB SQL ──────────────────────────────────────────
echo [2/5] Applying character-DB SQL (item_affix, item_talent_affix)...
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_CHARS%\item_affix.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: item_affix.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_CHARS%\item_talent_affix.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: item_talent_affix.sql failed & pause & exit /b 1 )
echo   Character DB updated.
echo.

REM ── Step 3: Apply world-DB SQL ──────────────────────────────────────────────
echo [3/5] Applying world-DB SQL (affixes, imprints, custom spells)...

REM Affix templates and talent affix definitions
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\affix_template.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: affix_template.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\talent_affix_def.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: talent_affix_def.sql failed & pause & exit /b 1 )

REM Imprint system
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\imprint_def.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: imprint_def.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\imprint_rune_items.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: imprint_rune_items.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\spell_script_names_imprint.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_script_names_imprint.sql failed & pause & exit /b 1 )

REM Custom spell_dbc overrides (server-side mechanics for all custom spells)
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\spell_dbc_celestial_resonance.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_dbc_celestial_resonance.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\spell_dbc_vanishing_backstab.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_dbc_vanishing_backstab.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\spell_dbc_arcane_shot_variants.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_dbc_arcane_shot_variants.sql failed & pause & exit /b 1 )

echo   World DB updated.
echo.

REM ── Step 4: Patch SpellItemEnchantment.dbc (tooltip text) ───────────────────
echo [4/5] Patching SpellItemEnchantment.dbc and rebuilding client MPQ patch...
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%patch_dbc.ps1"
if %ERRORLEVEL% neq 0 (
    echo ERROR: patch_dbc.ps1 failed. Check that tools\mpqbuild.exe exists.
    pause & exit /b 1
)
echo.

REM ── Step 5: Patch Spell.dbc + SkillLineAbility.dbc (custom spells) ──────────
echo [5/5] Patching Spell.dbc / SkillLineAbility.dbc and rebuilding client MPQ patch...
powershell -ExecutionPolicy Bypass -File "%MODULE_ROOT%\tools\patch_custom_spells.ps1"
if %ERRORLEVEL% neq 0 (
    echo ERROR: patch_custom_spells.ps1 failed. Check imprints\custom_spells.json.
    pause & exit /b 1
)
echo.

echo ============================================================
echo  Done! All steps completed successfully.
echo  Restart the worldserver to apply DB changes.
echo  Restart the WoW client to pick up the updated MPQ patches.
echo ============================================================
echo.
pause
endlocal
