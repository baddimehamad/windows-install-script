#Requires -Version 5.1
<#
.SYNOPSIS
    Core logic for Windows Automatic Setup.

.DESCRIPTION
    Every action lives here: software installation, printer setup, local users
    and the built-in Administrator. Nothing in this module prompts or writes to
    the console directly.

    Progress goes through a log sink registered with Set-SetupLogSink. Actions
    return a result object (see New-SetupResult) instead of mutating global
    state, so both the console front-end and the WPF front-end can share it.

    The module needs no external dependency: Windows PowerShell 5.1 and the
    .NET Framework that ships with Windows 10/11 are enough.
#>

$script:ModuleRoot = $PSScriptRoot
$script:LogSink = $null
$script:Winget = $null
$script:WingetChecked = $false
$script:WingetSourceChecked = $false
$script:WingetSourceHealthy = $true
$script:WingetRetriedForSource = $false

# --------------------------------------------------------------------------
# Infrastructure
# --------------------------------------------------------------------------

function Get-SetupRootPath {
    <# Returns the folder that holds Software.json, Installers and Drivers. #>
    return $script:ModuleRoot
}

function Set-SetupLogSink {
    <#
    .SYNOPSIS
        Registers the callback that receives progress messages.
    .PARAMETER Sink
        Scriptblock with two parameters: level and message. Called for every
        log line. Must not throw.
    #>
    param([scriptblock]$Sink)
    $script:LogSink = $Sink
}

function Clear-SetupLogSink {
    $script:LogSink = $null
}

function Write-SetupLog {
    <#
    .SYNOPSIS
        Sends one message to the registered sink.
    #>
    param(
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Detail', 'Task')]
        [string]$Level = 'Info',
        [AllowEmptyString()][string]$Message = ''
    )
    if ($null -eq $script:LogSink) { return }
    # [void]: a sink that returns a value must never pollute the action output.
    try { [void](& $script:LogSink $Level $Message) } catch { }
}

function New-SetupResult {
    <#
    .SYNOPSIS
        Builds the standard action result.
    .DESCRIPTION
        Success = the action did what was asked.
        Skipped = nothing was attempted on purpose (not an error).
    #>
    param(
        [string]$Name = '',
        [bool]$Success = $true,
        [bool]$Skipped = $false,
        [int]$ExitCode = 0,
        [bool]$RestartRequired = $false,
        [string]$Message = '',
        [hashtable]$Data = @{}
    )
    return [pscustomobject]@{
        Name            = $Name
        Success         = $Success
        Skipped         = $Skipped
        ExitCode        = $ExitCode
        RestartRequired = $RestartRequired
        Message         = $Message
        Data            = $Data
    }
}

# --------------------------------------------------------------------------
# Configuration and catalog
# --------------------------------------------------------------------------

function Get-SetupConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Software.json was not found at $Path. Restore the configuration file and run the setup again."
    }
    try {
        $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "Could not parse Software.json. Check that it contains valid JSON. Details: $($_.Exception.Message)"
    }
    return $config
}

function Get-SoftwareCatalog {
    <#
    .SYNOPSIS
        Returns the enabled software entries as display-ready items.
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($app in @($Config.Apps)) {
        if ($null -eq $app -or $app.Enabled -eq $false) { continue }
        if ([string]$app.Type -ne 'winget' -or [string]::IsNullOrWhiteSpace([string]$app.Id)) { continue }
        $hasFallback = ($null -ne $app.FallbackUrl) -and (-not [string]::IsNullOrWhiteSpace([string]$app.FallbackUrl))
        $detail = ("Winget ID: {0}" -f [string]$app.Id)
        if ($hasFallback) { $detail = $detail + ' [+direct-download fallback]' }
        [void]$items.Add([pscustomobject]@{
            Kind         = 'winget'
            Name         = [string]$app.Name
            Detail       = $detail
            Id           = [string]$app.Id
            Exists       = $true
            WillDownload = $false
            Item         = $app
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
            $fullPath = Join-Path $script:ModuleRoot $relativePath
            $detail = $relativePath
        }

        $exists = (-not [string]::IsNullOrWhiteSpace($fullPath)) -and (Test-Path -LiteralPath $fullPath -PathType Leaf)
        $hasUrl = ($null -ne $installer.Url) -and (-not [string]::IsNullOrWhiteSpace([string]$installer.Url))
        $willDownload = $false
        if (-not $exists) {
            if ($hasUrl) {
                $detail = "$detail [WILL DOWNLOAD]"
                $willDownload = $true
            } else {
                $detail = "$detail [FILE NOT FOUND]"
            }
        }
        [void]$items.Add([pscustomobject]@{
            Kind         = 'local'
            Name         = [string]$installer.Name
            Detail       = $detail
            Id           = [string]$installer.Path
            Exists       = $exists
            WillDownload = $willDownload
            Item         = $installer
        })
    }

    return $items.ToArray()
}

function Test-LocalAccountName {
    <#
    .SYNOPSIS
        Validates a Windows local account name.
    .OUTPUTS
        $null when the name is valid, otherwise a human readable reason.
    #>
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'The account name cannot be empty.'
    }
    if ($Name.Length -gt 20) {
        return 'The local account name must be 20 characters or fewer.'
    }
    foreach ($character in '"/\[]:;|=,+*?<>'.ToCharArray()) {
        if ($Name.Contains([string]$character)) {
            return ('The account name contains an invalid character: {0}' -f $character)
        }
    }
    return $null
}

# --------------------------------------------------------------------------
# Winget
# --------------------------------------------------------------------------

function Get-WingetCommand {
    # Cached lookup so a removed/renamed winget is detected once per module instance.
    if (-not $script:WingetChecked) {
        $script:Winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        $script:WingetChecked = $true
    }
    return $script:Winget
}

function Repair-SetupWingetSource {
    <#
    .SYNOPSIS
        Detects a corrupt winget source database and resets it once per run.
    .OUTPUTS
        $true when sources are usable.
    #>
    param([switch]$Force)

    $winget = Get-WingetCommand
    if ($null -eq $winget) { return $false }
    if ($script:WingetSourceChecked -and -not $Force) { return $script:WingetSourceHealthy }

    $script:WingetSourceChecked = $true
    $script:WingetSourceHealthy = $true
    try {
        $out = & $winget.Source source list 2>&1 | Out-String
        # EN: "Failed when opening sources" / FR: "ouverture des sources / echec ... source".
        $bad = ($LASTEXITCODE -ne 0) -or ($out -match '(?i)opening sources|ouverture.*sources?|[e\xe9]chec.*sources?|sources?.*reset|sources?.*r[e\xe9]initial')
        if (-not $bad) { return $true }

        Write-SetupLog -Level Warning -Message 'Winget sources look broken. Running: winget source reset --force ...'
        & $winget.Source source reset --force 2>&1 | Out-Null
        Write-SetupLog -Level Info -Message 'Updating Winget sources...'
        & $winget.Source source update 2>&1 | Out-Null

        $out2 = & $winget.Source source list 2>&1 | Out-String
        if (($LASTEXITCODE -eq 0) -and ($out2 -notmatch '(?i)opening sources|ouverture.*sources?|[e\xe9]chec.*sources?')) {
            Write-SetupLog -Level Success -Message 'Winget sources repaired.'
            return $true
        }
        Write-SetupLog -Level Warning -Message 'Winget sources still failing after reset. Installs may fail with source errors.'
        Write-SetupLog -Level Warning -Message 'Manual fix: run "winget source reset --force" then "winget source update" in a new admin PowerShell.'
        $script:WingetSourceHealthy = $false
        return $false
    } catch {
        $script:WingetSourceHealthy = $false
        return $false
    }
}

