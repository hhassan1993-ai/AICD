@echo off
REM run-server-console.cmd
REM
REM Launches FXServer directly in THIS console window (no redirection,
REM no hidden process) so output streams live and the cfx> prompt is
REM usable for typing commands directly at the server console. The
REM server console bypasses ACE, so admin-restricted commands such as
REM "test_m1" work here without setting up the admin principal.
REM
REM This complements scripts\restart-and-check.ps1, which redirects
REM stdout to a file that only flushes when the server exits and is
REM therefore useless for watching a session in progress. Use THIS
REM script whenever you need to see what the server is doing live, or
REM to type commands at it interactively.
REM
REM Layout mirrors scripts\restart-and-check.ps1: working directory at
REM the repo root, server.cfg loaded via a path relative to that root
REM (+exec server/server.cfg), and citizen_dir pointing at the artifact's
REM citizen folder. See restart-and-check.ps1 and README.md for the full
REM rationale.
REM
REM License key resolution (same precedence as the other scripts):
REM   1. first command-line argument to this script
REM   2. FIVEM_LICENSE_KEY environment variable
REM   3. first non-comment, non-blank line of server\license.key
REM The key is passed as +set sv_licenseKey after +exec. server.cfg
REM deliberately does not set that convar, so the command line is its only
REM source; the key is never echoed or written to disk by this script.
REM
REM Usage:
REM   scripts\run-server-console.cmd
REM   scripts\run-server-console.cmd cfxk_YOURKEYHERE

setlocal EnableDelayedExpansion

REM Resolve the repo root from this script's own location, regardless of
REM the caller's current working directory.
pushd "%~dp0.." >nul
set "REPO_ROOT=%CD%"
popd

set "ARTIFACT_DIR=%REPO_ROOT%\server\artifact"
set "FXSERVER_EXE=%ARTIFACT_DIR%\FXServer.exe"
set "CITIZEN_DIR=%ARTIFACT_DIR%\citizen"
set "LICENSE_KEY_FILE=%REPO_ROOT%\server\license.key"

if not exist "%FXSERVER_EXE%" (
    echo ERROR: FXServer.exe not found at "%FXSERVER_EXE%".
    echo        Run scripts\get-server.ps1 first to download the server artifact.
    pause
    exit /b 1
)

set "LICENSE_KEY="
set "LICENSE_KEY_SOURCE="

if not "%~1"=="" (
    set "LICENSE_KEY=%~1"
    set "LICENSE_KEY_SOURCE=command-line argument"
) else if defined FIVEM_LICENSE_KEY (
    set "LICENSE_KEY=%FIVEM_LICENSE_KEY%"
    set "LICENSE_KEY_SOURCE=FIVEM_LICENSE_KEY environment variable"
)

if not defined LICENSE_KEY if exist "%LICENSE_KEY_FILE%" (
    for /f "usebackq delims=" %%L in ("%LICENSE_KEY_FILE%") do (
        if not defined LICENSE_KEY (
            set "CANDIDATE_LINE=%%L"
            for /f "tokens=* delims= " %%T in ("!CANDIDATE_LINE!") do set "CANDIDATE_LINE=%%T"
            if defined CANDIDATE_LINE (
                if "!CANDIDATE_LINE:~0,1!" NEQ "#" (
                    set "LICENSE_KEY=!CANDIDATE_LINE!"
                    set "LICENSE_KEY_SOURCE=server\license.key"
                )
            )
        )
    )
)

if not defined LICENSE_KEY (
    echo ERROR: No FiveM license key found.
    echo        Provide one via: run-server-console.cmd ^<key^>
    echo        or set the FIVEM_LICENSE_KEY environment variable,
    echo        or create server\license.key ^(see server\license.key.example;
    echo        the file is gitignored and never committed^).
    echo        Get a free key at https://portal.cfx.re
    pause
    exit /b 1
)

echo license key: loaded from %LICENSE_KEY_SOURCE%

echo.
echo ============================================================
echo   FXServer LIVE CONSOLE
echo ============================================================
echo   This is the live server console: output streams here as it
echo   happens, unlike restart-and-check.ps1's log file, which does
echo   not flush until the server exits.
echo.
echo   The server keeps running until you close this window or
echo   type "quit" at the cfx^> prompt below.
echo.
echo   The server console bypasses ACE, so you can type admin
echo   commands directly at the cfx^> prompt without setting up the
echo   admin principal, e.g.:
echo       test_m1
echo ============================================================
echo.

cd /d "%REPO_ROOT%"

"%FXSERVER_EXE%" +set citizen_dir "%CITIZEN_DIR%" +exec server/server.cfg +set sv_licenseKey "%LICENSE_KEY%"

set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%
