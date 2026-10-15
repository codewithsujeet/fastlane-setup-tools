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
