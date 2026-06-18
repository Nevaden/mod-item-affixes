@echo off
setlocal
set SCRIPT_DIR=%~dp0
set MODULE_ROOT=%SCRIPT_DIR%..

echo ============================================================
echo  mod-item-affixes -- UNINSTALL
echo.
echo  IMPORTANT: Stop worldserver.exe NOW before continuing.
echo  The script rebuilds the worldserver without the module.
echo  If worldserver is running, the install step will fail and
echo  the server will crash on next start looking for removed tables.
echo.
echo  WARNING: This permanently removes all mod data:
echo.
echo    Characters DB  -- DROPS tables (ALL PLAYER AFFIX DATA LOST):
echo      item_affix, item_talent_affix, item_imprint
echo.
echo    World DB  -- DROPS mod-owned tables:
echo      affix_template, talent_affix_def, imprint_def
echo    World DB  -- DELETES rows from shared tables:
echo      item_template  (rune items)
echo      spell_dbc      (custom imprint/spell-swap spells)
echo      spell_script_names  (imprint/spell-swap bindings)
echo.
echo    Client  -- REMOVES the two MPQ patch files
echo    Server  -- REMOVES mod_item_affixes.conf and .conf.dist
echo    CMake   -- Excludes module from next build (if CMAKE+BUILD_DIR set)
echo.
echo  After this script you must manually:
echo    1. Remove the ItemAffixes addon from your WoW client:
echo       Interface\AddOns\ItemAffixes\
echo    2. Restart the WoW client
echo    3. Restart the worldserver
echo ============================================================
echo.
echo  Type UNINSTALL and press Enter to confirm (Ctrl+C to cancel):
set /p CONFIRM=
if /i not "%CONFIRM%"=="UNINSTALL" (
    echo  Cancelled. No changes made.
    exit /b 0
)
echo.

REM -- Load config -------------------------------------------------------------
if not exist "%SCRIPT_DIR%db_config.bat" (
    echo ERROR: scripts\db_config.bat not found. Cannot locate databases.
    pause & exit /b 1
)
if exist "%SCRIPT_DIR%local_config.bat" call "%SCRIPT_DIR%local_config.bat"
call "%SCRIPT_DIR%db_config.bat"

REM -- Compute ID range ends ----------------------------------------------------
set /a RUNE_ITEM_ID_END=%RUNE_ITEM_ID_START% + 99
set /a IMPRINT_SPELL_ID_END=%IMPRINT_SPELL_ID_START% + 99
set /a SPELLSWAP_SPELL_ID_END=%SPELLSWAP_SPELL_ID_START% + 99

REM -- Step 1: Drop character DB tables ----------------------------------------
echo [1/4] Removing character DB tables (player affix data)...
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% -e ^
  "DROP TABLE IF EXISTS item_affix, item_talent_affix, item_imprint;"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to drop character tables.
    pause & exit /b 1
)
echo   Dropped: item_affix, item_talent_affix, item_imprint
echo.

REM -- Step 2: Clean world DB --------------------------------------------------
echo [2/4] Removing world DB tables and mod rows...
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% -e ^
  "DROP TABLE IF EXISTS affix_template, talent_affix_def, imprint_def;"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to drop world tables.
    pause & exit /b 1
)
echo   Dropped: affix_template, talent_affix_def, imprint_def

%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% -e ^
  "DELETE FROM item_template WHERE entry BETWEEN %RUNE_ITEM_ID_START% AND %RUNE_ITEM_ID_END%;"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to remove rune item_template rows.
    pause & exit /b 1
)
echo   Deleted item_template rows %RUNE_ITEM_ID_START%-%RUNE_ITEM_ID_END% (rune items)

%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% -e ^
  "DELETE FROM spell_dbc WHERE Id BETWEEN %IMPRINT_SPELL_ID_START% AND %IMPRINT_SPELL_ID_END% OR Id BETWEEN %SPELLSWAP_SPELL_ID_START% AND %SPELLSWAP_SPELL_ID_END%;"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to remove spell_dbc rows.
    pause & exit /b 1
)
echo   Deleted spell_dbc rows (IDs %IMPRINT_SPELL_ID_START%-%IMPRINT_SPELL_ID_END% and %SPELLSWAP_SPELL_ID_START%-%SPELLSWAP_SPELL_ID_END%)

%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% -e ^
  "DELETE FROM spell_script_names WHERE spell_id BETWEEN %IMPRINT_SPELL_ID_START% AND %IMPRINT_SPELL_ID_END% OR spell_id BETWEEN %SPELLSWAP_SPELL_ID_START% AND %SPELLSWAP_SPELL_ID_END%;"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to remove spell_script_names rows.
    pause & exit /b 1
)
echo   Deleted spell_script_names rows for custom spells
echo.

