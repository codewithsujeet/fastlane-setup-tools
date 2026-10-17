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
    $IosPath = Join-Path $ProjectPath "ios"
    $HasAndroid = Test-Path -LiteralPath $AppPath -PathType Container
    $HasIOS = Test-Path -LiteralPath $IosPath -PathType Container
    $PackageJsonPath = Join-Path $ProjectPath "package.json"

    if (-not (Test-Path -LiteralPath $PackageJsonPath)) {
        throw "package.json not found. Run this script from your React Native project root."
    }

    if (-not $HasAndroid -and -not $HasIOS) {
        throw "Neither android/app nor ios folder was found in: $ProjectPath"
    }

    $ApplicationId = $null
    if ($HasAndroid) {
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
        "fastlane:testflight" = "cd ios && bundle exec fastlane testflight"
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

    
# Serialize package.json
$JsonContent = $PackageJson | ConvertTo-Json -Depth 100

# Write UTF-8 without BOM for consistent Node.js compatibility
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    $PackageJsonPath,
    $JsonContent + [Environment]::NewLine,
    $Utf8NoBom
)

# Validate the generated JSON before formatting
try {
    $null = Get-Content -LiteralPath $PackageJsonPath -Raw |
        ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Generated package.json is invalid: $($_.Exception.Message)"
}

