@echo off
setlocal
set SCRIPT_DIR=%~dp0
set ALL_OK=1

echo ============================================================
echo  mod-item-affixes -- Configuration Check
echo ============================================================
echo.

if not exist "%SCRIPT_DIR%config.bat" (
    echo [FAIL] scripts\config.bat not found.
    echo        Copy scripts\config.bat.example to scripts\config.bat
    echo        and fill in your values, then re-run this check.
    echo.
    pause
    exit /b 1
)
if exist "%SCRIPT_DIR%local_config.bat" call "%SCRIPT_DIR%local_config.bat"
call "%SCRIPT_DIR%config.bat"

REM -- MySQL executable --------------------------------------------------------
if not defined MYSQL (
    echo [FAIL] MYSQL is not set in config.bat
    set ALL_OK=0
    goto :check_char_db
)
if not exist %MYSQL% (
    echo [FAIL] MySQL executable not found: %MYSQL%
    echo        Update MYSQL= in scripts\config.bat
    set ALL_OK=0
) else (
    echo  [OK]  MySQL: %MYSQL%
)

:check_char_db
REM -- Character DB connection --------------------------------------------------
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_CHAR% -e "SELECT 1;" >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [FAIL] Cannot connect to characters DB '%DB_CHAR%' at %MYSQL_HOST%
    echo        Check MYSQL_HOST, USER, PASS, DB_CHAR in scripts\config.bat
    set ALL_OK=0
) else (
    echo  [OK]  Characters DB: %DB_CHAR% at %MYSQL_HOST%
)

REM -- World DB connection ------------------------------------------------------
%MYSQL% -h %MYSQL_HOST% -u %USER% -p%PASS% %DB_WORLD% -e "SELECT 1;" >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [FAIL] Cannot connect to world DB '%DB_WORLD%' at %MYSQL_HOST%
    echo        Check MYSQL_HOST, USER, PASS, DB_WORLD in scripts\config.bat
    set ALL_OK=0
) else (
    echo  [OK]  World DB: %DB_WORLD% at %MYSQL_HOST%
)

REM -- Server DBC directory ----------------------------------------------------
if not defined SERVER_DBC_DIR (
    echo [FAIL] SERVER_DBC_DIR is not set in config.bat
    set ALL_OK=0
    goto :check_client_dir
)
if not exist "%SERVER_DBC_DIR%\SpellItemEnchantment.dbc" (
    echo [FAIL] SpellItemEnchantment.dbc not found in SERVER_DBC_DIR:
    echo        %SERVER_DBC_DIR%
    echo        Update SERVER_DBC_DIR= in scripts\config.bat
    set ALL_OK=0
) else (
    echo  [OK]  SERVER_DBC_DIR: %SERVER_DBC_DIR%
)

:check_client_dir
REM -- Client Data directory ---------------------------------------------------
if not defined CLIENT_DATA_DIR (
    echo [FAIL] CLIENT_DATA_DIR is not set in config.bat
    set ALL_OK=0
    goto :check_mpq
)
if not exist "%CLIENT_DATA_DIR%" (
    echo [FAIL] CLIENT_DATA_DIR does not exist: %CLIENT_DATA_DIR%
    echo        Update CLIENT_DATA_DIR= in scripts\config.bat
    set ALL_OK=0
) else (
    echo  [OK]  CLIENT_DATA_DIR: %CLIENT_DATA_DIR%
)

:check_mpq
REM -- MPQBuild tool -----------------------------------------------------------
if not exist "%SCRIPT_DIR%..\tools\mpqbuild.exe" (
    echo [FAIL] tools\mpqbuild.exe not found.
    echo        It should be included in the module -- re-clone the repository.
    set ALL_OK=0
) else (
    echo  [OK]  tools\mpqbuild.exe found
)

REM -- CMake (optional) --------------------------------------------------------
if not defined CMAKE (
    echo  [--]  CMAKE not set (optional -- only needed for manage\enable.bat / disable.bat)
    goto :check_build_dir
)
if not exist %CMAKE% (
    echo  [!!]  CMAKE set but not found: %CMAKE%
    echo        Update CMAKE= in scripts\config.bat
) else (
    echo  [OK]  CMAKE: %CMAKE%
)

:check_build_dir
REM -- Build directory (optional) ----------------------------------------------
if not defined BUILD_DIR (
    echo  [--]  BUILD_DIR not set (optional -- only needed for manage\enable.bat / disable.bat)
    goto :summary
)
if not exist "%BUILD_DIR%\CMakeCache.txt" (
    echo  [!!]  BUILD_DIR set but CMakeCache.txt not found: %BUILD_DIR%
    echo        Update BUILD_DIR= in scripts\config.bat
) else (
    echo  [OK]  BUILD_DIR: %BUILD_DIR%
)

:summary
echo.
if %ALL_OK%==1 (
    echo  All required checks passed.
    echo  You are ready to run the install scripts.
    echo ============================================================
    echo.
    pause
    endlocal
    exit /b 0
) else (
    echo  One or more required checks failed.
    echo  Fix the issues listed above, then re-run scripts\check-config.bat.
    echo ============================================================
    echo.
    pause
    endlocal
    exit /b 1
)
