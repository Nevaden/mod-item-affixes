@echo off
setlocal
set SCRIPT_DIR=%~dp0
set MODULE_ROOT=%SCRIPT_DIR%..
set SQL_WORLD=%MODULE_ROOT%\data\sql\db-world
set SQL_CHARS=%MODULE_ROOT%\data\sql\db-characters

echo ============================================================
echo  mod-item-affixes -- UPDATE DEFINITIONS
echo.
echo  Applies all affix, imprint, and custom spell changes from
echo  the latest JSON definitions and rebuilds client MPQ files.
echo  Run this after pulling new mod updates from git.
echo ============================================================
echo.

REM ── Load config ─────────────────────────────────────────────────────────────
if exist "%SCRIPT_DIR%local_config.bat" call "%SCRIPT_DIR%local_config.bat"
if not exist "%SCRIPT_DIR%db_config.bat" (
    echo ERROR: scripts\db_config.bat not found.
    echo        Copy scripts\db_config.bat.example to scripts\db_config.bat and fill it in.
    pause & exit /b 1
)
call "%SCRIPT_DIR%db_config.bat"

REM ── Step 1: Validate config ──────────────────────────────────────────────────
echo [1/4] Checking configuration...
call "%SCRIPT_DIR%test_config.bat"
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Fix the configuration issues above, then re-run update.bat.
    pause & exit /b 1
)
echo.

REM ── Step 2: Regenerate SQL from JSON ────────────────────────────────────────
echo [2/4] Generating SQL from JSON definitions...
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_affixes.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: build_affixes.ps1 failed & pause & exit /b 1 )
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_talent_affixes.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: build_talent_affixes.ps1 failed & pause & exit /b 1 )
echo.

REM ── Step 3: Apply data SQL ───────────────────────────────────────────────────
echo [3/4] Applying updated data SQL...
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
echo   Done.
echo.

REM ── Step 4: Rebuild client DBC and MPQ ───────────────────────────────────────
echo [4/4] Patching client DBC files and rebuilding MPQ patches...
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%patch_dbc.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_dbc.ps1 failed & pause & exit /b 1 )
powershell -ExecutionPolicy Bypass -File "%MODULE_ROOT%\tools\patch_custom_spells.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_custom_spells.ps1 failed & pause & exit /b 1 )
echo.

echo ============================================================
echo  Update complete. Restart the worldserver to apply changes.
echo  Restart the WoW client to pick up updated MPQ patches.
echo ============================================================
echo.
pause
endlocal
