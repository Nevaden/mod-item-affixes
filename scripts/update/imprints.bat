@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..
set MODULE_ROOT=%SCRIPT_DIR%..\..
set SQL_WORLD=%MODULE_ROOT%\data\sql\db-world

echo ============================================================
echo  mod-item-affixes -- UPDATE: Imprints
echo  Reloads imprint SQL and rebuilds the client spell patch.
echo  Run after editing imprint_def.sql or custom_spells.json
echo ============================================================
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    pause & exit /b 1
)
if exist "%SCRIPTS_ROOT%\local_config.bat" call "%SCRIPTS_ROOT%\local_config.bat"
call "%SCRIPTS_ROOT%\config.bat"

echo Applying imprint SQL to %DB_WORLD%...
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
echo   SQL applied.
echo.

echo Rebuilding client spell patch...
powershell -ExecutionPolicy Bypass -File "%MODULE_ROOT%\tools\patch_custom_spells.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_custom_spells.ps1 failed & pause & exit /b 1 )
echo.

echo ============================================================
echo  Imprints updated.
echo  Restart worldserver + WoW client to apply.
echo ============================================================
echo.
pause
endlocal
