[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot
)

$ErrorActionPreference = "Stop"

# ============================================================
# START: FASTLANE TOOLS INSTALLER
# Run this script from the cloned fastlane-setup-tools folder.
# It copies only the three approved files to an existing
# React Native project. It does not clone or modify the project
# repository itself.
# ============================================================

$SourceRoot = $PSScriptRoot
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

$RequiredProjectFiles = @(
    (Join-Path $ProjectRoot "package.json"),
    (Join-Path $ProjectRoot "android")
)

$FilesToCopy = @(
    "setup-fastlane.ps1",
    "setup-fastlane.cmd",
    "FASTLANE_SETUP_GUIDE.md"
)

try {
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
        throw "Project path does not exist: $ProjectRoot"
    }

    if (-not (Test-Path -LiteralPath $RequiredProjectFiles[0] -PathType Leaf)) {
        throw "package.json was not found in '$ProjectRoot'. Specify the React Native project root."
    }

    if (-not (Test-Path -LiteralPath $RequiredProjectFiles[1] -PathType Container)) {
        throw "The android folder was not found in '$ProjectRoot'. This installer is for an Android React Native project."
    }

    foreach ($FileName in $FilesToCopy) {
        $SourceFile = Join-Path $SourceRoot $FileName

        if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
            throw "Required source file is missing from the tools repository: $FileName"
        }
    }

    Write-Host "Tools repository: $SourceRoot" -ForegroundColor Cyan
    Write-Host "React Native project: $ProjectRoot" -ForegroundColor Cyan
    Write-Host ""

    foreach ($FileName in $FilesToCopy) {
        $SourceFile = Join-Path $SourceRoot $FileName
        $TargetFile = Join-Path $ProjectRoot $FileName

        if (Test-Path -LiteralPath $TargetFile -PathType Leaf) {
            $SourceHash = (Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash
            $TargetHash = (Get-FileHash -LiteralPath $TargetFile -Algorithm SHA256).Hash

            if ($SourceHash -eq $TargetHash) {
                Write-Host "Already up to date: $FileName" -ForegroundColor Green
                continue
            }

            $Replace = Read-Host "$FileName already exists and differs. Replace it? (Y/N)"
            if ($Replace -notmatch '^(Y|YES)$') {
                Write-Host "Kept existing file: $FileName" -ForegroundColor Yellow
                continue
            }
        }

        Copy-Item -LiteralPath $SourceFile -Destination $TargetFile -Force
        Write-Host "Copied: $FileName" -ForegroundColor Green
    }

    $SetupScript = Join-Path $ProjectRoot "setup-fastlane.ps1"

    if (-not (Test-Path -LiteralPath $SetupScript -PathType Leaf)) {
        throw "setup-fastlane.ps1 was not installed. Check whether you declined to replace an existing file."
    }

    Write-Host ""
    $RunSetup = Read-Host "Run setup-fastlane.ps1 now? Review the script first. (Y/N)"

    if ($RunSetup -match '^(Y|YES)$') {
        Push-Location $ProjectRoot
        try {
            & $SetupScript -ProjectPath $ProjectRoot

            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                throw "setup-fastlane.ps1 exited with code $LASTEXITCODE."
            }

            Write-Host "Fastlane setup completed." -ForegroundColor Green
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Host "Setup was not run. Later, run .\setup-fastlane.ps1 from the React Native project root." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Installer finished successfully." -ForegroundColor Green
}
catch {
    Write-Host "Installer failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================
# END: FASTLANE TOOLS INSTALLER
# ============================================================
