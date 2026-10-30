@echo off
setlocal DisableDelayedExpansion
set "ERRORLEVEL="
if not exist "%~dp0DragonCodexBoot.exe" (
    echo Launcher missing. Extract or build the complete program first.
    exit /b 1
)
"%~dp0DragonCodexBoot.exe" --restore-entrypoints
set "launcherExit=%ERRORLEVEL%"
echo.
pause
exit /b %launcherExit%
