param(
    [string]$OriginalUserSid
)

# Windows automatic setup: account options + numbered software selection.
# Configure software in Software.json. Only applications chosen at the menu are run.

$ErrorActionPreference = 'Continue'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $scriptRoot 'Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("setup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# Preserve the originally signed-in user's SID if UAC requests credentials for another admin.
if ([string]::IsNullOrWhiteSpace($OriginalUserSid)) {
    $OriginalUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}
$script:OriginalUserSid = $OriginalUserSid

# Relaunch elevated if needed.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator permission is required. Approve the Windows UAC prompt.' -ForegroundColor Yellow
    try {
        $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -OriginalUserSid "{1}"' -f $MyInvocation.MyCommand.Path, $OriginalUserSid
        $elevatedProcess = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $argumentLine
        exit $elevatedProcess.ExitCode
    } catch {
        Write-Error 'Elevation was cancelled or failed.'
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

try { Start-Transcript -Path $logFile -Append | Out-Null } catch {}

$script:failed = [System.Collections.Generic.List[string]]::new()
$script:winget = Get-Command winget.exe -ErrorAction SilentlyContinue

function Ask-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Question,
        [bool]$DefaultYes = $false
    )
    if ($DefaultYes) { $prompt = '[Y/n]' } else { $prompt = '[y/N]' }
    $answer = Read-Host "$Question $prompt"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return ($answer.Trim().ToLowerInvariant() -in @('y', 'yes'))
}

