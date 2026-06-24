@echo off
setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..
set MODULE_ROOT=%SCRIPT_DIR%..\..
set SQL_WORLD=%MODULE_ROOT%\data\sql\db-world
set SQL_IMPRINTS=%SQL_WORLD%\imprints

echo ============================================================
echo  mod-item-affixes -- UPDATE: Imprints
echo  Applies all SQL from data\sql\db-world\imprints\ and
echo  rebuilds the client spell patch.
echo  Run after editing imprint definitions or adding new imprints.
echo  (For a full update including affixes, run update-all.bat instead.)
echo ============================================================
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    pause & exit /b 1
)
if exist "%SCRIPTS_ROOT%\local_config.bat" call "%SCRIPTS_ROOT%\local_config.bat"
call "%SCRIPTS_ROOT%\config.bat"

echo Applying imprint SQL to %DB_WORLD%...
for %%f in ("%SQL_IMPRINTS%\*.sql") do (
    echo   Applying %%~nxf...
    %MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%%f"
    if !ERRORLEVEL! neq 0 ( echo ERROR: %%~nxf failed & pause & exit /b 1 )
)
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
