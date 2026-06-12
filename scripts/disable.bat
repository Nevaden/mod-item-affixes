@echo off
setlocal

REM ── Configure for your installation ──────────────────────────────────────
set CMAKE="C:\Program Files\CMake\bin\cmake.exe"
set BUILD=C:\AzerothCore\build
REM ──────────────────────────────────────────────────────────────────────────

echo ============================================================
echo  mod-item-affixes -- DISABLE
echo  NOTE: Make sure worldserver.exe is NOT running before
echo  this completes, or the install step will fail.
echo ============================================================
echo.

echo [1/3] Reconfiguring CMake (disabling mod-item-affixes)...
%CMAKE% -DDISABLED_AC_MODULES=mod-item-affixes "%BUILD%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: CMake configure failed.
    pause & exit /b 1
)

echo.
echo [2/3] Building worldserver...
%CMAKE% --build "%BUILD%" --target worldserver --config RelWithDebInfo
if %ERRORLEVEL% neq 0 (
    echo ERROR: Build failed.
    pause & exit /b 1
)

echo.
echo [3/3] Installing...
%CMAKE% --install "%BUILD%" --config RelWithDebInfo
if %ERRORLEVEL% neq 0 (
    echo ERROR: Install failed. Is worldserver.exe still running?
    pause & exit /b 1
)

echo.
echo Done! mod-item-affixes is DISABLED.
echo Start worldserver.exe to apply.
echo.
pause
endlocal