function Configure-BuiltInAdministrator {
    Write-Host ''
    Write-Host 'This will enable the built-in Administrator account (SID ending in -500).' -ForegroundColor Yellow
    Write-Host 'Step 1: confirm. Step 2: you will be asked to enter a new password for that account.' -ForegroundColor Yellow
    $confirmation = Read-Host 'Type YES to continue, or anything else to cancel'
    if ($confirmation -cne 'YES') {
        Write-Host 'Administrator account change cancelled.' -ForegroundColor DarkYellow
        return
    }

    try {
        $administratorAccount = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
        if ($null -eq $administratorAccount) {
            throw 'Could not find the built-in Administrator account (SID ending in -500).'
        }

        Write-Host ''
        Write-Host 'Step: enter a new password for the built-in Administrator account.' -ForegroundColor White
        Write-Host 'Password input is hidden. Use a strong, unique password for this machine.' -ForegroundColor Yellow
        $securePassword = Read-Host 'Enter new Administrator password (leave blank to cancel)' -AsSecureString
        if ($null -eq $securePassword -or $securePassword.Length -eq 0) {
            Write-Host 'Administrator account change cancelled (no password entered).' -ForegroundColor DarkYellow
            return
        }
        $confirmPassword = Read-Host 'Confirm new Administrator password' -AsSecureString
        if ($null -eq $confirmPassword -or $confirmPassword.Length -eq 0) {
            Write-Host 'Administrator account change cancelled (confirmation was empty).' -ForegroundColor DarkYellow
            return
        }

        $plainFirst = [System.Net.NetworkCredential]::new('', $securePassword).Password
        $plainConfirm = [System.Net.NetworkCredential]::new('', $confirmPassword).Password
        try {
            if ($plainFirst -cne $plainConfirm) {
                Write-Host 'Passwords do not match. Administrator account was not changed.' -ForegroundColor Yellow
                $script:failed.Add('Built-in Administrator configuration skipped: passwords did not match')
                return
            }
            if ($plainFirst.Length -lt 8) {
                Write-Host 'Password must be at least 8 characters. Administrator account was not changed.' -ForegroundColor Yellow
                $script:failed.Add('Built-in Administrator configuration skipped: password too short')
                return
            }
        } finally {
            $plainFirst = $null
            $plainConfirm = $null
        }

        Set-LocalUser -Name $administratorAccount.Name -Password $securePassword -ErrorAction Stop
        Enable-LocalUser -Name $administratorAccount.Name -ErrorAction Stop
        Write-Host ("Enabled built-in Administrator account '{0}' and set the password you entered." -f $administratorAccount.Name) -ForegroundColor Green
        Write-Host 'Use a unique password per machine, especially on business or internet-exposed computers.' -ForegroundColor Yellow
    } catch {
        Write-Host ("Could not configure the built-in Administrator account: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $script:failed.Add('Built-in Administrator configuration failed')
    } finally {
        if (Get-Variable -Name securePassword -Scope Local -ErrorAction SilentlyContinue) { $securePassword = $null }
        if (Get-Variable -Name confirmPassword -Scope Local -ErrorAction SilentlyContinue) { $confirmPassword = $null }
    }
}

function Rename-CurrentLocalUser {
    Write-Host ''
    try {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($script:OriginalUserSid)
        $localAccount = Get-LocalUser -SID $sid -ErrorAction Stop
    } catch {
        Write-Host 'The originally signed-in account could not be matched to a local Windows account.' -ForegroundColor Yellow
        Write-Host 'Automatic rename supports local accounts, not domain/Entra ID accounts. No account was changed.' -ForegroundColor Yellow
        return
    }

    Write-Host ("Current local account name: {0}" -f $localAccount.Name)
    Write-Host 'This changes the local account name and display name. It does NOT rename the existing C:\Users profile folder.' -ForegroundColor Yellow
    $newName = (Read-Host 'Enter the new account name (1-20 characters), or leave blank to cancel').Trim()
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host 'Account rename cancelled.' -ForegroundColor DarkYellow
        return
    }
    if ($newName.Length -gt 20) {
        Write-Host 'The local account name must be 20 characters or fewer.' -ForegroundColor Yellow
        $script:failed.Add('Account rename skipped: new name exceeded 20 characters')
        return
    }

    $invalidChars = '"/\[]:;|=,+*?<>'.ToCharArray()
    foreach ($character in $invalidChars) {
        if ($newName.Contains([string]$character)) {
            Write-Host ('The account name contains an invalid character: {0}' -f $character) -ForegroundColor Yellow
            $script:failed.Add('Account rename skipped: invalid characters in new name')
            return
        }
    }

    $allLocalUsers = @(Get-LocalUser -ErrorAction Stop)
    $duplicate = $allLocalUsers | Where-Object { $_.Name -ieq $newName -and $_.SID.Value -ne $localAccount.SID.Value } | Select-Object -First 1
    if ($duplicate) {
        Write-Host ("A local account named '{0}' already exists." -f $newName) -ForegroundColor Yellow
        $script:failed.Add('Account rename skipped: target name already exists')
        return
    }
    if ($localAccount.Name -ieq $newName) {
        Write-Host 'The new name is the same as the current name; no change needed.' -ForegroundColor DarkYellow
        return
    }

    try {
        Rename-LocalUser -Name $localAccount.Name -NewName $newName -ErrorAction Stop
        try {
            Set-LocalUser -Name $newName -FullName $newName -ErrorAction Stop
        } catch {
            Write-Host 'The account was renamed, but Windows did not accept the display-name update.' -ForegroundColor Yellow
        }
        Write-Host ("Renamed local account '{0}' to '{1}'. Sign out or restart to see the new name everywhere." -f $localAccount.Name, $newName) -ForegroundColor Green
        Write-Host 'The existing user profile folder was left unchanged.' -ForegroundColor Yellow
    } catch {
        Write-Host ("Could not rename the local account: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $script:failed.Add('Local user account rename failed')
    }
}

function Install-WingetApp {
    param([Parameter(Mandatory = $true)]$App)

    if (-not $script:winget) {
        Write-Host ("Skipping {0}: winget is not available." -f $App.Name) -ForegroundColor Yellow
        $script:failed.Add(("{0} (winget unavailable)" -f $App.Name))
        return
    }

    Write-Host ("`n--- Installing {0} ({1}) ---" -f $App.Name, $App.Id) -ForegroundColor Cyan
    $wingetArgs = @(
        'install', '--id', [string]$App.Id, '--exact', '--source', 'winget',
        '--silent', '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    & $script:winget.Source @wingetArgs
    $exitCode = $LASTEXITCODE
    # 0x8A15002B is Winget's "already installed" result on common versions.
    if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq -1978335189) {
        Write-Host ("Finished: {0} (exit code {1})" -f $App.Name, $exitCode) -ForegroundColor Green
        if ($exitCode -eq 3010) { Write-Host 'A restart may be required.' -ForegroundColor Yellow }
    } else {
        Write-Host ("Installer returned exit code {0}: {1}" -f $exitCode, $App.Name) -ForegroundColor Yellow
        $script:failed.Add(("{0} (exit code {1})" -f $App.Name, $exitCode))
    }
}

function Install-LocalSoftware {
    param([Parameter(Mandatory = $true)]$Installer)

    $relativePath = [string]$Installer.Path
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        Write-Host ("Skipping {0}: no Path is configured in Software.json." -f $Installer.Name) -ForegroundColor Yellow
        $script:failed.Add(("{0} (no installer path configured)" -f $Installer.Name))
        return
    }

    if ([System.IO.Path]::IsPathRooted($relativePath)) {
        $installerPath = $relativePath
    } else {
        $installerPath = Join-Path $script:scriptRoot $relativePath
    }

    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        Write-Host ("Not found: {0} ({1})" -f $Installer.Name, $installerPath) -ForegroundColor Yellow
        Write-Host 'Copy the installer to the configured path, or update its Path in Software.json.' -ForegroundColor Yellow
        $script:failed.Add(("{0} (installer file missing)" -f $Installer.Name))
        return
    }

    $arguments = @()
    if ($null -ne $Installer.Arguments) { $arguments = @($Installer.Arguments | ForEach-Object { [string]$_ }) }
    $extension = [System.IO.Path]::GetExtension($installerPath).ToLowerInvariant()
    $workingDirectory = Split-Path -Parent $installerPath

    try {
        Write-Host ("`n--- Running {0} ---" -f $Installer.Name) -ForegroundColor Cyan
        if ($extension -eq '.msi') {
            $processFile = Join-Path $env:WINDIR 'System32\msiexec.exe'
            $argumentParts = @('/i', ('"{0}"' -f $installerPath)) + $arguments
        } else {
            $processFile = $installerPath
            $argumentParts = $arguments
        }

        $startParameters = @{
            FilePath         = $processFile
            WorkingDirectory = $workingDirectory
            Wait             = $true
            PassThru         = $true
            ErrorAction      = 'Stop'
        }
        if ($argumentParts.Count -gt 0) {
            $startParameters.ArgumentList = ($argumentParts -join ' ')
        }
        $process = Start-Process @startParameters
        $exitCode = $process.ExitCode
        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641) {
            Write-Host ("Finished: {0} (exit code {1})" -f $Installer.Name, $exitCode) -ForegroundColor Green
            if ($exitCode -in @(3010, 1641)) { Write-Host 'The installer reported that a restart may be required.' -ForegroundColor Yellow }
        } else {
            Write-Host ("Installer returned exit code {0}: {1}" -f $exitCode, $Installer.Name) -ForegroundColor Yellow
            $script:failed.Add(("{0} (exit code {1})" -f $Installer.Name, $exitCode))
        }
    } catch {
        Write-Host ("Could not run {0}: {1}" -f $Installer.Name, $_.Exception.Message) -ForegroundColor Red
        $script:failed.Add(("{0} (launch error)" -f $Installer.Name))
    }
}