Write-Host "package.json generated and validated." -ForegroundColor Green


    try {
        Get-Content -LiteralPath $PackageJsonPath -Raw |
            ConvertFrom-Json |
            Out-Null
    }
    catch {
        throw "The updated package.json is invalid JSON."
    }

    Write-Host "package.json updated and formatted successfully." -ForegroundColor Green
    }

    if ($HasAndroid) {
    $FastlanePath = Join-Path $AndroidPath "fastlane"

    New-Item -ItemType Directory -Path $FastlanePath -Force |
        Out-Null

    $GemfileContent = @'
source "https://rubygems.org"

gem "fastlane"
'@

    $AppfileContent = @'
json_key_file("./fastlane/__ANDROID_PROJECT_JSON__.json")
package_name("__ANDROID_APPLICATION_ID__")
'@

    $AppfileContent = $AppfileContent.Replace(
        "__ANDROID_APPLICATION_ID__",
        $ApplicationId
    )

    # Create the expected Android service-account JSON path as a template.
    # Replace this template with the real JSON downloaded from Google Play Console before deployment.
    $AndroidProjectName = $null
    try {
        $AndroidPackageJsonObject = Get-Content -LiteralPath $PackageJsonPath -Raw | ConvertFrom-Json
        $AndroidProjectName = [string]$AndroidPackageJsonObject.name
    }
    catch { $AndroidProjectName = $null }
    if ([string]::IsNullOrWhiteSpace($AndroidProjectName)) {
        $AndroidProjectName = Split-Path -Leaf $ProjectPath
    }
    $SafeAndroidProjectName = ($AndroidProjectName -replace '[^A-Za-z0-9._-]', '-')
    if ([string]::IsNullOrWhiteSpace($SafeAndroidProjectName)) {
        $SafeAndroidProjectName = "react-native-app"
    }
    # Fastlane's json_key_file must point to a real Google Play service-account JSON.
    # The generated template is intentionally non-functional until replaced with the real downloaded key.
    $AndroidProjectJsonPath = Join-Path $FastlanePath ($SafeAndroidProjectName + ".json")
    $AppfileContent = $AppfileContent.Replace("__ANDROID_PROJECT_JSON__", $SafeAndroidProjectName)
    $AndroidProjectJsonObject = [ordered]@{
        type = "service_account"
        project_id = "REPLACE_WITH_GOOGLE_CLOUD_PROJECT_ID"
        private_key_id = "REPLACE_WITH_PRIVATE_KEY_ID"
        private_key = "REPLACE_WITH_PRIVATE_KEY_FROM_GOOGLE_SERVICE_ACCOUNT_JSON"
        client_email = "REPLACE_WITH_SERVICE_ACCOUNT_EMAIL"
        client_id = "REPLACE_WITH_SERVICE_ACCOUNT_CLIENT_ID"
        auth_uri = "https://accounts.google.com/o/oauth2/auth"
        token_uri = "https://oauth2.googleapis.com/token"
        auth_provider_x509_cert_url = "https://www.googleapis.com/oauth2/v1/certs"
        client_x509_cert_url = "REPLACE_WITH_CLIENT_CERTIFICATE_URL"
        universe_domain = "googleapis.com"
    }
    $AndroidProjectJsonContent = $AndroidProjectJsonObject | ConvertTo-Json -Depth 5

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
        },
        @{
            Path = $AndroidProjectJsonPath
            Content = $AndroidProjectJsonContent
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
    }

    Write-Step "Detecting iOS Fastlane configuration"

    if ($HasIOS) {
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
                if ($Candidate -and $Candidate -notmatch '\$\(' -and $Candidate -notmatch '\*' -and $Candidate -notmatch '(Tests|UITests)$') {
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
            Where-Object { $_.FullName -match '\.xcodeproj[\\/]xcshareddata[\\/]xcschemes[\\/]|\.xcworkspace[\\/]xcshareddata[\\/]xcschemes[\\/]' }
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

        # Generate a stable AuthKeyNNNNN.p8 filename. Reuse an existing generated filename on reruns.
        $ExistingAuthKey = Get-ChildItem -LiteralPath $IosFastlanePath -Filter "AuthKey[0-9][0-9][0-9][0-9][0-9].p8" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ExistingAuthKey) {
            $IosAuthKeyFileName = $ExistingAuthKey.Name
        }
        else {
            $AuthKeyNumber = Get-Random -Minimum 10000 -Maximum 100000
            $IosAuthKeyFileName = "AuthKey$AuthKeyNumber.p8"
        }

        $IosFastfileContent = @'
default_platform(:ios)

platform :ios do

  desc "Build and upload to TestFlight"
  lane :testflight do

    api_key = app_store_connect_api_key(
      key_id: "KHK7587878",
      issuer_id: "frte03b-6fb2-4089-be60-8071d381abf5",
      key_filepath: "./fastlane/__IOS_AUTHKEY_FILENAME__",
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
        $IosFastfileContent = $IosFastfileContent.Replace("__IOS_SCHEME__", $Scheme).Replace("__IOS_AUTHKEY_FILENAME__", $IosAuthKeyFileName)

        $IosGemfileContent = @'
source "https://rubygems.org"

gem "fastlane"
'@

        # Remove the previously generated iOS project JSON metadata file only when it is
        # clearly the old generated template. Do not delete unrelated/user-owned JSON files.
        $OldProjectName = $null
        try {
            $PackageJsonObject = Get-Content -LiteralPath $PackageJsonPath -Raw | ConvertFrom-Json
            $OldProjectName = [string]$PackageJsonObject.name
        }
        catch { $OldProjectName = $null }
        if ([string]::IsNullOrWhiteSpace($OldProjectName)) {
            $OldProjectName = Split-Path -Leaf $ProjectPath
        }
        $OldSafeProjectName = ($OldProjectName -replace '[^A-Za-z0-9._-]', '-')
        if (-not [string]::IsNullOrWhiteSpace($OldSafeProjectName)) {
            $OldIosJsonPath = Join-Path $IosFastlanePath ($OldSafeProjectName + ".json")
            if (Test-Path -LiteralPath $OldIosJsonPath -PathType Leaf) {
                try {
                    $OldJson = Get-Content -LiteralPath $OldIosJsonPath -Raw | ConvertFrom-Json
                    if ($OldJson.app_store_connect -and $OldJson.project_name) {
                        Remove-Item -LiteralPath $OldIosJsonPath -Force
                        Write-Host "Removed old generated iOS metadata JSON: $OldIosJsonPath" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "Kept existing iOS JSON because its contents could not be verified: $OldIosJsonPath" -ForegroundColor Yellow
                }
            }
        }

        # Create a clearly marked placeholder at the generated filename. Replace its contents
        # with the real private key downloaded from App Store Connect before using TestFlight.
        $P8PlaceholderPath = Join-Path $IosFastlanePath $IosAuthKeyFileName
        if (-not (Test-Path -LiteralPath $P8PlaceholderPath -PathType Leaf)) {
            $P8PlaceholderContent = @'
PLACEHOLDER ONLY - NOT A VALID APP STORE CONNECT PRIVATE KEY.
Replace this entire file with the real .p8 key downloaded from App Store Connect.
Do not commit the real private key to source control.
'@
            Set-Content -LiteralPath $P8PlaceholderPath -Value $P8PlaceholderContent -Encoding ASCII
            Write-Host "Created key placeholder: $P8PlaceholderPath" -ForegroundColor Yellow
        }

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
                if ($Answer.Trim() -notin @("", "y", "Y", "yes", "YES")) {
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
        Write-Host "iOS API key filename: $IosAuthKeyFileName" -ForegroundColor Green
        Write-Host "Replace the placeholder at ios/fastlane/$IosAuthKeyFileName with the real .p8 downloaded from App Store Connect." -ForegroundColor Yellow
        Write-Host "ASC_KEY_ID and ASC_ISSUER_ID must be copied from App Store Connect; they cannot be random values." -ForegroundColor Yellow
        Write-Host "Optional: set ASC_KEY_PATH if your real key is stored at another path." -ForegroundColor Yellow
        Write-Host "Note: iOS builds/TestFlight uploads must run on macOS with Xcode." -ForegroundColor Yellow
    }
    else {
        Write-Host "No ios folder found; skipping iOS Fastlane setup." -ForegroundColor Yellow
    }

    Write-Step "Checking Ruby and Bundler"

    $BundleCommand = Get-Command bundle -ErrorAction SilentlyContinue
    if (-not $BundleCommand) {
        if (-not (Get-Command ruby -ErrorAction SilentlyContinue) -or -not (Get-Command gem -ErrorAction SilentlyContinue)) {
            Write-Host "Ruby/Bundler is not installed. Fastlane files were generated, but Gemfile.lock cannot be resolved on this machine." -ForegroundColor Yellow
            Write-Host "Install Ruby and Bundler, then run 'bundle install' inside each platform folder." -ForegroundColor Yellow
        }
        else {
            Write-Host "Bundler command not found. Installing Bundler..." -ForegroundColor Yellow
            & gem install bundler
            if ($LASTEXITCODE -ne 0) {
                throw "Could not install Bundler. Run 'gem install bundler' manually and retry."
            }
        }
    }

    if (Get-Command bundle -ErrorAction SilentlyContinue) {
        if ($HasAndroid) {
            Write-Step "Running bundle install in android folder (creates android/Gemfile.lock)"
            Push-Location $AndroidPath
            try {
                & bundle install
                if ($LASTEXITCODE -ne 0) {
                    throw "Android bundle install failed with exit code $LASTEXITCODE."
                }
            }
            finally { Pop-Location }
        }

        if ($HasIOS) {
            Write-Step "Running bundle install in ios folder (creates ios/Gemfile.lock)"
            Push-Location $IosPath
            try {
                & bundle install
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "iOS bundle install failed on this machine. iOS Fastlane files remain generated; retry 'bundle install' in ios on macOS with Ruby/Bundler installed." -ForegroundColor Yellow
                }
                elseif (Test-Path -LiteralPath (Join-Path $IosPath "Gemfile.lock") -PathType Leaf) {
                    Write-Host "Created/updated ios/Gemfile.lock" -ForegroundColor Green
                }
            }
            finally { Pop-Location }
        }
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " Fastlane setup completed successfully!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green

    Write-Host "Project: $ProjectPath"
    if ($ApplicationId) { Write-Host "Application ID: $ApplicationId" }
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
    if ($HasIOS) {
        Write-Host "  npm run fastlane:testflight"
    }
    Write-Host ""
    Write-Host "Note: fastlane:deploy defaults to production unless a track is supplied." -ForegroundColor Yellow
    if ($HasAndroid) {
        $AndroidJsonName = $SafeAndroidProjectName + ".json"
        Write-Host "Replace android/fastlane/$AndroidJsonName with the real Google Play service-account JSON before deploying." -ForegroundColor Yellow
    }
    if ($HasIOS) {
        Write-Host "Replace the generated ios/fastlane/$IosAuthKeyFileName placeholder with the real .p8 private key from App Store Connect." -ForegroundColor Yellow
        Write-Host "ASC_KEY_ID and ASC_ISSUER_ID must be the actual values from App Store Connect; random values will not authenticate." -ForegroundColor Yellow
        Write-Host "Never commit the .p8 private key to Git." -ForegroundColor Yellow
        Write-Host "Run iOS build/TestFlight lanes on macOS with Xcode installed." -ForegroundColor Yellow
    }
}
catch {
    Write-Host ""
    Write-Host "Fastlane setup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
