## Step 3: Run the Installer from CMD or PowerShell

Open **Command Prompt (CMD)** or **PowerShell** from the root directory of your React Native project and follow one of the options below.

### Option A — Command Prompt (CMD)

Run the following commands:

```cmd
git clone https://github.com/codewithsujeet/fastlane-setup-tools.git "%TEMP%\fastlane-tools"
call "%TEMP%\fastlane-tools\install-fastlane.cmd"
```

**Note:** Before running the installer, ensure that the CMD launcher passes the current React Native project directory to the installation script. Apply the required correction to the CMD launcher if necessary.

### Option B — PowerShell (Recommended)

Run the following commands:

```powershell
irm "https://raw.githubusercontent.com/codewithsujeet/fastlane-setup-tools/master/install-fastlane.ps1" -OutFile "$env:TEMP\install-fastlane.ps1"

& "$env:TEMP\install-fastlane.ps1" -ProjectRoot (Get-Location).Path
```

The first command downloads the PowerShell installer to your temporary directory. The second command executes the installer and explicitly passes the current directory as the React Native project root.

### Important Notes

- Run the commands from the root directory of your React Native project.
- Ensure that Git is installed and available in your system's `PATH`.
- Review the installation script before executing it, especially when downloading scripts directly from the internet.
- The PowerShell option explicitly passes the project root, helping the installer target the correct project directory.