# --------------------------------------------------------------------------
# Software installation
# --------------------------------------------------------------------------

function Install-SetupFile {
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

function Install-SetupWingetFallback {
    <#
    .SYNOPSIS
        Installs the vendor's direct download for an app.
    .OUTPUTS
        A result object when a fallback is configured, otherwise $null.
    #>
    param([Parameter(Mandatory = $true)]$App)

    $fallbackUrl = ''
    if ($null -ne $App.FallbackUrl) { $fallbackUrl = ([string]$App.FallbackUrl).Trim() }
    if ([string]::IsNullOrWhiteSpace($fallbackUrl)) { return $null }

    try {
        $uri = [System.Uri]$fallbackUrl
        $fileName = [System.IO.Path]::GetFileName($uri.LocalPath)
        if ([string]::IsNullOrWhiteSpace($fileName) -or -not $fileName.Contains('.')) {
            $safe = ($App.Name -replace '[^\w\-]+', '_').Trim('_')
            $fileName = "$safe.exe"
        }
        $destDir = Join-Path $script:ModuleRoot 'Installers'
        New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
        $destPath = Join-Path $destDir $fileName
        if (-not (Test-Path -LiteralPath $destPath -PathType Leaf)) {
            Write-SetupLog -Level Info -Message ("Downloading fallback for {0} ..." -f $App.Name)
            $dlParams = @{ Uri = $fallbackUrl; OutFile = $destPath; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -le 5) { $dlParams['UseBasicParsing'] = $true }
            Invoke-WebRequest @dlParams
        } else {
            Write-SetupLog -Level Detail -Message ("Reusing previously downloaded fallback: {0}" -f $destPath)
        }

        $fallbackArgs = @()
        if ($null -ne $App.FallbackArgs) { $fallbackArgs = @($App.FallbackArgs | ForEach-Object { [string]$_ }) }
        Write-SetupLog -Level Task -Message ("Installing {0} (direct download fallback)" -f $App.Name)
        $exitCode = Install-SetupFile -FilePath $destPath -ExtraArgs $fallbackArgs
        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641) {
            Write-SetupLog -Level Success -Message ("Finished via fallback: {0} (exit code {1})" -f $App.Name, $exitCode)
            return New-SetupResult -Name $App.Name -Success $true -ExitCode $exitCode `
                -RestartRequired ($exitCode -in @(3010, 1641)) -Message 'Installed from the vendor download.'
        }
        Write-SetupLog -Level Warning -Message ("Fallback installer returned exit code {0}: {1}" -f $exitCode, $App.Name)
        return New-SetupResult -Name $App.Name -Success $false -ExitCode $exitCode `
            -Message ("Fallback installer returned exit code {0}." -f $exitCode)
    } catch {
        Write-SetupLog -Level Error -Message ("Fallback download/install failed for {0}: {1}" -f $App.Name, $_.Exception.Message)
        return New-SetupResult -Name $App.Name -Success $false -Message 'Fallback download/install failed.'
    }
}

function Install-SetupWingetApp {
    <#
    .SYNOPSIS
        Installs one winget package, with source repair, one retry and an
        optional direct-download fallback.
    #>
    param([Parameter(Mandatory = $true)]$App)

    $winget = Get-WingetCommand
    if ($null -eq $winget) {
        Write-SetupLog -Level Warning -Message ("Skipping {0}: winget is not available." -f $App.Name)
        return New-SetupResult -Name ([string]$App.Name) -Success $false `
            -Message 'winget is not available. Install Microsoft App Installer (https://aka.ms/getwinget).'
    }

    # Known issue: winget sources often fail when running as the built-in Administrator (SID -500).
    try {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($currentSid -match '-500$') {
            Write-SetupLog -Level Warning -Message 'Note: you are running as the built-in Administrator; winget sources often fail in this account.'
            Write-SetupLog -Level Warning -Message 'If installs fail, sign in as a regular admin user and try again.'
        }
    } catch {}

    [void](Repair-SetupWingetSource)

    Write-SetupLog -Level Task -Message ("Installing {0} ({1})" -f $App.Name, $App.Id)
    # Keep the buffered capture: hash-mismatch detection needs the full text,
    # and the wording differs between English and French Windows.
    $wingetArgs = @(
        'install', '--id', [string]$App.Id, '--exact', '--source', 'winget',
        '--silent', '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    $wingetOut = & $winget.Source @wingetArgs 2>&1 | Out-String
    if (-not [string]::IsNullOrWhiteSpace($wingetOut)) {
        Write-SetupLog -Level Detail -Message $wingetOut.TrimEnd()
    }
    $exitCode = $LASTEXITCODE
    $hashMismatch = $wingetOut -match '(?i)hash|hachage|mismatch|non concordance|ne correspond pas'

    # 0x8A15002B (-1978335189) is winget's "already installed" result.
    if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq -1978335189) {
        Write-SetupLog -Level Success -Message ("Finished: {0} (exit code {1})" -f $App.Name, $exitCode)
        if ($exitCode -eq 3010) { Write-SetupLog -Level Warning -Message 'A restart may be required.' }
        return New-SetupResult -Name $App.Name -Success $true -ExitCode $exitCode `
            -RestartRequired ($exitCode -eq 3010) -Message 'Installed.'
    }

    if ($hashMismatch) {
        Write-SetupLog -Level Warning -Message 'Winget reports an installer hash mismatch (stale manifest on the server side).'
        Write-SetupLog -Level Warning -Message 'Winget refuses "--ignore-security-hash" while running as administrator, so trying the direct download instead.'
        $fallback = Install-SetupWingetFallback -App $App
        if ($null -ne $fallback) { return $fallback }
    }

    # One automatic retry: if sources broke mid-run (e.g. exit 1978335217 /
    # "failed when opening sources"), reset them and try the app once more.
    if (-not $script:WingetRetriedForSource) {
        $script:WingetRetriedForSource = $true
        Write-SetupLog -Level Warning -Message 'First attempt failed. Re-checking Winget sources and retrying once...'
        $script:WingetSourceChecked = $false
        [void](Repair-SetupWingetSource -Force)
        $wingetOut = & $winget.Source @wingetArgs 2>&1 | Out-String
        if (-not [string]::IsNullOrWhiteSpace($wingetOut)) {
            Write-SetupLog -Level Detail -Message $wingetOut.TrimEnd()
        }
        $exitCode = $LASTEXITCODE
        if ($wingetOut -match '(?i)hash|hachage|mismatch|non concordance|ne correspond pas') {
            Write-SetupLog -Level Warning -Message 'Retry also reports a hash mismatch; trying the direct download instead.'
            $fallback = Install-SetupWingetFallback -App $App
            if ($null -ne $fallback) { return $fallback }
        }
        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq -1978335189) {
            Write-SetupLog -Level Success -Message ("Finished on retry: {0} (exit code {1})" -f $App.Name, $exitCode)
            if ($exitCode -eq 3010) { Write-SetupLog -Level Warning -Message 'A restart may be required.' }
            return New-SetupResult -Name $App.Name -Success $true -ExitCode $exitCode `
                -RestartRequired ($exitCode -eq 3010) -Message 'Installed on retry.'
        }
    }

    # Last resort for apps with a configured direct download.
    if (($null -ne $App.FallbackUrl) -and (-not [string]::IsNullOrWhiteSpace([string]$App.FallbackUrl))) {
        Write-SetupLog -Level Warning -Message ("Winget failed for {0}; trying the configured direct download..." -f $App.Name)
        $fallback = Install-SetupWingetFallback -App $App
        if ($null -ne $fallback) { return $fallback }
    }

    if ($exitCode -eq 1978335217 -or $exitCode -eq -1978335217) {
        Write-SetupLog -Level Warning -Message ("Installer returned exit code {0}: {1}" -f $exitCode, $App.Name)
        Write-SetupLog -Level Warning -Message 'This is a Winget source error ("Failed when opening sources").'
        Write-SetupLog -Level Warning -Message 'Fix: open a new admin PowerShell and run "winget source reset --force", then "winget source update", then rerun.'
        Write-SetupLog -Level Warning -Message 'Also update App Installer: https://aka.ms/getwinget'
        return New-SetupResult -Name $App.Name -Success $false -ExitCode $exitCode `
            -Message 'Winget source error. See the log for the manual fix.'
    }

    Write-SetupLog -Level Warning -Message ("Installer returned exit code {0}: {1}" -f $exitCode, $App.Name)
    return New-SetupResult -Name $App.Name -Success $false -ExitCode $exitCode `
        -Message ("Installer returned exit code {0}." -f $exitCode)
}

function Install-SetupLocalPackage {
    <#
    .SYNOPSIS
        Runs a local .exe/.msi installer, downloading it first when a Url is set.
    #>
    param([Parameter(Mandatory = $true)]$Installer)

    $name = [string]$Installer.Name
    $relativePath = [string]$Installer.Path
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        Write-SetupLog -Level Warning -Message ("Skipping {0}: no Path is configured in Software.json." -f $name)
        return New-SetupResult -Name $name -Success $false -Message 'No installer path is configured in Software.json.'
    }

    if ([System.IO.Path]::IsPathRooted($relativePath)) {
        $installerPath = $relativePath
    } else {
        $installerPath = Join-Path $script:ModuleRoot $relativePath
    }

    $downloadUrl = ''
    if ($null -ne $Installer.Url) { $downloadUrl = ([string]$Installer.Url).Trim() }
    if ((-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) -and (-not [string]::IsNullOrWhiteSpace($downloadUrl))) {
        try {
            $parentDir = Split-Path -Parent $installerPath
            if (-not [string]::IsNullOrWhiteSpace($parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
            }
            Write-SetupLog -Level Info -Message ("Downloading {0} ..." -f $name)
            Write-SetupLog -Level Detail -Message ("From: {0}" -f $downloadUrl)
            Write-SetupLog -Level Detail -Message ("To: {0}" -f $installerPath)
            $dlParams = @{ Uri = $downloadUrl; OutFile = $installerPath; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -le 5) { $dlParams['UseBasicParsing'] = $true }
            Invoke-WebRequest @dlParams
            $dlInfo = Get-Item -LiteralPath $installerPath -ErrorAction Stop
            if ($dlInfo.Length -lt 1024) { throw ("Downloaded file is only {0} bytes." -f $dlInfo.Length) }
            Write-SetupLog -Level Success -Message ("Downloaded: {0} ({1:N0} bytes)" -f $name, $dlInfo.Length)
        } catch {
            Write-SetupLog -Level Error -Message ("Download failed for {0}: {1}" -f $name, $_.Exception.Message)
            return New-SetupResult -Name $name -Success $false -Message 'Download failed.'
        }
    }

    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        Write-SetupLog -Level Warning -Message ("Not found: {0} ({1})" -f $name, $installerPath)
        Write-SetupLog -Level Warning -Message 'Copy the installer to the configured path, or update its Path in Software.json.'
        return New-SetupResult -Name $name -Success $false -Message 'Installer file is missing.'
    }

    $arguments = @()
    if ($null -ne $Installer.Arguments) { $arguments = @($Installer.Arguments | ForEach-Object { [string]$_ }) }
    $extension = [System.IO.Path]::GetExtension($installerPath).ToLowerInvariant()
    $workingDirectory = Split-Path -Parent $installerPath

    try {
        Write-SetupLog -Level Task -Message ("Running {0}" -f $name)
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
            Write-SetupLog -Level Success -Message ("Finished: {0} (exit code {1})" -f $name, $exitCode)
            if ($exitCode -in @(3010, 1641)) {
                Write-SetupLog -Level Warning -Message 'The installer reported that a restart may be required.'
            }
            return New-SetupResult -Name $name -Success $true -ExitCode $exitCode `
                -RestartRequired ($exitCode -in @(3010, 1641)) -Message 'Installed.'
        }
        Write-SetupLog -Level Warning -Message ("Installer returned exit code {0}: {1}" -f $exitCode, $name)
        return New-SetupResult -Name $name -Success $false -ExitCode $exitCode `
            -Message ("Installer returned exit code {0}." -f $exitCode)
    } catch {
        Write-SetupLog -Level Error -Message ("Could not run {0}: {1}" -f $name, $_.Exception.Message)
        return New-SetupResult -Name $name -Success $false -Message 'Could not launch the installer.'
    }
}

# --------------------------------------------------------------------------
# Built-in Administrator and signed-in account
# --------------------------------------------------------------------------

function Get-BuiltInAdminAccount {
    # Language-agnostic: finds SID ending in -500, so it works whether the
    # account is named Administrator (EN) or Administrateur (FR).
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

function Get-CurrentLocalAccount {
    param([string]$Sid)

    if ([string]::IsNullOrWhiteSpace($Sid)) { return $null }
    try {
        $sidObject = [System.Security.Principal.SecurityIdentifier]::new($Sid)
        return Get-LocalUser -SID $sidObject -ErrorAction Stop
    } catch {
        return $null
    }
}

function Enable-BuiltInAdministrator {
    <#
    .SYNOPSIS
        Enables the built-in Administrator account and sets the given password.
    #>
    param([Parameter(Mandatory = $true)][Security.SecureString]$Password)

    $account = Get-BuiltInAdminAccount
    if ($null -eq $account) {
        return New-SetupResult -Name 'Built-in Administrator' -Success $false `
            -Message 'Could not find the built-in Administrator account (SID ending in -500).'
    }
    $adminName = [string]$account.Name

    $plainLength = 0
    try { $plainLength = [System.Net.NetworkCredential]::new('', $Password).Password.Length } catch { $plainLength = $Password.Length }
    if ($plainLength -lt 8) {
        return New-SetupResult -Name $adminName -Success $false -Message 'Password must be at least 8 characters.'
    }

    $activated = $false
    $failureMessage = ''
    try {
        Set-LocalUser -Name $adminName -Password $Password -ErrorAction Stop
        Enable-LocalUser -Name $adminName -ErrorAction Stop
        $activated = $true
    } catch {
        # Fallback for editions where the LocalUser cmdlets are limited: net user works in EN and FR.
        Write-SetupLog -Level Warning -Message ("LocalUser cmdlet failed ({0}), trying 'net user' fallback..." -f $_.Exception.Message)
        $plainPwd = $null
        try {
            $plainPwd = [System.Net.NetworkCredential]::new('', $Password).Password
            & net user $adminName $plainPwd 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "net user set password failed (exit $LASTEXITCODE)." }
            & net user $adminName /active:yes 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "net user /active:yes failed (exit $LASTEXITCODE)." }
            $activated = $true
        } catch {
            $failureMessage = $_.Exception.Message
        } finally {
            $plainPwd = $null
        }
    }

    if (-not $activated) {
        return New-SetupResult -Name $adminName -Success $false `
            -Message ("Could not configure the built-in Administrator account: {0}" -f $failureMessage)
    }

    # Verify so the caller can show proof, in either language.
    try {
        $check = Get-LocalUser -Name $adminName -ErrorAction Stop
        if ($check.Enabled) {
            Write-SetupLog -Level Success -Message ("Enabled built-in account '{0}' and set the new password." -f $adminName)
            return New-SetupResult -Name $adminName -Success $true `
                -Message ("Enabled '{0}' and set the password you entered." -f $adminName)
        }
        Write-SetupLog -Level Warning -Message ("Password set for '{0}', but Windows still reports it as disabled." -f $adminName)
        return New-SetupResult -Name $adminName -Success $false `
            -Message ("Password set for '{0}', but Windows still reports it as disabled." -f $adminName)
    } catch {
        Write-SetupLog -Level Success -Message ("Enabled built-in account '{0}' (verification skipped)." -f $adminName)
        return New-SetupResult -Name $adminName -Success $true `
            -Message ("Enabled '{0}'. Verification was skipped." -f $adminName)
    }
}

