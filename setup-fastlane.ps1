param(
    [string]$ProjectPath = $PSScriptRoot,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Helper: write a file with backup/overwrite logic (shared by both platforms)
# ---------------------------------------------------------------------------
function Write-FastlaneFile {
    param(
        [string]$FilePath,
        [string]$FileContent,
        [bool]$ForceOverwrite
    )

    if ((Test-Path -LiteralPath $FilePath) -and -not $ForceOverwrite) {
        Write-Host "Preserving existing file: $FilePath" -ForegroundColor Yellow
        Write-Host "Use -Force to replace it."
        return
    }

    if (Test-Path -LiteralPath $FilePath) {
        $BackupPath = "$FilePath.backup"
        if (-not (Test-Path -LiteralPath $BackupPath)) {
            Copy-Item -LiteralPath $FilePath -Destination $BackupPath
            Write-Host "Backup created: $BackupPath" -ForegroundColor Yellow
        }
        else {
            Write-Host "Preserved existing backup: $BackupPath" -ForegroundColor Yellow
        }
    }

    Set-Content -LiteralPath $FilePath -Value $FileContent -Encoding UTF8
    Write-Host "Created: $FilePath" -ForegroundColor Green
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
        '(?m)^\s*applicationId\s*(?:=\s*)?["'']([ ^"'']+)["'']'
    )

    if (-not $Match.Success) {
        throw "Could not detect applicationId in $GradleFile. Add it manually to android/fastlane/Appfile."
    }

    $ApplicationId = $Match.Groups[1].Value

    Write-Host "Detected application ID: $ApplicationId" -ForegroundColor Green

    # ======================================================================
    #  PACKAGE.JSON — npm scripts (Android + iOS)
    # ======================================================================

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
        # ---- Android ----
        "aab"                    = "cd android&&gradlew bundleRelease"
        "release"                = "cd android&&gradlew assembleRelease"
        "fastlane:build"         = "cd android && bundle exec fastlane build"
        "fastlane:apk"           = "cd android && bundle exec fastlane apk"
        "fastlane:deploy"        = "cd android && bundle exec fastlane deploy"
        "fastlane:internal"      = "cd android && bundle exec fastlane internal"
        # ---- iOS ----
        "fastlane:ios:beta"      = "cd ios && bundle exec fastlane beta"
        "fastlane:ios:release"   = "cd ios && bundle exec fastlane release"
        "fastlane:ios:build"     = "cd ios && bundle exec fastlane build_only"
        "fastlane:ios:test"      = "cd ios && bundle exec fastlane tests"
        "fastlane:ios:match"     = "cd ios && bundle exec fastlane match_sync"
        "fastlane:ios:certs"     = "cd ios && bundle exec fastlane certificates"
        "fastlane:ios:bump"      = "cd ios && bundle exec fastlane increment_build"
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

    # ======================================================================
    #  ANDROID — Fastlane configuration (unchanged)
    # ======================================================================

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

    Write-Step "Generating Android Fastlane files"

    foreach ($File in $Files) {
        Write-FastlaneFile -FilePath $File.Path `
            -FileContent $File.Content `
            -ForceOverwrite $Force
    }

    # ======================================================================
    #  iOS — Full Production-Grade Fastlane Integration
    # ======================================================================

    Write-Step "Detecting iOS project configuration"

    $IosPath = Join-Path $ProjectPath "ios"
    if (Test-Path -LiteralPath $IosPath) {

        # ------------------------------------------------------------------
        #  Detect Xcode project, workspace, bundle ID, team ID, and scheme
        # ------------------------------------------------------------------

        $XcodeProject = Get-ChildItem -LiteralPath $IosPath -Directory -Filter "*.xcodeproj" |
            Select-Object -First 1

        # CocoaPods projects use a .xcworkspace — detect it for Gymfile.
        $XcodeWorkspace = Get-ChildItem -LiteralPath $IosPath -Directory -Filter "*.xcworkspace" |
            Where-Object { $_.Name -notmatch 'project\.xcworkspace' } |
            Select-Object -First 1

        $PbxprojPath = $null
        if ($XcodeProject) {
            $PbxprojPath = Join-Path $XcodeProject.FullName "project.pbxproj"
        }

        $IosBundleId = $null
        $IosTeamId = $null
        $IosProjectName = $null

        if ($PbxprojPath -and (Test-Path -LiteralPath $PbxprojPath)) {
            $PbxprojContent = Get-Content -LiteralPath $PbxprojPath -Raw

            # Extract bundle identifier (skip variable expansions and wildcards)
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

            # Extract development team
            $TeamMatch = [regex]::Match(
                $PbxprojContent,
                'DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]+);'
            )
            if ($TeamMatch.Success) {
                $IosTeamId = $TeamMatch.Groups[1].Value.Trim()
            }

            # Extract PRODUCT_NAME for display purposes
            $ProductNameMatch = [regex]::Match(
                $PbxprojContent,
                'PRODUCT_NAME\s*=\s*"?([^";]+)"?\s*;'
            )
            if ($ProductNameMatch.Success) {
                $IosProjectName = $ProductNameMatch.Groups[1].Value.Trim()
                if ($IosProjectName -eq '$(TARGET_NAME)') { $IosProjectName = $null }
            }
        }

        # Prefer an explicitly shared Xcode scheme; fall back to the project name.
        $Scheme = $null
        $SchemeFiles = Get-ChildItem -LiteralPath $IosPath -Recurse -File -Filter "*.xcscheme" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\.xcodeproj\\xcshareddata\\xcschemes\\|\.xcworkspace\\xcshareddata\\xcschemes\\' }
        if ($SchemeFiles) {
            $Scheme = [System.IO.Path]::GetFileNameWithoutExtension($SchemeFiles[0].Name)
        }
        if (-not $Scheme -and $XcodeProject) {
            $Scheme = [System.IO.Path]::GetFileNameWithoutExtension($XcodeProject.Name)
        }
        if (-not $IosProjectName -and $Scheme) {
            $IosProjectName = $Scheme
        }

        # ------------------------------------------------------------------
        #  Prompt for any values that could not be auto-detected
        # ------------------------------------------------------------------

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

        if ($XcodeWorkspace) {
            Write-Host "Detected Xcode workspace: $($XcodeWorkspace.Name) (CocoaPods)" -ForegroundColor Green
        }

        # Apple ID email — use env var or prompt.
        $AppleId = $env:FASTLANE_APPLE_ID
        if ([string]::IsNullOrWhiteSpace($AppleId)) {
            $AppleId = Read-Host "Enter Apple ID email (used by Fastlane Appfile)"
        }

        # ITC Team ID (optional, for accounts with multiple iTunes Connect teams)
        $ItcTeamId = $env:FASTLANE_ITC_TEAM_ID
        if ([string]::IsNullOrWhiteSpace($ItcTeamId)) {
            $ItcTeamId = Read-Host "Enter iTunes Connect Team ID (press Enter to skip if single-team account)"
        }

        # Match git URL (for fastlane match code signing)
        $MatchGitUrl = $env:MATCH_GIT_URL
        if ([string]::IsNullOrWhiteSpace($MatchGitUrl)) {
            $MatchGitUrl = Read-Host "Enter Git URL for match certificates repo (e.g. git@github.com:org/certs.git, press Enter to skip)"
        }

        if ([string]::IsNullOrWhiteSpace($IosBundleId) -or
            [string]::IsNullOrWhiteSpace($IosTeamId) -or
            [string]::IsNullOrWhiteSpace($Scheme) -or
            [string]::IsNullOrWhiteSpace($AppleId)) {
            throw "iOS Fastlane requires bundle ID, team ID, scheme, and Apple ID. Cannot continue."
        }

        # ------------------------------------------------------------------
        #  Generate all iOS Fastlane files
        # ------------------------------------------------------------------

        $IosFastlanePath = Join-Path $IosPath "fastlane"
        New-Item -ItemType Directory -Path $IosFastlanePath -Force | Out-Null

        # ---- Appfile ----
        $IosAppfileContent = @"
# Fastlane Appfile — iOS
# Auto-generated by setup-fastlane.ps1

app_identifier("$IosBundleId")
apple_id("$AppleId")
team_id("$IosTeamId")
"@
        if (-not [string]::IsNullOrWhiteSpace($ItcTeamId)) {
            $IosAppfileContent += "`nitc_team_id(`"$ItcTeamId`")"
        }

        # ---- Gemfile ----
        $IosGemfileContent = @'
source "https://rubygems.org"

gem "fastlane"

plugins_path = File.join(File.dirname(__FILE__), 'fastlane', 'Pluginfile')
eval_gemfile(plugins_path) if File.exist?(plugins_path)
'@

        # ---- Pluginfile ----
        $IosPluginfileContent = @'
# Autogenerated by fastlane
#
# Ensure this file is checked in to source control!

# gem 'fastlane-plugin-versioning'         # Advanced version/build number management
# gem 'fastlane-plugin-badge'              # Add beta badges to app icons
# gem 'fastlane-plugin-firebase_app_distribution'  # Firebase App Distribution
'@

        # ---- Matchfile (code signing via fastlane match) ----
        $IosMatchfileContent = @"
# Matchfile — Fastlane Match (code signing)
# Docs: https://docs.fastlane.tools/actions/match/

type("appstore")
app_identifier(["$IosBundleId"])
team_id("$IosTeamId")
"@
        if (-not [string]::IsNullOrWhiteSpace($MatchGitUrl)) {
            $IosMatchfileContent += "`ngit_url(`"$MatchGitUrl`")"
            $IosMatchfileContent += @'

storage_mode("git")
readonly(true)
'@
        }
        else {
            $IosMatchfileContent += @'

# git_url("git@github.com:your-org/certificates.git")
# storage_mode("git")
# readonly(true)
'@
        }

        # ---- Gymfile (build configuration) ----
        $GymWorkspaceOrProject = ""
        if ($XcodeWorkspace) {
            $GymWorkspaceOrProject = "workspace(`"$($XcodeWorkspace.Name)`")"
        }
        elseif ($XcodeProject) {
            $GymWorkspaceOrProject = "project(`"$($XcodeProject.Name)`")"
        }

        $IosGymfileContent = @"
# Gymfile — Build configuration
# Docs: https://docs.fastlane.tools/actions/gym/

scheme("$Scheme")
$GymWorkspaceOrProject
clean(true)
output_directory("./build")
output_name("$Scheme")
export_method("app-store")

# Uncomment for specific SDK or destination overrides:
# sdk("iphoneos")
# destination("generic/platform=iOS")
# xcargs("-allowProvisioningUpdates")
"@

        # ---- .env.default (App Store Connect API key configuration) ----
        $IosEnvDefaultContent = @"
# .env.default — App Store Connect API Key configuration
# Docs: https://docs.fastlane.tools/app-store-connect-api/
#
# SECURITY: Never commit this file with real values to source control.
#           Add ios/fastlane/.env.default to .gitignore.
#
# Obtain these values from App Store Connect -> Users and Access -> Keys:
#   1. Generate an API key with "App Manager" role (or higher)
#   2. Download the .p8 private key file (one-time download!)
#   3. Note the Key ID and Issuer ID shown on the page

ASC_KEY_ID=YOUR_KEY_ID_HERE
ASC_ISSUER_ID=YOUR_ISSUER_ID_HERE
ASC_KEY_PATH=./fastlane/AuthKey.p8

# Optional: Set FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD for 2FA accounts
# FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
"@

        # ---- Fastfile (production-grade with all lanes) ----
        # Build workspace argument for build_app
        $WorkspaceArg = ""
        if ($XcodeWorkspace) {
            $WorkspaceArg = "`n      workspace: `"$($XcodeWorkspace.Name)`","
        }

        $IosFastfileContent = @"
# frozen_string_literal: true

default_platform(:ios)

# ---------------------------------------------------------------------------
#  Shared helper: build an App Store Connect API key from environment
# ---------------------------------------------------------------------------
def asc_api_key
  app_store_connect_api_key(
    key_id:       ENV.fetch('ASC_KEY_ID'),
    issuer_id:    ENV.fetch('ASC_ISSUER_ID'),
    key_filepath: ENV.fetch(
      'ASC_KEY_PATH',
      File.expand_path("./AuthKey_#{ENV.fetch('ASC_KEY_ID')}.p8", __dir__)
    ),
    duration:  1200,
    in_house:  false
  )
end

platform :ios do

  # ---- Before all lanes --------------------------------------------------------
  before_all do
    # Ensure the Xcode command-line tools point to the right Xcode
    # xcversion(version: "~> 15.0")  # uncomment to pin Xcode version
  end

  # ---- Code Signing (Match) ---------------------------------------------------

  desc 'Sync code-signing certificates & profiles via fastlane match'
  lane :match_sync do |options|
    match_type = options[:type] || 'appstore'
    match(
      type:     match_type,
      readonly: options[:readonly] != false,
      app_identifier: ['$IosBundleId']
    )
  end

  desc 'Fetch certificates and profiles without modifying the repo'
  lane :certificates do
    match(type: 'development', readonly: true)
    match(type: 'appstore',    readonly: true)
  end

  # ---- Build -----------------------------------------------------------------

  desc 'Build the app (no upload)'
  lane :build_only do
    match(type: 'appstore', readonly: true)

    build_app(
      scheme:        '$Scheme',$WorkspaceArg
      export_method: 'app-store',
      clean:         true,
      output_directory: './build'
    )
  end

  # ---- Tests -----------------------------------------------------------------

  desc 'Run all unit and UI tests'
  lane :tests do
    run_tests(
      scheme:    '$Scheme',$WorkspaceArg
      devices:   ['iPhone 15'],
      clean:     true,
      code_coverage: true
    )
  end

  # ---- TestFlight (Beta) -----------------------------------------------------

  desc 'Build and upload to TestFlight'
  lane :beta do |options|
    api_key = asc_api_key

    # Sync code-signing
    match(type: 'appstore', readonly: true)

    # Increment build number (App Store requires unique build numbers)
    increment_build_number(
      build_number: options[:build_number] || (latest_testflight_build_number(api_key: api_key) + 1)
    )

    # Build the release IPA
    build_app(
      scheme:        '$Scheme',$WorkspaceArg
      export_method: 'app-store',
      clean:         true,
      output_directory: './build'
    )

    # Upload to TestFlight
    upload_to_testflight(
      api_key: api_key,
      skip_waiting_for_build_processing: true,
      changelog: options[:changelog] || 'Bug fixes and improvements'
    )

    # Notify the team (optional — uncomment and configure)
    # slack(
    #   message: "New TestFlight build uploaded! Build: #{lane_context[SharedValues::BUILD_NUMBER]}",
    #   slack_url: ENV['SLACK_WEBHOOK_URL']
    # )
  end

  # ---- App Store (Production Release) ----------------------------------------

  desc 'Build and submit to the App Store for review'
  lane :release do |options|
    api_key = asc_api_key

    # Sync code-signing
    match(type: 'appstore', readonly: true)

    # Increment build number
    increment_build_number(
      build_number: options[:build_number] || (latest_testflight_build_number(api_key: api_key) + 1)
    )

    # Build
    build_app(
      scheme:        '$Scheme',$WorkspaceArg
      export_method: 'app-store',
      clean:         true,
      output_directory: './build'
    )

    # Upload to App Store Connect
    upload_to_app_store(
      api_key:                api_key,
      force:                  true,
      skip_metadata:          options[:skip_metadata] != false,
      skip_screenshots:       options[:skip_screenshots] != false,
      submit_for_review:      options[:submit] || false,
      automatic_release:      options[:auto_release] || false,
      precheck_include_in_app_purchases: false
    )
  end

  # ---- Version Bump ----------------------------------------------------------

  desc 'Increment the build number'
  lane :increment_build do |options|
    if options[:build_number]
      increment_build_number(build_number: options[:build_number])
    else
      increment_build_number
    end

    commit_msg = "chore(ios): bump build number to #{get_build_number}"
    UI.success(commit_msg)

    # Uncomment to auto-commit the version bump:
    # commit_version_bump(
    #   message: commit_msg,
    #   xcodeproj: '$($XcodeProject.Name)'
    # )
  end

  # ---- Error Handling --------------------------------------------------------

  error do |lane, exception|
    UI.error("Lane #{lane} failed: #{exception.message}")

    # Uncomment to notify via Slack on failure:
    # slack(
    #   message: ":x: Lane `#{lane}` failed!\n#{exception.message}",
    #   slack_url: ENV['SLACK_WEBHOOK_URL'],
    #   success: false
    # )
  end
end
"@

        # ---- .gitignore for iOS fastlane secrets ----
        $IosGitignoreContent = @'
# Fastlane iOS — secrets and build artifacts
# NEVER commit .p8 private keys or provisioning profiles to source control

# App Store Connect API private key
*.p8
AuthKey_*.p8

# Environment files with secrets
.env.default
.env.*
!.env.default.template

# Build artifacts
build/
*.ipa
*.dSYM.zip
*.app.dSYM

# Fastlane working files
report.xml
Preview.html
screenshots/
test_output/

# Provisioning profiles (managed by match)
*.mobileprovision
*.provisionprofile
'@

        # ------------------------------------------------------------------
        #  Collect all iOS files to write
        # ------------------------------------------------------------------

        $IosFiles = @(
            @{
                Path    = Join-Path $IosFastlanePath "Appfile"
                Content = $IosAppfileContent
            },
            @{
                Path    = Join-Path $IosFastlanePath "Fastfile"
                Content = $IosFastfileContent
            },
            @{
                Path    = Join-Path $IosFastlanePath "Pluginfile"
                Content = $IosPluginfileContent
            },
            @{
                Path    = Join-Path $IosFastlanePath "Matchfile"
                Content = $IosMatchfileContent
            },
            @{
                Path    = Join-Path $IosFastlanePath "Gymfile"
                Content = $IosGymfileContent
            },
            @{
                Path    = Join-Path $IosFastlanePath ".env.default"
                Content = $IosEnvDefaultContent
            },
            @{
                Path    = Join-Path $IosFastlanePath ".gitignore"
                Content = $IosGitignoreContent
            },
            @{
                Path    = Join-Path $IosPath "Gemfile"
                Content = $IosGemfileContent
            }
        )

        Write-Step "Generating iOS Fastlane files"

        foreach ($File in $IosFiles) {
            Write-FastlaneFile -FilePath $File.Path `
                -FileContent $File.Content `
                -ForceOverwrite $Force
        }

        # ------------------------------------------------------------------
        #  Summary of detected/configured iOS values
        # ------------------------------------------------------------------

        Write-Host ""
        Write-Host "---- iOS Configuration Summary ----" -ForegroundColor Cyan
        Write-Host "  Bundle ID:    $IosBundleId"
        Write-Host "  Apple ID:     $AppleId"
        Write-Host "  Team ID:      $IosTeamId"
        Write-Host "  Scheme:       $Scheme"
        if ($IosProjectName) {
            Write-Host "  Project Name: $IosProjectName"
        }
        if ($XcodeWorkspace) {
            Write-Host "  Workspace:    $($XcodeWorkspace.Name)"
        }
        if (-not [string]::IsNullOrWhiteSpace($ItcTeamId)) {
            Write-Host "  ITC Team ID:  $ItcTeamId"
        }
        if (-not [string]::IsNullOrWhiteSpace($MatchGitUrl)) {
            Write-Host "  Match Repo:   $MatchGitUrl"
        }
        Write-Host ""

        Write-Host "IMPORTANT SECURITY NOTES:" -ForegroundColor Red
        Write-Host "  1. Place your .p8 private key at: ios/fastlane/AuthKey.p8" -ForegroundColor Yellow
        Write-Host "  2. NEVER commit .p8 files to source control!" -ForegroundColor Yellow
        Write-Host "  3. Edit ios/fastlane/.env.default with your ASC_KEY_ID and ASC_ISSUER_ID" -ForegroundColor Yellow
        Write-Host "  4. The .gitignore already excludes .p8 and .env files" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "NOTE: Actual iOS builds and TestFlight uploads require macOS with Xcode." -ForegroundColor Yellow
        Write-Host "      These configuration files prepare everything so you can build on a Mac." -ForegroundColor Yellow
    }
    else {
        Write-Host "No ios folder found; skipping iOS Fastlane setup." -ForegroundColor Yellow
    }

    # ======================================================================
    #  Ruby / Bundler check and install
    # ======================================================================

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

    # ======================================================================
    #  bundle install — Android
    # ======================================================================

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

    # ======================================================================
    #  bundle install — iOS (if present)
    # ======================================================================

    $IosPath = Join-Path $ProjectPath "ios"
    if (Test-Path -LiteralPath (Join-Path $IosPath "Gemfile")) {
        Write-Step "Running bundle install in ios folder"

        Push-Location $IosPath
        try {
            & bundle install
            if ($LASTEXITCODE -ne 0) {
                Write-Host "bundle install in ios/ failed (exit code $LASTEXITCODE). You may need to run it on macOS." -ForegroundColor Yellow
            }
        }
        finally {
            Pop-Location
        }
    }

    # ======================================================================
    #  Final summary
    # ======================================================================

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
    Write-Host "Android NPM scripts:" -ForegroundColor Cyan
    Write-Host "  npm run aab                  # Gradle bundleRelease"
    Write-Host "  npm run release              # Gradle assembleRelease"
    Write-Host "  npm run fastlane:build       # Fastlane AAB build"
    Write-Host "  npm run fastlane:apk         # Fastlane APK build"
    Write-Host "  npm run fastlane:internal    # Upload to internal track"
    Write-Host "  npm run fastlane:deploy      # Deploy to production"
    Write-Host ""
    Write-Host "iOS NPM scripts (run on macOS):" -ForegroundColor Cyan
    Write-Host "  npm run fastlane:ios:beta     # Build + upload to TestFlight"
    Write-Host "  npm run fastlane:ios:release  # Build + submit to App Store"
    Write-Host "  npm run fastlane:ios:build    # Build only (no upload)"
    Write-Host "  npm run fastlane:ios:test     # Run unit/UI tests"
    Write-Host "  npm run fastlane:ios:match    # Sync code-signing certs"
    Write-Host "  npm run fastlane:ios:certs    # Fetch dev + appstore certs"
    Write-Host "  npm run fastlane:ios:bump     # Increment build number"
    Write-Host ""
    Write-Host "iOS setup checklist:" -ForegroundColor Cyan
    Write-Host "  1. Edit ios/fastlane/.env.default with ASC_KEY_ID and ASC_ISSUER_ID"
    Write-Host "  2. Place AuthKey.p8 in ios/fastlane/ (NEVER commit this file!)"
    Write-Host "  3. Set up match repo for code signing (optional but recommended)"
    Write-Host "  4. Run 'npm run fastlane:ios:certs' on macOS to sync certificates"
    Write-Host "  5. Run 'npm run fastlane:ios:beta' on macOS to build and upload"
    Write-Host ""
    Write-Host "Note: fastlane:deploy defaults to production unless a track is supplied." -ForegroundColor Yellow
    Write-Host "Google Play credentials must be available at android/fastlane/e-oms.json." -ForegroundColor Yellow
}
catch {
    Write-Host ""
    Write-Host "Fastlane setup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
