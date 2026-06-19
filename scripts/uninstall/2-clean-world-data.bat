@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..

echo ============================================================
echo  mod-item-affixes -- UNINSTALL Step 2 of 3: Clean World Data
echo  Drops mod-owned tables, removes mod rows from shared tables,
echo  and removes the mod config file from the server.
echo ============================================================
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    echo        Copy scripts\config.bat.example to scripts\config.bat and fill it in.
    pause & exit /b 1
)
if exist "%SCRIPTS_ROOT%\local_config.bat" call "%SCRIPTS_ROOT%\local_config.bat"
call "%SCRIPTS_ROOT%\config.bat"

set /a RUNE_ITEM_ID_END=%RUNE_ITEM_ID_START% + 99
set /a IMPRINT_SPELL_ID_END=%IMPRINT_SPELL_ID_START% + 99
set /a SPELLSWAP_SPELL_ID_END=%SPELLSWAP_SPELL_ID_START% + 99

echo Dropping world tables from %DB_WORLD%...
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% -e ^
  "DROP TABLE IF EXISTS affix_template, talent_affix_def, imprint_def;"
if %ERRORLEVEL% neq 0 ( echo ERROR: Failed to drop world tables. & pause & exit /b 1 )
echo   Dropped: affix_template, talent_affix_def, imprint_def

echo Removing mod rows from shared tables...
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% -e ^
  "DELETE FROM item_template WHERE entry BETWEEN %RUNE_ITEM_ID_START% AND %RUNE_ITEM_ID_END%;"
if %ERRORLEVEL% neq 0 ( echo ERROR: item_template delete failed. & pause & exit /b 1 )
echo   Deleted item_template rows (IDs %RUNE_ITEM_ID_START%-%RUNE_ITEM_ID_END%)

%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% -e ^
  "DELETE FROM spell_dbc WHERE Id BETWEEN %IMPRINT_SPELL_ID_START% AND %IMPRINT_SPELL_ID_END% OR Id BETWEEN %SPELLSWAP_SPELL_ID_START% AND %SPELLSWAP_SPELL_ID_END%;"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_dbc delete failed. & pause & exit /b 1 )
echo   Deleted spell_dbc rows

%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% -e ^
  "DELETE FROM spell_script_names WHERE spell_id BETWEEN %IMPRINT_SPELL_ID_START% AND %IMPRINT_SPELL_ID_END% OR spell_id BETWEEN %SPELLSWAP_SPELL_ID_START% AND %SPELLSWAP_SPELL_ID_END%;"
if %ERRORLEVEL% neq 0 ( echo ERROR: spell_script_names delete failed. & pause & exit /b 1 )
echo   Deleted spell_script_names rows
echo.

echo Removing server config files...
set CONF_MODULES=%SERVER_DBC_DIR%\..\..\..\env\dist\configs\modules
if exist "%CONF_MODULES%\mod_item_affixes.conf" (
    del "%CONF_MODULES%\mod_item_affixes.conf"
    echo   Removed: mod_item_affixes.conf
)
if exist "%CONF_MODULES%\mod_item_affixes.conf.dist" (
    del "%CONF_MODULES%\mod_item_affixes.conf.dist"
    echo   Removed: mod_item_affixes.conf.dist
)
echo.

echo ============================================================
echo  Step 2 complete.
echo.
echo  IMPORTANT -- manual client cleanup required before restarting:
echo.
if defined PATCH_SUFFIX_DBC (
    echo  Delete these files from your WoW Data folder:
    if defined CLIENT_DATA_DIR (
        echo    %CLIENT_DATA_DIR%\patch-%PATCH_SUFFIX_DBC%.MPQ
        echo    %CLIENT_DATA_DIR%\enus\patch-enUS-%PATCH_SUFFIX_DBC%.MPQ
    ) else (
        echo    patch-%PATCH_SUFFIX_DBC%.MPQ  (locate your WoW Data folder)
        echo    enus\patch-enUS-%PATCH_SUFFIX_DBC%.MPQ
    )
) else (
    echo  DBC patch suffix unknown. Check scripts\local_config.bat for
    echo  PATCH_SUFFIX_DBC, or look for patch-*.MPQ files created at install time.
)
if defined PATCH_SUFFIX_SPELLS (
    if defined CLIENT_DATA_DIR (
        echo    %CLIENT_DATA_DIR%\patch-%PATCH_SUFFIX_SPELLS%.MPQ
        echo    %CLIENT_DATA_DIR%\enus\patch-enUS-%PATCH_SUFFIX_SPELLS%.MPQ
    ) else (
        echo    patch-%PATCH_SUFFIX_SPELLS%.MPQ
        echo    enus\patch-enUS-%PATCH_SUFFIX_SPELLS%.MPQ
    )
) else (
    echo  Spell patch suffix unknown. Check scripts\local_config.bat for
    echo  PATCH_SUFFIX_SPELLS.
)
echo.
echo  Also remove the addon: Interface\AddOns\ItemAffixes\
echo.
echo  Next: run uninstall\3-rebuild-server.bat
echo        (excludes module from cmake build)
echo ============================================================
echo.
pause
endlocal