function Rename-SetupLocalAccount {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$NewName
    )

    $NewName = $NewName.Trim()
    $validation = Test-LocalAccountName -Name $NewName
    if ($null -ne $validation) {
        return New-SetupResult -Name $Name -Success $false -Message $validation
    }

    try {
        $account = Get-LocalUser -Name $Name -ErrorAction Stop
    } catch {
        return New-SetupResult -Name $Name -Success $false `
            -Message ("Could not find the local account '{0}'." -f $Name)
    }

    if ($account.Name -ieq $NewName) {
        return New-SetupResult -Name $Name -Success $true -Skipped $true `
            -Message 'The new name is the same as the current name; no change needed.'
    }

    try {
        $allLocalUsers = @(Get-LocalUser -ErrorAction Stop)
    } catch {
        return New-SetupResult -Name $Name -Success $false -Message 'Could not list local users.'
    }
    $duplicate = $allLocalUsers | Where-Object { $_.Name -ieq $NewName -and $_.SID.Value -ne $account.SID.Value } | Select-Object -First 1
    if ($null -ne $duplicate) {
        return New-SetupResult -Name $Name -Success $false `
            -Message ("A local account named '{0}' already exists." -f $NewName)
    }

    try {
        Rename-LocalUser -Name $account.Name -NewName $NewName -ErrorAction Stop
        try {
            Set-LocalUser -Name $NewName -FullName $NewName -ErrorAction Stop
        } catch {
            Write-SetupLog -Level Warning -Message 'The account was renamed, but Windows did not accept the display-name update.'
        }
        Write-SetupLog -Level Success -Message ("Renamed local account '{0}' to '{1}'." -f $account.Name, $NewName)
        return New-SetupResult -Name $NewName -Success $true `
            -Message ("Renamed '{0}' to '{1}'. Sign out or restart to see the new name everywhere." -f $account.Name, $NewName) `
            -Data @{ OldName = $account.Name }
    } catch {
        Write-SetupLog -Level Error -Message ("Could not rename the local account: {0}" -f $_.Exception.Message)
        return New-SetupResult -Name $Name -Success $false `
            -Message ("Could not rename the local account: {0}" -f $_.Exception.Message)
    }
}

