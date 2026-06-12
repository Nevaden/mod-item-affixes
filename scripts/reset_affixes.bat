@echo off
setlocal

REM ── Configure for your installation ──────────────────────────────────────
set MYSQL="C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe"
set USER=acore
set PASS=YOUR_PASSWORD
REM ──────────────────────────────────────────────────────────────────────────

set SCRIPT_DIR=%~dp0
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

%MYSQL% -u %USER% -p%PASS% acore_characters < "%SQL_RESET%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to apply reset_item_affixes.sql
    pause & exit /b 1
)
echo   Done. All item_affix rows cleared.
echo   Restart worldserver — items will re-initialize to UNROLLED on next login/pickup.
echo.
pause
endlocal
