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

# The built-in progress bar makes PS 5.1 file downloads ~10x slower
# (matters for 100+ MB installers like Chrome). Hide it globally.
$ProgressPreference = 'SilentlyContinue'

$script:failed = [System.Collections.Generic.List[string]]::new()
$script:winget = Get-Command winget.exe -ErrorAction SilentlyContinue
$script:wingetSourceChecked = $false
$script:wingetSourceHealthy = $true
$script:wingetRetriedForSource = $false

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

function Get-BuiltInAdminAccount {
    # Language-agnostic: finds SID ending in -500, so it works whether
    # the account is named Administrator (EN) or Administrateur (FR).
    try {
        $found = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
        if ($null -ne $found) { return $found }
    } catch {}
    # Fallback for editions where Get-LocalUser is unavailable: try well-known names.
    foreach ($name in @('Administrator', 'Administrateur')) {
        try {
            $fallback = Get-LocalUser -Name $name -ErrorAction Stop
            if ($null -ne $fallback) { return $fallback }
        } catch {}
        try {
            net user $name 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return [PSCustomObject]@{ Name = $name; SID = $null; Enabled = $null; Fallback = $true }
            }
        } catch {}
    }
    return $null
}

function Configure-BuiltInAdministrator {
    Write-Host ''
    # Look up FIRST so French PCs see their real name before confirming.
    $administratorAccount = Get-BuiltInAdminAccount
    if ($null -eq $administratorAccount) {
        Write-Host 'Could not find the built-in Administrator account (SID ending in -500).' -ForegroundColor Red
        Write-Host 'Introuvable : compte administrateur integre (SID se terminant par -500).' -ForegroundColor Red
        $script:failed.Add('Built-in Administrator configuration failed: account not found')
        return
    }
    $adminName = $administratorAccount.Name
    $enabledState = ''
    if ($null -ne $administratorAccount.Enabled) {
        $enabledState = if ($administratorAccount.Enabled) { ' (currently enabled / actuellement active)' } else { ' (currently disabled / actuellement desactive)' }
    }
    Write-Host ("Found built-in account: '{0}'{1} [SID ending in -500]. Works in English and French." -f $adminName, $enabledState) -ForegroundColor Cyan
    Write-Host 'This will enable it and set a new password that you enter (hidden input).' -ForegroundColor Yellow
    Write-Host 'Cela va activer ce compte et definir un nouveau mot de passe que vous saisissez.' -ForegroundColor Yellow
    $confirmation = ((Read-Host 'Type YES/OUI (or Y/O) to continue, anything else to cancel') | ForEach-Object { "$_".Trim() })
    # Case-insensitive on purpose: yes, YES, Yes, oui, OUI all work.
    if ($confirmation -notin @('YES', 'Y', 'OUI', 'O')) {
        Write-Host ("Cancelled (you typed '{0}'). No change was made. / Annule." -f $confirmation) -ForegroundColor DarkYellow
        return
    }

    try {
        Write-Host ''
        Write-Host ("Step: enter a new password for '{0}'. / Etape : nouveau mot de passe." -f $adminName) -ForegroundColor White
        Write-Host 'Password input is hidden. Minimum 8 characters. / Saisie masquee. 8 caracteres minimum.' -ForegroundColor Yellow
        $securePassword = Read-Host ("Enter new password for '{0}' (leave blank to cancel)" -f $adminName) -AsSecureString
        if ($null -eq $securePassword -or $securePassword.Length -eq 0) {
            Write-Host 'Administrator account change cancelled (no password entered).' -ForegroundColor DarkYellow
            return
        }
        $confirmPassword = Read-Host 'Confirm new password / Confirmez le mot de passe' -AsSecureString
        if ($null -eq $confirmPassword -or $confirmPassword.Length -eq 0) {
            Write-Host 'Cancelled (confirmation was empty). / Annule.' -ForegroundColor DarkYellow
            return
        }

        $plainFirst = [System.Net.NetworkCredential]::new('', $securePassword).Password
        $plainConfirm = [System.Net.NetworkCredential]::new('', $confirmPassword).Password
        try {
            if ($plainFirst -cne $plainConfirm) {
                Write-Host 'Passwords do not match. Account was not changed. / Mots de passe differents.' -ForegroundColor Yellow
                $script:failed.Add('Built-in Administrator configuration skipped: passwords did not match')
                return
            }
            if ($plainFirst.Length -lt 8) {
                Write-Host 'Password must be at least 8 characters. Account was not changed. / 8 caracteres minimum.' -ForegroundColor Yellow
                $script:failed.Add('Built-in Administrator configuration skipped: password too short')
                return
            }
        } finally {
            $plainFirst = $null
            $plainConfirm = $null
        }

        $activated = $false
        try {
            Set-LocalUser -Name $adminName -Password $securePassword -ErrorAction Stop
            Enable-LocalUser -Name $adminName -ErrorAction Stop
            $activated = $true
        } catch {
            # Fallback for editions where the LocalUser cmdlets are limited: net user works in EN and FR.
            Write-Host ("LocalUser cmdlet failed ({0}), trying 'net user' fallback..." -f $_.Exception.Message) -ForegroundColor Yellow
            $plainPwd = [System.Net.NetworkCredential]::new('', $securePassword).Password
            try {
                & net user $adminName $plainPwd 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "net user set password failed (exit $LASTEXITCODE)." }
                & net user $adminName /active:yes 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "net user /active:yes failed (exit $LASTEXITCODE)." }
                $activated = $true
            } finally {
                $plainPwd = $null
            }
        }
        if (-not $activated) { throw 'Activation failed with both LocalUser cmdlets and net user fallback.' }

        # Verify so the user sees proof, in either language.
        try {
            $check = Get-LocalUser -Name $adminName -ErrorAction Stop
            if ($check.Enabled) {
                Write-Host ("Enabled built-in account '{0}' and set the password you entered. / Compte '{0}' active." -f $adminName) -ForegroundColor Green
            } else {
                Write-Host ("Password set for '{0}', but Windows still reports it as disabled." -f $adminName) -ForegroundColor Yellow
                $script:failed.Add('Built-in Administrator password set but account still disabled')
            }
        } catch {
            Write-Host ("Enabled built-in account '{0}' and set the password you entered. (Verification skipped.)" -f $adminName) -ForegroundColor Green
        }
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

