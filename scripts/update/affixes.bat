@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..
set MODULE_ROOT=%SCRIPT_DIR%..\..
set SQL_WORLD=%MODULE_ROOT%\data\sql\db-world

echo ============================================================
echo  mod-item-affixes -- UPDATE: Affixes
echo  Regenerates SQL from affixes JSON and reloads affix data.
echo  Run after editing affixes/*.json or class_affixes/*.json
echo ============================================================
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    pause & exit /b 1
)
call "%SCRIPTS_ROOT%\config.bat"

echo Generating SQL from JSON...
powershell -ExecutionPolicy Bypass -File "%SCRIPTS_ROOT%\build_affixes.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: build_affixes.ps1 failed & pause & exit /b 1 )
powershell -ExecutionPolicy Bypass -File "%SCRIPTS_ROOT%\build_talent_affixes.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: build_talent_affixes.ps1 failed & pause & exit /b 1 )
echo.

echo Applying to %DB_WORLD%...
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\affix_template.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: affix_template.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%\talent_affix_def.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: talent_affix_def.sql failed & pause & exit /b 1 )
echo   Done.
echo.

echo ============================================================
echo  Affixes updated. Restart worldserver to apply.
echo ============================================================
echo.
pause
endlocal
