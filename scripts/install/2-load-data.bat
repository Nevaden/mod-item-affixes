@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..
set MODULE_ROOT=%SCRIPT_DIR%..\..
set SQL_WORLD=%MODULE_ROOT%\data\sql\db-world

echo ============================================================
echo  mod-item-affixes -- INSTALL Step 2 of 3: Load Data
echo  Generates SQL from JSON and applies all affix, imprint,
echo  and custom spell data to the world database.
echo ============================================================
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    echo        Copy scripts\config.bat.example to scripts\config.bat and fill it in.
    pause & exit /b 1
)
if exist "%SCRIPTS_ROOT%\local_config.bat" call "%SCRIPTS_ROOT%\local_config.bat"
call "%SCRIPTS_ROOT%\config.bat"

echo Generating SQL from JSON definitions...
powershell -ExecutionPolicy Bypass -File "%SCRIPTS_ROOT%\build_affixes.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: build_affixes.ps1 failed & pause & exit /b 1 )
powershell -ExecutionPolicy Bypass -File "%SCRIPTS_ROOT%\build_talent_affixes.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: build_talent_affixes.ps1 failed & pause & exit /b 1 )
echo   SQL generated.
echo.

echo Applying world DB data to %DB_WORLD%...
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
echo   All data applied.
echo.

echo ============================================================
echo  Step 2 complete.
echo  Next: run install\3-patch-client.bat  (Windows client patch)
echo  Then: start the worldserver and confirm affixes loaded.
echo ============================================================
echo.
pause
endlocal
