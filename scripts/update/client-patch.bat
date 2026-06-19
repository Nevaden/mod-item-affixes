@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..
set MODULE_ROOT=%SCRIPT_DIR%..\..

echo ============================================================
echo  mod-item-affixes -- UPDATE: Client Patch  (Windows only)
echo  Rebuilds DBC and MPQ patch files from current definitions.
echo  Run after: any change that affects display names or spells.
echo ============================================================
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    pause & exit /b 1
)
if exist "%SCRIPTS_ROOT%\local_config.bat" call "%SCRIPTS_ROOT%\local_config.bat"
call "%SCRIPTS_ROOT%\config.bat"

echo Patching DBC and rebuilding MPQ files...
powershell -ExecutionPolicy Bypass -File "%SCRIPTS_ROOT%\patch_dbc.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_dbc.ps1 failed & pause & exit /b 1 )
powershell -ExecutionPolicy Bypass -File "%MODULE_ROOT%\tools\patch_custom_spells.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_custom_spells.ps1 failed & pause & exit /b 1 )

echo.
echo ============================================================
echo  Client patch rebuilt.
echo  Restart the WoW client to pick up updated MPQ files.
echo ============================================================
echo.
pause
endlocal
