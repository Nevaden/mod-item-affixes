@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..
set MODULE_ROOT=%SCRIPT_DIR%..\..
set SQL_RESET=%MODULE_ROOT%\data\sql\db-characters\reset_item_affixes.sql

echo ============================================================
echo  mod-item-affixes -- RESET PLAYER AFFIXES
echo.
echo  WARNING: Deletes ALL rows from item_affix.
echo  Every player item loses its rolled affix data.
echo  Use only for testing or after a major affix rebalance.
echo  Items will re-roll on next pickup or login.
echo ============================================================
echo.
echo Press Ctrl+C to cancel, or any key to continue...
pause > nul

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    pause & exit /b 1
)
call "%SCRIPTS_ROOT%\config.bat"

%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_RESET%"
if %ERRORLEVEL% neq 0 ( echo ERROR: reset_item_affixes.sql failed & pause & exit /b 1 )
echo   Done. All item_affix rows cleared.
echo   Restart worldserver -- items will re-roll on next login or pickup.
echo.
pause
endlocal
