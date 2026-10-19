@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "FORCE_ARG="

if /I "%~1"=="-Force" set "FORCE_ARG=-Force"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup-fastlane.ps1" -ProjectPath "%SCRIPT_DIR%." %FORCE_ARG%

if errorlevel 1 (
    echo.
    echo Fastlane setup failed. Read the error above.
    pause
    exit /b 1
)

echo.
echo Fastlane setup and bundle install completed successfully.
pause
