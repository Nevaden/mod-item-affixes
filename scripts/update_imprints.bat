@echo off
setlocal

set SCRIPT_DIR=%~dp0

if exist "%SCRIPT_DIR%local_config.bat" call "%SCRIPT_DIR%local_config.bat"
if not exist "%SCRIPT_DIR%db_config.bat" (
    echo ERROR: scripts\db_config.bat not found.
    echo Copy scripts\db_config.bat.example to scripts\db_config.bat and fill in your local MySQL credentials.
    pause & exit /b 1
)
call "%SCRIPT_DIR%db_config.bat"

set SQL_DIR=%SCRIPT_DIR%..\data\sql\db-world

echo ============================================================
echo  mod-item-affixes -- IMPRINT UPDATE
echo.
echo  Steps:
echo    1. Apply imprint SQL to world database
echo    2. Rebuild client DBC / MPQ patch files
echo ============================================================
echo.

REM ── Step 1: Apply SQL ───────────────────────────────────────────────────
echo [1/3] Applying imprint SQL to %DB_WORLD%...

REM Table definitions and type rows
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_DIR%\imprint_def.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: imprint_def.sql failed & pause & exit /b 1 )

REM Rune item templates
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_DIR%\imprint_rune_items.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: imprint_rune_items.sql failed & pause & exit /b 1 )

REM Script name bindings (all imprint spells)
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_DIR%\spell_script_names_imprint.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_script_names_imprint.sql failed & pause & exit /b 1 )

REM Server-side spell_dbc overrides for each custom imprint spell
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_DIR%\spell_dbc_celestial_resonance.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_dbc_celestial_resonance.sql failed & pause & exit /b 1 )

%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_DIR%\spell_dbc_vanishing_backstab.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_dbc_vanishing_backstab.sql failed & pause & exit /b 1 )

echo   SQL applied successfully.
echo.

REM ── Step 2: Rebuild client DBC + MPQ ────────────────────────────────────
echo [2/3] Rebuilding client DBC and MPQ patch files...
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\tools\patch_custom_spells.ps1"
if %ERRORLEVEL% neq 0 (
    echo ERROR: patch_custom_spells.ps1 failed.
    pause & exit /b 1
)
echo.

echo [3/3] Done. Restart the worldserver manually to apply the DB and DBC changes.
echo.

echo ============================================================
echo  Done! All imprint steps completed successfully.
echo  Test with:  .imprint grant 6    (Vanishing Backstab on a Rogue)
echo ============================================================
echo.
pause
endlocal