function Repair-WingetSource {
    # Winget's source database corrupts often ("Failed when opening sources").
    # Detect it via `source list` and auto-reset once per run.
    if ($script:wingetSourceChecked) { return $script:wingetSourceHealthy }
    $script:wingetSourceChecked = $true
    $script:wingetSourceHealthy = $true
    try {
        $out = & $script:winget.Source source list 2>&1 | Out-String
        # EN: "Failed when opening sources" / FR: "ouverture des sources / echec ... source".
        $bad = ($LASTEXITCODE -ne 0) -or ($out -match '(?i)opening sources|ouverture.*sources?|[e\xe9]chec.*sources?|sources?.*reset|sources?.*r[e\xe9]initial')
        if (-not $bad) { return $true }
        Write-Host 'Winget sources look broken. Running: winget source reset --force ...' -ForegroundColor Yellow
        & $script:winget.Source source reset --force 2>&1 | Out-Null
        Write-Host 'Updating Winget sources...' -ForegroundColor Cyan
        & $script:winget.Source source update 2>&1 | Out-Null
        $out2 = & $script:winget.Source source list 2>&1 | Out-String
        if (($LASTEXITCODE -eq 0) -and ($out2 -notmatch '(?i)opening sources|ouverture.*sources?|[e\xe9]chec.*sources?')) {
            Write-Host 'Winget sources repaired.' -ForegroundColor Green
            return $true
        }
        Write-Host 'Winget sources still failing after reset. Installs may fail with source errors.' -ForegroundColor Yellow
        Write-Host 'Manual fix: run "winget source reset --force" then "winget source update" in a new admin PowerShell.' -ForegroundColor Yellow
        $script:wingetSourceHealthy = $false
        return $false
    } catch {
        $script:wingetSourceHealthy = $false
        return $false
    }
}

function Install-FileWithSilentDefaults {
    # Runs an .msi via msiexec (/qn) or an .exe with the given args. Returns the exit code.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ExtraArgs = @()
    )
    $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $workingDirectory = Split-Path -Parent $FilePath
    if ($extension -eq '.msi') {
        $processFile = Join-Path $env:WINDIR 'System32\msiexec.exe'
        $argumentParts = @('/i', ('"{0}"' -f $FilePath), '/qn', '/norestart') + $ExtraArgs
    } else {
        $processFile = $FilePath
        $argumentParts = $ExtraArgs
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
    return $process.ExitCode
}

function Install-WingetFallbackUrl {
    # Direct-download fallback when winget itself fails (e.g. hash mismatch,
    # which winget refuses to override while running as admin).
    param([Parameter(Mandatory = $true)]$App)
    $fallbackUrl = ''
    if ($null -ne $App.FallbackUrl) { $fallbackUrl = ([string]$App.FallbackUrl).Trim() }
    if ([string]::IsNullOrWhiteSpace($fallbackUrl)) { return $false }
    try {
        $uri = [System.Uri]$fallbackUrl
        $fileName = [System.IO.Path]::GetFileName($uri.LocalPath)
        if ([string]::IsNullOrWhiteSpace($fileName) -or -not $fileName.Contains('.')) {
            $safe = ($App.Name -replace '[^\w\-]+', '_').Trim('_')
            $fileName = "$safe.exe"
        }
        $destDir = Join-Path $script:scriptRoot 'Installers'
        New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
        $destPath = Join-Path $destDir $fileName
        if (-not (Test-Path -LiteralPath $destPath -PathType Leaf)) {
            Write-Host ("Downloading fallback for {0} ..." -f $App.Name) -ForegroundColor Cyan
            $dlParams = @{ Uri = $fallbackUrl; OutFile = $destPath; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -le 5) { $dlParams['UseBasicParsing'] = $true }
            Invoke-WebRequest @dlParams
        } else {
            Write-Host ("Reusing previously downloaded fallback: {0}" -f $destPath) -ForegroundColor DarkGray
        }
        $fallbackArgs = @()
        if ($null -ne $App.FallbackArgs) { $fallbackArgs = @($App.FallbackArgs | ForEach-Object { [string]$_ }) }
        Write-Host ("`n--- Installing {0} (direct download fallback) ---" -f $App.Name) -ForegroundColor Cyan
        $exitCode = Install-FileWithSilentDefaults -FilePath $destPath -ExtraArgs $fallbackArgs
        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641) {
            Write-Host ("Finished via fallback: {0} (exit code {1})" -f $App.Name, $exitCode) -ForegroundColor Green
            if ($exitCode -in @(3010, 1641)) { Write-Host 'A restart may be required.' -ForegroundColor Yellow }
            return $true
        }
        Write-Host ("Fallback installer returned exit code {0}: {1}" -f $exitCode, $App.Name) -ForegroundColor Yellow
        $script:failed.Add(("{0} (fallback exit code {1})" -f $App.Name, $exitCode))
        return $true  # attempted
    } catch {
        Write-Host ("Fallback download/install failed for {0}: {1}" -f $App.Name, $_.Exception.Message) -ForegroundColor Red
        $script:failed.Add(("{0} (fallback failed)" -f $App.Name))
        return $true  # attempted
    }
}

