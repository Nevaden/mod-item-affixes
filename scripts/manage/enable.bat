@echo off
setlocal
set SCRIPT_DIR=%~dp0
set SCRIPTS_ROOT=%SCRIPT_DIR%..

echo ============================================================
echo  mod-item-affixes -- MANAGE: Enable
echo  Reconfigures CMake to include the module and rebuilds.
echo  All DB data is preserved.
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
    echo ERROR: CMAKE is not set in config.bat.
    echo        Uncomment and fill in CMAKE= and BUILD_DIR= to use this script.
    pause & exit /b 1
)
if not defined BUILD_DIR (
    echo ERROR: BUILD_DIR is not set in config.bat.
    pause & exit /b 1
)

echo Reconfiguring CMake to include mod-item-affixes...
%CMAKE% -DDISABLED_AC_MODULES="" -DMODULE_MOD-ITEM-AFFIXES=default "%BUILD_DIR%"
if %ERRORLEVEL% neq 0 ( echo ERROR: CMake configure failed. & goto :end )

if exist "%BUILD_DIR%\modules\RelWithDebInfo\modules.lib" del "%BUILD_DIR%\modules\RelWithDebInfo\modules.lib"
if exist "%BUILD_DIR%\bin\RelWithDebInfo\worldserver.exe" del "%BUILD_DIR%\bin\RelWithDebInfo\worldserver.exe"

echo Building worldserver (this will take a few minutes)...
%CMAKE% --build "%BUILD_DIR%" --target worldserver --config RelWithDebInfo
if %ERRORLEVEL% neq 0 ( echo ERROR: Build failed. & goto :end )

echo Installing...
%CMAKE% --install "%BUILD_DIR%" --config RelWithDebInfo
if %ERRORLEVEL% neq 0 ( echo ERROR: Install failed. Is worldserver.exe still running? & goto :end )

echo   mod-item-affixes ENABLED. Start worldserver to apply.

:end
echo.
echo Close this window when done.
cmd /k
endlocal
