@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..

echo ============================================================
echo  mod-item-affixes -- UNINSTALL Step 1 of 3: Drop Tables
echo.
echo  WARNING: Permanently deletes ALL player affix data.
echo    Drops from characters DB: item_affix, item_talent_affix,
echo    item_imprint
echo.
echo  This cannot be undone.
echo ============================================================
echo.
echo  Type UNINSTALL and press Enter to confirm (Ctrl+C to cancel):
set /p CONFIRM=
if /i not "%CONFIRM%"=="UNINSTALL" (
    echo Cancelled. No changes made.
    pause & exit /b 0
)
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    echo        Copy scripts\config.bat.example to scripts\config.bat and fill it in.
    pause & exit /b 1
)
call "%SCRIPTS_ROOT%\config.bat"

echo Dropping character DB tables from %DB_CHAR%...
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% -e ^
  "DROP TABLE IF EXISTS item_affix, item_talent_affix, item_imprint;"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to drop character tables.
    pause & exit /b 1
)
echo   Dropped: item_affix, item_talent_affix, item_imprint
echo.

echo ============================================================
echo  Step 1 complete.
echo  Next: run uninstall\2-clean-world-data.bat
echo ============================================================
echo.
pause
endlocal