function Get-SelectableSoftware {
    param([Parameter(Mandatory = $true)]$Config)

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($app in @($Config.Apps)) {
        if ($null -eq $app -or $app.Enabled -eq $false) { continue }
        if ([string]$app.Type -ne 'winget' -or [string]::IsNullOrWhiteSpace([string]$app.Id)) { continue }
        [void]$items.Add([PSCustomObject]@{
            Kind = 'winget'
            Name = [string]$app.Name
            Detail = ("Winget ID: {0}" -f [string]$app.Id)
            Item = $app
        })
    }

    foreach ($installer in @($Config.LocalInstallers)) {
        if ($null -eq $installer -or $installer.Enabled -eq $false) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$installer.Name)) { continue }
        $relativePath = [string]$installer.Path
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            $fullPath = ''
            $detail = 'Local installer path not configured'
        } elseif ([System.IO.Path]::IsPathRooted($relativePath)) {
            $fullPath = $relativePath
            $detail = $relativePath
        } else {
            $fullPath = Join-Path $script:scriptRoot $relativePath
            $detail = $relativePath
        }
        if ([string]::IsNullOrWhiteSpace($fullPath) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            $detail = "$detail [FILE NOT FOUND]"
        }
        [void]$items.Add([PSCustomObject]@{
            Kind = 'local'
            Name = [string]$installer.Name
            Detail = $detail
            Item = $installer
        })
    }
    return $items.ToArray()
}

function Select-SoftwareToInstall {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items)

    if ($Items.Count -eq 0) {
        Write-Host 'No enabled software entries were found in Software.json.' -ForegroundColor Yellow
        return @()
    }

    Write-Host ''
    Write-Host 'SOFTWARE LIST — enter numbers separated by commas (example: 1,3,5).' -ForegroundColor Cyan
    Write-Host 'Enter A to select all enabled items, or 0 to skip software installation.' -ForegroundColor Cyan
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $number = $index + 1
        $kindLabel = if ($Items[$index].Kind -eq 'winget') { 'Winget' } else { 'Local' }
        Write-Host (" {0,2}. [{1}] {2} — {3}" -f $number, $kindLabel, $Items[$index].Name, $Items[$index].Detail)
    }

    while ($true) {
        $response = (Read-Host 'Software numbers').Trim()
        if ([string]::IsNullOrWhiteSpace($response) -or $response -eq '0') { return @() }
        if ($response -match '^(?i:a|all)$') { return $Items }

        $tokens = $response -split '[,;\s]+'
        $indices = [System.Collections.Generic.List[int]]::new()
        $invalid = $false
        foreach ($token in $tokens) {
            if ($token -notmatch '^\d+$') {
                $invalid = $true
                break
            }
            $number = [int]$token
            if ($number -lt 1 -or $number -gt $Items.Count) {
                $invalid = $true
                break
            }
            if (-not $indices.Contains($number)) { [void]$indices.Add($number) }
        }
        if ($invalid -or $indices.Count -eq 0) {
            Write-Host ("Invalid selection. Enter numbers from 1 to {0}, A, or 0." -f $Items.Count) -ForegroundColor Yellow
            continue
        }

        $selectedItems = @()
        foreach ($number in $indices) { $selectedItems += $Items[$number - 1] }
        return $selectedItems
    }
}