function Set-SetupLocalAccountPassword {
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][Security.SecureString]$Password
    )

    $plainLength = 0
    try { $plainLength = [System.Net.NetworkCredential]::new('', $Password).Password.Length } catch { $plainLength = $Password.Length }
    if ($plainLength -lt 8) {
        return New-SetupResult -Name $UserName -Success $false -Message 'Password must be at least 8 characters.'
    }

    try {
        Set-LocalUser -Name $UserName -Password $Password -ErrorAction Stop
        Write-SetupLog -Level Success -Message ("Password changed for '{0}'." -f $UserName)
        return New-SetupResult -Name $UserName -Success $true -Message 'Password changed.'
    } catch {
        Write-SetupLog -Level Error -Message ("Could not change the password: {0}" -f $_.Exception.Message)
        return New-SetupResult -Name $UserName -Success $false `
            -Message 'Could not change the password. Windows password complexity policy may have rejected it.'
    }
}

# --------------------------------------------------------------------------
# Local users and groups
# --------------------------------------------------------------------------

function Get-UserGroupNames {
    param([Parameter(Mandatory = $true)]$User)

    $groups = @()
    try {
        foreach ($group in @(Get-LocalGroup -ErrorAction Stop)) {
            try {
                $hit = @(Get-LocalGroupMember -Group $group.Name -ErrorAction Stop |
                    Where-Object { $null -ne $_.SID -and ($_.SID.Value -eq $User.SID.Value) })
                if ($hit.Count -gt 0) { $groups += $group.Name }
            } catch {}
        }
    } catch {}
    return $groups
}

function Get-LocalUserInventory {
    <#
    .SYNOPSIS
        Lists local users with their groups and sole-administrator flag.
    #>
    try {
        $users = @(Get-LocalUser -ErrorAction Stop | Sort-Object Name)
    } catch {
        throw ("Could not list local users: {0}" -f $_.Exception.Message)
    }

    $enabledAdminSids = @()
    try {
        $adminGroup = @(Get-LocalGroup -ErrorAction Stop | Where-Object {
            $null -ne $_.SID -and $_.SID.Value -match '-544$'
        } | Select-Object -First 1)
        if ($adminGroup.Count -ge 1) {
            foreach ($member in @(Get-LocalGroupMember -Group $adminGroup[0].Name -ErrorAction SilentlyContinue)) {
                if ($member.ObjectClass -ne 'User') { continue }
                $memberUser = Get-LocalUser -SID $member.SID -ErrorAction SilentlyContinue
                if ($null -ne $memberUser -and $memberUser.Enabled) {
                    $enabledAdminSids += $memberUser.SID.Value
                }
            }
        }
    } catch {}

    $soleAdmin = ($enabledAdminSids.Count -eq 1)
    $items = @()
    foreach ($user in $users) {
        $sidValue = ''
        if ($null -ne $user.SID) { $sidValue = $user.SID.Value }
        $items += [pscustomobject]@{
            Name        = $user.Name
            FullName    = [string]$user.FullName
            Enabled     = [bool]$user.Enabled
            SID         = $sidValue
            Groups      = @(Get-UserGroupNames -User $user)
            IsSoleAdmin = ($soleAdmin -and ($enabledAdminSids -contains $sidValue))
        }
    }
    return $items
}

function Get-LocalGroupNames {
    try {
        return @(Get-LocalGroup -ErrorAction Stop | Sort-Object Name | Select-Object -ExpandProperty Name)
    } catch {
        return @()
    }
}

function Get-SoleAdminLock {
    <#
    .SYNOPSIS
        Tells whether group membership is frozen for this account.
    .DESCRIPTION
        With only one enabled administrator left on the PC, any permission
        change is refused: locking the last admin out would be unrecoverable.
    #>
    param([Parameter(Mandatory = $true)][string]$UserName)

    $account = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($null -eq $account) {
        return [pscustomobject]@{ Locked = $false; Message = '' }
    }

    try {
        $adminGroup = @(Get-LocalGroup -ErrorAction Stop | Where-Object { $_.SID.Value -match '-544$' } | Select-Object -First 1)
        if ($adminGroup.Count -ge 1) {
            $enabledAdmins = @(Get-LocalGroupMember -Group $adminGroup[0].Name -ErrorAction SilentlyContinue | Where-Object {
                $_.ObjectClass -eq 'User' -and
                (($tmpUser = Get-LocalUser -SID $_.SID -ErrorAction SilentlyContinue) -and $tmpUser.Enabled)
            })
            if (($enabledAdmins.Count -eq 1) -and ($enabledAdmins[0].SID.Value -eq $account.SID.Value)) {
                return [pscustomobject]@{
                    Locked  = $true
                    Message = ("'{0}' is the only enabled administrator on this PC. Group membership is frozen for this account. Create or enable another admin first." -f $UserName)
                }
            }
        }
    } catch {}

    return [pscustomobject]@{ Locked = $false; Message = '' }
}

function Add-SetupLocalGroupMember {
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$GroupName
    )

    $lock = Get-SoleAdminLock -UserName $UserName
    if ($lock.Locked) { return New-SetupResult -Name $UserName -Success $false -Message $lock.Message }

    try {
        Add-LocalGroupMember -Group $GroupName -Member $UserName -ErrorAction Stop
        Write-SetupLog -Level Success -Message ("Added '{0}' to '{1}'." -f $UserName, $GroupName)
        return New-SetupResult -Name $UserName -Success $true -Message ("Added to '{0}'." -f $GroupName)
    } catch {
        Write-SetupLog -Level Error -Message ("Could not add to the group: {0}" -f $_.Exception.Message)
        return New-SetupResult -Name $UserName -Success $false `
            -Message ("Could not add to the group: {0}" -f $_.Exception.Message)
    }
}

