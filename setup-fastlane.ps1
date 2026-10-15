param(
    [string]$ProjectPath = $PSScriptRoot,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

try {
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        throw "ProjectPath is empty."
    }

    $ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
    $AndroidPath = Join-Path $ProjectPath "android"
    $AppPath = Join-Path $AndroidPath "app"
    $PackageJsonPath = Join-Path $ProjectPath "package.json"

    if (-not (Test-Path -LiteralPath $PackageJsonPath)) {
        throw "package.json not found. Run this script from your React Native project root."
    }

    if (-not (Test-Path -LiteralPath $AppPath)) {
        throw "Android app folder not found: $AppPath"
    }

    $GradleFile = @(
        (Join-Path $AppPath "build.gradle"),
        (Join-Path $AppPath "build.gradle.kts")
    ) |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not $GradleFile) {
        throw "android/app/build.gradle or build.gradle.kts not found."
    }

    $GradleContent = Get-Content -LiteralPath $GradleFile -Raw

    $Match = [regex]::Match(
        $GradleContent,
        '(?m)^\s*applicationId\s*(?:=\s*)?["'']([^"'']+)["'']'
    )

    if (-not $Match.Success) {
        throw "Could not detect applicationId in $GradleFile. Add it manually to android/fastlane/Appfile."
    }

    $ApplicationId = $Match.Groups[1].Value

    Write-Host "Detected application ID: $ApplicationId" -ForegroundColor Green

    Write-Step "Updating package.json scripts"

    try {
        $PackageJson = Get-Content -LiteralPath $PackageJsonPath -Raw |
            ConvertFrom-Json
    }
    catch {
        throw "Could not parse package.json. Check that it contains valid JSON."
    }

    if ($null -eq $PackageJson.scripts) {
        $PackageJson |
            Add-Member -MemberType NoteProperty `
                -Name "scripts" `
                -Value ([PSCustomObject]@{})
    }

    $NewScripts = [ordered]@{
        "aab"               = "cd android&&gradlew bundleRelease"
        "release"           = "cd android&&gradlew assembleRelease"
        "fastlane:build"    = "cd android && bundle exec fastlane build"
        "fastlane:apk"      = "cd android && bundle exec fastlane apk"
        "fastlane:deploy"   = "cd android && bundle exec fastlane deploy"
        "fastlane:internal" = "cd android && bundle exec fastlane internal"
    }

    foreach ($Entry in $NewScripts.GetEnumerator()) {
        $ExistingProperty = $PackageJson.scripts.PSObject.Properties[$Entry.Key]

        if ($null -ne $ExistingProperty) {
            $PackageJson.scripts.($Entry.Key) = $Entry.Value
        }
        else {
            $PackageJson.scripts |
                Add-Member -MemberType NoteProperty `
                    -Name $Entry.Key `
                    -Value $Entry.Value
        }

        Write-Host "Updated npm script: $($Entry.Key)" -ForegroundColor Green
    }

    $JsonContent = $PackageJson | ConvertTo-Json -Depth 100
    $JsonContent = $JsonContent.Replace('\u0026', '&')
    $JsonContent = $JsonContent.Replace('\u003e', '>')
    $JsonContent = $JsonContent.Replace('\u003c', '<')

    Set-Content `
        -LiteralPath $PackageJsonPath `
        -Value $JsonContent `
        -Encoding UTF8

    try {
        Get-Content -LiteralPath $PackageJsonPath -Raw |
            ConvertFrom-Json |
            Out-Null
    }
    catch {
        throw "The updated package.json is invalid JSON."
    }

    Write-Host "package.json updated and formatted successfully." -ForegroundColor Green


    $FastlanePath = Join-Path $AndroidPath "fastlane"

    New-Item -ItemType Directory -Path $FastlanePath -Force |
        Out-Null

    $GemfileContent = @'
source "https://rubygems.org"

gem "fastlane"
'@

    $AppfileContent = @'
json_key_file("./fastlane/e-oms.json")
package_name("__ANDROID_APPLICATION_ID__")
'@

    $AppfileContent = $AppfileContent.Replace(
        "__ANDROID_APPLICATION_ID__",
        $ApplicationId
    )

    $FastfileContent = @'
default_platform(:android)

platform :android do
  desc "Runs all the tests"
  lane :test do
    gradle(
      task: "test"
    )
  end

  desc "Build Release AAB"
  lane :build do
    gradle(
      task: "bundle",
      build_type: "Release"
    )
  end

  desc "Build Release APK"
  lane :apk do
    gradle(
      task: "assemble",
      build_type: "Release"
    )
  end

  desc "Deploy to Google Play"
  lane :deploy do |options|
    gradle(
      task: "bundle",
      build_type: "Release"
    )
    aab = "app/build/outputs/bundle/release/app-release.aab"
    upload_to_play_store(
      track: options[:track] || "production",
      aab: aab,
      skip_upload_apk: true,
      skip_upload_metadata: true,
      skip_upload_images: true,
      skip_upload_screenshots: true
    )
  end

  desc "Upload to Internal Track"
  lane :internal do
    gradle(
      task: "bundle",
      build_type: "Release"
    )
    aab = "app/build/outputs/bundle/release/app-release.aab"
    upload_to_play_store(
      track: "internal",
      aab: aab,
      skip_upload_apk: true,
      skip_upload_metadata: true,
      skip_upload_images: true,
      skip_upload_screenshots: true
    )
  end
end
'@

    $Files = @(
        @{
            Path = Join-Path $AndroidPath "Gemfile"
            Content = $GemfileContent
        },
        @{
            Path = Join-Path $FastlanePath "Appfile"
            Content = $AppfileContent
        },
        @{
            Path = Join-Path $FastlanePath "Fastfile"
            Content = $FastfileContent
        }
    )

    Write-Step "Generating Fastlane files"

    foreach ($File in $Files) {
        if ((Test-Path -LiteralPath $File.Path) -and -not $Force) {
            Write-Host "Preserving existing file: $($File.Path)" -ForegroundColor Yellow
            Write-Host "Use -Force to replace it."
            continue
        }

        if (Test-Path -LiteralPath $File.Path) {
            $FileBackupPath = "$($File.Path).backup"

            if (-not (Test-Path -LiteralPath $FileBackupPath)) {
                Copy-Item -LiteralPath $File.Path -Destination $FileBackupPath
                Write-Host "Backup created: $FileBackupPath" -ForegroundColor Yellow
            }
            else {
                Write-Host "Preserved existing backup: $FileBackupPath" -ForegroundColor Yellow
            }
        }

        Set-Content -LiteralPath $File.Path `
            -Value $File.Content `
            -Encoding UTF8

        Write-Host "Created: $($File.Path)" -ForegroundColor Green
    }


    Write-Step "Detecting iOS Fastlane configuration"

    $IosPath = Join-Path $ProjectPath "ios"
    if (Test-Path -LiteralPath $IosPath) {
        $XcodeProject = Get-ChildItem -LiteralPath $IosPath -Directory -Filter "*.xcodeproj" |
            Select-Object -First 1
        $PbxprojPath = $null
        if ($XcodeProject) {
            $PbxprojPath = Join-Path $XcodeProject.FullName "project.pbxproj"
        }

        $IosBundleId = $null
        $IosTeamId = $null
        if ($PbxprojPath -and (Test-Path -LiteralPath $PbxprojPath)) {
            $PbxprojContent = Get-Content -LiteralPath $PbxprojPath -Raw

            $BundleMatches = [regex]::Matches(
                $PbxprojContent,
                'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);'
            )
            foreach ($BundleMatch in $BundleMatches) {
                $Candidate = $BundleMatch.Groups[1].Value.Trim().Trim('"')
                if ($Candidate -and $Candidate -notmatch '\$\(' -and $Candidate -notmatch '\*') {
                    $IosBundleId = $Candidate
                    break
                }
            }

            $TeamMatch = [regex]::Match(
                $PbxprojContent,
                'DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]+);'
            )
            if ($TeamMatch.Success) {
                $IosTeamId = $TeamMatch.Groups[1].Value.Trim()
            }
        }

        # Prefer an explicitly shared Xcode scheme; fall back to the project name.
        $Scheme = $null
        $SharedSchemesPath = Join-Path $IosPath "fastlane"
        $SchemeFiles = Get-ChildItem -LiteralPath $IosPath -Recurse -File -Filter "*.xcscheme" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\.xcodeproj\\xcshareddata\\xcschemes\\|\.xcworkspace\\xcshareddata\\xcschemes\\' }
        if ($SchemeFiles) {
            $Scheme = [System.IO.Path]::GetFileNameWithoutExtension($SchemeFiles[0].Name)
        }
        if (-not $Scheme -and $XcodeProject) {
            $Scheme = [System.IO.Path]::GetFileNameWithoutExtension($XcodeProject.Name)
        }

        if (-not $IosBundleId) {
            $IosBundleId = Read-Host "Could not detect iOS bundle ID. Enter app_identifier (e.g. com.example.app)"
        } else {
            Write-Host "Detected iOS bundle ID: $IosBundleId" -ForegroundColor Green
        }

        if (-not $IosTeamId) {
            $IosTeamId = Read-Host "Could not detect Apple Developer Team ID. Enter team_id"
        } else {
            Write-Host "Detected Apple Developer Team ID: $IosTeamId" -ForegroundColor Green
        }

        if (-not $Scheme) {
            $Scheme = Read-Host "Could not detect Xcode scheme. Enter scheme name"
        } else {
            Write-Host "Detected Xcode scheme: $Scheme" -ForegroundColor Green
        }

        # Apple ID email is not stored reliably in an Xcode project, so use an environment
        # variable when set, otherwise ask the developer. It is not guessed from the project.
        $AppleId = $env:FASTLANE_APPLE_ID
        if ([string]::IsNullOrWhiteSpace($AppleId)) {
            $AppleId = Read-Host "Enter Apple ID email (used by Fastlane Appfile)"
        }

        if ([string]::IsNullOrWhiteSpace($IosBundleId) -or
            [string]::IsNullOrWhiteSpace($IosTeamId) -or
            [string]::IsNullOrWhiteSpace($Scheme) -or
            [string]::IsNullOrWhiteSpace($AppleId)) {
            throw "iOS Fastlane values cannot be empty."
        }

        $IosFastlanePath = Join-Path $IosPath "fastlane"
        New-Item -ItemType Directory -Path $IosFastlanePath -Force | Out-Null

        $IosAppfileContent = @'
app_identifier("__IOS_BUNDLE_ID__")
apple_id("__APPLE_ID__")
team_id("__IOS_TEAM_ID__")
'@
        $IosAppfileContent = $IosAppfileContent.Replace("__IOS_BUNDLE_ID__", $IosBundleId).
            Replace("__APPLE_ID__", $AppleId).
            Replace("__IOS_TEAM_ID__", $IosTeamId)

        $IosFastfileContent = @'
default_platform(:ios)

platform :ios do
  desc "Build and upload to TestFlight"
  lane :testflight do
    api_key = app_store_connect_api_key(
      key_id: ENV.fetch("ASC_KEY_ID"),
      issuer_id: ENV.fetch("ASC_ISSUER_ID"),
      key_filepath: ENV.fetch(
        "ASC_KEY_PATH",
        File.expand_path("./AuthKey_#{ENV.fetch('ASC_KEY_ID')}.p8", __dir__)
      ),
      duration: 1200,
      in_house: false
    )

    build_app(
      scheme: "__IOS_SCHEME__",
      export_method: "app-store"
    )

    upload_to_testflight(
      api_key: api_key,
      skip_waiting_for_build_processing: true
    )
  end
end
'@
        $IosFastfileContent = $IosFastfileContent.Replace("__IOS_SCHEME__", $Scheme)

        $IosGemfileContent = @'
source "https://rubygems.org"

gem "fastlane"
'@

        $IosFiles = @(
            @{
                Path = Join-Path $IosFastlanePath "Appfile"
                Content = $IosAppfileContent
            },
            @{
                Path = Join-Path $IosFastlanePath "Fastfile"
                Content = $IosFastfileContent
            },
            @{
                Path = Join-Path $IosPath "Gemfile"
                Content = $IosGemfileContent
            }
        )

        Write-Step "Generating iOS Fastlane files"
        foreach ($File in $IosFiles) {
            if ((Test-Path -LiteralPath $File.Path) -and -not $Force) {
                $Answer = Read-Host "File exists: $($File.Path). Overwrite? (y/N)"
                if ($Answer -notin @("y", "Y", "yes", "YES")) {
                    Write-Host "Preserving existing file: $($File.Path)" -ForegroundColor Yellow
                    continue
                }
            }

            if (Test-Path -LiteralPath $File.Path) {
                $BackupPath = "$($File.Path).backup"
                if (-not (Test-Path -LiteralPath $BackupPath)) {
                    Copy-Item -LiteralPath $File.Path -Destination $BackupPath
                    Write-Host "Backup created: $BackupPath" -ForegroundColor Yellow
                }
            }

            Set-Content -LiteralPath $File.Path -Value $File.Content -Encoding UTF8
            Write-Host "Created: $($File.Path)" -ForegroundColor Green
        }

        Write-Host "iOS bundle ID: $IosBundleId"
        Write-Host "Apple ID: $AppleId"
        Write-Host "Team ID: $IosTeamId"
        Write-Host "Scheme: $Scheme"
        Write-Host "Note: iOS builds/TestFlight uploads must run on macOS with Xcode." -ForegroundColor Yellow
        Write-Host "Set ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH before running the TestFlight lane." -ForegroundColor Yellow
    }
    else {
        Write-Host "No ios folder found; skipping iOS Fastlane setup." -ForegroundColor Yellow
    }

    Write-Step "Checking Ruby and Bundler"

    if (-not (Get-Command ruby -ErrorAction SilentlyContinue)) {
        throw "Ruby was not found. Install Ruby with DevKit from https://rubyinstaller.org/, reopen the terminal, and rerun this script."
    }

    if (-not (Get-Command gem -ErrorAction SilentlyContinue)) {
        throw "RubyGems command was not found. Verify your Ruby installation and PATH."
    }

    if (-not (Get-Command bundle -ErrorAction SilentlyContinue)) {
        Write-Host "Bundler command not found. Installing Bundler..." -ForegroundColor Yellow

        & gem install bundler

        if ($LASTEXITCODE -ne 0) {
            throw "Could not install Bundler. Run 'gem install bundler' manually and retry."
        }
    }

    if (-not (Get-Command bundle -ErrorAction SilentlyContinue)) {
        throw "Bundler is still not available. Restart the terminal and rerun the setup script."
    }

    Write-Step "Running bundle install in android folder"

    Push-Location $AndroidPath

    try {
        & bundle install

        if ($LASTEXITCODE -ne 0) {
            throw "bundle install failed with exit code $LASTEXITCODE. Fix the dependency or network error and rerun the script."
        }
    }
    finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " Fastlane setup completed successfully!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green

    Write-Host "Project: $ProjectPath"
    Write-Host "Application ID: $ApplicationId"
    Write-Host ""
    Write-Host "Run from the project root:"
    Write-Host '  PowerShell: powershell -NoProfile -ExecutionPolicy Bypass -File ".\setup-fastlane.ps1"'
    Write-Host "  CMD:        setup-fastlane.cmd"
    Write-Host ""
    Write-Host "NPM scripts:"
    Write-Host "  npm run aab"
    Write-Host "  npm run release"
    Write-Host "  npm run fastlane:build"
    Write-Host "  npm run fastlane:apk"
    Write-Host "  npm run fastlane:internal"
    Write-Host "  npm run fastlane:deploy"
    Write-Host ""
    Write-Host "Note: fastlane:deploy defaults to production unless a track is supplied." -ForegroundColor Yellow
    Write-Host "Google Play credentials must be available at android/fastlane/e-oms.json." -ForegroundColor Yellow
}
catch {
    Write-Host ""
    Write-Host "Fastlane setup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
