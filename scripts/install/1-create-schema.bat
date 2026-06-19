@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..
set MODULE_ROOT=%SCRIPT_DIR%..\..
set SQL_CHARS=%MODULE_ROOT%\data\sql\db-characters

echo ============================================================
echo  mod-item-affixes -- INSTALL Step 1 of 3: Create DB Schema
echo  Creates mod tables in the characters and world databases.
echo ============================================================
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    echo        Copy scripts\config.bat.example to scripts\config.bat and fill it in.
    pause & exit /b 1
)
call "%SCRIPTS_ROOT%\config.bat"

echo Creating character DB tables in %DB_CHAR%...
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_CHARS%\item_affix.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: item_affix.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_CHARS%\item_talent_affix.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: item_talent_affix.sql failed & pause & exit /b 1 )
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% < "%SQL_CHARS%\item_imprint.sql"
if %ERRORLEVEL% neq 0 ( echo ERROR: item_imprint.sql failed & pause & exit /b 1 )
echo   item_affix, item_talent_affix, item_imprint created.
echo.

REM Copy mod_item_affixes.conf.dist -> .conf if not already done
set CONF_MODULES=%SERVER_DBC_DIR%\..\..\..\env\dist\configs\modules
if exist "%CONF_MODULES%\mod_item_affixes.conf" (
    echo   mod_item_affixes.conf already exists -- skipping.
) else if exist "%CONF_MODULES%\mod_item_affixes.conf.dist" (
    copy "%CONF_MODULES%\mod_item_affixes.conf.dist" "%CONF_MODULES%\mod_item_affixes.conf" > nul
    echo   Copied mod_item_affixes.conf.dist to mod_item_affixes.conf
    echo   Edit it at: %CONF_MODULES%\mod_item_affixes.conf
) else (
    echo   NOTE: mod_item_affixes.conf.dist not found.
    echo   Run cmake --install first, then re-run this script (or copy manually).
    echo   The module works with defaults if .conf is missing.
)

echo.
echo ============================================================
echo  Step 1 complete.
echo  Next: run install\2-load-data.bat
echo ============================================================
echo.
pause
endlocal