function Remove-SetupLocalGroupMember {
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$GroupName
    )

    $lock = Get-SoleAdminLock -UserName $UserName
    if ($lock.Locked) { return New-SetupResult -Name $UserName -Success $false -Message $lock.Message }

    try {
        Remove-LocalGroupMember -Group $GroupName -Member $UserName -ErrorAction Stop
        Write-SetupLog -Level Success -Message ("Removed '{0}' from '{1}'." -f $UserName, $GroupName)
        return New-SetupResult -Name $UserName -Success $true -Message ("Removed from '{0}'." -f $GroupName)
    } catch {
        Write-SetupLog -Level Error -Message ("Could not remove from the group: {0}" -f $_.Exception.Message)
        return New-SetupResult -Name $UserName -Success $false `
            -Message ("Could not remove from the group: {0}" -f $_.Exception.Message)
    }
}

# --------------------------------------------------------------------------
# Printers
# --------------------------------------------------------------------------

function Get-PrinterInventory {
    <#
    .SYNOPSIS
        Lists installed printers with the default flag.
    #>
    if (-not (Get-Command Get-Printer -ErrorAction SilentlyContinue)) { return @() }
    $printers = @(Get-Printer -ErrorAction SilentlyContinue | Sort-Object Name)
    $defaultName = ''
    try {
        $default = Get-CimInstance -ClassName Win32_Printer -Filter 'Default = TRUE' -ErrorAction Stop
        if ($null -ne $default) { $defaultName = [string]$default.Name }
    } catch {}

    $items = @()
    foreach ($printer in $printers) {
        $items += [pscustomobject]@{
            Name       = $printer.Name
            DriverName = [string]$printer.DriverName
            PortName   = [string]$printer.PortName
            Status     = [string]$printer.PrinterStatus
            IsDefault  = ($printer.Name -eq $defaultName)
        }
    }
    return $items
}

function Get-PrinterDriverNames {
    if (-not (Get-Command Get-PrinterDriver -ErrorAction SilentlyContinue)) { return @() }
    return @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
}

function Rename-SetupPrinter {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$NewName
    )

    $NewName = $NewName.Trim()
    if ([string]::IsNullOrWhiteSpace($NewName)) {
        return New-SetupResult -Name $Name -Success $false -Message 'The printer name cannot be empty.'
    }
    if (-not (Get-Command Rename-Printer -ErrorAction SilentlyContinue)) {
        return New-SetupResult -Name $Name -Success $false -Message 'Rename-Printer is not available on this Windows edition.'
    }
    if ($NewName -ieq $Name) {
        return New-SetupResult -Name $Name -Success $true -Skipped $true -Message 'The new name is the same; no change needed.'
    }
    if ($null -ne (Get-Printer -Name $NewName -ErrorAction SilentlyContinue)) {
        return New-SetupResult -Name $Name -Success $false -Message ("A printer named '{0}' already exists." -f $NewName)
    }

    try {
        Rename-Printer -Name $Name -NewName $NewName -ErrorAction Stop
        Write-SetupLog -Level Success -Message ("Renamed printer '{0}' to '{1}'." -f $Name, $NewName)
        return New-SetupResult -Name $NewName -Success $true -Message ("Renamed to '{0}'." -f $NewName)
    } catch {
        Write-SetupLog -Level Error -Message ("Could not rename the printer: {0}" -f $_.Exception.Message)
        return New-SetupResult -Name $Name -Success $false `
            -Message ("Could not rename the printer: {0}" -f $_.Exception.Message)
    }
}

function Get-DriverCacheRoot {
    # Persistent cache outside the online staging folder (which is wiped on
    # every run), so a downloaded driver package is reused next time.
    $base = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [System.IO.Path]::GetTempPath() }
    $cache = Join-Path $base 'Windows_Auto_Setup_Online\Drivers'
    try {
        New-Item -ItemType Directory -Path $cache -Force -ErrorAction Stop | Out-Null
        return $cache
    } catch {
        $fallback = Join-Path ([System.IO.Path]::GetTempPath()) 'Windows_Auto_Setup_Online\Drivers'
        New-Item -ItemType Directory -Path $fallback -Force -ErrorAction Stop | Out-Null
        return $fallback
    }
}

function Get-DriverInfCandidates {
    param([string]$Folder)

    if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path -LiteralPath $Folder -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $Folder -Filter '*.inf' -File -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -ExpandProperty FullName)
}

