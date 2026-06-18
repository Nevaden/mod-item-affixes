@echo off
setlocal
set SCRIPT_DIR=%~dp0

echo ============================================================
echo  mod-item-affixes -- ENABLE
echo  NOTE: Make sure worldserver.exe is NOT running before
echo  this completes, or the install step will fail.
echo ============================================================
echo.

REM ── Load config ─────────────────────────────────────────────────────────────
if not exist "%SCRIPT_DIR%db_config.bat" (
    echo ERROR: scripts\db_config.bat not found.
    echo        Copy scripts\db_config.bat.example to scripts\db_config.bat and fill it in.
    pause & exit /b 1
)
call "%SCRIPT_DIR%db_config.bat"

if not defined CMAKE (
    echo ERROR: CMAKE is not set in scripts\db_config.bat
    echo        Uncomment and fill in the CMAKE= line.
    pause & exit /b 1
)
if not defined BUILD_DIR (
    echo ERROR: BUILD_DIR is not set in scripts\db_config.bat
    echo        Uncomment and fill in the BUILD_DIR= line.
    pause & exit /b 1
)

echo [1/3] Reconfiguring CMake (enabling mod-item-affixes)...
%CMAKE% -DDISABLED_AC_MODULES="" "%BUILD_DIR%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: CMake configure failed.
    pause & exit /b 1
)

echo.
echo [2/3] Building worldserver...
%CMAKE% --build "%BUILD_DIR%" --target worldserver --config RelWithDebInfo
if %ERRORLEVEL% neq 0 (
    echo ERROR: Build failed.
    pause & exit /b 1
)

echo.
echo [3/3] Installing...
%CMAKE% --install "%BUILD_DIR%" --config RelWithDebInfo
if %ERRORLEVEL% neq 0 (
    echo ERROR: Install failed. Is worldserver.exe still running?
    pause & exit /b 1
)

echo.
echo Done! mod-item-affixes is ENABLED.
echo Start worldserver.exe to apply.
echo.
pause
endlocal
