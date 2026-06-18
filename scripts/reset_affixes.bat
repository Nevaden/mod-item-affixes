@echo off
setlocal

set SCRIPT_DIR=%~dp0

if exist "%SCRIPT_DIR%local_config.bat" call "%SCRIPT_DIR%local_config.bat"
if not exist "%SCRIPT_DIR%db_config.bat" (
    echo ERROR: scripts\db_config.bat not found.
    echo Copy scripts\db_config.bat.example to scripts\db_config.bat and fill in your local MySQL credentials.
    pause & exit /b 1
)
call "%SCRIPT_DIR%db_config.bat"

set SQL_RESET=%SCRIPT_DIR%..\data\sql\db-characters\reset_item_affixes.sql

echo ============================================================
echo  mod-item-affixes -- RESET PLAYER AFFIXES
echo.
echo  WARNING: This will DELETE all rows from item_affix.
echo  All player items will lose their rolled affixes.
echo  Use only for testing or after a major affix system change.
echo ============================================================
echo.
echo Press Ctrl+C to cancel, or any key to continue...
pause > nul

%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_RESET%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to apply reset_item_affixes.sql
    pause & exit /b 1
)
echo   Done. All item_affix rows cleared.
echo   Restart worldserver - items will re-initialize to UNROLLED on next login/pickup.
echo.
pause
endlocal