function Install-WingetApp {
    param([Parameter(Mandatory = $true)]$App)

    if (-not $script:winget) {
        Write-Host ("Skipping {0}: winget is not available." -f $App.Name) -ForegroundColor Yellow
        $script:failed.Add(("{0} (winget unavailable)" -f $App.Name))
        return
    }

    # Known issue: winget sources often fail when running as the built-in Administrator (SID -500).
    try {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($currentSid -match '-500$') {
            Write-Host 'Note: you are running as the built-in Administrator; winget sources often fail in this account.' -ForegroundColor Yellow
            Write-Host 'If installs fail, log in as a regular admin user and rerun option 3.' -ForegroundColor Yellow
        }
    } catch {}

    [void](Repair-WingetSource)

    Write-Host ("`n--- Installing {0} ({1}) ---" -f $App.Name, $App.Id) -ForegroundColor Cyan
    $wingetArgs = @(
        'install', '--id', [string]$App.Id, '--exact', '--source', 'winget',
        '--silent', '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    # Capture output so hash-mismatch (EN "hash" / FR "hachage") can be detected in any language.
    $wingetOut = & $script:winget.Source @wingetArgs 2>&1 | Out-String
    Write-Host $wingetOut
    $exitCode = $LASTEXITCODE
    $hashMismatch = $wingetOut -match '(?i)hash|hachage|mismatch|non concordance|ne correspond pas'
    # 0x8A15002B is Winget's "already installed" result on common versions.
    if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq -1978335189) {
        Write-Host ("Finished: {0} (exit code {1})" -f $App.Name, $exitCode) -ForegroundColor Green
        if ($exitCode -eq 3010) { Write-Host 'A restart may be required.' -ForegroundColor Yellow }
        return
    }

    if ($hashMismatch) {
        Write-Host 'Winget reports an installer hash mismatch (stale manifest on the server side).' -ForegroundColor Yellow
        Write-Host 'Winget refuses "--ignore-security-hash" while running as administrator, so trying direct download instead.' -ForegroundColor Yellow
        if (Install-WingetFallbackUrl -App $App) { return }
    }

    # One automatic retry: if sources broke mid-run (e.g. exit 1978335217 / "failed when
    # opening sources"), reset them and try the app once more before giving up.
    if (-not $script:wingetRetriedForSource) {
        $script:wingetRetriedForSource = $true
        Write-Host 'First attempt failed. Re-checking Winget sources and retrying once...' -ForegroundColor Yellow
        $script:wingetSourceChecked = $false
        [void](Repair-WingetSource)
        $wingetOut = & $script:winget.Source @wingetArgs 2>&1 | Out-String
        Write-Host $wingetOut
        $exitCode = $LASTEXITCODE
        if ($wingetOut -match '(?i)hash|hachage|mismatch|non concordance|ne correspond pas') {
            Write-Host 'Retry also reports a hash mismatch; trying direct download instead.' -ForegroundColor Yellow
            if (Install-WingetFallbackUrl -App $App) { return }
        }
        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq -1978335189) {
            Write-Host ("Finished on retry: {0} (exit code {1})" -f $App.Name, $exitCode) -ForegroundColor Green
            if ($exitCode -eq 3010) { Write-Host 'A restart may be required.' -ForegroundColor Yellow }
            return
        }
    }

    # Last resort for apps with a configured direct download: better than a bare failure.
    if (($null -ne $App.FallbackUrl) -and (-not [string]::IsNullOrWhiteSpace([string]$App.FallbackUrl))) {
        Write-Host ("Winget failed for {0}; trying configured direct download..." -f $App.Name) -ForegroundColor Yellow
        if (Install-WingetFallbackUrl -App $App) { return }
    }

    if ($exitCode -eq 1978335217 -or $exitCode -eq -1978335217) {
        Write-Host ("Installer returned exit code {0}: {1}" -f $exitCode, $App.Name) -ForegroundColor Yellow
        Write-Host 'This is a Winget source error ("Failed when opening sources").' -ForegroundColor Yellow
        Write-Host 'Fix: open a new admin PowerShell and run "winget source reset --force", then "winget source update", then rerun.' -ForegroundColor Yellow
        Write-Host 'Also update App Installer: https://aka.ms/getwinget' -ForegroundColor Yellow
    } else {
        Write-Host ("Installer returned exit code {0}: {1}" -f $exitCode, $App.Name) -ForegroundColor Yellow
    }
    $script:failed.Add(("{0} (exit code {1})" -f $App.Name, $exitCode))
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

    $downloadUrl = ''
    if ($null -ne $Installer.Url) { $downloadUrl = ([string]$Installer.Url).Trim() }
    if ((-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) -and (-not [string]::IsNullOrWhiteSpace($downloadUrl))) {
        try {
            $parentDir = Split-Path -Parent $installerPath
            if (-not [string]::IsNullOrWhiteSpace($parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
            }
            Write-Host ("Downloading {0} ..." -f $Installer.Name) -ForegroundColor Cyan
            Write-Host ("  From: {0}" -f $downloadUrl) -ForegroundColor DarkGray
            Write-Host ("  To: {0}" -f $installerPath) -ForegroundColor DarkGray
            $dlParams = @{ Uri = $downloadUrl; OutFile = $installerPath; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -le 5) { $dlParams['UseBasicParsing'] = $true }
            Invoke-WebRequest @dlParams
            $dlInfo = Get-Item -LiteralPath $installerPath -ErrorAction Stop
            if ($dlInfo.Length -lt 1024) { throw ("Downloaded file is only {0} bytes." -f $dlInfo.Length) }
            Write-Host ("Downloaded: {0} ({1:N0} bytes)" -f $Installer.Name, $dlInfo.Length) -ForegroundColor Green
        } catch {
            Write-Host ("Download failed for {0}: {1}" -f $Installer.Name, $_.Exception.Message) -ForegroundColor Red
            $script:failed.Add(("{0} (download failed)" -f $Installer.Name))
            return
        }
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

function Show-PrinterList {
    $printers = @(Get-Printer -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($printers.Count -eq 0) {
        Write-Host 'No printers installed on this PC. / Aucune imprimante installee.' -ForegroundColor Yellow
        return @()
    }
    $defaultName = ''
    try {
        $def = Get-CimInstance -ClassName Win32_Printer -Filter 'Default = TRUE' -ErrorAction Stop
        if ($null -ne $def) { $defaultName = $def.Name }
    } catch {}
    Write-Host ''
    Write-Host 'INSTALLED PRINTERS / IMPRIMANTES INSTALLEES :' -ForegroundColor Cyan
    for ($i = 0; $i -lt $printers.Count; $i++) {
        $tag = ''
        if ($printers[$i].Name -eq $defaultName) { $tag = ' [DEFAULT / DEFAUT]' }
        Write-Host (" {0,2}. {1}{2}" -f ($i + 1), $printers[$i].Name, $tag)
        Write-Host ("     Driver: {0} | Port: {1} | Status: {2}" -f $printers[$i].DriverName, $printers[$i].PortName, $printers[$i].PrinterStatus)
    }
    return $printers
}

function Rename-ChosenPrinter {
    if (-not (Get-Command Rename-Printer -ErrorAction SilentlyContinue)) {
        Write-Host 'Rename-Printer is not available on this Windows edition.' -ForegroundColor Red
        $script:failed.Add('Printer rename skipped: Rename-Printer unavailable')
        return
    }
    $printers = Show-PrinterList
    if ($printers.Count -eq 0) { return }
    Write-Host '  0. Cancel / Annuler'
    $choice = ((Read-Host 'Printer number to rename / Numero a renommer') | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '0') {
        Write-Host 'Rename cancelled. / Annule.' -ForegroundColor DarkYellow
        return
    }
    if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $printers.Count) {
        Write-Host 'Invalid printer selection.' -ForegroundColor Yellow
        $script:failed.Add('Printer rename skipped: invalid selection')
        return
    }
    $oldName = $printers[[int]$choice - 1].Name
    $newName = ((Read-Host ("New name for '{0}' (blank to cancel)" -f $oldName)) | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host 'Rename cancelled.' -ForegroundColor DarkYellow
        return
    }
    if ($newName -ieq $oldName) {
        Write-Host 'The new name is the same; no change needed.' -ForegroundColor DarkYellow
        return
    }
    if ($null -ne (Get-Printer -Name $newName -ErrorAction SilentlyContinue)) {
        Write-Host ("A printer named '{0}' already exists." -f $newName) -ForegroundColor Yellow
        $script:failed.Add('Printer rename skipped: target name already exists')
        return
    }
    try {
        Rename-Printer -Name $oldName -NewName $newName -ErrorAction Stop
        Write-Host ("Renamed printer '{0}' to '{1}'." -f $oldName, $newName) -ForegroundColor Green
    } catch {
        Write-Host ("Could not rename the printer: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $script:failed.Add('Printer rename failed')
    }
}

function Get-UserGroupNames {
    param([Parameter(Mandatory = $true)]$User)
    $groups = @()
    try {
        foreach ($g in @(Get-LocalGroup -ErrorAction Stop)) {
            try {
                $hit = @(Get-LocalGroupMember -Group $g.Name -ErrorAction Stop | Where-Object { $null -ne $_.SID -and ($_.SID.Value -eq $User.SID.Value) })
                if ($hit.Count -gt 0) { $groups += $g.Name }
            } catch {}
        }
    } catch {}
    return $groups
}

function Show-LocalUserList {
    try {
        $users = @(Get-LocalUser -ErrorAction Stop | Sort-Object Name)
    } catch {
        Write-Host ("Could not list local users: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return @()
    }
    if ($users.Count -eq 0) {
        Write-Host 'No local users found. / Aucun utilisateur local.' -ForegroundColor Yellow
        return @()
    }
    Write-Host ''
    Write-Host 'LOCAL USERS / UTILISATEURS LOCAUX :' -ForegroundColor Cyan
    foreach ($u in $users) {
        $state = if ($u.Enabled) { 'Enabled/Active' } else { 'Disabled/Desactive' }
        $groups = Get-UserGroupNames -User $u
        $memberOf = if ($groups.Count -gt 0) { $groups -join ', ' } else { '(no groups)' }
        Write-Host (" {0,2}. {1} [{2}]" -f (@($users).IndexOf($u) + 1), $u.Name, $state)
        Write-Host ("     Member of / Membre de : {0}" -f $memberOf) -ForegroundColor DarkGray
    }
    return $users
}

function Select-LocalUserByNumber {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Users,
        [string]$Prompt = 'User number / Numero (0 = cancel)'
    )
    if ($Users.Count -eq 0) { return $null }
    Write-Host '  0. Cancel / Annuler'
    $choice = ((Read-Host $Prompt) | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '0') {
        Write-Host 'Cancelled. / Annule.' -ForegroundColor DarkYellow
        return $null
    }
    if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $Users.Count) {
        Write-Host 'Invalid user selection.' -ForegroundColor Yellow
        $script:failed.Add('User action skipped: invalid selection')
        return $null
    }
    return $Users[[int]$choice - 1]
}

function Rename-ChosenLocalUser {
    $users = Show-LocalUserList
    if ($users.Count -eq 0) { return }
    $account = Select-LocalUserByNumber -Users $users -Prompt 'User number to rename / Numero a renommer (0 = cancel)'
    if ($null -eq $account) { return }
    $newName = ((Read-Host ("New name for '{0}' (1-20 chars, blank to cancel)" -f $account.Name)) | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host 'Rename cancelled.' -ForegroundColor DarkYellow
        return
    }
    if ($newName.Length -gt 20) {
        Write-Host 'The local account name must be 20 characters or fewer.' -ForegroundColor Yellow
        $script:failed.Add('User rename skipped: name too long')
        return
    }
    foreach ($character in '"/\[]:;|=,+*?<>'.ToCharArray()) {
        if ($newName.Contains([string]$character)) {
            Write-Host ('The account name contains an invalid character: {0}' -f $character) -ForegroundColor Yellow
            $script:failed.Add('User rename skipped: invalid characters')
            return
        }
    }
    try {
        $allLocalUsers = @(Get-LocalUser -ErrorAction Stop)
    } catch {
        Write-Host ("Could not list local users: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return
    }
    $duplicate = $allLocalUsers | Where-Object { $_.Name -ieq $newName -and $_.SID.Value -ne $account.SID.Value } | Select-Object -First 1
    if ($duplicate) {
        Write-Host ("A local account named '{0}' already exists." -f $newName) -ForegroundColor Yellow
        $script:failed.Add('User rename skipped: target name already exists')
        return
    }
    if ($account.Name -ieq $newName) {
        Write-Host 'The new name is the same as the current name; no change needed.' -ForegroundColor DarkYellow
        return
    }
    try {
        Rename-LocalUser -Name $account.Name -NewName $newName -ErrorAction Stop
        try {
            Set-LocalUser -Name $newName -FullName $newName -ErrorAction Stop
        } catch {
            Write-Host 'The account was renamed, but Windows did not accept the display-name update.' -ForegroundColor Yellow
        }
        Write-Host ("Renamed local account '{0}' to '{1}'. Sign out or restart to see the new name everywhere." -f $account.Name, $newName) -ForegroundColor Green
        Write-Host 'The existing user profile folder was left unchanged.' -ForegroundColor Yellow
    } catch {
        Write-Host ("Could not rename the local account: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $script:failed.Add('Local user account rename failed')
    }
}

function Set-ChosenLocalUserPassword {
    $users = Show-LocalUserList
    if ($users.Count -eq 0) { return }
    $account = Select-LocalUserByNumber -Users $users -Prompt 'User number for password change / Numero (0 = cancel)'
    if ($null -eq $account) { return }
    Write-Host 'Password input is hidden. Minimum 8 characters. / Saisie masquee. 8 caracteres minimum.' -ForegroundColor Yellow
    $securePassword = Read-Host ("Enter new password for '{0}' (blank to cancel)" -f $account.Name) -AsSecureString
    if ($null -eq $securePassword -or $securePassword.Length -eq 0) {
        Write-Host 'Password change cancelled.' -ForegroundColor DarkYellow
        return
    }
    $confirmPassword = Read-Host 'Confirm new password / Confirmez' -AsSecureString
    if ($null -eq $confirmPassword -or $confirmPassword.Length -eq 0) {
        Write-Host 'Password change cancelled (confirmation was empty).' -ForegroundColor DarkYellow
        return
    }
    $plainFirst = [System.Net.NetworkCredential]::new('', $securePassword).Password
    $plainConfirm = [System.Net.NetworkCredential]::new('', $confirmPassword).Password
    try {
        if ($plainFirst -cne $plainConfirm) {
            Write-Host 'Passwords do not match. Nothing was changed. / Mots de passe differents.' -ForegroundColor Yellow
            $script:failed.Add('User password change skipped: passwords did not match')
            return
        }
        if ($plainFirst.Length -lt 8) {
            Write-Host 'Password must be at least 8 characters. Nothing was changed. / 8 caracteres minimum.' -ForegroundColor Yellow
            $script:failed.Add('User password change skipped: password too short')
            return
        }
    } finally {
        $plainFirst = $null
        $plainConfirm = $null
    }
    try {
        Set-LocalUser -Name $account.Name -Password $securePassword -ErrorAction Stop
        Write-Host ("Password changed for '{0}'." -f $account.Name) -ForegroundColor Green
    } catch {
        Write-Host ("Could not change the password: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host 'Windows password complexity policy may have rejected it.' -ForegroundColor Yellow
        $script:failed.Add('Local user password change failed')
    } finally {
        if (Get-Variable -Name securePassword -Scope Local -ErrorAction SilentlyContinue) { $securePassword = $null }
        if (Get-Variable -Name confirmPassword -Scope Local -ErrorAction SilentlyContinue) { $confirmPassword = $null }
    }
}

function Edit-ChosenLocalUserGroups {
    $users = Show-LocalUserList
    if ($users.Count -eq 0) { return }
    $account = Select-LocalUserByNumber -Users $users -Prompt 'User number for group change / Numero (0 = cancel)'
    if ($null -eq $account) { return }
    # Freeze group membership for the sole remaining enabled administrator:
    # with only one active admin, any permission change is refused outright.
    try {
        $adminGroupObj = @(Get-LocalGroup -ErrorAction Stop | Where-Object { $_.SID.Value -match '-544$' } | Select-Object -First 1)
        if ($adminGroupObj.Count -ge 1) {
            $enabledAdmins = @(Get-LocalGroupMember -Group $adminGroupObj[0].Name -ErrorAction SilentlyContinue | Where-Object {
                $_.ObjectClass -eq 'User' -and
                (($tmpUser = Get-LocalUser -SID $_.SID -ErrorAction SilentlyContinue) -and $tmpUser.Enabled)
            })
            if (($enabledAdmins.Count -eq 1) -and ($enabledAdmins[0].SID.Value -eq $account.SID.Value)) {
                Write-Host ("LOCKED: '{0}' is the only enabled administrator on this PC." -f $account.Name) -ForegroundColor Red
                Write-Host 'Group membership is frozen for this account. Create or enable another admin first.' -ForegroundColor Red
                Write-Host 'Verrouille : dernier administrateur actif. Adhésions bloquées.' -ForegroundColor Red
                $script:failed.Add('Group change blocked: last enabled administrator is protected')
                return
            }
        }
    } catch {}
    try {
        $allGroups = @(Get-LocalGroup -ErrorAction Stop | Sort-Object Name)
    } catch {
        Write-Host ("Could not list local groups: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return
    }
    $current = @(Get-UserGroupNames -User $account)
    Write-Host ("'{0}' is a member of / est membre de : {1}" -f $account.Name, $(if ($current.Count -gt 0) { $current -join ', ' } else { '(no groups)' })) -ForegroundColor Cyan
    $mode = ((Read-Host '[A]dd to a group / Ajouter, [R]emove from a group / Retirer (0 = cancel)') | ForEach-Object { "$_".Trim().ToLowerInvariant() })
    if ([string]::IsNullOrWhiteSpace($mode) -or $mode -in @('0', 'q', 'quit', 'exit')) {
        Write-Host 'Group change cancelled.' -ForegroundColor DarkYellow
        return
    }
    if ($mode -in @('a', 'add', 'ajouter')) {
        Write-Host ''
        Write-Host 'LOCAL GROUPS / GROUPES LOCAUX :' -ForegroundColor Cyan
        for ($i = 0; $i -lt $allGroups.Count; $i++) {
            $tag = if ($current -icontains $allGroups[$i].Name) { ' [already member]' } else { '' }
            Write-Host (" {0,2}. {1}{2}" -f ($i + 1), $allGroups[$i].Name, $tag)
        }
        Write-Host '  0. Cancel / Annuler'
        $gChoice = ((Read-Host 'Group number / Numero') | ForEach-Object { "$_".Trim() })
        if ([string]::IsNullOrWhiteSpace($gChoice) -or $gChoice -eq '0') {
            Write-Host 'Group change cancelled.' -ForegroundColor DarkYellow
            return
        }
        if ($gChoice -notmatch '^\d+$' -or [int]$gChoice -lt 1 -or [int]$gChoice -gt $allGroups.Count) {
            Write-Host 'Invalid group selection.' -ForegroundColor Yellow
            $script:failed.Add('Group change skipped: invalid selection')
            return
        }
        $group = $allGroups[[int]$gChoice - 1]
        if ($current -icontains $group.Name) {
            Write-Host ("'{0}' is already a member of '{1}'." -f $account.Name, $group.Name) -ForegroundColor DarkYellow
            return
        }
        try {
            Add-LocalGroupMember -Group $group.Name -Member $account.Name -ErrorAction Stop
            Write-Host ("Added '{0}' to '{1}'." -f $account.Name, $group.Name) -ForegroundColor Green
        } catch {
            Write-Host ("Could not add to the group: {0}" -f $_.Exception.Message) -ForegroundColor Red
            $script:failed.Add('Group membership change failed')
        }
    } elseif ($mode -in @('r', 'remove', 'retirer', 'retire')) {
        if ($current.Count -eq 0) {
            Write-Host ("'{0}' is not a member of any group." -f $account.Name) -ForegroundColor DarkYellow
            return
        }
        Write-Host 'Current groups:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $current.Count; $i++) { Write-Host (" {0,2}. {1}" -f ($i + 1), $current[$i]) }
        Write-Host '  0. Cancel / Annuler'
        $gChoice = ((Read-Host 'Group number to remove from / Numero') | ForEach-Object { "$_".Trim() })
        if ([string]::IsNullOrWhiteSpace($gChoice) -or $gChoice -eq '0') {
            Write-Host 'Group change cancelled.' -ForegroundColor DarkYellow
            return
        }
        if ($gChoice -notmatch '^\d+$' -or [int]$gChoice -lt 1 -or [int]$gChoice -gt $current.Count) {
            Write-Host 'Invalid group selection.' -ForegroundColor Yellow
            $script:failed.Add('Group change skipped: invalid selection')
            return
        }
        $groupName = $current[[int]$gChoice - 1]
        try {
            Remove-LocalGroupMember -Group $groupName -Member $account.Name -ErrorAction Stop
            Write-Host ("Removed '{0}' from '{1}'." -f $account.Name, $groupName) -ForegroundColor Green
        } catch {
            Write-Host ("Could not remove from the group: {0}" -f $_.Exception.Message) -ForegroundColor Red
            $script:failed.Add('Group membership change failed')
        }
    } else {
        Write-Host 'Type A to add or R to remove. Nothing was changed.' -ForegroundColor Yellow
    }
}

function Show-UserMenu {
    if (-not (Get-Command Get-LocalUser -ErrorAction SilentlyContinue)) {
        Write-Host 'Local user cmdlets are not available on this Windows edition.' -ForegroundColor Red
        $script:failed.Add('Users menu skipped: LocalUser cmdlets unavailable')
        return
    }
    while ($true) {
        Write-Host ''
        Write-Host 'USERS / UTILISATEURS :' -ForegroundColor Cyan
        Write-Host '  1. List local users (details + member of)'
        Write-Host '  2. Rename a user'
        Write-Host "  3. Change a user's password"
        Write-Host "  4. Change a user's groups (member of)"
        Write-Host '  0. Back to main menu / Retour'
        $sub = ((Read-Host 'Users option') | ForEach-Object { "$_".Trim() })
        if ($sub -match '^(?i:0|q|quit|exit|b|back)$' -or [string]::IsNullOrWhiteSpace($sub)) {
            return
        }
        switch ($sub) {
            '1' { [void](Show-LocalUserList); Read-Host 'Press Enter to continue / Entree pour continuer' | Out-Null }
            '2' { Rename-ChosenLocalUser }
            '3' { Set-ChosenLocalUserPassword }
            '4' { Edit-ChosenLocalUserGroups }
            default {
                Write-Host 'Invalid users option. Use 1, 2, 3, 4, or 0.' -ForegroundColor Yellow
            }
        }
    }
}

function Show-PrinterMenu {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not (Get-Command Get-Printer -ErrorAction SilentlyContinue)) {
        Write-Host 'Printer cmdlets (PrintManagement) are not available on this Windows edition.' -ForegroundColor Red
        $script:failed.Add('Printer menu skipped: PrintManagement unavailable')
        return
    }
    while ($true) {
        Write-Host ''
        Write-Host 'PRINTERS / IMPRIMANTES :' -ForegroundColor Cyan
        Write-Host '  1. Install a printer (TCP/IP: manufacturer, IP, name)'
        Write-Host '  2. List installed printers'
        Write-Host '  3. Rename a printer'
        Write-Host '  0. Back to main menu / Retour'
        $sub = ((Read-Host 'Printer option') | ForEach-Object { "$_".Trim() })
        if ($sub -match '^(?i:0|q|quit|exit|b|back)$' -or [string]::IsNullOrWhiteSpace($sub)) {
            return
        }
        switch ($sub) {
            '1' { Install-NetworkPrinter -Config $Config }
            '2' { [void](Show-PrinterList); Read-Host 'Press Enter to continue / Entree pour continuer' | Out-Null }
            '3' { Rename-ChosenPrinter }
            default {
                Write-Host 'Invalid printer option. Use 1, 2, 3, or 0.' -ForegroundColor Yellow
            }
        }
    }
}

function Install-NetworkPrinter {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not (Get-Command Add-Printer -ErrorAction SilentlyContinue)) {
        Write-Host 'Printer cmdlets (PrintManagement) are not available on this Windows edition.' -ForegroundColor Red
        $script:failed.Add('Printer install skipped: PrintManagement unavailable')
        return
    }

    $presets = @(@($Config.PrinterDrivers) | Where-Object { $null -ne $_ -and $_.Enabled -ne $false -and -not [string]::IsNullOrWhiteSpace([string]$_.Make) })
    if ($presets.Count -eq 0) {
        Write-Host 'No printer driver presets are enabled in Software.json (PrinterDrivers).' -ForegroundColor Yellow
        $script:failed.Add('Printer install skipped: no PrinterDrivers presets')
        return
    }

    Write-Host ''
    Write-Host 'PRINTER MANUFACTURER / FABRICANT :' -ForegroundColor Cyan
    for ($i = 0; $i -lt $presets.Count; $i++) {
        Write-Host (" {0,2}. {1}" -f ($i + 1), $presets[$i].Make)
    }
    Write-Host '  0. Cancel / Annuler'
    $makeChoice = ((Read-Host 'Manufacturer number / Numero') | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($makeChoice) -or $makeChoice -eq '0') {
        Write-Host 'Printer install cancelled. / Annule.' -ForegroundColor DarkYellow
        return
    }
    if ($makeChoice -notmatch '^\d+$' -or [int]$makeChoice -lt 1 -or [int]$makeChoice -gt $presets.Count) {
        Write-Host 'Invalid manufacturer selection.' -ForegroundColor Yellow
        $script:failed.Add('Printer install skipped: invalid manufacturer')
        return
    }
    $preset = $presets[[int]$makeChoice - 1]
    Write-Host ("Selected: {0}" -f $preset.Make) -ForegroundColor Green

    # --- Driver files: local folder/INF, or download via Url, or ask for a path. ---
    $driverDir = ''
    $presetPath = [string]$preset.Path
    if (-not [string]::IsNullOrWhiteSpace($presetPath)) {
        if ([System.IO.Path]::IsPathRooted($presetPath)) { $driverDir = $presetPath }
        else { $driverDir = Join-Path $script:scriptRoot $presetPath }
    }
    $presetUrl = ''
    if ($null -ne $preset.Url) { $presetUrl = ([string]$preset.Url).Trim() }
    $infPath = ''
    if ((-not [string]::IsNullOrWhiteSpace($driverDir)) -and (Test-Path -LiteralPath $driverDir)) {
        if ((Test-Path -LiteralPath $driverDir -PathType Leaf) -and $driverDir.ToLowerInvariant().EndsWith('.inf')) {
            $infPath = $driverDir
        } else {
            $infs = @(Get-ChildItem -LiteralPath $driverDir -Filter '*.inf' -File -ErrorAction SilentlyContinue)
            if ($infs.Count -eq 1) { $infPath = $infs[0].FullName }
            elseif ($infs.Count -gt 1) {
                Write-Host 'Several INF files found, pick one:' -ForegroundColor Cyan
                for ($i = 0; $i -lt $infs.Count; $i++) { Write-Host (" {0,2}. {1}" -f ($i + 1), $infs[$i].Name) }
                $infChoice = ((Read-Host 'INF number') | ForEach-Object { "$_".Trim() })
                if ($infChoice -match '^\d+$' -and [int]$infChoice -ge 1 -and [int]$infChoice -le $infs.Count) {
                    $infPath = $infs[[int]$infChoice - 1].FullName
                }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($infPath) -and (-not [string]::IsNullOrWhiteSpace($presetUrl))) {
        try {
            if ([string]::IsNullOrWhiteSpace($driverDir)) { $driverDir = Join-Path $script:scriptRoot 'Drivers' }
            New-Item -ItemType Directory -Path $driverDir -Force -ErrorAction Stop | Out-Null
            $uri = [System.Uri]$presetUrl
            $dlName = [System.IO.Path]::GetFileName($uri.LocalPath)
            if ([string]::IsNullOrWhiteSpace($dlName)) { $dlName = 'driver_package.zip' }
            $dlPath = Join-Path $driverDir $dlName
            Write-Host ("Downloading driver from {0} ..." -f $presetUrl) -ForegroundColor Cyan
            $dlParams = @{ Uri = $presetUrl; OutFile = $dlPath; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -le 5) { $dlParams['UseBasicParsing'] = $true }
            Invoke-WebRequest @dlParams
            if ($dlPath.ToLowerInvariant().EndsWith('.zip')) {
                Expand-Archive -LiteralPath $dlPath -DestinationPath $driverDir -Force -ErrorAction Stop
            }
            $infs = @(Get-ChildItem -LiteralPath $driverDir -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue)
            if ($infs.Count -ge 1) { $infPath = $infs[0].FullName }
        } catch {
            Write-Host ("Driver download failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }
    if ([string]::IsNullOrWhiteSpace($infPath)) {
        Write-Host ("Driver files for '{0}' were not found." -f $preset.Make) -ForegroundColor Yellow
        Write-Host 'Download the universal driver from the vendor site (e.g. Konica Minolta Universal PCL6),' -ForegroundColor Yellow
        Write-Host 'extract it, and point Software.json PrinterDrivers Path at the folder (or fill Url).' -ForegroundColor Yellow
        $manualInf = ((Read-Host 'Or enter a full path to an .inf file now (blank to cancel)') | ForEach-Object { "$_".Trim() })
        if ([string]::IsNullOrWhiteSpace($manualInf) -or -not (Test-Path -LiteralPath $manualInf -PathType Leaf)) {
            Write-Host 'Printer install cancelled (no driver INF).' -ForegroundColor DarkYellow
            $script:failed.Add('Printer install skipped: no driver INF')
            return
        }
        $infPath = $manualInf
    }

    # --- Import the driver, auto-detecting its real name (works in EN and FR Windows). ---
    $driversBefore = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $skipImport = $false
    if ((-not [string]::IsNullOrWhiteSpace([string]$preset.DriverHint))) {
        $alreadyThere = @($driversBefore | Where-Object { "$_" -ieq ([string]$preset.DriverHint) })
        if ($alreadyThere.Count -ge 1) {
            Write-Host ("Driver already installed, reusing: '{0}'" -f $alreadyThere[0]) -ForegroundColor Green
            $driverName = $alreadyThere[0]
            $skipImport = $true
        }
    }
    if (-not $skipImport) {
    Write-Host ("Importing driver from {0} ..." -f $infPath) -ForegroundColor Cyan

    # Stage 1: Use pnputil to stage the driver package into the Windows driver store.
    # For V4 print drivers (ClassVer=4.0), pnputil /install often fails to auto-register
    # the printer driver even though the package IS staged successfully. We treat
    # staging as a separate step and don't give up on a non-zero exit code.
    $pnpOut = & pnputil.exe /add-driver "$infPath" /install 2>&1 | Out-String
    $pnpExit = $LASTEXITCODE
    # Accept success in any locale: English "successfully", French "correctement"/"existe deja", etc.
    $pnpOk = ($pnpExit -eq 0) -or ($pnpOut -match '(?i)successfully|correctement|already exists|existe d')
    $driversAfter = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $newDrivers = @($driversAfter | Where-Object { $_ -notin $driversBefore })
    $driverName = ''

    # Stage 2: If pnputil did not auto-register the driver, try Add-PrinterDriver (V4 method).
    # This is the proper way to install V4 class printer drivers: stage first, then register.
    if ($newDrivers.Count -eq 0) {
        $fallbackName = [string]$preset.DriverHint
        if (-not [string]::IsNullOrWhiteSpace($fallbackName)) {
            # Check if it was staged but not yet registered as a printer driver
            if (-not $pnpOk) {
                Write-Host $pnpOut -ForegroundColor DarkGray
            }
            Write-Host ("Registering V4 driver via Add-PrinterDriver: '{0}' ..." -f $fallbackName) -ForegroundColor Yellow
            try {
                # NOTE: Add-PrinterDriver has no -InfPath parameter; -Name alone
                # registers a driver package already staged by pnputil.
                Add-PrinterDriver -Name $fallbackName -ErrorAction Stop
                Write-Host ("Add-PrinterDriver succeeded for '{0}'." -f $fallbackName) -ForegroundColor Green
            } catch {
                Write-Host ("Add-PrinterDriver failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
            }
            $driversAfter = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $newDrivers = @($driversAfter | Where-Object { $_ -notin $driversBefore })
        }
    }

    # Stage 3: If still not registered, try the legacy printui.dll method (V3 drivers).
    if ($newDrivers.Count -eq 0) {
        $fallbackName = [string]$preset.DriverHint
        if (-not [string]::IsNullOrWhiteSpace($fallbackName)) {
            Write-Host 'V4 registration did not work, trying printui fallback (V3 method)...' -ForegroundColor Yellow
            $printuiOut = & rundll32.exe printui.dll,PrintUIEntry /ia /f "$infPath" /m "$fallbackName" 2>&1 | Out-String
            Start-Sleep -Seconds 3   # printui is async, give it a moment
            $driversAfter = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $newDrivers = @($driversAfter | Where-Object { $_ -notin $driversBefore })
            if (($newDrivers.Count -eq 0) -and ($driversAfter -inotcontains $fallbackName)) {
                Write-Host $printuiOut -ForegroundColor DarkGray
            }
        }
    }

    # --- Pick the driver name from whatever got registered. ---
    if ($newDrivers.Count -eq 1) {
        $driverName = $newDrivers[0]
    } elseif ($newDrivers.Count -gt 1) {
        Write-Host 'Several drivers were imported, pick one:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $newDrivers.Count; $i++) { Write-Host (" {0,2}. {1}" -f ($i + 1), $newDrivers[$i]) }
        $drvChoice = ((Read-Host 'Driver number') | ForEach-Object { "$_".Trim() })
        if ($drvChoice -match '^\d+$' -and [int]$drvChoice -ge 1 -and [int]$drvChoice -le $newDrivers.Count) {
            $driverName = $newDrivers[[int]$drvChoice - 1]
        }
    }
    # Check by DriverHint even if newDrivers is empty (driver may have been there under a different snapshot)
    if ([string]::IsNullOrWhiteSpace($driverName) -and (-not [string]::IsNullOrWhiteSpace([string]$preset.DriverHint))) {
        $hint = [string]$preset.DriverHint
        $match = @($driversAfter | Where-Object { "$_" -ieq $hint })
        if ($match.Count -ge 1) { $driverName = $match[0] }
    }
    if ([string]::IsNullOrWhiteSpace($driverName)) {
        Write-Host 'pnputil output (for diagnosis):' -ForegroundColor Yellow
        Write-Host $pnpOut -ForegroundColor DarkGray
        Write-Host 'The driver package did not register on this Windows.' -ForegroundColor Red
        Write-Host 'Tip: You may need to download a newer driver from the manufacturer website.' -ForegroundColor Yellow
        @($driversAfter | Select-Object -Last 10) | ForEach-Object { Write-Host (" - {0}" -f $_) }
        while ([string]::IsNullOrWhiteSpace($driverName)) {
            $typedName = ((Read-Host 'Type the exact driver name from the list above (blank to cancel)') | ForEach-Object { "$_".Trim() })
            if ([string]::IsNullOrWhiteSpace($typedName)) { break }
            $nameMatch = @($driversAfter | Where-Object { "$_" -ieq $typedName })
            if ($nameMatch.Count -ge 1) {
                $driverName = $nameMatch[0]
            } else {
                Write-Host ("No installed driver named '{0}'. Pick one from the list." -f $typedName) -ForegroundColor Yellow
                $driversAfter = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($driverName)) {
        Write-Host 'Printer install cancelled (no driver selected).' -ForegroundColor DarkYellow
        $script:failed.Add('Printer install skipped: no driver name')
        return
    }
    Write-Host ("Driver ready: '{0}'" -f $driverName) -ForegroundColor Green
    } # end if (-not $skipImport)

    # --- TCP/IP port + printer on this local PC. ---
    $ipAddress = ((Read-Host 'Printer IP address or hostname / Adresse IP ou nom') | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        Write-Host 'Printer install cancelled (no IP/hostname).' -ForegroundColor DarkYellow
        $script:failed.Add('Printer install skipped: no address')
        return
    }
    $portInput = ((Read-Host 'Port (Enter = 9100 RAW)') | ForEach-Object { "$_".Trim() })
    $portNumber = 9100
    if (-not [string]::IsNullOrWhiteSpace($portInput)) {
        if ($portInput -notmatch '^\d+$' -or [int]$portInput -lt 1 -or [int]$portInput -gt 65535) {
            Write-Host 'Invalid port, using 9100.' -ForegroundColor Yellow
        } else {
            $portNumber = [int]$portInput
        }
    }
    $defaultName = ("{0} {1}" -f $preset.Make, $ipAddress)
    $printerName = ((Read-Host ("Printer name on this PC (Enter = '{0}')" -f $defaultName)) | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($printerName)) { $printerName = $defaultName }

    $portName = "TCP_$ipAddress"
    try {
        $existingPort = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue
        if ($null -eq $existingPort) {
            Add-PrinterPort -Name $portName -PrinterHostAddress $ipAddress -PortNumber $portNumber -ErrorAction Stop
            Write-Host ("Created TCP/IP port '{0}' -> {1}:{2}." -f $portName, $ipAddress, $portNumber) -ForegroundColor Green
        } else {
            Write-Host ("Reusing existing port '{0}'." -f $portName) -ForegroundColor DarkGray
        }
        $existingPrinter = Get-Printer -Name $printerName -ErrorAction SilentlyContinue
        if ($null -ne $existingPrinter) {
            $overwrite = ((Read-Host ("A printer named '{0}' already exists. Overwrite? [y/N]" -f $printerName)) | ForEach-Object { "$_".Trim().ToLowerInvariant() })
            if ($overwrite -notin @('y', 'yes', 'o', 'oui')) {
                Write-Host 'Kept the existing printer unchanged.' -ForegroundColor DarkYellow
                return
            }
            Remove-Printer -Name $printerName -ErrorAction Stop
        }
        Add-Printer -Name $printerName -DriverName $driverName -PortName $portName -ErrorAction Stop
        Write-Host ("Printer '{0}' installed on port '{1}' with driver '{2}'." -f $printerName, $portName, $driverName) -ForegroundColor Green
    } catch {
        Write-Host ("Could not install the printer: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $script:failed.Add('Printer install failed')
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
            Detail = ("Winget ID: {0}" -f [string]$app.Id) + $(if (($null -ne $app.FallbackUrl) -and (-not [string]::IsNullOrWhiteSpace([string]$app.FallbackUrl))) { ' [+direct-download fallback]' } else { '' })
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
            $hasUrl = ($null -ne $installer.Url) -and (-not [string]::IsNullOrWhiteSpace([string]$installer.Url))
            if ($hasUrl) {
                $detail = "$detail [WILL DOWNLOAD]"
            } else {
                $detail = "$detail [FILE NOT FOUND]"
            }
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
    Write-Host 'SOFTWARE LIST - enter numbers separated by commas (example: 1,3,5).' -ForegroundColor Cyan
    Write-Host 'Enter A to select all enabled items, or 0 to skip software installation.' -ForegroundColor Cyan
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $number = $index + 1
        $kindLabel = if ($Items[$index].Kind -eq 'winget') { 'Winget' } else { 'Local' }
        Write-Host (" {0,2}. [{1}] {2} - {3}" -f $number, $kindLabel, $Items[$index].Name, $Items[$index].Detail)
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
    $configPath = Join-Path $scriptRoot 'Software.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Software.json was not found at $configPath. Restore the configuration file and run the setup again."
    }
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    } catch {
        throw "Could not parse Software.json. Check that it contains valid JSON. Details: $($_.Exception.Message)"
    }

    while ($true) {
    $script:failed.Clear()
    $script:wingetRetriedForSource = $false
    Clear-Host
    Write-Host '========================================================' -ForegroundColor Cyan
    Write-Host '              WINDOWS AUTOMATIC SETUP' -ForegroundColor Cyan
    Write-Host '========================================================' -ForegroundColor Cyan
    Write-Host ("Log file: {0}" -f $logFile)
    Write-Host ''

    Write-Host 'Choose what you want to do: / Choisissez :' -ForegroundColor White
    Write-Host '  1. Enable built-in Administrator and set a new password (you will enter it)'
    Write-Host '  2. Rename the currently signed-in local user account'
    Write-Host '  3. Choose software to install from a numbered list'
    Write-Host '  4. Printers (install / list / rename)'
    Write-Host '  5. Users (list / rename / password / groups)'
    Write-Host '  6. Run all options (1+2+3+4+5)'
    Write-Host '  0. Exit / Quitter'
    Write-Host ''
    Write-Host 'You can choose more than one option, for example: 1,3'

    $mainChoice = ((Read-Host 'Enter option number(s)') | ForEach-Object { "$_".Trim() })
    if ($mainChoice -match '^(?i:0|q|quit|exit)$') {
        Write-Host 'Exiting without further changes. / Fin.' -ForegroundColor DarkYellow
        break
    }
    if ([string]::IsNullOrWhiteSpace($mainChoice)) {
        continue
    }

    if ($mainChoice -eq '6') {
        $actions = @('1', '2', '3', '4', '5')
    } else {
        $actions = @($mainChoice -split '[,;\s]+' | Select-Object -Unique)
        $validActions = @('1', '2', '3', '4', '5')
        $invalidActions = @($actions | Where-Object { $_ -notin $validActions })
        if ($invalidActions.Count -gt 0) {
            Write-Host 'Invalid main-menu selection. Use 1, 2, 3, 4, 5, 6, or 0. Example: 1,3' -ForegroundColor Yellow
            Read-Host 'Press Enter for main menu / Entree = menu principal'
            continue
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
                Write-Host 'Checking Winget sources...' -ForegroundColor Cyan
                [void](Repair-WingetSource)
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

    if ($actions -contains '4') { Show-PrinterMenu -Config $config }
    if ($actions -contains '5') { Show-UserMenu }

    Write-Host ''
    Write-Host '--------------------------------------------------------' -ForegroundColor Cyan
    Write-Host 'STEP FINISHED / ETAPE TERMINEE' -ForegroundColor Green
    Write-Host ("Log file: {0}" -f $logFile)
    if ($script:failed.Count -gt 0) {
        Write-Host 'Some actions or applications may not have completed:' -ForegroundColor Yellow
        foreach ($item in $script:failed) { Write-Host (" - {0}" -f $item) -ForegroundColor Yellow }
        Write-Host 'Review the log and installer exit codes above.'
    } else {
        Write-Host 'No errors were recorded for actions/software that were attempted.' -ForegroundColor Green
    }
    Write-Host 'A sign-out or restart may be needed for account-name changes and some installers.' -ForegroundColor Yellow
    Write-Host ''
    $next = ((Read-Host 'Press Enter for HOME menu, or type 0 to exit / Entree = menu, 0 = quitter') | ForEach-Object { "$_".Trim() })
    if ($next -match '^(?i:0|q|quit|exit)$') {
        Write-Host 'Exiting. / Fin.' -ForegroundColor DarkYellow
        break
    }
    } # end while(menu)
} catch {
    Write-Host ("SETUP ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Log file: {0}" -f $logFile)
    Read-Host 'Press Enter to close'
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
