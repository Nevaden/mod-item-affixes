@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..
set MODULE_ROOT=%SCRIPT_DIR%..\..

echo ============================================================
echo  mod-item-affixes -- INSTALL Step 3 of 3: Patch Client
echo  Windows only. Patches DBC files and builds MPQ patch files
echo  so WoW displays correct affix and spell names.
echo ============================================================
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    echo        Copy scripts\config.bat.example to scripts\config.bat and fill it in.
    pause & exit /b 1
)
if exist "%SCRIPTS_ROOT%\local_config.bat" call "%SCRIPTS_ROOT%\local_config.bat"
call "%SCRIPTS_ROOT%\config.bat"

echo Patching SpellItemEnchantment.dbc and rebuilding DBC MPQ...
powershell -ExecutionPolicy Bypass -File "%SCRIPTS_ROOT%\patch_dbc.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_dbc.ps1 failed & pause & exit /b 1 )

echo.
echo Patching Spell.dbc and rebuilding custom spells MPQ...
powershell -ExecutionPolicy Bypass -File "%MODULE_ROOT%\tools\patch_custom_spells.ps1"
if %ERRORLEVEL% neq 0 ( echo ERROR: patch_custom_spells.ps1 failed & pause & exit /b 1 )

echo.
echo ============================================================
echo  Step 3 complete. Installation finished!
echo.
echo  What to do next:
echo    1. Start the worldserver
echo       Look for: mod-item-affixes: loaded NNN affix template(s)
echo    2. If your WoW client is on another machine, copy the MPQ
echo       files listed above from your Data folder to that machine
echo    3. Install the addon: addon\ItemAffixes\ into
echo       WoW\Interface\AddOns\ItemAffixes\
echo    4. Start the WoW client
echo ============================================================
echo.
pause
endlocal