function Resolve-SetupDriverInf {
    # Returns the INF to use. A driver folder normally holds exactly one INF;
    # with several, -PreferredInf (from the UI) wins, then the first by name.
    param(
        [string]$Folder,
        [string]$PreferredInf = ''
    )

    if ((-not [string]::IsNullOrWhiteSpace($PreferredInf)) -and (Test-Path -LiteralPath $PreferredInf -PathType Leaf)) {
        return $PreferredInf
    }
    $candidates = @(Get-DriverInfCandidates -Folder $Folder)
    if ($candidates.Count -eq 1) { return $candidates[0] }
    if ($candidates.Count -gt 1) {
        Write-SetupLog -Level Warning -Message ("Several INF files found; using {0}. Provide an explicit INF path to choose another." -f (Split-Path -Leaf $candidates[0]))
        return $candidates[0]
    }
    return ''
}

function Save-SetupDriverFolder {
    <#
    .SYNOPSIS
        Downloads a driver folder from the project repository, file by file,
        and marks the folder complete only when every size matches.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $repo = 'baddimehamad/windows-install-script'
    $branch = 'main'
    $headers = @{ 'User-Agent' = 'Windows-Auto-Setup' }
    try {
        # One recursive tree call lists the whole repo (including subfolders).
        # Per-folder listing would need dozens of API calls for packages such
        # as Epson, which keeps files under WINX64\SETUP\... and blows the
        # unauthenticated 60-requests/hour limit.
        $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/git/trees/${branch}?recursive=1" -Headers $headers -ErrorAction Stop
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -eq 403) {
            Write-SetupLog -Level Error -Message 'GitHub API rate limit reached while listing driver files.'
            Write-SetupLog -Level Warning -Message 'Wait a few minutes and retry, or provide the .inf path manually.'
        } else {
            Write-SetupLog -Level Error -Message ("Could not list driver files on GitHub: {0}" -f $_.Exception.Message)
        }
        return $false
    }

    $tree = @($response.tree)
    $prefix = $RepoPath.Trim('/') + '/'
    $entries = @($tree | Where-Object { $_.type -eq 'blob' -and $_.path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($entries.Count -eq 0) {
        Write-SetupLog -Level Warning -Message ("No driver package for '{0}' is stored in the repository." -f $RepoPath)
        return $false
    }

    # Packages like Epson ship the same driver for x86/amd64/arm64. On an x64
    # PC only the common files + WINX64 are needed; skip the other arch trees.
    $hasWinX64 = @($entries | Where-Object { $_.path -match '(?i)/WINX64/' }).Count -gt 0
    if ($hasWinX64 -and $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') {
        $entries = @($entries | Where-Object { $_.path -notmatch '(?i)/WINX86/' -and $_.path -notmatch '(?i)/ARM64/' })
    }

    $totalBytes = (($entries | Measure-Object -Property size -Sum).Sum)
    New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $Destination '.complete') -PathType Leaf)) {
        # An unmarked folder is a failed/partial download: start clean so a
        # stale INF cannot be mistaken for a complete driver package.
        Get-ChildItem -LiteralPath $Destination -File -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Write-SetupLog -Level Info -Message ("Downloading {0} driver files ({1:N1} MB) from GitHub ..." -f $entries.Count, ($totalBytes / 1MB))
    foreach ($file in $entries) {
        $relative = $file.path.Substring($prefix.Length) -replace '/', '\'
        $destFile = Join-Path $Destination $relative
        $parent = Split-Path -Parent $destFile
        if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
        $expected = [int64]$file.size
        if ((Test-Path -LiteralPath $destFile -PathType Leaf) -and ((Get-Item -LiteralPath $destFile).Length -eq $expected)) { continue }
        try {
            $encodedPath = (($file.path -split '/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
            $url = "https://raw.githubusercontent.com/$repo/$branch/$encodedPath"
            $dlParams = @{ Uri = $url; OutFile = $destFile; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -le 5) { $dlParams['UseBasicParsing'] = $true }
            Invoke-WebRequest @dlParams
            if (-not (Test-Path -LiteralPath $destFile -PathType Leaf)) { throw 'file was not created' }
            if ((Get-Item -LiteralPath $destFile).Length -ne $expected) { throw 'size mismatch' }
        } catch {
            Remove-Item -LiteralPath (Join-Path $Destination '.complete') -Force -ErrorAction SilentlyContinue
            Write-SetupLog -Level Error -Message ("Download failed for {0}: {1}" -f $file.path, $_.Exception.Message)
            return $false
        }
    }

    # Only a fully verified folder is marked complete and trusted as a cache.
    Set-Content -LiteralPath (Join-Path $Destination '.complete') -Value 'ok' -Encoding ASCII
    return $true
}

function Install-SetupNetworkPrinter {
    <#
    .SYNOPSIS
        Installs a TCP/IP printer, importing the driver package when needed.

    .DESCRIPTION
        Driver resolution order: explicit INF, local Drivers folder, persistent
        cache, repository download, preset Url. The driver is staged with
        pnputil then registered with Add-PrinterDriver or printui.

    .PARAMETER PreferredInf
        Full path to an .inf file. Used when a driver folder holds several.
    .PARAMETER PreferredDriverName
        Exact registered driver name to use when several drivers are imported.
    .PARAMETER Overwrite
        Replace an existing printer that has the same name.
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Make,
        [Parameter(Mandatory = $true)][string]$HostAddress,
        [int]$Port = 9100,
        [string]$PrinterName = '',
        [string]$PreferredInf = '',
        [string]$PreferredDriverName = '',
        [switch]$Overwrite
    )

    $address = ([string]$HostAddress).Trim()
    if ([string]::IsNullOrWhiteSpace($address)) {
        return New-SetupResult -Name $Make -Success $false -Message 'No printer IP address or hostname was provided.'
    }
    if ($Port -lt 1 -or $Port -gt 65535) {
        Write-SetupLog -Level Warning -Message ("Invalid port ({0}); using 9100." -f $Port)
        $Port = 9100
    }
    if (-not (Get-Command Add-Printer -ErrorAction SilentlyContinue)) {
        return New-SetupResult -Name $Make -Success $false `
            -Message 'Printer cmdlets (PrintManagement) are not available on this Windows edition.'
    }
    if ([string]::IsNullOrWhiteSpace($PrinterName)) {
        $PrinterName = ("{0} {1}" -f $Make, $address)
    }
    $PrinterName = $PrinterName.Trim()

    $presets = @(@($Config.PrinterDrivers) | Where-Object {
        $null -ne $_ -and $_.Enabled -ne $false -and -not [string]::IsNullOrWhiteSpace([string]$_.Make)
    })
    if ($presets.Count -eq 0) {
        return New-SetupResult -Name $Make -Success $false `
            -Message 'No printer driver presets are enabled in Software.json (PrinterDrivers).'
    }
    $preset = $presets | Where-Object { [string]$_.Make -ieq $Make } | Select-Object -First 1
    if ($null -eq $preset) {
        return New-SetupResult -Name $Make -Success $false `
            -Message ("No printer driver preset named '{0}' is enabled in Software.json." -f $Make)
    }

    # Check this first: no point downloading a driver package for a printer
    # that will not be replaced.
    $existingPrinter = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    if (($null -ne $existingPrinter) -and (-not $Overwrite)) {
        return New-SetupResult -Name $PrinterName -Success $true -Skipped $true `
            -Message ("A printer named '{0}' already exists. Enable the replace option to overwrite it." -f $PrinterName)
    }

    # If the driver is already registered, no files are needed at all. This also
    # matters in online mode, where the Drivers/ folder is not staged.
    $driversBefore = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $driverName = ''
    $skipImport = $false
    $driverHint = [string]$preset.DriverHint
    if (-not [string]::IsNullOrWhiteSpace($driverHint)) {
        $alreadyThere = @($driversBefore | Where-Object { "$_" -ieq $driverHint })
        if ($alreadyThere.Count -ge 1) {
            Write-SetupLog -Level Success -Message ("Driver already installed, reusing: '{0}'" -f $alreadyThere[0])
            $driverName = $alreadyThere[0]
            $skipImport = $true
        }
    }
    if ((-not $skipImport) -and (-not [string]::IsNullOrWhiteSpace($PreferredDriverName))) {
        $match = @($driversBefore | Where-Object { "$_" -ieq $PreferredDriverName })
        if ($match.Count -ge 1) {
            Write-SetupLog -Level Success -Message ("Driver already installed, reusing: '{0}'" -f $match[0])
            $driverName = $match[0]
            $skipImport = $true
        }
    }

    $infPath = ''
    if (-not $skipImport) {
        $driverDir = ''
        $relativeDriverPath = ''
        $presetPath = ([string]$preset.Path).Trim()
        if (-not [string]::IsNullOrWhiteSpace($presetPath)) {
            if ([System.IO.Path]::IsPathRooted($presetPath)) {
                $driverDir = $presetPath
            } else {
                $driverDir = Join-Path $script:ModuleRoot $presetPath
                $relativeDriverPath = ($presetPath -replace '\\', '/').Trim('/')
            }
        }
        $presetUrl = ''
        if ($null -ne $preset.Url) { $presetUrl = ([string]$preset.Url).Trim() }

        # 1) Explicit INF chosen in the UI.
        if ((-not [string]::IsNullOrWhiteSpace($PreferredInf)) -and (Test-Path -LiteralPath $PreferredInf -PathType Leaf)) {
            $infPath = $PreferredInf
        }

        # 2) Folder next to the script (local copy / Git clone).
        if ([string]::IsNullOrWhiteSpace($infPath) -and (-not [string]::IsNullOrWhiteSpace($driverDir))) {
            if ((Test-Path -LiteralPath $driverDir -PathType Leaf) -and $driverDir.ToLowerInvariant().EndsWith('.inf')) {
                $infPath = $driverDir
            } else {
                $infPath = Resolve-SetupDriverInf -Folder $driverDir -PreferredInf $PreferredInf
            }
        }

        # 3) Persistent cache from a previous run (ProgramData, survives the
        #    online staging folder being wiped).
        $cacheDir = ''
        if ([string]::IsNullOrWhiteSpace($infPath) -and (-not [string]::IsNullOrWhiteSpace($relativeDriverPath))) {
            $leaf = Split-Path -Leaf $relativeDriverPath
            if (-not [string]::IsNullOrWhiteSpace($leaf)) {
                try { $cacheDir = Join-Path (Get-DriverCacheRoot) $leaf } catch { $cacheDir = '' }
                if ((-not [string]::IsNullOrWhiteSpace($cacheDir)) -and (Test-Path -LiteralPath (Join-Path $cacheDir '.complete') -PathType Leaf)) {
                    $infPath = Resolve-SetupDriverInf -Folder $cacheDir -PreferredInf $PreferredInf
                }
            }
        }

        # 4) Online mode: Drivers/ is not staged, so fetch the folder from the repo.
        if ([string]::IsNullOrWhiteSpace($infPath) -and (-not [string]::IsNullOrWhiteSpace($relativeDriverPath)) -and (-not [string]::IsNullOrWhiteSpace($cacheDir))) {
            Write-SetupLog -Level Info -Message 'Driver files are not present locally; fetching them from the repository ...'
            if (Save-SetupDriverFolder -RepoPath $relativeDriverPath -Destination $cacheDir) {
                $infPath = Resolve-SetupDriverInf -Folder $cacheDir -PreferredInf $PreferredInf
                if (-not [string]::IsNullOrWhiteSpace($infPath)) {
                    Write-SetupLog -Level Detail -Message ("Driver files saved to {0}" -f $cacheDir)
                }
            }
        }

        # 5) Preset Url (vendor download).
        if ([string]::IsNullOrWhiteSpace($infPath) -and (-not [string]::IsNullOrWhiteSpace($presetUrl))) {
            try {
                if ([string]::IsNullOrWhiteSpace($driverDir)) {
                    if (-not [string]::IsNullOrWhiteSpace($cacheDir)) { $driverDir = $cacheDir }
                    else { $driverDir = Join-Path $script:ModuleRoot 'Drivers' }
                }
                New-Item -ItemType Directory -Path $driverDir -Force -ErrorAction Stop | Out-Null
                $uri = [System.Uri]$presetUrl
                $dlName = [System.IO.Path]::GetFileName($uri.LocalPath)
                if ([string]::IsNullOrWhiteSpace($dlName)) { $dlName = 'driver_package.zip' }
                $dlPath = Join-Path $driverDir $dlName
                Write-SetupLog -Level Info -Message ("Downloading driver from {0} ..." -f $presetUrl)
                $dlParams = @{ Uri = $presetUrl; OutFile = $dlPath; ErrorAction = 'Stop' }
                if ($PSVersionTable.PSVersion.Major -le 5) { $dlParams['UseBasicParsing'] = $true }
                Invoke-WebRequest @dlParams
                if ($dlPath.ToLowerInvariant().EndsWith('.zip')) {
                    Expand-Archive -LiteralPath $dlPath -DestinationPath $driverDir -Force -ErrorAction Stop
                }
                $infs = @(Get-ChildItem -LiteralPath $driverDir -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue)
                if ($infs.Count -ge 1) { $infPath = $infs[0].FullName }
            } catch {
                Write-SetupLog -Level Error -Message ("Driver download failed: {0}" -f $_.Exception.Message)
            }
        }

        if ([string]::IsNullOrWhiteSpace($infPath)) {
            Write-SetupLog -Level Warning -Message ("Driver files for '{0}' were not found." -f $preset.Make)
            return New-SetupResult -Name $PrinterName -Success $false `
                -Message 'Driver files were not found. Provide an .inf path, or set Url/Path in Software.json.' `
                -Data @{ NeedInf = $true }
        }
    }

    # --- Import the driver, auto-detecting its real name (works in EN and FR Windows). ---
    if (-not $skipImport) {
        Write-SetupLog -Level Info -Message ("Importing driver from {0} ..." -f $infPath)

        # Stage 1: pnputil stages the package into the Windows driver store.
        # For V4 print drivers pnputil often fails to auto-register the driver
        # even though the package IS staged, so staging is a separate step.
        $pnpOut = & pnputil.exe /add-driver "$infPath" /install 2>&1 | Out-String
        $pnpExit = $LASTEXITCODE
        # Accept success in any locale: EN "successfully", FR "correctement"/"existe deja".
        $pnpOk = ($pnpExit -eq 0) -or ($pnpOut -match '(?i)successfully|correctement|already exists|existe d')
        $driversAfter = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $newDrivers = @($driversAfter | Where-Object { $_ -notin $driversBefore })

        # Stage 2: Add-PrinterDriver registers a package already staged by pnputil.
        if ($newDrivers.Count -eq 0) {
            $fallbackName = $driverHint
            if (-not [string]::IsNullOrWhiteSpace($fallbackName)) {
                if (-not $pnpOk) { Write-SetupLog -Level Detail -Message $pnpOut.TrimEnd() }
                Write-SetupLog -Level Warning -Message ("Registering V4 driver via Add-PrinterDriver: '{0}' ..." -f $fallbackName)
                try {
                    # Add-PrinterDriver has no -InfPath parameter; -Name registers
                    # a driver package already staged by pnputil.
                    Add-PrinterDriver -Name $fallbackName -ErrorAction Stop
                    Write-SetupLog -Level Success -Message ("Add-PrinterDriver succeeded for '{0}'." -f $fallbackName)
                } catch {
                    Write-SetupLog -Level Detail -Message ("Add-PrinterDriver failed: {0}" -f $_.Exception.Message)
                }
                $driversAfter = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
                $newDrivers = @($driversAfter | Where-Object { $_ -notin $driversBefore })
            }
        }

        # Stage 3: legacy printui.dll method (V3 drivers).
        if ($newDrivers.Count -eq 0) {
            $fallbackName = $driverHint
            if (-not [string]::IsNullOrWhiteSpace($fallbackName)) {
                Write-SetupLog -Level Warning -Message 'V4 registration did not work, trying printui fallback (V3 method)...'
                $printuiOut = & rundll32.exe printui.dll,PrintUIEntry /ia /f "$infPath" /m "$fallbackName" 2>&1 | Out-String
                Start-Sleep -Seconds 3   # printui is async, give it a moment
                $driversAfter = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
                $newDrivers = @($driversAfter | Where-Object { $_ -notin $driversBefore })
                if (($newDrivers.Count -eq 0) -and ($driversAfter -inotcontains $fallbackName)) {
                    Write-SetupLog -Level Detail -Message $printuiOut.TrimEnd()
                }
            }
        }

        # --- Pick the driver name from whatever got registered. ---
        if ($newDrivers.Count -eq 1) {
            $driverName = $newDrivers[0]
        } elseif ($newDrivers.Count -gt 1) {
            $chosen = ''
            if (-not [string]::IsNullOrWhiteSpace($PreferredDriverName)) {
                $match = @($newDrivers | Where-Object { "$_" -ieq $PreferredDriverName })
                if ($match.Count -gt 0) { $chosen = [string]$match[0] }
            }
            if ([string]::IsNullOrWhiteSpace($chosen) -and (-not [string]::IsNullOrWhiteSpace($driverHint))) {
                $match = @($newDrivers | Where-Object { "$_" -ieq $driverHint })
                if ($match.Count -gt 0) { $chosen = [string]$match[0] }
            }
            if ([string]::IsNullOrWhiteSpace($chosen)) {
                Write-SetupLog -Level Warning -Message ("Several drivers were imported; using '{0}'." -f $newDrivers[0])
                $chosen = [string]$newDrivers[0]
            }
            $driverName = $chosen
        }
        # Check by DriverHint even if newDrivers is empty (driver may have been
        # staged under a name that was already in the snapshot).
        if ([string]::IsNullOrWhiteSpace($driverName) -and (-not [string]::IsNullOrWhiteSpace($driverHint))) {
            $match = @($driversAfter | Where-Object { "$_" -ieq $driverHint })
            if ($match.Count -ge 1) { $driverName = $match[0] }
        }
        if ([string]::IsNullOrWhiteSpace($driverName)) {
            Write-SetupLog -Level Warning -Message 'pnputil output (for diagnosis):'
            Write-SetupLog -Level Detail -Message $pnpOut.TrimEnd()
            Write-SetupLog -Level Error -Message 'The driver package did not register on this Windows.'
            Write-SetupLog -Level Warning -Message 'Tip: download a newer driver from the manufacturer website.'
            return New-SetupResult -Name $PrinterName -Success $false `
                -Message 'The driver package did not register on this Windows.' `
                -Data @{ NeedDriverName = $true; Drivers = @($driversAfter) }
        }
        Write-SetupLog -Level Success -Message ("Driver ready: '{0}'" -f $driverName)
    }

    # --- TCP/IP port + printer on this local PC. ---
    $portName = "TCP_$address"
    try {
        $existingPort = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue
        if ($null -eq $existingPort) {
            Add-PrinterPort -Name $portName -PrinterHostAddress $address -PortNumber $Port -ErrorAction Stop
            Write-SetupLog -Level Success -Message ("Created TCP/IP port '{0}' -> {1}:{2}." -f $portName, $address, $Port)
        } else {
            Write-SetupLog -Level Detail -Message ("Reusing existing port '{0}'." -f $portName)
        }

        if ($null -ne $existingPrinter) {
            Remove-Printer -Name $PrinterName -ErrorAction Stop
            Write-SetupLog -Level Detail -Message ("Removed the existing printer '{0}'." -f $PrinterName)
        }
        Add-Printer -Name $PrinterName -DriverName $driverName -PortName $portName -ErrorAction Stop
        Write-SetupLog -Level Success -Message ("Printer '{0}' installed on port '{1}' with driver '{2}'." -f $PrinterName, $portName, $driverName)
        return New-SetupResult -Name $PrinterName -Success $true `
            -Message ("Printer installed on {0}:{1}." -f $address, $Port) `
            -Data @{ DriverName = $driverName; PortName = $portName }
    } catch {
        Write-SetupLog -Level Error -Message ("Could not install the printer: {0}" -f $_.Exception.Message)
        return New-SetupResult -Name $PrinterName -Success $false `
            -Message ("Could not install the printer: {0}" -f $_.Exception.Message)
    }
}

# --------------------------------------------------------------------------

Export-ModuleMember -Function @(
    'Get-SetupRootPath',
    'Set-SetupLogSink',
    'Clear-SetupLogSink',
    'Write-SetupLog',
    'New-SetupResult',
    'Get-SetupConfig',
    'Get-SoftwareCatalog',
    'Test-LocalAccountName',
    'Repair-SetupWingetSource',
    'Install-SetupWingetApp',
    'Install-SetupLocalPackage',
    'Get-BuiltInAdminAccount',
    'Get-CurrentLocalAccount',
    'Enable-BuiltInAdministrator',
    'Rename-SetupLocalAccount',
    'Set-SetupLocalAccountPassword',
    'Get-LocalUserInventory',
    'Get-LocalGroupNames',
    'Get-SoleAdminLock',
    'Add-SetupLocalGroupMember',
    'Remove-SetupLocalGroupMember',
    'Get-PrinterInventory',
    'Get-PrinterDriverNames',
    'Rename-SetupPrinter',
    'Get-DriverInfCandidates',
    'Install-SetupNetworkPrinter'
)