try {
    Clear-Host
    Write-Host '========================================================' -ForegroundColor Cyan
    Write-Host '              WINDOWS AUTOMATIC SETUP' -ForegroundColor Cyan
    Write-Host '========================================================' -ForegroundColor Cyan
    Write-Host ("Log file: {0}" -f $logFile)
    Write-Host ''

    $configPath = Join-Path $scriptRoot 'Software.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Software.json was not found at $configPath. Restore the configuration file and run the setup again."
    }
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    } catch {
        throw "Could not parse Software.json. Check that it contains valid JSON. Details: $($_.Exception.Message)"
    }

    Write-Host 'Choose what you want to do:' -ForegroundColor White
    Write-Host '  1. Enable built-in Administrator and set a new password (you will enter it)'
    Write-Host '  2. Rename the currently signed-in local user account'
    Write-Host '  3. Choose software to install from a numbered list'
    Write-Host '  4. Run all three options'
    Write-Host '  0. Exit'
    Write-Host ''
    Write-Host 'You can choose more than one option, for example: 1,3'

    $mainChoice = (Read-Host 'Enter option number(s)').Trim()
    if ([string]::IsNullOrWhiteSpace($mainChoice) -or $mainChoice -eq '0') {
        Write-Host 'No changes requested. Exiting.' -ForegroundColor DarkYellow
        return
    }

    if ($mainChoice -eq '4') {
        $actions = @('1', '2', '3')
    } else {
        $actions = @($mainChoice -split '[,;\s]+' | Select-Object -Unique)
        $validActions = @('1', '2', '3')
        $invalidActions = @($actions | Where-Object { $_ -notin $validActions })
        if ($invalidActions.Count -gt 0) {
            Write-Host 'Invalid main-menu selection. Use 1, 2, 3, 4, or 0. Example: 1,3' -ForegroundColor Yellow
            Read-Host 'Press Enter to close'
            return
        }
    }

    if ($actions -contains '1') { Configure-BuiltInAdministrator }
    if ($actions -contains '2') { Rename-CurrentLocalUser }

    if ($actions -contains '3') {
        $availableSoftware = @(Get-SelectableSoftware -Config $config)
        $chosenSoftware = @(Select-SoftwareToInstall -Items $availableSoftware)

        if ($chosenSoftware.Count -gt 0) {
            if (-not $script:winget -and @($chosenSoftware | Where-Object { $_.Kind -eq 'winget' }).Count -gt 0) {
                Write-Host ''
                Write-Host 'winget was not found. Winget apps will be skipped, but selected local installers can still run.' -ForegroundColor Yellow
                Write-Host 'Install/update Microsoft App Installer, then rerun the script: https://aka.ms/getwinget' -ForegroundColor Yellow
            } elseif ($script:winget) {
                Write-Host ''
                Write-Host 'Updating Winget sources...' -ForegroundColor Cyan
                & $script:winget.Source source update
            }

            foreach ($chosen in $chosenSoftware) {
                if ($chosen.Kind -eq 'winget') {
                    Install-WingetApp -App $chosen.Item
                } else {
                    Install-LocalSoftware -Installer $chosen.Item
                }
            }
        } else {
            Write-Host 'No software selected.' -ForegroundColor DarkYellow
        }
    }

    Write-Host ''
    Write-Host '========================================================' -ForegroundColor Cyan
    Write-Host 'SETUP FINISHED' -ForegroundColor Green
    Write-Host ("Log file: {0}" -f $logFile)
    if ($script:failed.Count -gt 0) {
        Write-Host 'Some actions or applications may not have completed:' -ForegroundColor Yellow
        foreach ($item in $script:failed) { Write-Host (" - {0}" -f $item) -ForegroundColor Yellow }
        Write-Host 'Review the log and installer exit codes above.'
    } else {
        Write-Host 'No errors were recorded for actions/software that were attempted.' -ForegroundColor Green
    }
    Write-Host 'A sign-out or restart may be needed for account-name changes and some installers.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
} catch {
    Write-Host ("SETUP ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Log file: {0}" -f $logFile)
    Read-Host 'Press Enter to close'
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
