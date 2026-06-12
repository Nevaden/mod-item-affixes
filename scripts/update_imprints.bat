@echo off
setlocal

set MYSQL="C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe"
set USER=acore
set PASS=UnlimitedCosmicPower
set SCRIPT_DIR=%~dp0
set SQL_DIR=%SCRIPT_DIR%..\data\sql\db-world
set WS_EXE=E:\servers\Wow\Standard\bin\worldserver.exe
set WS_CFG=E:\servers\Wow\Standard\bin\configs\worldserver.conf
set WS_DIR=E:\servers\Wow\Standard\bin

echo ============================================================
echo  mod-item-affixes -- IMPRINT UPDATE
echo.
echo  Steps:
echo    1. Apply imprint SQL to acore_world
echo    2. Rebuild client DBC / MPQ patch files
echo ============================================================
echo.

REM ── Step 1: Apply SQL ───────────────────────────────────────────────────
echo [1/3] Applying imprint SQL to acore_world...

REM Table definitions and type rows
%MYSQL% -u %USER% -p%PASS% acore_world < "%SQL_DIR%\imprint_def.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: imprint_def.sql failed & pause & exit /b 1 )

REM Rune item templates
%MYSQL% -u %USER% -p%PASS% acore_world < "%SQL_DIR%\imprint_rune_items.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: imprint_rune_items.sql failed & pause & exit /b 1 )

REM Script name bindings (all imprint spells)
%MYSQL% -u %USER% -p%PASS% acore_world < "%SQL_DIR%\spell_script_names_imprint.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_script_names_imprint.sql failed & pause & exit /b 1 )

REM Server-side spell_dbc overrides for each custom imprint spell
%MYSQL% -u %USER% -p%PASS% acore_world < "%SQL_DIR%\spell_dbc_celestial_resonance.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_dbc_celestial_resonance.sql failed & pause & exit /b 1 )

%MYSQL% -u %USER% -p%PASS% acore_world < "%SQL_DIR%\spell_dbc_vanishing_backstab.sql"
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
