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

set SQL_WORLD=%SCRIPT_DIR%..\data\sql\db-world\affix_template.sql
set SQL_CHARS=%SCRIPT_DIR%..\data\sql\db-characters\item_affix.sql
set SQL_TALENT_WORLD=%SCRIPT_DIR%..\data\sql\db-world\talent_affix_def.sql
set SQL_TALENT_CHARS=%SCRIPT_DIR%..\data\sql\db-characters\item_talent_affix.sql

echo ============================================================
echo  mod-item-affixes -- FULL UPDATE
echo.
echo  Steps:
echo    1. Regenerate SQL from affixes.json
echo    2. Apply SQL to databases
echo    3. Sync DBC entries + rebuild client MPQ
echo ============================================================
echo.

REM -- Step 1: Regenerate SQL ----------------------------------------------
echo [1/4] Generating SQL from JSON files...
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_affixes.ps1"
if %ERRORLEVEL% neq 0 (
    echo ERROR: build_affixes.ps1 failed. Check affixes.json for syntax errors.
    pause & exit /b 1
)
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_talent_affixes.ps1"
if %ERRORLEVEL% neq 0 (
    echo ERROR: build_talent_affixes.ps1 failed. Check affixes/talent_affixes.json for syntax errors.
    pause & exit /b 1
)
echo.

REM -- Step 2: Apply SQL ---------------------------------------------------
echo [2/4] Applying SQL to databases...
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_CHARS%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to apply item_affix.sql
    pause & exit /b 1
)
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_WORLD%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to apply affix_template.sql
    pause & exit /b 1
)
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_TALENT_CHARS%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to apply item_talent_affix.sql
    pause & exit /b 1
)
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% < "%SQL_TALENT_WORLD%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to apply talent_affix_def.sql
    pause & exit /b 1
)
echo   SQL applied successfully.
echo.

REM -- Step 3: Patch DBC + rebuild client MPQ ------------------------------
echo [3/4] Syncing DBC entries and rebuilding client MPQ patch files...
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%patch_dbc.ps1"
if %ERRORLEVEL% neq 0 (
    echo ERROR: patch_dbc.ps1 failed. Check that tools\mpqbuild.exe exists.
    pause & exit /b 1
)
echo.

echo [3/3] Done. Restart the worldserver manually to apply the DB and DBC changes.
echo.

echo ============================================================
echo  Done! All steps completed successfully.
echo ============================================================
echo.
pause
endlocal