REM -- Step 3: Remove client MPQ files -----------------------------------------
echo [3/4] Removing client MPQ patch files...
if not defined CLIENT_DATA_DIR (
    echo   WARNING: CLIENT_DATA_DIR not set -- cannot remove MPQ files.
    echo   Remove them manually from your WoW Data folder.
) else (
    set REMOVED_ANY=0
    if defined PATCH_SUFFIX_DBC (
        if exist "%CLIENT_DATA_DIR%\patch-%PATCH_SUFFIX_DBC%.MPQ" (
            del "%CLIENT_DATA_DIR%\patch-%PATCH_SUFFIX_DBC%.MPQ"
            echo   Removed: patch-%PATCH_SUFFIX_DBC%.MPQ
            set REMOVED_ANY=1
        )
        if exist "%CLIENT_DATA_DIR%\enus\patch-enUS-%PATCH_SUFFIX_DBC%.MPQ" (
            del "%CLIENT_DATA_DIR%\enus\patch-enUS-%PATCH_SUFFIX_DBC%.MPQ"
            echo   Removed: enus\patch-enUS-%PATCH_SUFFIX_DBC%.MPQ
            set REMOVED_ANY=1
        )
    )
    if defined PATCH_SUFFIX_SPELLS (
        if exist "%CLIENT_DATA_DIR%\patch-%PATCH_SUFFIX_SPELLS%.MPQ" (
            del "%CLIENT_DATA_DIR%\patch-%PATCH_SUFFIX_SPELLS%.MPQ"
            echo   Removed: patch-%PATCH_SUFFIX_SPELLS%.MPQ
            set REMOVED_ANY=1
        )
        if exist "%CLIENT_DATA_DIR%\enus\patch-enUS-%PATCH_SUFFIX_SPELLS%.MPQ" (
            del "%CLIENT_DATA_DIR%\enus\patch-enUS-%PATCH_SUFFIX_SPELLS%.MPQ"
            echo   Removed: enus\patch-enUS-%PATCH_SUFFIX_SPELLS%.MPQ
            set REMOVED_ANY=1
        )
    )
    if %REMOVED_ANY%==0 (
        echo   No MPQ suffixes recorded in local_config.bat.
        echo   Remove the mod's MPQ files manually from: %CLIENT_DATA_DIR%
    )
)
echo.

REM -- Step 4: Remove server config ---------------------------------------------
echo [4/5] Removing server config...
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

REM -- Step 5: Disable module in cmake and rebuild ------------------------------
echo [5/5] Disabling module in CMake build and rebuilding worldserver...
if not defined CMAKE (
    echo   SKIPPED: CMAKE not set in db_config.bat.
    echo   Run scripts\disable.bat (after filling in CMAKE and BUILD_DIR)
    echo   or manually reconfigure and rebuild before restarting the worldserver.
    goto :done
)
if not defined BUILD_DIR (
    echo   SKIPPED: BUILD_DIR not set in db_config.bat.
    echo   Run scripts\disable.bat (after filling in BUILD_DIR)
    echo   or manually reconfigure and rebuild before restarting the worldserver.
    goto :done
)
echo   Reconfiguring CMake to exclude mod-item-affixes...
%CMAKE% -DDISABLED_AC_MODULES=mod-item-affixes "%BUILD_DIR%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: CMake configure failed. Rebuild manually before restarting worldserver.
    goto :done
)
echo   Building worldserver (this will take a few minutes)...
%CMAKE% --build "%BUILD_DIR%" --target worldserver --config RelWithDebInfo
if %ERRORLEVEL% neq 0 (
    echo ERROR: Build failed. Fix build errors then run cmake --install manually.
    goto :done
)
echo   Installing...
%CMAKE% --install "%BUILD_DIR%" --config RelWithDebInfo
if %ERRORLEVEL% neq 0 (
    echo ERROR: Install failed. Is worldserver.exe still running?
    goto :done
)
echo   Worldserver rebuilt and installed without mod-item-affixes.

:done
echo.
echo ============================================================
echo  Uninstall complete.
echo.
echo  Remaining manual steps:
echo    1. Remove the ItemAffixes addon from your WoW client:
echo       Interface\AddOns\ItemAffixes\
echo    2. Restart the WoW client (clears MPQ patches and addon)
echo    3. Restart the worldserver
echo ============================================================
echo.
pause
endlocal
