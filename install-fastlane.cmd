@echo off
setlocal

REM ============================================================
REM START: FASTLANE TOOLS INSTALLER LAUNCHER FOR CMD
REM Run this from the root of your React Native project.
REM ============================================================

set "INSTALLER_URL=https://raw.githubusercontent.com/codewithsujeet/fastlane-setup-tools/feat/fastlane-iOS/install-fastlane.ps1"
set "INSTALLER_FILE=%TEMP%\install-fastlane.ps1"

echo Downloading Fastlane installer...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-WebRequest -Uri '%INSTALLER_URL%' -OutFile '%INSTALLER_FILE%' -UseBasicParsing -ErrorAction Stop } catch { Write-Error $_; exit 1 }"

if errorlevel 1 (
    echo ERROR: Could not download install-fastlane.ps1.
    exit /b 1
)

if not exist "%INSTALLER_FILE%" (
    echo ERROR: Installer file was not downloaded.
    exit /b 1
)

echo Running Fastlane installer...

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_FILE%" -ProjectRoot "%CD%"

if errorlevel 1 (
    echo ERROR: Fastlane installer failed.
    exit /b 1
)

echo Fastlane installer finished.
exit /b 0

REM ============================================================
REM END: FASTLANE TOOLS INSTALLER LAUNCHER FOR CMD
REM ============================================================
