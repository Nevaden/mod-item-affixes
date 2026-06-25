@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..
set MODULE_ROOT=%SCRIPT_DIR%..\..

echo ============================================================
echo  mod-item-affixes -- INSTALL Step 0 (pre-build)
echo  Apply required AzerothCore engine patches.
echo  Run this BEFORE cmake / Rebuild-Server.bat.
echo  Safe to run more than once (all patches are idempotent).
echo ============================================================
echo.

powershell -ExecutionPolicy Bypass -File "%SCRIPTS_ROOT%\apply_core_patches.ps1"
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: apply_core_patches.ps1 failed.
    echo        See CORE_PATCHES.md to apply the failing patch by hand.
    pause & exit /b 1
)

echo.
echo ============================================================
echo  Step 0 complete.
echo.
echo  What to do next:
echo    1. Build the server  -- run Rebuild-Server.bat
echo    2. Start the server once so it creates mod config files
echo    3. Run install\1-create-schema.bat
echo    4. Run install\2-load-data.bat
echo    5. Run install\3-patch-client.bat
echo ============================================================
echo.
pause
endlocal
