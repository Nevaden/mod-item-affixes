@echo off
setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..
set MODULE_ROOT=%SCRIPT_DIR%..\..
set SQL_WORLD=%MODULE_ROOT%\data\sql\db-world
set SQL_IMPRINTS=%SQL_WORLD%\imprints

echo ============================================================
echo  mod-item-affixes -- FULL UPDATE  (run after any git pull)
echo.
echo  Covers everything in one shot:
echo    [1] Generic, class, and talent affixes (JSON -> SQL -> DB)
echo    [2] All imprint definitions, rune items, creatures,
echo        spell DBC overrides, and script bindings
echo    [3] Client patch files (Spell.dbc + SkillLineAbility.dbc)
echo.
echo  Safe to re-run at any time -- all SQL uses upserts.
echo  Does NOT touch player data or DB schema.
echo ============================================================
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    echo        Copy scripts\config.bat.example to scripts\config.bat and fill it in.
    pause & exit /b 1
)
if exist "%SCRIPTS_ROOT%\local_config.bat" call "%SCRIPTS_ROOT%\local_config.bat"
call "%SCRIPTS_ROOT%\config.bat"

echo [1/3] Generating and applying affix data...
powershell -ExecutionPolicy Bypass -File "%SCRIPTS_ROOT%\build_affixes.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: build_affixes.ps1 failed & pause & exit /b 1 )
powershell -ExecutionPolicy Bypass -File "%SCRIPTS_ROOT%\build_talent_affixes.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: build_talent_affixes.ps1 failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\affix_template.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: affix_template.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\talent_affix_def.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: talent_affix_def.sql failed & pause & exit /b 1 )
echo   Done.
echo.

echo [2/3] Applying imprint data...
for %%f in ("%SQL_IMPRINTS%\*.sql") do (
    echo   Applying %%~nxf...
    %MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%%f"
    if !ERRORLEVEL! neq 0 ( echo ERROR: %%~nxf failed & pause & exit /b 1 )
)
echo   Done.
echo.

echo [3/3] Rebuilding client patch files...
powershell -ExecutionPolicy Bypass -File "%SCRIPTS_ROOT%\patch_dbc.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_dbc.ps1 failed & pause & exit /b 1 )
powershell -ExecutionPolicy Bypass -File "%MODULE_ROOT%\tools\patch_custom_spells.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_custom_spells.ps1 failed & pause & exit /b 1 )
echo   Done.
echo.

echo ============================================================
echo  All updates applied.
echo  Restart worldserver + WoW client to apply changes.
echo ============================================================
echo.
pause
endlocal
