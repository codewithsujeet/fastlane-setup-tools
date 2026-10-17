
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ============================================================
# START: FASTLANE TOOLS INSTALLER
# ============================================================

$RepoOwner = "codewithsujeet"
$RepoName = "fastlane-setup-tools"
$Branch = "feat/fastlane-iOS"

$FilesToInstall = @(
    @{
        Source = "setup-fastlane.ps1"
        Destination = "setup-fastlane.ps1"
    },
    @{
        Source = "setup-fastlane.cmd"
        Destination = "setup-fastlane.cmd"
    },
    @{
        Source = "FASTLANE_SETUP_GUIDE"
        Destination = "FASTLANE_SETUP_GUIDE.md"
    }
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

    Write-Host ""
    Write-Host "Fastlane Tools Installer" -ForegroundColor Cyan
    Write-Host "Project: $ProjectRoot" -ForegroundColor Cyan
    Write-Host "Branch: $Branch" -ForegroundColor Cyan
    Write-Host ""

    # Download and validate all files before copying any of them.
    foreach ($File in $FilesToInstall) {
        $Url = "$BaseUrl/$($File.Source)"
        $TempFile = Join-Path $TempDirectory $File.Source

        Write-Host "Downloading $($File.Source)..." -ForegroundColor Cyan

        try {
            Invoke-WebRequest -Uri $Url -OutFile $TempFile -UseBasicParsing
        }
        catch {
            throw "Could not download '$($File.Source)' from '$Url'. Check the repository, branch, filename, and repository visibility. Details: $($_.Exception.Message)"
        }

        if (-not (Test-Path -LiteralPath $TempFile -PathType Leaf)) {
            throw "Download failed: $($File.Source)"
        }

        if ((Get-Item -LiteralPath $TempFile).Length -eq 0) {
            throw "Downloaded file is empty: $($File.Source)"
        }

        $DownloadedText = Get-Content -LiteralPath $TempFile -Raw

        if ($DownloadedText -match '^\s*(404:\s*Not Found|Not Found)\s*$') {
            throw "GitHub returned 404 for '$($File.Source)'. Verify the exact filename on the $Branch branch."
        }
    }

    # Copy files into the existing React Native project.
    foreach ($File in $FilesToInstall) {
        $TempFile = Join-Path $TempDirectory $File.Source
        $DestinationFile = Join-Path $ProjectRoot $File.Destination

        if (Test-Path -LiteralPath $DestinationFile -PathType Leaf) {
            $ExistingHash = (Get-FileHash -LiteralPath $DestinationFile -Algorithm SHA256).Hash
            $DownloadedHash = (Get-FileHash -LiteralPath $TempFile -Algorithm SHA256).Hash

            if ($ExistingHash -eq $DownloadedHash) {
                Write-Host "Already up to date: $($File.Destination)" -ForegroundColor Green
                continue
            }

            if (-not $Force) {
                $Answer = Read-Host "'$($File.Destination)' already exists and differs. Replace it? (Y/N)"

                if ($Answer -notmatch '^(Y|YES)$') {
                    Write-Host "Keeping existing file: $($File.Destination)" -ForegroundColor Yellow
                    continue
                }
            }
            else {
                Write-Host "Force enabled: replacing $($File.Destination)" -ForegroundColor Yellow
            }
        }

        Copy-Item -LiteralPath $TempFile -Destination $DestinationFile -Force
        Write-Host "Installed: $($File.Destination)" -ForegroundColor Green
    }

    $SetupScript = Join-Path $ProjectRoot "setup-fastlane.ps1"

    if (-not (Test-Path -LiteralPath $SetupScript -PathType Leaf)) {
        throw "setup-fastlane.ps1 is missing from the project root. Check whether you declined to replace an existing file."
    }

    Write-Host ""
    $RunSetup = Read-Host "Run setup-fastlane.ps1 now? Review the script first. (Y/N)"

    if ($RunSetup -match '^(Y|YES)$') {
        Write-Host "Running Fastlane setup..." -ForegroundColor Cyan

        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $SetupScript `
            -ProjectPath $ProjectRoot

        if ($LASTEXITCODE -ne 0) {
            throw "setup-fastlane.ps1 failed with exit code $LASTEXITCODE. Check the setup script output and confirm it supports -ProjectPath."
        }

        Write-Host "Fastlane setup completed." -ForegroundColor Green
    }
    else {
        Write-Host "Setup skipped. Run .\setup-fastlane.ps1 later from your project root." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Installer finished successfully." -ForegroundColor Green
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
