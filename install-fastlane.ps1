[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ============================================================
# START: FASTLANE TOOLS INSTALLER
# Downloads exactly three files from the tools repository into
# an existing React Native Android project, then optionally
# runs setup-fastlane.ps1.
# ============================================================

$RepoOwner = "codewithsujeet"
$RepoName = "fastlane-setup-tools"
$Branch = "master"

$FilesToInstall = @(
    "setup-fastlane.ps1",
    "setup-fastlane.cmd",
    "FASTLANE_SETUP_GUIDE"
)

$TempDirectory = $null

try {
    $ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
        throw "Project directory not found: $ProjectRoot"
    }

    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot "package.json") -PathType Leaf)) {
        throw "package.json not found. Run this installer from your React Native project root."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot "android") -PathType Container)) {
        throw "android folder not found. This installer requires an Android React Native project."
    }

    $TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("fastlane-tools-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null

    $BaseUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"

    Write-Host "Project root: $ProjectRoot" -ForegroundColor Cyan
    Write-Host "Source: $BaseUrl" -ForegroundColor Cyan

    foreach ($FileName in $FilesToInstall) {
        $Url = "$BaseUrl/$FileName"
        $TempFile = Join-Path $TempDirectory $FileName
        $DestinationFile = Join-Path $ProjectRoot $FileName

        Write-Host "Downloading $FileName..." -ForegroundColor Cyan

        try {
            Invoke-WebRequest -Uri $Url -OutFile $TempFile -UseBasicParsing
        }
        catch {
            throw "Could not download '$FileName' from '$Url'. Confirm the file exists at the root of the '$Branch' branch and the repository is public. Details: $($_.Exception.Message)"
        }

        if (-not (Test-Path -LiteralPath $TempFile -PathType Leaf) -or (Get-Item -LiteralPath $TempFile).Length -eq 0) {
            throw "Downloaded file is missing or empty: $FileName"
        }

        # Prevent installing a GitHub 404/error page as a script.
        $DownloadedText = Get-Content -LiteralPath $TempFile -Raw
        if ($DownloadedText -match '^\s*(404:\s*Not Found|Not Found)\s*$') {
            throw "GitHub returned 404 for '$FileName'. Check the filename, repository, and branch."
        }

        if (Test-Path -LiteralPath $DestinationFile -PathType Leaf) {
            $ExistingHash = (Get-FileHash -LiteralPath $DestinationFile -Algorithm SHA256).Hash
            $DownloadedHash = (Get-FileHash -LiteralPath $TempFile -Algorithm SHA256).Hash

            if ($ExistingHash -eq $DownloadedHash) {
                Write-Host "Already up to date: $FileName" -ForegroundColor Green
                continue
            }

            if (-not $Force) {
                $Answer = Read-Host "'$FileName' already exists and differs. Replace it? (Y/N)"
                if ($Answer -notmatch '^(Y|YES)$') {
                    Write-Host "Keeping existing file: $FileName" -ForegroundColor Yellow
                    continue
                }
            }
            else {
                Write-Host "Force enabled: replacing $FileName" -ForegroundColor Yellow
            }
        }

        Copy-Item -LiteralPath $TempFile -Destination $DestinationFile -Force
        Write-Host "Installed: $FileName" -ForegroundColor Green
    }

    $SetupScript = Join-Path $ProjectRoot "setup-fastlane.ps1"

    if (-not (Test-Path -LiteralPath $SetupScript -PathType Leaf)) {
        throw "setup-fastlane.ps1 is not available in the project root. If you kept an older file, rerun with -Force after reviewing the replacement."
    }

    $RunSetup = Read-Host "Run setup-fastlane.ps1 now? Review the script first. (Y/N)"

    if ($RunSetup -match '^(Y|YES)$') {
        Push-Location $ProjectRoot
        try {
            # Use a child PowerShell process so errors and exit codes are reliable.
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SetupScript -ProjectPath $ProjectRoot
            if ($LASTEXITCODE -ne 0) {
                throw "setup-fastlane.ps1 failed with exit code $LASTEXITCODE. Confirm it supports the -ProjectPath parameter."
            }
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Host "Setup skipped. To run later, use: .\setup-fastlane.ps1" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Fastlane tools installation finished." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "INSTALLER ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($TempDirectory -and (Test-Path -LiteralPath $TempDirectory)) {
        Remove-Item -LiteralPath $TempDirectory -Recurse -Force
    }
}

# ============================================================
# END: FASTLANE TOOLS INSTALLER
# ============================================================
