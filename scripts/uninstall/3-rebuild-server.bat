@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..

echo ============================================================
echo  mod-item-affixes -- UNINSTALL Step 3 of 3: Rebuild Server
echo  Excludes the module from cmake and rebuilds worldserver.
echo  STOP worldserver.exe before continuing.
echo ============================================================
echo.

if not exist "%SCRIPTS_ROOT%\config.bat" (
    echo ERROR: scripts\config.bat not found.
    echo        Copy scripts\config.bat.example to scripts\config.bat and fill it in.
    pause & exit /b 1
)
call "%SCRIPTS_ROOT%\config.bat"

if not defined CMAKE (
    echo SKIPPED: CMAKE not set in config.bat.
    echo          Fill in CMAKE and BUILD_DIR, then run manage\disable.bat,
    echo          or manually run:
    echo            cmake -DDISABLED_AC_MODULES=mod-item-affixes
    echo                  -DMODULE_MOD-ITEM-AFFIXES=disabled ^<build_dir^>
    echo          then cmake --build and cmake --install.
    goto :end
)
if not defined BUILD_DIR (
    echo SKIPPED: BUILD_DIR not set in config.bat.
    goto :end
)

echo Reconfiguring CMake to exclude mod-item-affixes...
%CMAKE% -DDISABLED_AC_MODULES=mod-item-affixes -DMODULE_MOD-ITEM-AFFIXES=disabled "%BUILD_DIR%"
if %ERRORLEVEL% neq 0 ( echo ERROR: CMake configure failed. & goto :end )

if exist "%BUILD_DIR%\modules\RelWithDebInfo\modules.lib" del "%BUILD_DIR%\modules\RelWithDebInfo\modules.lib"
if exist "%BUILD_DIR%\bin\RelWithDebInfo\worldserver.exe" del "%BUILD_DIR%\bin\RelWithDebInfo\worldserver.exe"

echo Building worldserver (this will take a few minutes)...
%CMAKE% --build "%BUILD_DIR%" --target worldserver --config RelWithDebInfo
if %ERRORLEVEL% neq 0 ( echo ERROR: Build failed. Fix errors then run cmake --install manually. & goto :end )

echo Installing...
%CMAKE% --install "%BUILD_DIR%" --config RelWithDebInfo
if %ERRORLEVEL% neq 0 ( echo ERROR: Install failed. Is worldserver.exe still running? & goto :end )

echo   Worldserver rebuilt and installed without mod-item-affixes.

:end
echo.
echo ============================================================
echo  Uninstall complete. You can now start the worldserver.
echo  Close this window when done.
echo ============================================================
cmd /k
endlocal
