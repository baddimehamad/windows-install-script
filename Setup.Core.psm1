#Requires -Version 5.1
<#
.SYNOPSIS
    Core logic for Windows Automatic Setup.

.DESCRIPTION
    Every action lives here: software installation, printer setup, local users,
    the built-in Administrator and the read-only system dashboard. Nothing in
    this module prompts or writes to the console directly.

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

function Get-SetupCatalogEntry {
    <#
    .SYNOPSIS
        Returns the Software.json entry behind a catalog display item.
    .DESCRIPTION
        Get-SoftwareCatalog wraps each entry for the front-ends. Actions that
        need the configured fields (Id, Source, Path, Url, Version, FallbackUrl)
        accept both shapes so a caller can pass either one.
    #>
    param($Item)
    if ($null -eq $Item) { return $null }
    $property = $Item.PSObject.Properties['Item']
    if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    return $Item
}

function Get-SetupCatalogSource {
    <#
    .SYNOPSIS
        Returns the winget source configured for a catalog entry.
    .DESCRIPTION
        "winget" is the default. An entry that sets Source to "msstore" is
        installed and updated from the Microsoft Store source. Version lists
        are only available for the winget source.
    #>
    param($Item)
    $source = 'winget'
    if ($null -eq $Item) { return $source }
    $property = $Item.PSObject.Properties['Source']
    if ($null -eq $property) { return $source }
    $candidate = ([string]$property.Value).Trim().ToLowerInvariant()
    if ($candidate -eq 'msstore') { $source = 'msstore' }
    return $source
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
        Timestamp       = (Get-Date)
    }
}

# --------------------------------------------------------------------------
# System information, preflight checks and restore points
# --------------------------------------------------------------------------

function Test-SetupPendingReboot {
    <#
    .SYNOPSIS
        Returns $true when Windows has a pending restart.
    #>
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) { return $true }
    }
    try {
        $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
        if ($null -ne $session.PendingFileRenameOperations) { return $true }
    } catch { }
    return $false
}

function Get-SetupSystemInfo {
    <#
    .SYNOPSIS
        Collects the machine information used by reports and preflight checks.
    #>
    $info = [ordered]@{
        ComputerName         = [string]$env:COMPUTERNAME
        UserName             = ''
        IsAdministrator      = $false
        OSName               = ''
        OSVersion            = ''
        OSBuild              = ''
        DisplayVersion       = ''
        Architecture         = ''
        TimeZone             = ''
        TimeZoneDisplay      = ''
        Manufacturer         = ''
        Model                = ''
        Domain               = ''
        PartOfDomain         = $false
        CPUName              = ''
        CPUCores             = $null
        CPULogicalProcessors = $null
        RAMGB                = $null
        LastBootTime         = ''
        UptimeHours          = $null
        PowerShellVersion    = $PSVersionTable.PSVersion.ToString()
        WingetVersion        = ''
        SystemDrive          = [string]$env:SystemDrive
        FreeSpaceGB          = $null
        TotalSpaceGB         = $null
        PendingReboot        = $false
        GeneratedAt          = (Get-Date).ToString('o')
    }

    try { $info.UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { }
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $info.IsAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }

    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $computer) {
            $info.Manufacturer = ([string]$computer.Manufacturer).Trim()
            $info.Model = ([string]$computer.Model).Trim()
            $info.Domain = [string]$computer.Domain
            $info.PartOfDomain = [bool]$computer.PartOfDomain
            if ($null -ne $computer.TotalPhysicalMemory) {
                $info.RAMGB = [math]::Round(([double]$computer.TotalPhysicalMemory / 1GB), 1)
            }
        }
    } catch { }

    try {
        $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $processor) {
            $info.CPUName = ([string]$processor.Name).Trim()
            $info.CPUCores = $processor.NumberOfCores
            $info.CPULogicalProcessors = $processor.NumberOfLogicalProcessors
        }
    } catch { }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $os) {
            $info.OSName = [string]$os.Caption
            $info.OSVersion = [string]$os.Version
            $info.OSBuild = [string]$os.BuildNumber
            $info.Architecture = [string]$os.OSArchitecture
            if ($null -ne $os.LastBootUpTime) {
                $boot = [datetime]$os.LastBootUpTime
                $info.LastBootTime = $boot.ToString('yyyy-MM-dd HH:mm')
                $uptime = (Get-Date) - $boot
                if ($uptime.TotalHours -ge 0) { $info.UptimeHours = [math]::Round($uptime.TotalHours, 1) }
            }
        }
    } catch { }

    try {
        $versionKey = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($null -ne $versionKey.DisplayVersion) { $info.DisplayVersion = [string]$versionKey.DisplayVersion }
        elseif ($null -ne $versionKey.ReleaseId) { $info.DisplayVersion = [string]$versionKey.ReleaseId }
    } catch { }

    try {
        $timeZone = [TimeZoneInfo]::Local
        $info.TimeZone = [string]$timeZone.Id
        $info.TimeZoneDisplay = [string]$timeZone.DisplayName
    } catch { }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -ne $winget) {
        try {
            $versionText = (& $winget.Source --version 2>&1 | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($versionText)) { $info.WingetVersion = $versionText }
        } catch { }
    }

    $drive = [string]$env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'C:' }
    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $disk) {
            if ($null -ne $disk.FreeSpace) { $info.FreeSpaceGB = [math]::Round(([double]$disk.FreeSpace / 1GB), 2) }
            if ($null -ne $disk.Size) { $info.TotalSpaceGB = [math]::Round(([double]$disk.Size / 1GB), 2) }
        }
    } catch { }

    $info.PendingReboot = Test-SetupPendingReboot
    return [pscustomobject]$info
}

# --------------------------------------------------------------------------
# Read-only system dashboard
# --------------------------------------------------------------------------

function New-SetupSystemRow {
    param(
        [string]$LabelKey = '',
        [string]$Label = '',
        [string]$Value = '',
        [string]$ValueKey = '',
        [string]$Detail = '',
        [ValidateSet('Info', 'Ok', 'Warning', 'Error', 'Muted')][string]$Tone = 'Info'
    )
    return [pscustomobject]@{
        LabelKey = $LabelKey
        Label    = $Label
        Value    = [string]$Value
        ValueKey = $ValueKey
        Detail   = [string]$Detail
        Tone     = $Tone
    }
}

function New-SetupSystemStateRow {
    param(
        [string]$LabelKey,
        [string]$Label,
        [string]$State,
        [string]$Tone = 'Info',
        [string]$Detail = ''
    )
    $states = @{
        'On'          = @{ Key = 'System.Value.On'; Text = 'On' }
        'Off'         = @{ Key = 'System.Value.Off'; Text = 'Off' }
        'Running'     = @{ Key = 'System.Value.Running'; Text = 'Running' }
        'Stopped'     = @{ Key = 'System.Value.Stopped'; Text = 'Stopped' }
        'Protected'   = @{ Key = 'System.Value.Protected'; Text = 'Protected' }
        'Unprotected' = @{ Key = 'System.Value.Unprotected'; Text = 'Unprotected' }
        'Activated'   = @{ Key = 'System.Value.Activated'; Text = 'Activated' }
        'NotActivated' = @{ Key = 'System.Value.NotActivated'; Text = 'Not activated' }
        'Healthy'     = @{ Key = 'System.Value.Healthy'; Text = 'Healthy' }
        'Warning'     = @{ Key = 'System.Value.Warning'; Text = 'Warning' }
        'Unhealthy'   = @{ Key = 'System.Value.Unhealthy'; Text = 'Unhealthy' }
        'Connected'   = @{ Key = 'System.Value.Connected'; Text = 'Connected' }
        'NotConnected' = @{ Key = 'System.Value.NotConnected'; Text = 'No Internet' }
        'Present'     = @{ Key = 'System.Value.Present'; Text = 'Present' }
        'NotPresent'  = @{ Key = 'System.Value.NotPresent'; Text = 'Not present' }
        'Ready'       = @{ Key = 'System.Value.Ready'; Text = 'Ready' }
        'NotReady'    = @{ Key = 'System.Value.NotReady'; Text = 'Not ready' }
        'Yes'         = @{ Key = 'System.Value.Yes'; Text = 'Yes' }
        'No'          = @{ Key = 'System.Value.No'; Text = 'No' }
        'Never'       = @{ Key = 'System.Value.Never'; Text = 'Never' }
        'NotPaused'   = @{ Key = 'System.Value.NotPaused'; Text = 'Not paused' }
        'CheckNotRun' = @{ Key = 'System.Value.CheckNotRun'; Text = 'Not checked' }
        'UpToDate'    = @{ Key = 'System.Value.UpToDate'; Text = 'Up to date' }
        'NotChecked'  = @{ Key = 'System.Value.NotChecked'; Text = 'Not checked' }
        'Unknown'     = @{ Key = 'System.Value.Unknown'; Text = 'Unknown' }
        'NotAvailable' = @{ Key = 'System.Value.NotAvailable'; Text = 'Not available' }
        'AcPower'     = @{ Key = 'System.Value.AcPower'; Text = 'On AC power' }
        'Charging'    = @{ Key = 'System.Value.Charging'; Text = 'Charging' }
        'Discharging' = @{ Key = 'System.Value.Discharging'; Text = 'Discharging' }
        'FullyCharged' = @{ Key = 'System.Value.FullyCharged'; Text = 'Fully charged' }
        'BatteryLow'  = @{ Key = 'System.Value.BatteryLow'; Text = 'Low' }
        'BatteryCritical' = @{ Key = 'System.Value.BatteryCritical'; Text = 'Critical' }
    }
    $valueKey = ''
    $valueText = [string]$State
    if ($states.ContainsKey($State)) {
        $valueKey = [string]$states[$State].Key
        $valueText = [string]$states[$State].Text
    }
    return New-SetupSystemRow -LabelKey $LabelKey -Label $Label -Value $valueText -ValueKey $valueKey -Detail $Detail -Tone $Tone
}

function New-SetupSystemSection {
    param(
        [string]$Id,
        [string]$TitleKey,
        [string]$Title,
        [object[]]$Rows = @()
    )
    return [pscustomobject]@{
        Id       = $Id
        TitleKey = $TitleKey
        Title    = $Title
        Rows     = @($Rows)
    }
}

function Format-SetupSystemDateTime {
    param($Value)
    if ($null -eq $Value) { return '' }
    try {
        $date = [datetime]$Value
        if ($date.Year -lt 2000) { return '' }
        return $date.ToString('yyyy-MM-dd HH:mm')
    } catch {
        return [string]$Value
    }
}

function Format-SetupSystemUptime {
    param($Hours)
    if ($null -eq $Hours) { return '' }
    $total = [double]$Hours
    if ($total -lt 1) { return ("{0} min" -f [math]::Round($total * 60, 0)) }
    if ($total -lt 24) { return ("{0:0.0} h" -f $total) }
    $days = [math]::Floor($total / 24)
    $rest = [math]::Round($total - ($days * 24), 0)
    return ("{0} d {1} h" -f $days, $rest)
}

function Format-SetupLinkSpeed {
    param($BitsPerSecond)
    if ($null -eq $BitsPerSecond) { return '' }
    try {
        $value = [double]$BitsPerSecond
    } catch {
        return [string]$BitsPerSecond
    }
    if ($value -le 0) { return '' }
    if ($value -ge 1000000000) { return ("{0:0.#} Gbps" -f ($value / 1000000000)) }
    if ($value -ge 1000000) { return ("{0:0.#} Mbps" -f ($value / 1000000)) }
    return ("{0:0} Kbps" -f ($value / 1000))
}

function Get-SetupWindowsUpdateStatus {
    <#
    .SYNOPSIS
        Reads the Windows Update service state and, when requested, searches
        for available updates through the Windows Update Agent COM API.
    #>
    [CmdletBinding()]
    param([switch]$CheckUpdates)

    $status = [ordered]@{
        Success       = $true
        Searched      = $false
        ServiceStatus = ''
        ServiceStart  = ''
        LastSearch    = ''
        LastInstall   = ''
        PausedUntil   = ''
        PendingReboot = $false
        Updates       = @()
        UpdateCount   = 0
        DriverCount   = 0
        Message       = ''
    }

    try {
        $service = Get-Service -Name 'wuauserv' -ErrorAction Stop
        $status.ServiceStatus = [string]$service.Status
        $status.ServiceStart = [string]$service.StartType
    } catch {
        $status.Success = $false
        $status.Message = $_.Exception.Message
    }

    try {
        $autoUpdate = New-Object -ComObject 'Microsoft.Update.AutoUpdate' -ErrorAction Stop
        $results = $autoUpdate.Results
        if ($null -ne $results) {
            $status.LastSearch = Format-SetupSystemDateTime $results.LastSearchSuccessDate
            $status.LastInstall = Format-SetupSystemDateTime $results.LastInstallationSuccessDate
        }
    } catch { }

    try {
        $settings = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction Stop
        if ($null -ne $settings.PauseUpdatesExpiryTime) {
            $paused = [datetime]$settings.PauseUpdatesExpiryTime
            if ($paused -gt (Get-Date)) { $status.PausedUntil = $paused.ToString('yyyy-MM-dd') }
        }
    } catch { }

    $status.PendingReboot = Test-SetupPendingReboot

    if ($CheckUpdates) {
        $status.Searched = $true
        Write-SetupLog -Level Info -Message 'Searching Windows Update for available updates.'
        try {
            $session = New-Object -ComObject 'Microsoft.Update.Session' -ErrorAction Stop
            $searcher = $session.CreateUpdateSearcher()
            $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
            $updates = [System.Collections.Generic.List[object]]::new()
            foreach ($update in @($result.Updates)) {
                $kb = ''
                try {
                    foreach ($id in @($update.KBArticleIDs)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
                            $kb = 'KB' + [string]$id
                            break
                        }
                    }
                } catch { }
                $sizeMB = $null
                try {
                    if ($null -ne $update.MaxDownloadSize) {
                        $sizeMB = [math]::Round(([double]$update.MaxDownloadSize / 1MB), 1)
                    }
                } catch { }
                $isDriver = $false
                try { $isDriver = ([int]$update.Type -eq 2) } catch { }
                $reboot = $false
                try { $reboot = [bool]$update.RebootRequired } catch { }
                $updates.Add([pscustomobject]@{
                    Title          = [string]$update.Title
                    KB             = $kb
                    SizeMB         = $sizeMB
                    IsDriver       = $isDriver
                    RebootRequired = $reboot
                })
            }
            $status.Updates = @($updates)
            $status.UpdateCount = @($updates | Where-Object { -not $_.IsDriver }).Count
            $status.DriverCount = @($updates | Where-Object { $_.IsDriver }).Count
            Write-SetupLog -Level Info -Message ("Windows Update search finished: {0} update(s), {1} driver update(s)." -f $status.UpdateCount, $status.DriverCount)
        } catch {
            $status.Success = $false
            $status.Message = $_.Exception.Message
            Write-SetupLog -Level Warning -Message ("Windows Update search failed: {0}" -f $_.Exception.Message)
        }
    }

    return [pscustomobject]$status
}

function Get-SetupSecurityStatus {
    <#
    .SYNOPSIS
        Read-only security status: Defender, firewall, Secure Boot, TPM,
        BitLocker, UAC and Windows activation.
    #>
    $status = [ordered]@{
        Success            = $true
        Defender           = 'Unknown'
        RealTimeProtection = 'Unknown'
        SignatureVersion   = ''
        SignatureUpdated   = ''
        FirewallDomain     = 'Unknown'
        FirewallPrivate    = 'Unknown'
        FirewallPublic     = 'Unknown'
        SecureBoot         = 'Unknown'
        TpmPresent         = 'Unknown'
        TpmReady           = 'Unknown'
        BitLocker          = 'Unknown'
        UacEnabled         = 'Unknown'
        Activation         = 'Unknown'
        ActivationName     = ''
        Message            = ''
    }

    $defenderCommand = Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($null -ne $defenderCommand) {
        try {
            $defender = Get-MpComputerStatus -ErrorAction Stop
            $status.Defender = if ($defender.AntivirusEnabled) { 'On' } else { 'Off' }
            $status.RealTimeProtection = if ($defender.RealTimeProtectionEnabled) { 'On' } else { 'Off' }
            $status.SignatureVersion = [string]$defender.AntivirusSignatureVersion
            $status.SignatureUpdated = Format-SetupSystemDateTime $defender.AntivirusSignatureLastUpdated
        } catch {
            $status.Defender = 'NotAvailable'
            $status.RealTimeProtection = 'NotAvailable'
        }
    } else {
        $status.Defender = 'NotAvailable'
        $status.RealTimeProtection = 'NotAvailable'
    }

    try {
        foreach ($profile in @(Get-NetFirewallProfile -ErrorAction Stop)) {
            $state = if ($profile.Enabled) { 'On' } else { 'Off' }
            switch ([string]$profile.Name) {
                'Domain' { $status.FirewallDomain = $state }
                'Private' { $status.FirewallPrivate = $state }
                'Public' { $status.FirewallPublic = $state }
            }
        }
    } catch { }

    $secureBootCommand = Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
    if ($null -eq $secureBootCommand) {
        $status.SecureBoot = 'NotAvailable'
    } else {
        try {
            $status.SecureBoot = if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'On' } else { 'Off' }
        } catch {
            $status.SecureBoot = 'NotAvailable'
        }
    }

    $tpmCommand = Get-Command Get-Tpm -ErrorAction SilentlyContinue
    if ($null -ne $tpmCommand) {
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            $status.TpmPresent = if ($tpm.TpmPresent) { 'Present' } else { 'NotPresent' }
            if ($tpm.TpmPresent) {
                $status.TpmReady = if ($tpm.TpmReady) { 'Ready' } else { 'NotReady' }
            } else {
                $status.TpmReady = 'NotAvailable'
            }
        } catch {
            $status.TpmPresent = 'NotAvailable'
            $status.TpmReady = 'NotAvailable'
        }
    } else {
        $status.TpmPresent = 'NotAvailable'
        $status.TpmReady = 'NotAvailable'
    }

    $bitLockerCommand = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
    if ($null -ne $bitLockerCommand) {
        try {
            $systemDrive = if ([string]::IsNullOrWhiteSpace([string]$env:SystemDrive)) { 'C:' } else { [string]$env:SystemDrive }
            $volume = Get-BitLockerVolume -MountPoint $systemDrive -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $volume) {
                $status.BitLocker = if ([string]$volume.ProtectionStatus -eq 'On') { 'Protected' } else { 'Unprotected' }
            }
        } catch {
            $status.BitLocker = 'NotAvailable'
        }
    } else {
        $status.BitLocker = 'NotAvailable'
    }

    try {
        $policies = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
        if ($null -ne $policies.EnableLUA) {
            $status.UacEnabled = if ([int]$policies.EnableLUA -ne 0) { 'On' } else { 'Off' }
        }
    } catch { }

    try {
        $license = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter 'PartialProductKey IS NOT NULL' -ErrorAction Stop |
            Where-Object { [string]$_.Name -like 'Windows*' } | Select-Object -First 1
        if ($null -ne $license) {
            $status.Activation = if ([int]$license.LicenseStatus -eq 1) { 'Activated' } else { 'NotActivated' }
            $status.ActivationName = [string]$license.Name
        }
    } catch { }

    return [pscustomobject]$status
}

function Get-SetupStorageStatus {
    <#
    .SYNOPSIS
        Read-only storage report: volumes, free space and physical disk health.
    #>
    $status = [ordered]@{
        Success      = $true
        StorageSense = 'Unknown'
        Volumes      = @()
        Disks        = @()
        Message      = ''
    }

    try {
        $volumes = [System.Collections.Generic.List[object]]::new()
        foreach ($volume in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)) {
            $size = if ($null -ne $volume.Size) { [double]$volume.Size } else { 0 }
            $free = if ($null -ne $volume.FreeSpace) { [double]$volume.FreeSpace } else { 0 }
            $freeGB = [math]::Round(($free / 1GB), 1)
            $totalGB = [math]::Round(($size / 1GB), 1)
            $percent = if ($size -gt 0) { [int][math]::Round(($free / $size) * 100, 0) } else { 0 }
            $tone = 'Ok'
            if ($percent -lt 5 -or $freeGB -lt 5) { $tone = 'Error' }
            elseif ($percent -lt 12 -or $freeGB -lt 15) { $tone = 'Warning' }
            $volumes.Add([pscustomobject]@{
                DeviceID    = [string]$volume.DeviceID
                VolumeName  = [string]$volume.VolumeName
                FileSystem  = [string]$volume.FileSystem
                FreeGB      = $freeGB
                TotalGB     = $totalGB
                FreePercent = $percent
                Tone        = $tone
            })
        }
        $status.Volumes = @($volumes)
    } catch {
        $status.Success = $false
        $status.Message = $_.Exception.Message
    }

    try {
        $disks = [System.Collections.Generic.List[object]]::new()
        $physicalCommand = Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue
        if ($null -ne $physicalCommand) {
            foreach ($disk in @(Get-PhysicalDisk -ErrorAction Stop)) {
                $health = [string]$disk.HealthStatus
                $tone = switch ($health) {
                    'Healthy' { 'Ok' }
                    'Warning' { 'Warning' }
                    'Unhealthy' { 'Error' }
                    default { 'Muted' }
                }
                $operations = @($disk.OperationalStatus | ForEach-Object { [string]$_ }) -join ', '
                $disks.Add([pscustomobject]@{
                    Name              = [string]$disk.FriendlyName
                    MediaType         = [string]$disk.MediaType
                    Health            = $health
                    OperationalStatus = $operations
                    SizeGB            = [math]::Round(([double]$disk.Size / 1GB), 1)
                    Tone              = $tone
                })
            }
        } else {
            foreach ($disk in @(Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' -ClassName MSFT_PhysicalDisk -ErrorAction Stop)) {
                $health = switch ([int]$disk.HealthStatus) {
                    0 { 'Healthy' }
                    1 { 'Warning' }
                    2 { 'Unhealthy' }
                    default { 'Unknown' }
                }
                $media = switch ([int]$disk.MediaType) {
                    3 { 'HDD' }
                    4 { 'SSD' }
                    5 { 'SCM' }
                    default { 'Unspecified' }
                }
                $tone = switch ($health) {
                    'Healthy' { 'Ok' }
                    'Warning' { 'Warning' }
                    'Unhealthy' { 'Error' }
                    default { 'Muted' }
                }
                $disks.Add([pscustomobject]@{
                    Name              = [string]$disk.FriendlyName
                    MediaType         = $media
                    Health            = $health
                    OperationalStatus = (@($disk.OperationalStatus | ForEach-Object { [string]$_ }) -join ', ')
                    SizeGB            = [math]::Round(([double]$disk.Size / 1GB), 1)
                    Tone              = $tone
                })
            }
        }
        $status.Disks = @($disks)
    } catch { }

    try {
        $policy = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -ErrorAction Stop
        if ($null -ne $policy.'01') {
            $status.StorageSense = if ([int]$policy.'01' -ne 0) { 'On' } else { 'Off' }
        } else {
            $status.StorageSense = 'Off'
        }
    } catch {
        $status.StorageSense = 'Off'
    }

    return [pscustomobject]$status
}

function Get-SetupNetworkStatus {
    <#
    .SYNOPSIS
        Read-only network report: Internet reachability and active adapters.
    #>
    [CmdletBinding()]
    param([switch]$SkipInternet)

    $status = [ordered]@{
        Success  = $true
        Internet = 'NotChecked'
        Adapters = @()
        Message  = ''
    }

    if (-not $SkipInternet) {
        $status.Internet = 'Unknown'
        try {
            $ping = [System.Net.NetworkInformation.Ping]::new()
            $reply = $ping.Send('1.1.1.1', 1500)
            $status.Internet = if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { 'Connected' } else { 'NotConnected' }
        } catch {
            $status.Internet = 'Unknown'
        }
    }

    try {
        $adapters = [System.Collections.Generic.List[object]]::new()
        $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)
        foreach ($adapter in @(Get-NetAdapter -ErrorAction Stop)) {
            if ($adapter.Status -ne 'Up') { continue }
            if ([string]$adapter.InterfaceDescription -match 'Loopback') { continue }
            if ([string]$adapter.Name -match '^vEthernet') { continue }
            try {
                $config = $configs | Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex } | Select-Object -First 1
                $ipv4 = ''
                $ipv6 = ''
                $gateway = ''
                $dns = ''
                if ($null -ne $config) {
                    $ipv4 = (@($config.IPv4Address | ForEach-Object { [string]$_.IPAddress }) -join ', ')
                    $ipv6 = (@($config.IPv6Address | ForEach-Object { [string]$_.IPAddress }) -join ', ')
                    $gateway = (@($config.IPv4DefaultGateway | ForEach-Object { [string]$_.NextHop }) -join ', ')
                    $dns = (@($config.DNSServer | ForEach-Object { $_.ServerAddresses }) -join ', ')
                }
                $speedValue = $adapter.Speed
                if ($null -eq $speedValue) { $speedValue = $adapter.LinkSpeed }
                $adapters.Add([pscustomobject]@{
                    Name        = [string]$adapter.Name
                    Description = [string]$adapter.InterfaceDescription
                    IPv4        = $ipv4
                    IPv6        = $ipv6
                    Gateway     = $gateway
                    Dns         = $dns
                    LinkSpeed   = (Format-SetupLinkSpeed $speedValue)
                    MacAddress  = [string]$adapter.MacAddress
                })
            } catch { }
        }
        $status.Adapters = @($adapters)
    } catch {
        $status.Success = $false
        $status.Message = $_.Exception.Message
    }

    return [pscustomobject]$status
}

function Get-SetupPowerStatus {
    <#
    .SYNOPSIS
        Read-only power report: active plan, battery, hibernation and fast startup.
    #>
    $status = [ordered]@{
        Success        = $true
        ActivePlan     = ''
        ActivePlanGuid = ''
        ActivePlanKey  = ''
        AvailablePlans = @()
        BatteryPresent = $false
        BatteryPercent = $null
        BatteryState   = 'Unknown'
        Hibernate      = 'Unknown'
        FastStartup    = 'Unknown'
        Message        = ''
    }

    try {
        $plan = Get-CimInstance -Namespace 'root\cimv2\power' -ClassName Win32_PowerPlan -Filter 'IsActive=True' -ErrorAction Stop |
            Select-Object -First 1
        if ($null -ne $plan) { $status.ActivePlan = [string]$plan.ElementName }
    } catch { }

    try {
        $scheme = (& powercfg.exe /getactivescheme 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace([string]$status.ActivePlan) -and ($scheme -match '\(([^)]+)\)')) {
            $status.ActivePlan = $matches[1]
        }
        if ($scheme -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $status.ActivePlanGuid = $matches[1].ToLowerInvariant()
        }
    } catch { }

    $status.ActivePlanKey = switch ($status.ActivePlanGuid) {
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' { 'HighPerformance' }
        'a1841308-3541-4fab-bc81-f71556f20b4a' { 'PowerSaver' }
        '381b4222-f694-41f0-9685-ff5bb260df2e' { 'Balanced' }
        default { '' }
    }

    try {
        $planList = (& powercfg.exe /list 2>$null | Out-String)
        $availablePlans = [System.Collections.Generic.List[string]]::new()
        if ($planList -match '381b4222-f694-41f0-9685-ff5bb260df2e') { $availablePlans.Add('Balanced') }
        if ($planList -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') { $availablePlans.Add('HighPerformance') }
        if ($planList -match 'a1841308-3541-4fab-bc81-f71556f20b4a') { $availablePlans.Add('PowerSaver') }
        $status.AvailablePlans = @($availablePlans)
    } catch { }

    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $battery) {
            $status.BatteryPresent = $true
            if ($null -ne $battery.EstimatedChargeRemaining) {
                $status.BatteryPercent = [int]$battery.EstimatedChargeRemaining
            }
            $status.BatteryState = switch ([int]$battery.BatteryStatus) {
                1 { 'Discharging' }
                2 { 'AcPower' }
                3 { 'FullyCharged' }
                4 { 'BatteryLow' }
                5 { 'BatteryCritical' }
                6 { 'Charging' }
                7 { 'Charging' }
                8 { 'Charging' }
                9 { 'Charging' }
                11 { 'Charging' }
                default { 'Unknown' }
            }
        }
    } catch { }

    try {
        $power = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop
        if ($null -ne $power.HibernateEnabled) {
            $status.Hibernate = if ([int]$power.HibernateEnabled -ne 0) { 'On' } else { 'Off' }
        } elseif ($null -ne $power.HibernateEnabledDefault) {
            $status.Hibernate = if ([int]$power.HibernateEnabledDefault -ne 0) { 'On' } else { 'Off' }
        }
    } catch { }

    try {
        $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop
        if ($null -ne $session.HiberbootEnabled) {
            $status.FastStartup = if ([int]$session.HiberbootEnabled -ne 0) { 'On' } else { 'Off' }
        }
    } catch { }

    return [pscustomobject]$status
}

function Get-SetupFeatureStatus {
    <#
    .SYNOPSIS
        Read-only status of selected Windows optional features and developer
        settings. Requires elevation for the optional-feature list.
    #>
    $status = [ordered]@{
        Success       = $true
        Features      = @()
        LongPaths     = 'Unknown'
        DeveloperMode = 'Unknown'
        Message       = ''
    }

    $wanted = @(
        [pscustomobject]@{ Name = 'NetFx3'; LabelKey = 'System.Row.FeatureNetFx3'; Label = '.NET Framework 3.5' }
        [pscustomobject]@{ Name = 'Microsoft-Windows-Subsystem-Linux'; LabelKey = 'System.Row.FeatureWsl'; Label = 'Windows Subsystem for Linux' }
        [pscustomobject]@{ Name = 'VirtualMachinePlatform'; LabelKey = 'System.Row.FeatureVmPlatform'; Label = 'Virtual Machine Platform' }
        [pscustomobject]@{ Name = 'Microsoft-Hyper-V-All'; LabelKey = 'System.Row.FeatureHyperV'; Label = 'Hyper-V' }
        [pscustomobject]@{ Name = 'Containers-DisposableClientVM'; LabelKey = 'System.Row.FeatureSandbox'; Label = 'Windows Sandbox' }
    )

    $available = @{}
    $featureCommand = Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue
    if ($null -ne $featureCommand) {
        try {
            foreach ($feature in @(Get-WindowsOptionalFeature -Online -ErrorAction Stop)) {
                $available[[string]$feature.FeatureName] = [string]$feature.State
            }
        } catch {
            $status.Success = $false
            $status.Message = $_.Exception.Message
        }
    } else {
        $status.Success = $false
        $status.Message = 'The optional-feature cmdlets are not available.'
    }

    $features = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $wanted) {
        $state = 'Unknown'
        if ($available.ContainsKey($item.Name)) {
            $raw = [string]$available[$item.Name]
            if ($raw -eq 'Enabled') { $state = 'On' }
            elseif ($raw -eq 'Disabled') { $state = 'Off' }
        }
        $features.Add([pscustomobject]@{
            Name     = $item.Name
            LabelKey = $item.LabelKey
            Label    = $item.Label
            State    = $state
        })
    }
    $status.Features = @($features)

    try {
        $filesystem = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction Stop
        if ($null -ne $filesystem.LongPathsEnabled) {
            $status.LongPaths = if ([int]$filesystem.LongPathsEnabled -ne 0) { 'On' } else { 'Off' }
        } else {
            $status.LongPaths = 'Off'
        }
    } catch {
        $status.LongPaths = 'Off'
    }

    try {
        $developer = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction Stop
        if ($null -ne $developer.AllowDevelopmentWithoutDevLicense) {
            $status.DeveloperMode = if ([int]$developer.AllowDevelopmentWithoutDevLicense -ne 0) { 'On' } else { 'Off' }
        } else {
            $status.DeveloperMode = 'Off'
        }
    } catch {
        $status.DeveloperMode = 'Off'
    }

    return [pscustomobject]$status
}

function Get-SetupSystemDashboard {
    <#
    .SYNOPSIS
        Builds the read-only System dashboard shared by both front-ends.
    .PARAMETER CheckWindowsUpdate
        Run an online Windows Update search. This can take several minutes and
        is never enabled by default.
    .PARAMETER SkipInternet
        Skip the Internet reachability probe (used by offline tests).
    #>
    [CmdletBinding()]
    param(
        [switch]$CheckWindowsUpdate,
        [switch]$SkipInternet
    )

    $info = Get-SetupSystemInfo
    $update = Get-SetupWindowsUpdateStatus -CheckUpdates:$CheckWindowsUpdate
    $security = Get-SetupSecurityStatus
    $storage = Get-SetupStorageStatus
    $network = Get-SetupNetworkStatus -SkipInternet:$SkipInternet
    $power = Get-SetupPowerStatus
    $features = Get-SetupFeatureStatus

    $overviewRows = [System.Collections.Generic.List[object]]::new()

    $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.ComputerName' -Label 'Computer name' -Value $info.ComputerName))
    $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.User' -Label 'Signed-in user' -Value $info.UserName))
    if ([string]::IsNullOrWhiteSpace([string]$info.OSName)) {
        $overviewRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Windows' -Label 'Windows' -State 'NotAvailable' -Tone 'Muted'))
    } else {
        $windowsParts = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$info.DisplayVersion)) { $windowsParts += ("Version {0}" -f $info.DisplayVersion) }
        if (-not [string]::IsNullOrWhiteSpace([string]$info.OSBuild)) { $windowsParts += ("Build {0}" -f $info.OSBuild) }
        if (-not [string]::IsNullOrWhiteSpace([string]$info.Architecture)) { $windowsParts += [string]$info.Architecture }
        $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.Windows' -Label 'Windows' -Value $info.OSName -Detail ($windowsParts -join ' | ')))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$info.TimeZone)) {
        $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.TimeZone' -Label 'Time zone' `
            -Value $info.TimeZone -Detail $info.TimeZoneDisplay))
    }

    $machine = (@([string]$info.Manufacturer, [string]$info.Model) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
    if ([string]::IsNullOrWhiteSpace($machine)) {
        $overviewRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Machine' -Label 'Manufacturer / model' -State 'NotAvailable' -Tone 'Muted'))
    } else {
        $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.Machine' -Label 'Manufacturer / model' -Value $machine))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$info.Domain)) {
        $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.Domain' -Label 'Domain / workgroup' -Value $info.Domain))
    }

    if ([string]::IsNullOrWhiteSpace([string]$info.CPUName)) {
        $overviewRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Cpu' -Label 'Processor' -State 'NotAvailable' -Tone 'Muted'))
    } else {
        $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.Cpu' -Label 'Processor' -Value $info.CPUName))
        if ($null -ne $info.CPUCores) {
            $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.CpuCores' -Label 'Processor cores' -Value ([string]$info.CPUCores)))
        }
        if ($null -ne $info.CPULogicalProcessors) {
            $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.CpuThreads' -Label 'Logical processors' -Value ([string]$info.CPULogicalProcessors)))
        }
    }

    if ($null -ne $info.RAMGB) {
        $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.Ram' -Label 'Memory' -Value ("{0} GB" -f $info.RAMGB)))
    } else {
        $overviewRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Ram' -Label 'Memory' -State 'NotAvailable' -Tone 'Muted'))
    }

    $uptime = Format-SetupSystemUptime $info.UptimeHours
    if ([string]::IsNullOrWhiteSpace($uptime)) {
        $overviewRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Uptime' -Label 'Uptime' -State 'NotAvailable' -Tone 'Muted'))
    } else {
        $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.Uptime' -Label 'Uptime' -Value $uptime -Detail $info.LastBootTime))
    }

    $overviewRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.PendingRestart' -Label 'Pending restart' `
        -State $(if ($info.PendingReboot) { 'Yes' } else { 'No' }) -Tone $(if ($info.PendingReboot) { 'Warning' } else { 'Ok' })))
    $overviewRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Admin' -Label 'Administrator session' `
        -State $(if ($info.IsAdministrator) { 'Yes' } else { 'No' }) -Tone $(if ($info.IsAdministrator) { 'Ok' } else { 'Warning' })))
    $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.PowerShell' -Label 'PowerShell' -Value $info.PowerShellVersion))
    if ([string]::IsNullOrWhiteSpace([string]$info.WingetVersion)) {
        $overviewRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Winget' -Label 'Winget' -State 'NotAvailable' -Tone 'Muted'))
    } else {
        $overviewRows.Add((New-SetupSystemRow -LabelKey 'System.Row.Winget' -Label 'Winget' -Value $info.WingetVersion))
    }

    $updateRows = [System.Collections.Generic.List[object]]::new()
    if ($update.ServiceStatus -eq 'Running' -or $update.ServiceStatus -eq 'Stopped') {
        if ($update.ServiceStatus -eq 'Running') { $serviceTone = 'Ok' }
        elseif ($update.ServiceStart -eq 'Manual') { $serviceTone = 'Info' }
        else { $serviceTone = 'Warning' }
        $serviceDetail = if (-not [string]::IsNullOrWhiteSpace([string]$update.ServiceStart)) { ("Start type: {0}" -f $update.ServiceStart) } else { '' }
        $updateRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.UpdateService' -Label 'Windows Update service' `
            -State $update.ServiceStatus -Tone $serviceTone -Detail $serviceDetail))
    } else {
        $updateRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.UpdateService' -Label 'Windows Update service' -State 'NotAvailable' -Tone 'Muted'))
    }
    if ([string]::IsNullOrWhiteSpace([string]$update.LastSearch)) {
        $updateRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.LastSearch' -Label 'Last update search' -State 'Never' -Tone 'Muted'))
    } else {
        $updateRows.Add((New-SetupSystemRow -LabelKey 'System.Row.LastSearch' -Label 'Last update search' -Value $update.LastSearch))
    }
    if ([string]::IsNullOrWhiteSpace([string]$update.LastInstall)) {
        $updateRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.LastInstall' -Label 'Last update install' -State 'Never' -Tone 'Muted'))
    } else {
        $updateRows.Add((New-SetupSystemRow -LabelKey 'System.Row.LastInstall' -Label 'Last update install' -Value $update.LastInstall))
    }
    if ([string]::IsNullOrWhiteSpace([string]$update.PausedUntil)) {
        $updateRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Paused' -Label 'Updates paused' -State 'NotPaused' -Tone 'Ok'))
    } else {
        $updateRows.Add((New-SetupSystemRow -LabelKey 'System.Row.Paused' -Label 'Updates paused' -Value $update.PausedUntil -Tone 'Warning'))
    }

    if (-not $update.Searched) {
        $updateRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.AvailableUpdates' -Label 'Available updates' -State 'CheckNotRun' -Tone 'Muted'))
        $updateRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.DriverUpdates' -Label 'Driver updates' -State 'CheckNotRun' -Tone 'Muted'))
    } elseif (-not $update.Success) {
        $updateRows.Add((New-SetupSystemRow -LabelKey 'System.Row.AvailableUpdates' -Label 'Available updates' -Value $update.Message -Tone 'Error'))
        $updateRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.DriverUpdates' -Label 'Driver updates' -State 'Unknown' -Tone 'Muted'))
    } else {
        if ($update.UpdateCount -eq 0) {
            $updateRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.AvailableUpdates' -Label 'Available updates' -State 'UpToDate' -Tone 'Ok'))
        } else {
            $titles = @($update.Updates | Where-Object { -not $_.IsDriver } | Select-Object -First 6 | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace([string]$_.KB)) { ("{0} {1}" -f $_.KB, $_.Title) } else { [string]$_.Title }
            })
            $updateRows.Add((New-SetupSystemRow -LabelKey 'System.Row.AvailableUpdates' -Label 'Available updates' `
                -Value ([string]$update.UpdateCount) -Tone 'Warning' -Detail ($titles -join '; ')))
        }
        if ($update.DriverCount -eq 0) {
            $updateRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.DriverUpdates' -Label 'Driver updates' -State 'UpToDate' -Tone 'Ok'))
        } else {
            $driverTitles = @($update.Updates | Where-Object { $_.IsDriver } | Select-Object -First 6 | ForEach-Object { [string]$_.Title })
            $updateRows.Add((New-SetupSystemRow -LabelKey 'System.Row.DriverUpdates' -Label 'Driver updates' `
                -Value ([string]$update.DriverCount) -Tone 'Warning' -Detail ($driverTitles -join '; ')))
        }
    }

    $securityRows = [System.Collections.Generic.List[object]]::new()
    $defenderTone = switch ($security.Defender) { 'On' { 'Ok' } 'Off' { 'Warning' } default { 'Muted' } }
    $securityRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Defender' -Label 'Defender antivirus' -State $security.Defender -Tone $defenderTone))
    $realTimeTone = switch ($security.RealTimeProtection) { 'On' { 'Ok' } 'Off' { 'Warning' } default { 'Muted' } }
    $securityRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.RealTime' -Label 'Real-time protection' -State $security.RealTimeProtection -Tone $realTimeTone))
    if ([string]::IsNullOrWhiteSpace([string]$security.SignatureVersion)) {
        $securityRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Signature' -Label 'Antivirus signatures' -State 'NotAvailable' -Tone 'Muted'))
    } else {
        $securityRows.Add((New-SetupSystemRow -LabelKey 'System.Row.Signature' -Label 'Antivirus signatures' `
            -Value $security.SignatureVersion -Detail $security.SignatureUpdated))
    }
    foreach ($firewall in @(
            @{ Key = 'System.Row.FirewallDomain'; Label = 'Firewall (domain)'; State = $security.FirewallDomain }
            @{ Key = 'System.Row.FirewallPrivate'; Label = 'Firewall (private)'; State = $security.FirewallPrivate }
            @{ Key = 'System.Row.FirewallPublic'; Label = 'Firewall (public)'; State = $security.FirewallPublic })) {
        $tone = switch ([string]$firewall.State) { 'On' { 'Ok' } 'Off' { 'Warning' } default { 'Muted' } }
        $securityRows.Add((New-SetupSystemStateRow -LabelKey $firewall.Key -Label $firewall.Label -State $firewall.State -Tone $tone))
    }
    $secureBootTone = switch ($security.SecureBoot) { 'On' { 'Ok' } 'Off' { 'Warning' } default { 'Muted' } }
    $securityRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.SecureBoot' -Label 'Secure Boot' -State $security.SecureBoot -Tone $secureBootTone))
    $tpmTone = switch ($security.TpmPresent) {
        'Present' { if ($security.TpmReady -eq 'Ready') { 'Ok' } else { 'Warning' } }
        'NotPresent' { 'Muted' }
        default { 'Muted' }
    }
    $securityRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Tpm' -Label 'TPM' -State $security.TpmPresent -Tone $tpmTone))
    $securityRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.TpmReady' -Label 'TPM ready' -State $security.TpmReady `
        -Tone $(if ($security.TpmReady -eq 'Ready') { 'Ok' } elseif ($security.TpmReady -eq 'NotReady') { 'Warning' } else { 'Muted' })))
    $bitLockerTone = switch ($security.BitLocker) { 'Protected' { 'Ok' } 'Unprotected' { 'Warning' } default { 'Muted' } }
    $securityRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.BitLocker' -Label 'BitLocker (system drive)' -State $security.BitLocker -Tone $bitLockerTone))
    $uacTone = switch ($security.UacEnabled) { 'On' { 'Ok' } 'Off' { 'Warning' } default { 'Muted' } }
    $securityRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Uac' -Label 'User Account Control' -State $security.UacEnabled -Tone $uacTone))
    $activationTone = switch ($security.Activation) { 'Activated' { 'Ok' } 'NotActivated' { 'Error' } default { 'Muted' } }
    $securityRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Activation' -Label 'Windows activation' `
        -State $security.Activation -Tone $activationTone -Detail $security.ActivationName))

    $storageRows = [System.Collections.Generic.List[object]]::new()
    $storageSenseTone = switch ($storage.StorageSense) {
        'On' { 'Ok' }
        'Off' { 'Muted' }
        default { 'Muted' }
    }
    $storageRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.StorageSense' -Label 'Storage Sense' `
        -State $storage.StorageSense -Tone $storageSenseTone))
    foreach ($volume in @($storage.Volumes)) {
        $volumeLabel = [string]$volume.DeviceID
        if (-not [string]::IsNullOrWhiteSpace([string]$volume.VolumeName)) {
            $volumeLabel = ("{0} ({1})" -f $volume.DeviceID, $volume.VolumeName)
        }
        $volumeValue = ("{0:0.0} GB / {1:0.0} GB ({2}%)" -f $volume.FreeGB, $volume.TotalGB, $volume.FreePercent)
        $storageRows.Add((New-SetupSystemRow -Label $volumeLabel -Value $volumeValue -Tone $volume.Tone -Detail $volume.FileSystem))
    }
    foreach ($disk in @($storage.Disks)) {
        $detailParts = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$disk.MediaType)) { $detailParts += $disk.MediaType }
        if (-not [string]::IsNullOrWhiteSpace([string]$disk.Health)) { $detailParts += $disk.Health }
        if (-not [string]::IsNullOrWhiteSpace([string]$disk.OperationalStatus)) { $detailParts += $disk.OperationalStatus }
        $storageRows.Add((New-SetupSystemRow -Label $disk.Name -Value ("{0:0.0} GB" -f $disk.SizeGB) `
            -Tone $disk.Tone -Detail ($detailParts -join ' | ')))
    }
    if ($storageRows.Count -eq 0) {
        $storageRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Storage' -Label 'Storage' -State 'NotAvailable' -Tone 'Muted'))
    }

    $networkRows = [System.Collections.Generic.List[object]]::new()
    $internetTone = switch ($network.Internet) { 'Connected' { 'Ok' } 'NotConnected' { 'Warning' } default { 'Muted' } }
    $networkRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Internet' -Label 'Internet access' -State $network.Internet -Tone $internetTone))
    foreach ($adapter in @($network.Adapters)) {
        $address = [string]$adapter.IPv4
        $valueKey = ''
        if ([string]::IsNullOrWhiteSpace($address)) {
            $address = [string]$adapter.IPv6
        }
        if ([string]::IsNullOrWhiteSpace($address)) {
            $address = 'NotAvailable'
            $valueKey = 'System.Value.NotAvailable'
        }
        $adapterParts = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$adapter.Gateway)) { $adapterParts += ("GW {0}" -f $adapter.Gateway) }
        if (-not [string]::IsNullOrWhiteSpace([string]$adapter.Dns)) { $adapterParts += ("DNS {0}" -f $adapter.Dns) }
        if (-not [string]::IsNullOrWhiteSpace([string]$adapter.LinkSpeed)) { $adapterParts += $adapter.LinkSpeed }
        $networkRows.Add((New-SetupSystemRow -Label $adapter.Name -Value $address -ValueKey $valueKey -Detail ($adapterParts -join ' | ')))
    }
    if (@($network.Adapters).Count -eq 0) {
        $networkRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Adapter' -Label 'Active adapter' -State 'NotAvailable' -Tone 'Muted'))
    }

    $powerRows = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace([string]$power.ActivePlan)) {
        $powerRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.PowerPlan' -Label 'Power plan' -State 'NotAvailable' -Tone 'Muted'))
    } else {
        $powerRows.Add((New-SetupSystemRow -LabelKey 'System.Row.PowerPlan' -Label 'Power plan' -Value $power.ActivePlan))
    }
    if ($power.BatteryPresent -and $null -ne $power.BatteryPercent) {
        $batteryTone = if ($power.BatteryPercent -le 20) { 'Warning' } else { 'Info' }
        $powerRows.Add((New-SetupSystemRow -LabelKey 'System.Row.Battery' -Label 'Battery charge' -Value ("{0}%" -f $power.BatteryPercent) -Tone $batteryTone))
    } else {
        $powerRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Battery' -Label 'Battery charge' -State 'NotAvailable' -Tone 'Muted'))
    }
    $powerRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.BatteryState' -Label 'Battery state' -State $power.BatteryState `
        -Tone $(if ($power.BatteryState -in @('BatteryLow', 'BatteryCritical')) { 'Warning' } else { 'Info' })))
    $powerRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.Hibernate' -Label 'Hibernation' -State $power.Hibernate `
        -Tone $(if ($power.Hibernate -eq 'On') { 'Info' } else { 'Muted' })))
    $powerRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.FastStartup' -Label 'Fast startup' -State $power.FastStartup `
        -Tone $(if ($power.FastStartup -eq 'On') { 'Info' } else { 'Muted' })))

    $featureRows = [System.Collections.Generic.List[object]]::new()
    foreach ($feature in @($features.Features)) {
        $featureTone = switch ($feature.State) { 'On' { 'Ok' } 'Off' { 'Muted' } default { 'Info' } }
        $featureRows.Add((New-SetupSystemStateRow -LabelKey $feature.LabelKey -Label $feature.Label -State $feature.State -Tone $featureTone))
    }
    $featureRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.LongPaths' -Label 'Long path support' -State $features.LongPaths `
        -Tone $(if ($features.LongPaths -eq 'On') { 'Ok' } else { 'Muted' })))
    $featureRows.Add((New-SetupSystemStateRow -LabelKey 'System.Row.DeveloperMode' -Label 'Developer Mode' -State $features.DeveloperMode `
        -Tone $(if ($features.DeveloperMode -eq 'On') { 'Ok' } else { 'Muted' })))

    $sections = @(
        (New-SetupSystemSection -Id 'overview' -TitleKey 'System.Section.Overview' -Title 'Overview' -Rows $overviewRows.ToArray())
        (New-SetupSystemSection -Id 'windowsupdate' -TitleKey 'System.Section.WindowsUpdate' -Title 'Windows Update' -Rows $updateRows.ToArray())
        (New-SetupSystemSection -Id 'security' -TitleKey 'System.Section.Security' -Title 'Security' -Rows $securityRows.ToArray())
        (New-SetupSystemSection -Id 'storage' -TitleKey 'System.Section.Storage' -Title 'Storage' -Rows $storageRows.ToArray())
        (New-SetupSystemSection -Id 'network' -TitleKey 'System.Section.Network' -Title 'Network' -Rows $networkRows.ToArray())
        (New-SetupSystemSection -Id 'power' -TitleKey 'System.Section.Power' -Title 'Power' -Rows $powerRows.ToArray())
        (New-SetupSystemSection -Id 'features' -TitleKey 'System.Section.Features' -Title 'Windows features' -Rows $featureRows.ToArray())
    )

    $allRows = @($sections | ForEach-Object { @($_.Rows) })
    $warningCount = @($allRows | Where-Object { $_.Tone -eq 'Warning' }).Count
    $errorCount = @($allRows | Where-Object { $_.Tone -eq 'Error' }).Count

    return [pscustomobject]@{
        Success              = $true
        GeneratedAt          = (Get-Date).ToString('o')
        IncludeWindowsUpdate = [bool]$CheckWindowsUpdate
        Overview             = $info
        WindowsUpdate        = $update
        Security             = $security
        Storage              = $storage
        Network              = $network
        Power                = $power
        Features             = $features
        Sections             = $sections
        Summary              = [pscustomobject]@{
            SectionCount = @($sections).Count
            RowCount     = $allRows.Count
            WarningCount = $warningCount
            ErrorCount   = $errorCount
        }
        WarningCount         = $warningCount
        ErrorCount           = $errorCount
    }
}

function Export-SetupSystemReport {
    <#
    .SYNOPSIS
        Writes the read-only System dashboard to HTML, JSON or CSV.
    #>
    param(
        $Dashboard = $null,
        [string]$Directory = '',
        [string]$BaseName = 'system-report',
        [ValidateSet('Html', 'Json', 'Csv')][string]$Format = 'Html'
    )

    if ($null -eq $Dashboard) { $Dashboard = Get-SetupSystemDashboard }
    if ($null -eq $Dashboard -or $null -eq $Dashboard.PSObject.Properties['Sections']) {
        return New-SetupResult -Name 'System report' -Success $false -Message 'The system dashboard is empty.'
    }
    if ([string]::IsNullOrWhiteSpace($Directory)) {
        $Directory = Join-Path (Get-SetupRootPath) 'Logs'
    }
    try {
        New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
    } catch {
        return New-SetupResult -Name 'System report' -Success $false `
            -Message ("Could not create the report folder: {0}" -f $_.Exception.Message)
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeBase = ($BaseName -replace '[^\w\-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeBase)) { $safeBase = 'system-report' }
    $path = Join-Path $Directory ("{0}-{1}.{2}" -f $safeBase, $stamp, $Format.ToLowerInvariant())

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($section in @($Dashboard.Sections)) {
        foreach ($row in @($section.Rows)) {
            $label = [string]$row.Label
            if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$row.LabelKey }
            $value = [string]$row.Value
            if ([string]::IsNullOrWhiteSpace($value) -and -not [string]::IsNullOrWhiteSpace([string]$row.ValueKey)) { $value = [string]$row.ValueKey }
            $rows.Add([pscustomobject]@{
                Section = [string]$section.Title
                Item    = $label
                Value   = $value
                Detail  = [string]$row.Detail
                Tone    = [string]$row.Tone
            })
        }
    }

    try {
        switch ($Format) {
            'Csv' {
                $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
            }
            'Json' {
                [pscustomobject]@{
                    GeneratedAt  = [string]$Dashboard.GeneratedAt
                    WarningCount = [int]$Dashboard.WarningCount
                    ErrorCount   = [int]$Dashboard.ErrorCount
                    Sections     = @($Dashboard.Sections)
                } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
            }
            default {
                $encode = { param([string]$text) [System.Net.WebUtility]::HtmlEncode($text) }
                $builder = [System.Text.StringBuilder]::new()
                [void]$builder.AppendLine('<!DOCTYPE html>')
                [void]$builder.AppendLine('<html lang="en"><head><meta charset="utf-8">')
                [void]$builder.AppendLine('<title>Windows Automatic Setup - System report</title>')
                [void]$builder.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1f24;background:#f4f6f8}h1{font-size:22px}h2{font-size:16px;margin-top:24px}table{border-collapse:collapse;width:100%;background:#fff}th,td{border:1px solid #d7dce2;padding:7px 9px;text-align:left;font-size:13px;vertical-align:top}th{background:#eef3f8;width:220px}tr:nth-child(even) td{background:#fafbfc}.ok{color:#107c10}.bad{color:#c42b1c}.warn{color:#9a6100}.muted{color:#6b7680}.detail{color:#6b7680;font-size:12px}</style>')
                [void]$builder.AppendLine('</head><body>')
                [void]$builder.AppendLine('<h1>Windows Automatic Setup - System report</h1>')
                [void]$builder.AppendLine(('<p>Generated {0}</p>' -f (& $encode ([string]$Dashboard.GeneratedAt))))
                [void]$builder.AppendLine(('<p>Warnings: {0} | Errors: {1}</p>' -f $Dashboard.WarningCount, $Dashboard.ErrorCount))
                foreach ($section in @($Dashboard.Sections)) {
                    [void]$builder.AppendLine(('<h2>{0}</h2><table>' -f (& $encode ([string]$section.Title))))
                    foreach ($row in @($section.Rows)) {
                        $label = [string]$row.Label
                        if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$row.LabelKey }
                        $value = [string]$row.Value
                        if ([string]::IsNullOrWhiteSpace($value) -and -not [string]::IsNullOrWhiteSpace([string]$row.ValueKey)) { $value = [string]$row.ValueKey }
                        $class = switch ([string]$row.Tone) {
                            'Ok' { 'ok' }
                            'Warning' { 'warn' }
                            'Error' { 'bad' }
                            default { 'muted' }
                        }
                        $detail = ''
                        if (-not [string]::IsNullOrWhiteSpace([string]$row.Detail)) {
                            $detail = ('<div class="detail">{0}</div>' -f (& $encode ([string]$row.Detail)))
                        }
                        [void]$builder.AppendLine(('<tr><th>{0}</th><td class="{1}">{2}{3}</td></tr>' -f (& $encode $label), $class, (& $encode $value), $detail))
                    }
                    [void]$builder.AppendLine('</table>')
                }
                [void]$builder.AppendLine('</body></html>')
                Set-Content -LiteralPath $path -Value $builder.ToString() -Encoding UTF8
            }
        }
    } catch {
        return New-SetupResult -Name 'System report' -Success $false `
            -Message ("Could not write the system report: {0}" -f $_.Exception.Message)
    }

    return New-SetupResult -Name 'System report' -Success $true `
        -Message ("System report written to {0}." -f $path) `
        -Data @{ Path = $path; Format = $Format; Rows = $rows.Count }
}

# --------------------------------------------------------------------------
# Reversible system actions
# --------------------------------------------------------------------------

function Test-SetupElevated {
    <#
    .SYNOPSIS
        Returns $true when the current process is elevated.
    #>
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Format-SetupByteSize {
    <#
    .SYNOPSIS
        Formats a byte count for messages and reports.
    #>
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:0.0} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:0.0} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:0.0} KB" -f ($Bytes / 1KB)) }
    return ("{0:0} B" -f $Bytes)
}

function Get-SetupHibernationState {
    <#
    .SYNOPSIS
        Reads the hibernation state without changing anything.
    #>
    $state = 'Unknown'
    try {
        $power = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop
        if ($null -ne $power.HibernateEnabled) {
            $state = if ([int]$power.HibernateEnabled -ne 0) { 'On' } else { 'Off' }
        } elseif ($null -ne $power.HibernateEnabledDefault) {
            $state = if ([int]$power.HibernateEnabledDefault -ne 0) { 'On' } else { 'Off' }
        }
    } catch { }
    return $state
}

function Get-SetupFastStartupState {
    <#
    .SYNOPSIS
        Reads the fast-startup state without changing anything.
    #>
    $state = 'Unknown'
    try {
        $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop
        if ($null -ne $session.HiberbootEnabled) {
            $state = if ([int]$session.HiberbootEnabled -ne 0) { 'On' } else { 'Off' }
        }
    } catch { }
    return $state
}

function Set-SetupPowerPlan {
    <#
    .SYNOPSIS
        Switches the active power plan. DryRun previews the change.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Balanced', 'HighPerformance', 'PowerSaver')][string]$Name,
        [switch]$DryRun
    )

    $guid = switch ($Name) {
        'HighPerformance' { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
        'PowerSaver' { 'a1841308-3541-4fab-bc81-f71556f20b4a' }
        default { '381b4222-f694-41f0-9685-ff5bb260df2e' }
    }
    $label = switch ($Name) {
        'HighPerformance' { 'High performance' }
        'PowerSaver' { 'Power saver' }
        default { 'Balanced' }
    }

    if (-not $DryRun -and -not (Test-SetupElevated)) {
        $message = 'Administrator permission is required to change the power plan.'
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'Power plan' -Success $false -Message $message
    }

    $known = ''
    try { $known = (& powercfg.exe /list 2>$null | Out-String) } catch { }
    if ([string]::IsNullOrWhiteSpace($known) -or ($known -notmatch [regex]::Escape($guid))) {
        $message = ("The power plan '{0}' is not available on this PC." -f $label)
        Write-SetupLog -Level Warning -Message $message
        return New-SetupResult -Name 'Power plan' -Success $false -Message $message
    }

    $current = ''
    try {
        $active = (& powercfg.exe /getactivescheme 2>$null | Out-String)
        if ($active -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $current = $matches[1].ToLowerInvariant()
        }
    } catch { }

    if ($current -eq $guid) {
        return New-SetupResult -Name 'Power plan' -Success $true -Skipped $true `
            -Message ("The {0} power plan is already active." -f $label)
    }
    if ($DryRun) {
        return New-SetupResult -Name 'Power plan' -Success $true `
            -Message ("Preview: the power plan would switch to {0}." -f $label) `
            -Data @{ Plan = $Name; Guid = $guid; DryRun = $true }
    }

    try {
        $process = Start-Process -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $guid) -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($process.ExitCode -ne 0) { throw ("powercfg returned exit code {0}." -f $process.ExitCode) }
    } catch {
        $message = ("Could not change the power plan: {0}" -f $_.Exception.Message)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'Power plan' -Success $false -Message $message
    }

    $verified = ''
    try {
        $active = (& powercfg.exe /getactivescheme 2>$null | Out-String)
        if ($active -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $verified = $matches[1].ToLowerInvariant()
        }
    } catch { }

    if ($verified -ne $guid) {
        $message = ("Windows did not report the {0} plan as active." -f $label)
        Write-SetupLog -Level Warning -Message $message
        return New-SetupResult -Name 'Power plan' -Success $false -Message $message
    }
    $message = ("The {0} power plan is now active." -f $label)
    Write-SetupLog -Level Success -Message $message
    return New-SetupResult -Name 'Power plan' -Success $true -Message $message `
        -Data @{ Plan = $Name; Guid = $guid }
}

function Set-SetupHibernation {
    <#
    .SYNOPSIS
        Turns hibernation on or off. DryRun previews the change.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('On', 'Off')][string]$State,
        [switch]$DryRun
    )

    $current = Get-SetupHibernationState
    if ($current -eq $State) {
        return New-SetupResult -Name 'Hibernation' -Success $true -Skipped $true `
            -Message ("Hibernation is already {0}." -f $State.ToLowerInvariant())
    }
    if (-not $DryRun -and -not (Test-SetupElevated)) {
        $message = 'Administrator permission is required to change hibernation.'
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'Hibernation' -Success $false -Message $message
    }
    if ($DryRun) {
        return New-SetupResult -Name 'Hibernation' -Success $true `
            -Message ("Preview: hibernation would be turned {0}." -f $State.ToLowerInvariant()) `
            -Data @{ State = $State; DryRun = $true }
    }

    $fastStartupWasOn = ((Get-SetupFastStartupState) -eq 'On')
    try {
        $process = Start-Process -FilePath 'powercfg.exe' -ArgumentList @('/hibernate', $State.ToLowerInvariant()) -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($process.ExitCode -ne 0) { throw ("powercfg returned exit code {0}." -f $process.ExitCode) }
    } catch {
        $message = ("Could not change hibernation: {0}" -f $_.Exception.Message)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'Hibernation' -Success $false -Message $message
    }

    $message = ("Hibernation is now {0}." -f $State.ToLowerInvariant())
    if ($State -eq 'Off' -and $fastStartupWasOn) {
        $message = $message + ' Fast startup was also turned off.'
    }
    Write-SetupLog -Level Success -Message $message
    return New-SetupResult -Name 'Hibernation' -Success $true -Message $message -Data @{ State = $State }
}

function Set-SetupFastStartup {
    <#
    .SYNOPSIS
        Turns fast startup on or off. DryRun previews the change.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('On', 'Off')][string]$State,
        [switch]$DryRun
    )

    $current = Get-SetupFastStartupState
    if ($current -eq $State) {
        return New-SetupResult -Name 'Fast startup' -Success $true -Skipped $true `
            -Message ("Fast startup is already {0}." -f $State.ToLowerInvariant())
    }
    if ($State -eq 'On' -and (Get-SetupHibernationState) -ne 'On') {
        $message = 'Turn hibernation on before enabling fast startup.'
        Write-SetupLog -Level Warning -Message $message
        return New-SetupResult -Name 'Fast startup' -Success $false -Message $message
    }
    if (-not $DryRun -and -not (Test-SetupElevated)) {
        $message = 'Administrator permission is required to change fast startup.'
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'Fast startup' -Success $false -Message $message
    }
    if ($DryRun) {
        return New-SetupResult -Name 'Fast startup' -Success $true `
            -Message ("Preview: fast startup would be turned {0}." -f $State.ToLowerInvariant()) `
            -Data @{ State = $State; DryRun = $true }
    }

    $value = if ($State -eq 'On') { 1 } else { 0 }
    try {
        Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            -Name 'HiberbootEnabled' -Value $value -Type DWord -ErrorAction Stop
    } catch {
        $message = ("Could not change fast startup: {0}" -f $_.Exception.Message)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'Fast startup' -Success $false -Message $message
    }

    $verified = Get-SetupFastStartupState
    if ($verified -ne $State) {
        $message = 'Windows did not confirm the fast startup change. A restart may be required.'
        Write-SetupLog -Level Warning -Message $message
        return New-SetupResult -Name 'Fast startup' -Success $false -Message $message
    }
    $message = ("Fast startup is now {0}." -f $State.ToLowerInvariant())
    Write-SetupLog -Level Success -Message $message
    return New-SetupResult -Name 'Fast startup' -Success $true -Message $message `
        -Data @{ State = $State; RestartRequired = $true }
}

function Set-SetupPowerSettings {
    <#
    .SYNOPSIS
        Applies a power plan, hibernation and fast-startup choice in one call.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Keep', 'Balanced', 'HighPerformance', 'PowerSaver')][string]$Plan = 'Keep',
        [ValidateSet('Keep', 'On', 'Off')][string]$Hibernate = 'Keep',
        [ValidateSet('Keep', 'On', 'Off')][string]$FastStartup = 'Keep',
        [switch]$DryRun
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if ($Plan -ne 'Keep') { $results.Add((Set-SetupPowerPlan -Name $Plan -DryRun:$DryRun)) }
    if ($Hibernate -ne 'Keep') { $results.Add((Set-SetupHibernation -State $Hibernate -DryRun:$DryRun)) }
    if ($FastStartup -ne 'Keep') { $results.Add((Set-SetupFastStartup -State $FastStartup -DryRun:$DryRun)) }

    if ($results.Count -eq 0) {
        return New-SetupResult -Name 'Power settings' -Success $false -Message 'No power setting was selected.'
    }
    $failed = @($results | Where-Object { -not $_.Success })
    $active = @($results | Where-Object { -not $_.Skipped })
    $messages = @($results | ForEach-Object { [string]$_.Message } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return New-SetupResult -Name 'Power settings' -Success ($failed.Count -eq 0) -Skipped ($active.Count -eq 0) `
        -Message ($messages -join ' ') -Data @{ Results = @($results); DryRun = [bool]$DryRun }
}

function Set-SetupDnsPreset {
    <#
    .SYNOPSIS
        Sets DNS servers on one adapter or restores automatic (DHCP) DNS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AdapterName,
        [Parameter(Mandatory = $true)][ValidateSet('Automatic', 'Cloudflare', 'Google', 'Quad9')][string]$Preset,
        [switch]$DryRun
    )

    $adapter = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $AdapterName }) | Select-Object -First 1
    if ($null -eq $adapter) {
        $message = ("Network adapter '{0}' was not found." -f $AdapterName)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'DNS preset' -Success $false -Message $message
    }

    $servers = @()
    switch ($Preset) {
        'Cloudflare' { $servers = @('1.1.1.1', '1.0.0.1') }
        'Google' { $servers = @('8.8.8.8', '8.8.4.4') }
        'Quad9' { $servers = @('9.9.9.9', '149.112.112.112') }
    }
    $presetLabel = if ($Preset -eq 'Automatic') { 'Automatic (DHCP)' } else { ("{0} ({1})" -f $Preset, ($servers -join ', ')) }

    $current = @()
    try {
        $current = @(Get-DnsClientServerAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction Stop |
            ForEach-Object { $_.ServerAddresses })
    } catch { }
    if ($Preset -eq 'Automatic') {
        if ($current.Count -eq 0) {
            return New-SetupResult -Name 'DNS preset' -Success $true -Skipped $true `
                -Message ("'{0}' already uses automatic DNS." -f $AdapterName)
        }
    } elseif ((@($current | Sort-Object) -join ',') -eq (@($servers | Sort-Object) -join ',')) {
        return New-SetupResult -Name 'DNS preset' -Success $true -Skipped $true `
            -Message ("'{0}' already uses {1}." -f $AdapterName, $presetLabel)
    }

    if (-not $DryRun -and -not (Test-SetupElevated)) {
        $message = 'Administrator permission is required to change DNS servers.'
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'DNS preset' -Success $false -Message $message
    }
    if ($DryRun) {
        return New-SetupResult -Name 'DNS preset' -Success $true `
            -Message ("Preview: '{0}' DNS would be set to {1}." -f $AdapterName, $presetLabel) `
            -Data @{ AdapterName = $AdapterName; Preset = $Preset; Servers = @($servers); DryRun = $true }
    }

    try {
        if ($Preset -eq 'Automatic') {
            Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ResetServerAddresses -ErrorAction Stop
        } else {
            Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ServerAddresses $servers -ErrorAction Stop
        }
    } catch {
        $message = ("Could not change DNS servers: {0}" -f $_.Exception.Message)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'DNS preset' -Success $false -Message $message
    }

    if ($Preset -ne 'Automatic') {
        $verified = @()
        try {
            $verified = @(Get-DnsClientServerAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction Stop |
                ForEach-Object { $_.ServerAddresses })
        } catch { }
        if ((@($verified | Sort-Object) -join ',') -ne (@($servers | Sort-Object) -join ',')) {
            $message = ("Windows did not report the requested DNS servers on '{0}'." -f $AdapterName)
            Write-SetupLog -Level Warning -Message $message
            return New-SetupResult -Name 'DNS preset' -Success $false -Message $message
        }
    }

    $message = ("DNS servers on '{0}' are now {1}." -f $AdapterName, $presetLabel)
    Write-SetupLog -Level Success -Message $message
    return New-SetupResult -Name 'DNS preset' -Success $true -Message $message `
        -Data @{ AdapterName = $AdapterName; Preset = $Preset; Servers = @($servers) }
}

function Clear-SetupDnsCache {
    <#
    .SYNOPSIS
        Flushes the DNS resolver cache.
    #>
    [CmdletBinding()]
    param([switch]$DryRun)
    if ($DryRun) {
        return New-SetupResult -Name 'DNS cache' -Success $true -Message 'Preview: the DNS cache would be flushed.' `
            -Data @{ DryRun = $true }
    }
    try {
        if ($null -ne (Get-Command Clear-DnsClientCache -ErrorAction SilentlyContinue)) {
            Clear-DnsClientCache -ErrorAction Stop
        } else {
            $process = Start-Process -FilePath 'ipconfig.exe' -ArgumentList '/flushdns' -Wait -PassThru -NoNewWindow -ErrorAction Stop
            if ($process.ExitCode -ne 0) { throw ("ipconfig returned exit code {0}." -f $process.ExitCode) }
        }
    } catch {
        $message = ("Could not flush the DNS cache: {0}" -f $_.Exception.Message)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'DNS cache' -Success $false -Message $message
    }
    Write-SetupLog -Level Success -Message 'The DNS cache was flushed.'
    return New-SetupResult -Name 'DNS cache' -Success $true -Message 'The DNS cache was flushed.'
}

function Test-SetupNetworkPath {
    <#
    .SYNOPSIS
        Pings a host and optionally returns a traceroute. Read-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [ValidateRange(1, 10)][int]$Count = 3,
        [switch]$Traceroute
    )

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return New-SetupResult -Name 'Network test' -Success $false -Message 'Enter a host name or IP address.'
    }
    $targetText = $Target.Trim()

    $received = 0
    $times = [System.Collections.Generic.List[double]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $ping = $null
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        for ($index = 0; $index -lt $Count; $index++) {
            try {
                $reply = $ping.Send($targetText, 1500)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $received++
                    $times.Add([double]$reply.RoundtripTime)
                } else {
                    $errors.Add([string]$reply.Status)
                }
            } catch {
                $errors.Add($_.Exception.Message)
            }
        }
    } finally {
        if ($null -ne $ping) {
            try { $ping.Dispose() } catch { }
        }
    }

    $average = $null
    if ($times.Count -gt 0) {
        $average = [int][math]::Round((($times | Measure-Object -Average).Average), 0)
    }

    $path = @()
    if ($Traceroute -and $received -gt 0) {
        try {
            $output = (& tracert.exe -d -h 15 -w 500 $targetText 2>$null | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($output)) { $path = @($output -split "`r?`n") }
        } catch { }
    }

    $success = $received -gt 0
    $message = if ($success) {
        ("{0}: {1}/{2} reply/replies, average {3} ms." -f $targetText, $received, $Count, $average)
    } else {
        ("{0} did not reply to {1} ping(s)." -f $targetText, $Count)
    }
    $level = if ($success) { 'Success' } else { 'Warning' }
    Write-SetupLog -Level $level -Message $message
    return New-SetupResult -Name ("Network test: {0}" -f $targetText) -Success $success -Message $message `
        -Data @{ Target = $targetText; Sent = $Count; Received = $received; AverageMs = $average; Path = @($path); Errors = @($errors) }
}

function Clear-SetupTempFiles {
    <#
    .SYNOPSIS
        Removes old temporary files. DryRun previews without deleting.
    .DESCRIPTION
        Only folders under the current user's temp directory or Windows\Temp
        are accepted. Reparse points are skipped so a junction cannot lead the
        cleanup outside those folders.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Path = @(),
        [ValidateRange(0, 365)][int]$OlderThanDays = 1,
        [bool]$IncludeWindowsTemp = $true,
        [switch]$DryRun
    )

    $targets = [System.Collections.Generic.List[string]]::new()
    if (@($Path).Count -gt 0) {
        foreach ($item in @($Path)) {
            if ([string]::IsNullOrWhiteSpace([string]$item)) { continue }
            try { $full = [IO.Path]::GetFullPath([string]$item) } catch { continue }
            $allowedRoots = @([IO.Path]::GetTempPath())
            if (-not [string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
                $allowedRoots += (Join-Path ([string]$env:SystemRoot) 'Temp')
            }
            $allowed = $false
            foreach ($root in $allowedRoots) {
                try {
                    $rootFull = [IO.Path]::GetFullPath([string]$root).TrimEnd('\')
                    if ($full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
                        $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                        $allowed = $true
                    }
                } catch { }
            }
            if (-not $allowed) {
                $message = ("Refusing to clean a folder outside the temp directories: {0}" -f $full)
                Write-SetupLog -Level Error -Message $message
                return New-SetupResult -Name 'Temp cleanup' -Success $false -Message $message
            }
            if (Test-Path -LiteralPath $full -PathType Container) { $targets.Add($full) }
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace([string]$env:TEMP)) { $targets.Add([string]$env:TEMP) }
        if ($IncludeWindowsTemp -and -not [string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
            $targets.Add((Join-Path ([string]$env:SystemRoot) 'Temp'))
        }
    }

    $unique = @($targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($unique.Count -eq 0) {
        return New-SetupResult -Name 'Temp cleanup' -Success $false -Message 'No temporary folder was found.'
    }

    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $stack = [System.Collections.Generic.Stack[string]]::new()
    foreach ($folder in $unique) { $stack.Push($folder) }
    $files = [System.Collections.Generic.List[object]]::new()

    while ($stack.Count -gt 0) {
        $folder = $stack.Pop()
        if (-not $visited.Add($folder)) { continue }
        $children = @()
        try { $children = @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop) } catch { continue }
        foreach ($child in $children) {
            if ($child.PSIsContainer) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $stack.Push([string]$child.FullName)
                }
            } elseif ($child.LastWriteTime -lt $cutoff) {
                $files.Add($child)
            }
        }
    }

    $bytes = 0.0
    $deleted = 0
    $skipped = 0
    foreach ($file in $files) {
        try { $bytes += [double]$file.Length } catch { }
        if ($DryRun) { continue }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $deleted++
        } catch {
            $skipped++
        }
    }

    $sizeText = Format-SetupByteSize $bytes
    if ($DryRun) {
        $message = ("Preview: {0} temporary file(s) ({1}) older than {2} day(s) can be removed." -f $files.Count, $sizeText, $OlderThanDays)
    } elseif ($skipped -gt 0) {
        $message = ("Removed {0} of {1} temporary file(s) ({2}); {3} file(s) were in use." -f $deleted, $files.Count, $sizeText, $skipped)
    } else {
        $message = ("Removed {0} temporary file(s) ({1})." -f $deleted, $sizeText)
    }
    $level = if ($DryRun) { 'Info' } elseif ($skipped -gt 0) { 'Warning' } else { 'Success' }
    Write-SetupLog -Level $level -Message $message
    return New-SetupResult -Name 'Temp cleanup' -Success $true -Message $message `
        -Data @{ Files = $files.Count; Deleted = $deleted; Skipped = $skipped; Bytes = $bytes; Paths = @($unique); DryRun = [bool]$DryRun }
}

function Set-SetupStorageSense {
    <#
    .SYNOPSIS
        Turns Storage Sense on or off for the current user.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('On', 'Off')][string]$State,
        [switch]$DryRun
    )

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
    $current = 'Off'
    try {
        $policy = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        if ($null -ne $policy.'01') {
            $current = if ([int]$policy.'01' -ne 0) { 'On' } else { 'Off' }
        }
    } catch { }

    if ($current -eq $State) {
        return New-SetupResult -Name 'Storage Sense' -Success $true -Skipped $true `
            -Message ("Storage Sense is already {0}." -f $State.ToLowerInvariant())
    }
    if ($DryRun) {
        return New-SetupResult -Name 'Storage Sense' -Success $true `
            -Message ("Preview: Storage Sense would be turned {0}." -f $State.ToLowerInvariant()) `
            -Data @{ State = $State; DryRun = $true }
    }

    try {
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force -ErrorAction Stop | Out-Null }
        $value = if ($State -eq 'On') { 1 } else { 0 }
        Set-ItemProperty -LiteralPath $key -Name '01' -Value $value -Type DWord -ErrorAction Stop
    } catch {
        $message = ("Could not change Storage Sense: {0}" -f $_.Exception.Message)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'Storage Sense' -Success $false -Message $message
    }

    $message = ("Storage Sense is now {0}." -f $State.ToLowerInvariant())
    Write-SetupLog -Level Success -Message $message
    return New-SetupResult -Name 'Storage Sense' -Success $true -Message $message -Data @{ State = $State }
}

function Set-SetupTimeZone {
    <#
    .SYNOPSIS
        Changes the Windows time zone by its Windows time-zone ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [switch]$DryRun
    )

    $zone = $null
    try {
        $zone = [TimeZoneInfo]::FindSystemTimeZoneById($Id)
    } catch {
        $message = ("Time zone '{0}' was not found. Use a Windows time-zone ID such as 'Romance Standard Time'." -f $Id)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'Time zone' -Success $false -Message $message
    }

    $current = ''
    try { $current = [TimeZoneInfo]::Local.Id } catch { }
    if ($current -eq $zone.Id) {
        return New-SetupResult -Name 'Time zone' -Success $true -Skipped $true `
            -Message ("The time zone is already {0}." -f $zone.Id)
    }
    if (-not $DryRun -and -not (Test-SetupElevated)) {
        $message = 'Administrator permission is required to change the time zone.'
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'Time zone' -Success $false -Message $message
    }
    if ($DryRun) {
        return New-SetupResult -Name 'Time zone' -Success $true `
            -Message ("Preview: the time zone would change from {0} to {1}." -f $current, $zone.Id) `
            -Data @{ Id = $zone.Id; DisplayName = $zone.DisplayName; DryRun = $true }
    }

    try {
        Set-TimeZone -Id $zone.Id -ErrorAction Stop
    } catch {
        $message = ("Could not change the time zone: {0}" -f $_.Exception.Message)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name 'Time zone' -Success $false -Message $message
    }

    $verified = ''
    try { $verified = [TimeZoneInfo]::Local.Id } catch { }
    if ($verified -ne $zone.Id) {
        $message = 'Windows did not confirm the time zone change.'
        Write-SetupLog -Level Warning -Message $message
        return New-SetupResult -Name 'Time zone' -Success $false -Message $message
    }

    $offset = $zone.BaseUtcOffset
    $sign = if ($offset.TotalMinutes -ge 0) { '+' } else { '-' }
    $offsetText = ("UTC{0}{1:00}:{2:00}" -f $sign, [math]::Floor([math]::Abs($offset.TotalHours)), [math]::Abs($offset.Minutes))
    $message = ("The time zone is now {0} ({1}, {2})." -f $zone.Id, $zone.DisplayName, $offsetText)
    Write-SetupLog -Level Success -Message $message
    return New-SetupResult -Name 'Time zone' -Success $true -Message $message `
        -Data @{ Id = $zone.Id; DisplayName = $zone.DisplayName; Offset = $offsetText }
}

function Test-SetupRestorePointSupport {
    <#
    .SYNOPSIS
        Reports whether System Restore can create a checkpoint on this PC.
    #>
    $supported = $null -ne (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)
    $enabled = $false
    $reason = ''

    if (-not $supported) {
        $reason = 'The Checkpoint-Computer cmdlet is not available on this Windows edition.'
        return [pscustomobject]@{ Supported = $false; Enabled = $false; Reason = $reason }
    }

    try {
        $service = Get-Service -Name SDRSVC -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            $reason = 'The System Restore service (SDRSVC) was not found.'
            return [pscustomobject]@{ Supported = $true; Enabled = $false; Reason = $reason }
        }
        if ([string]$service.StartType -eq 'Disabled') {
            $reason = 'The System Restore service (SDRSVC) is disabled.'
            return [pscustomobject]@{ Supported = $true; Enabled = $false; Reason = $reason }
        }
        $enabled = $true
    } catch {
        $reason = ("Could not read the System Restore service: {0}" -f $_.Exception.Message)
        return [pscustomobject]@{ Supported = $true; Enabled = $false; Reason = $reason }
    }

    try {
        $settings = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -ErrorAction SilentlyContinue
        if ($null -ne $settings -and $null -ne $settings.PSObject.Properties['DisableSR'] -and [int]$settings.DisableSR -eq 1) {
            $enabled = $false
            $reason = 'System Restore is disabled by policy (DisableSR=1).'
        }
    } catch { }

    if ($enabled -and [string]::IsNullOrWhiteSpace($reason)) {
        $reason = 'System Restore is available.'
    }
    return [pscustomobject]@{ Supported = $true; Enabled = $enabled; Reason = $reason }
}

function New-SetupRestorePoint {
    <#
    .SYNOPSIS
        Creates a System Restore checkpoint with clear skip/failure reporting.
    .DESCRIPTION
        Windows normally limits checkpoints to one per 24 hours. The frequency
        value is temporarily set to zero, the checkpoint is created, then the
        previous value is restored. When System Restore is disabled or the
        checkpoint fails, the result is Skipped or unsuccessful instead of
        stopping the caller.
    #>
    param(
        [string]$Description = 'Windows Automatic Setup',
        [switch]$DryRun
    )

    $support = Test-SetupRestorePointSupport
    if (-not $support.Supported) {
        Write-SetupLog -Level Warning -Message ("Restore point skipped: {0}" -f $support.Reason)
        return New-SetupResult -Name 'System restore point' -Success $false -Skipped $true `
            -Message ("Restore point unavailable: {0}" -f $support.Reason) `
            -Data @{ Supported = $false; Enabled = $false }
    }
    if (-not $support.Enabled) {
        Write-SetupLog -Level Warning -Message ("Restore point skipped: {0}" -f $support.Reason)
        return New-SetupResult -Name 'System restore point' -Success $false -Skipped $true `
            -Message ("Restore point skipped: {0} Enable System Protection from Windows settings and try again." -f $support.Reason) `
            -Data @{ Supported = $true; Enabled = $false }
    }
    if ($DryRun) {
        return New-SetupResult -Name 'System restore point' -Success $true -Skipped $true `
            -Message ("Preview: a restore point would be created with the description '{0}'." -f $Description) `
            -Data @{ DryRun = $true; Description = $Description }
    }

    $registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $valueName = 'SystemRestorePointCreationFrequency'
    $hadValue = $false
    $previousValue = $null
    try {
        $current = Get-ItemProperty -LiteralPath $registryPath -Name $valueName -ErrorAction Stop
        if ($null -ne $current.PSObject.Properties[$valueName]) {
            $previousValue = $current.$valueName
            $hadValue = $true
        }
    } catch { }

    try {
        Write-SetupLog -Level Task -Message ("Creating a System Restore point: {0}" -f $Description)
        if ($hadValue) {
            Set-ItemProperty -LiteralPath $registryPath -Name $valueName -Value 0 -Type DWord -ErrorAction Stop
        } else {
            New-ItemProperty -LiteralPath $registryPath -Name $valueName -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }

        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop

        $point = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending | Select-Object -First 1
        $sequence = ''
        $created = ''
        if ($null -ne $point) {
            $sequence = [string]$point.SequenceNumber
            $created = [string]$point.CreationTime
        }
        Write-SetupLog -Level Success -Message ("System Restore point created: {0}" -f $Description)
        return New-SetupResult -Name 'System restore point' -Success $true `
            -Message ("Restore point created: {0}" -f $Description) `
            -Data @{ Description = $Description; SequenceNumber = $sequence; CreationTime = $created }
    } catch {
        Write-SetupLog -Level Warning -Message ("Could not create the System Restore point: {0}" -f $_.Exception.Message)
        return New-SetupResult -Name 'System restore point' -Success $false `
            -Message ("Could not create the System Restore point: {0}" -f $_.Exception.Message) `
            -Data @{ Description = $Description }
    } finally {
        try {
            if ($hadValue) {
                Set-ItemProperty -LiteralPath $registryPath -Name $valueName -Value $previousValue -Type DWord -ErrorAction SilentlyContinue
            } else {
                Remove-ItemProperty -LiteralPath $registryPath -Name $valueName -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}

function Test-SetupPreflight {
    <#
    .SYNOPSIS
        Runs read-only checks before an installation or system change.
    .DESCRIPTION
        Fail means the requested work is likely to fail (not elevated, too
        little disk space, unsupported OS). Warn means some operations can
        still run (no Internet, winget missing, pending restart).
    #>
    param([switch]$SkipInternet)

    $checks = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Name, [string]$Status, [string]$Message)
        [void]$checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Message = $Message })
    }

    $isAdmin = $false
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    if ($isAdmin) {
        & $add 'Administrator' 'Pass' 'The setup is running elevated.'
    } else {
        & $add 'Administrator' 'Fail' 'Administrator permission is required. Approve the UAC prompt and try again.'
    }

    $psMajor = $PSVersionTable.PSVersion.Major
    if ($psMajor -ge 5) {
        & $add 'PowerShell' 'Pass' ("Windows PowerShell {0} is available." -f $PSVersionTable.PSVersion)
    } else {
        & $add 'PowerShell' 'Fail' ("PowerShell 5.1 or newer is required; found {0}." -f $PSVersionTable.PSVersion)
    }

    $osBuild = 0
    $osCaption = ''
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $os) {
            $osCaption = [string]$os.Caption
            $osBuild = [int]$os.BuildNumber
        }
    } catch { }
    if ($osBuild -ge 10240) {
        & $add 'Windows version' 'Pass' ("{0} (build {1})." -f $osCaption, $osBuild)
    } elseif ($osBuild -gt 0) {
        & $add 'Windows version' 'Warn' ("{0} (build {1}) is older than Windows 10/11." -f $osCaption, $osBuild)
    } else {
        & $add 'Windows version' 'Warn' 'The Windows version could not be read.'
    }

    $systemInfo = Get-SetupSystemInfo
    if ($null -ne $systemInfo.FreeSpaceGB) {
        $free = [double]$systemInfo.FreeSpaceGB
        if ($free -lt 2) {
            & $add 'Disk space' 'Fail' ("Only {0} GB free on {1}. At least 2 GB is required." -f $free, $systemInfo.SystemDrive)
        } elseif ($free -lt 10) {
            & $add 'Disk space' 'Warn' ("{0} GB free on {1}. Some applications need several GB." -f $free, $systemInfo.SystemDrive)
        } else {
            & $add 'Disk space' 'Pass' ("{0} GB free on {1}." -f $free, $systemInfo.SystemDrive)
        }
    } else {
        & $add 'Disk space' 'Warn' 'Free disk space could not be read.'
    }

    if (-not $SkipInternet) {
        $internet = $false
        try {
            $response = Invoke-WebRequest -Uri 'https://www.microsoft.com' -Method Head -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            $internet = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
        } catch { }
        if ($internet) {
            & $add 'Internet' 'Pass' 'An Internet connection is available for Winget downloads.'
        } else {
            & $add 'Internet' 'Warn' 'No Internet connection was detected. Winget installs will fail; local installers can still run.'
        }
    }

    if ($null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        & $add 'Winget' 'Pass' 'winget is available.'
    } else {
        & $add 'Winget' 'Warn' 'winget is not available. Install Microsoft App Installer from https://aka.ms/getwinget.'
    }

    if (Test-SetupPendingReboot) {
        & $add 'Pending restart' 'Warn' 'Windows has a pending restart. Restart before installing to avoid installer conflicts.'
    } else {
        & $add 'Pending restart' 'Pass' 'No pending restart was detected.'
    }

    $restoreSupport = Test-SetupRestorePointSupport
    if ($restoreSupport.Supported -and $restoreSupport.Enabled) {
        & $add 'System Restore' 'Pass' 'A restore point can be created before changes.'
    } else {
        & $add 'System Restore' 'Warn' ("A restore point cannot be created: {0}" -f $restoreSupport.Reason)
    }

    $failCount = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count
    $warnCount = @($checks | Where-Object { $_.Status -eq 'Warn' }).Count
    return [pscustomobject]@{
        Name      = 'Preflight checks'
        Success   = ($failCount -eq 0)
        Checks    = $checks.ToArray()
        FailCount = $failCount
        WarnCount = $warnCount
        Message   = ("{0} check(s): {1} warning(s), {2} blocking." -f $checks.Count, $warnCount, $failCount)
        Timestamp = (Get-Date)
    }
}

# --------------------------------------------------------------------------
# Reports
# --------------------------------------------------------------------------

function Export-SetupReport {
    <#
    .SYNOPSIS
        Writes the current results and system information to CSV, HTML or JSON.
    #>
    param(
        [AllowEmptyCollection()][object[]]$Results = @(),
        $Config = $null,
        [string]$Directory = '',
        [string]$BaseName = 'setup-report',
        [ValidateSet('Csv', 'Html', 'Json')][string]$Format = 'Html'
    )

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        $Directory = Join-Path (Get-SetupRootPath) 'Logs'
    }
    try {
        New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
    } catch {
        return New-SetupResult -Name 'Report export' -Success $false `
            -Message ("Could not create the report folder: {0}" -f $_.Exception.Message)
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeBase = ($BaseName -replace '[^\w\-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeBase)) { $safeBase = 'setup-report' }

    $system = Get-SetupSystemInfo
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Results)) {
        if ($null -eq $entry) { continue }
        $status = 'Succeeded'
        if ($null -ne $entry.PSObject.Properties['Skipped'] -and [bool]$entry.Skipped) {
            $status = 'Skipped'
        } elseif ($null -ne $entry.PSObject.Properties['Success'] -and -not [bool]$entry.Success) {
            $status = 'Failed'
        }
        $time = ''
        if ($null -ne $entry.PSObject.Properties['Timestamp'] -and $null -ne $entry.Timestamp) {
            try { $time = ([datetime]$entry.Timestamp).ToString('yyyy-MM-dd HH:mm:ss') } catch { $time = [string]$entry.Timestamp }
        }
        $exitCode = ''
        if ($null -ne $entry.PSObject.Properties['ExitCode']) { $exitCode = [string]$entry.ExitCode }
        $restart = $false
        if ($null -ne $entry.PSObject.Properties['RestartRequired']) { $restart = [bool]$entry.RestartRequired }
        $rows.Add([pscustomobject]@{
            Time            = $time
            Item            = [string]$entry.Name
            Status          = $status
            ExitCode        = $exitCode
            RestartRequired = $restart
            Message         = [string]$entry.Message
        })
    }

    $catalogCount = 0
    if ($null -ne $Config) {
        try { $catalogCount = @(Get-SoftwareCatalog -Config $Config).Count } catch { }
    }
    $summary = [ordered]@{
        GeneratedAt   = (Get-Date).ToString('o')
        CatalogItems  = $catalogCount
        TotalResults  = $rows.Count
        Failed        = @($rows | Where-Object { $_.Status -eq 'Failed' }).Count
        Skipped       = @($rows | Where-Object { $_.Status -eq 'Skipped' }).Count
        Succeeded     = @($rows | Where-Object { $_.Status -eq 'Succeeded' }).Count
    }

    $path = Join-Path $Directory ("{0}-{1}.{2}" -f $safeBase, $stamp, $Format.ToLowerInvariant())
    try {
        switch ($Format) {
            'Csv' {
                $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
            }
            'Json' {
                [pscustomobject]@{
                    Summary = [pscustomobject]$summary
                    System  = $system
                    Results = $rows.ToArray()
                } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
            }
            default {
                $encode = { param([string]$text) [System.Net.WebUtility]::HtmlEncode($text) }
                $builder = [System.Text.StringBuilder]::new()
                [void]$builder.AppendLine('<!DOCTYPE html>')
                [void]$builder.AppendLine('<html lang="en"><head><meta charset="utf-8">')
                [void]$builder.AppendLine('<title>Windows Automatic Setup report</title>')
                [void]$builder.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1f24;background:#f4f6f8}h1{font-size:22px}h2{font-size:16px;margin-top:24px}table{border-collapse:collapse;width:100%;background:#fff}th,td{border:1px solid #d7dce2;padding:7px 9px;text-align:left;font-size:13px}th{background:#eef3f8}tr:nth-child(even) td{background:#fafbfc}.ok{color:#107c10}.bad{color:#c42b1c}.skip{color:#9a6100}</style>')
                [void]$builder.AppendLine('</head><body>')
                [void]$builder.AppendLine('<h1>Windows Automatic Setup report</h1>')
                [void]$builder.AppendLine(('<p>Generated {0}</p>' -f (& $encode $summary.GeneratedAt)))
                [void]$builder.AppendLine('<h2>System information</h2><table>')
                foreach ($property in $system.PSObject.Properties) {
                    [void]$builder.AppendLine(('<tr><th>{0}</th><td>{1}</td></tr>' -f (& $encode $property.Name), (& $encode ([string]$property.Value))))
                }
                [void]$builder.AppendLine('</table>')
                [void]$builder.AppendLine(('<h2>Results ({0})</h2>' -f $rows.Count))
                [void]$builder.AppendLine('<table><tr><th>Time</th><th>Item</th><th>Status</th><th>Exit code</th><th>Restart</th><th>Message</th></tr>')
                foreach ($row in $rows) {
                    $class = 'ok'
                    if ($row.Status -eq 'Failed') { $class = 'bad' }
                    elseif ($row.Status -eq 'Skipped') { $class = 'skip' }
                    [void]$builder.AppendLine(('<tr><td>{0}</td><td>{1}</td><td class="{2}">{3}</td><td>{4}</td><td>{5}</td><td>{6}</td></tr>' -f `
                        (& $encode $row.Time), (& $encode $row.Item), $class, (& $encode $row.Status), (& $encode $row.ExitCode), (& $encode ([string]$row.RestartRequired)), (& $encode $row.Message)))
                }
                [void]$builder.AppendLine('</table></body></html>')
                Set-Content -LiteralPath $path -Value $builder.ToString() -Encoding UTF8
            }
        }
    } catch {
        return New-SetupResult -Name 'Report export' -Success $false `
            -Message ("Could not write the report: {0}" -f $_.Exception.Message)
    }

    Write-SetupLog -Level Success -Message ("Report written: {0}" -f $path)
    return New-SetupResult -Name 'Report export' -Success $true `
        -Message ("Report written to {0}" -f $path) `
        -Data @{ Path = $path; Format = $Format; Rows = $rows.Count }
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

function Get-SetupCategories {
    <#
    .SYNOPSIS
        Returns the category definitions from Software.json.
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $items = @()
    foreach ($category in @($Config.Categories)) {
        if ($null -eq $category -or $category.Enabled -eq $false) { continue }
        $id = [string]$category.Id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $items += [pscustomobject]@{
            Id     = $id
            NameEn = [string]$category.NameEn
            NameFr = [string]$category.NameFr
        }
    }
    return $items
}

function Get-SetupProfiles {
    <#
    .SYNOPSIS
        Returns the selection profiles from Software.json.
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $items = @()
    foreach ($profile in @($Config.Profiles)) {
        if ($null -eq $profile -or $profile.Enabled -eq $false) { continue }
        $id = [string]$profile.Id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $apps = @()
        foreach ($app in @($profile.Apps)) {
            $text = [string]$app
            if (-not [string]::IsNullOrWhiteSpace($text)) { $apps += $text }
        }
        $items += [pscustomobject]@{
            Id     = $id
            NameEn = [string]$profile.NameEn
            NameFr = [string]$profile.NameFr
            Apps   = $apps
        }
    }
    return $items
}

function Get-SoftwareCatalog {
    <#
    .SYNOPSIS
        Returns the enabled software entries as display-ready items.
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $categories = @{}
    foreach ($category in @($Config.Categories)) {
        if ($null -eq $category) { continue }
        $id = [string]$category.Id
        if (-not [string]::IsNullOrWhiteSpace($id)) { $categories[$id] = $category }
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($app in @($Config.Apps)) {
        if ($null -eq $app -or $app.Enabled -eq $false) { continue }
        if ([string]$app.Type -ne 'winget' -or [string]::IsNullOrWhiteSpace([string]$app.Id)) { continue }
        $hasFallback = ($null -ne $app.FallbackUrl) -and (-not [string]::IsNullOrWhiteSpace([string]$app.FallbackUrl))
        $source = Get-SetupCatalogSource -Item $app
        $pinnedVersion = [string]$app.Version
        $pinned = -not [string]::IsNullOrWhiteSpace($pinnedVersion)
        # A pinned entry already fixes the version; the two options cannot be
        # combined, so the picker is only offered for unpinned entries. The
        # Microsoft Store source does not publish a usable version list either.
        $versionPicker = ($null -ne $app.PSObject.Properties['VersionPicker']) -and [bool]$app.VersionPicker
        if ($pinned -or $source -ne 'winget') { $versionPicker = $false }
        $idLabel = 'Winget ID'
        if ($source -eq 'msstore') { $idLabel = 'Store ID' }
        $detail = ("{0}: {1}" -f $idLabel, [string]$app.Id)
        if ($pinned) { $detail = $detail + (" | pinned version {0}" -f $pinnedVersion) }
        if ($hasFallback) { $detail = $detail + ' [+direct-download fallback]' }

        $categoryId = ''
        if ($null -ne $app.PSObject.Properties['Category']) { $categoryId = [string]$app.Category }
        $categoryEn = $categoryId
        $categoryFr = $categoryId
        if ($categories.ContainsKey($categoryId)) {
            $categoryEn = [string]$categories[$categoryId].NameEn
            $categoryFr = [string]$categories[$categoryId].NameFr
            if ([string]::IsNullOrWhiteSpace($categoryEn)) { $categoryEn = $categoryId }
            if ([string]::IsNullOrWhiteSpace($categoryFr)) { $categoryFr = $categoryEn }
        }

        [void]$items.Add([pscustomobject]@{
            Kind           = 'winget'
            Name           = [string]$app.Name
            Detail         = $detail
            Id             = [string]$app.Id
            Source         = $source
            Version        = $pinnedVersion
            Pinned         = $pinned
            VersionPicker  = $versionPicker
            Exists         = $true
            WillDownload   = $false
            CategoryId     = $categoryId
            Category       = $categoryEn
            CategoryNameEn = $categoryEn
            CategoryNameFr = $categoryFr
            Item           = $app
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

        $categoryId = ''
        if ($null -ne $installer.PSObject.Properties['Category']) { $categoryId = [string]$installer.Category }
        $categoryEn = $categoryId
        $categoryFr = $categoryId
        if ($categories.ContainsKey($categoryId)) {
            $categoryEn = [string]$categories[$categoryId].NameEn
            $categoryFr = [string]$categories[$categoryId].NameFr
            if ([string]::IsNullOrWhiteSpace($categoryEn)) { $categoryEn = $categoryId }
            if ([string]::IsNullOrWhiteSpace($categoryFr)) { $categoryFr = $categoryEn }
        }

        [void]$items.Add([pscustomobject]@{
            Kind           = 'local'
            Name           = [string]$installer.Name
            Detail         = $detail
            Id             = [string]$installer.Path
            Exists         = $exists
            WillDownload   = $willDownload
            CategoryId     = $categoryId
            Category       = $categoryEn
            CategoryNameEn = $categoryEn
            CategoryNameFr = $categoryFr
            Item           = $installer
        })
    }

    # Present entries grouped in the category order defined in Software.json.
    # Entries without a known category keep their original order at the end.
    $grouped = [System.Collections.Generic.List[object]]::new()
    foreach ($category in @($Config.Categories)) {
        if ($null -eq $category) { continue }
        $id = [string]$category.Id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        foreach ($item in $items) {
            if ([string]$item.CategoryId -eq $id) { [void]$grouped.Add($item) }
        }
    }
    foreach ($item in $items) {
        if (-not $grouped.Contains($item)) { [void]$grouped.Add($item) }
    }

    return $grouped.ToArray()
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

    $App = Get-SetupCatalogEntry -Item $App
    if ($null -eq $App) { return $null }
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

    $displayName = [string]$App.Name
    $App = Get-SetupCatalogEntry -Item $App
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = [string]$App.Name }
    $source = Get-SetupCatalogSource -Item $App
    $pinnedVersion = [string]$App.Version
    $pinned = -not [string]::IsNullOrWhiteSpace($pinnedVersion)
    $name = [string]$App.Name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $displayName }

    $winget = Get-WingetCommand
    if ($null -eq $winget) {
        Write-SetupLog -Level Warning -Message ("Skipping {0}: winget is not available." -f $name)
        return New-SetupResult -Name $name -Success $false `
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

    Write-SetupLog -Level Task -Message ("Installing {0} ({1})" -f $name, $App.Id)
    # Keep the buffered capture: hash-mismatch detection needs the full text,
    # and the wording differs between English and French Windows.
    $wingetArgs = @(
        'install', '--id', [string]$App.Id, '--exact', '--source', $source,
        '--silent', '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($pinned -and $source -eq 'winget') {
        # --force makes winget apply the pin even when another version is
        # already installed. Without it, winget refuses to change the version.
        $wingetArgs += @('--version', $pinnedVersion, '--force')
        Write-SetupLog -Level Info -Message ("Pinned version requested: {0}" -f $pinnedVersion)
    } elseif ($pinned) {
        Write-SetupLog -Level Warning -Message ("Version pinning is not supported for the {0} source; installing the current version." -f $source)
    }
    $wingetOut = & $winget.Source @wingetArgs 2>&1 | Out-String
    if (-not [string]::IsNullOrWhiteSpace($wingetOut)) {
        Write-SetupLog -Level Detail -Message $wingetOut.TrimEnd()
    }
    $exitCode = $LASTEXITCODE
    $hashMismatch = $wingetOut -match '(?i)hash|hachage|mismatch|non concordance|ne correspond pas'

    # 0x8A15002B (-1978335189) is winget's "already installed" result.
    if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq -1978335189) {
        Write-SetupLog -Level Success -Message ("Finished: {0} (exit code {1})" -f $name, $exitCode)
        if ($exitCode -eq 3010) { Write-SetupLog -Level Warning -Message 'A restart may be required.' }
        return New-SetupResult -Name $name -Success $true -ExitCode $exitCode `
            -RestartRequired ($exitCode -eq 3010) -Message 'Installed.'
    }

    if ($hashMismatch) {
        Write-SetupLog -Level Warning -Message 'Winget reports an installer hash mismatch (stale manifest on the server side).'
        if ($pinned) {
            Write-SetupLog -Level Warning -Message 'The direct-download fallback is disabled for a pinned version because it downloads the vendor latest.'
        } else {
            Write-SetupLog -Level Warning -Message 'Winget refuses "--ignore-security-hash" while running as administrator, so trying the direct download instead.'
            $fallback = Install-SetupWingetFallback -App $App
            if ($null -ne $fallback) { return $fallback }
        }
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
            if ($pinned) {
                Write-SetupLog -Level Warning -Message 'Retry also reports a hash mismatch; the pinned entry has no direct-download fallback.'
            } else {
                Write-SetupLog -Level Warning -Message 'Retry also reports a hash mismatch; trying the direct download instead.'
                $fallback = Install-SetupWingetFallback -App $App
                if ($null -ne $fallback) { return $fallback }
            }
        }
        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq -1978335189) {
            Write-SetupLog -Level Success -Message ("Finished on retry: {0} (exit code {1})" -f $name, $exitCode)
            if ($exitCode -eq 3010) { Write-SetupLog -Level Warning -Message 'A restart may be required.' }
            return New-SetupResult -Name $name -Success $true -ExitCode $exitCode `
                -RestartRequired ($exitCode -eq 3010) -Message 'Installed on retry.'
        }
    }

    # Last resort for apps with a configured direct download.
    if ((-not $pinned) -and ($null -ne $App.FallbackUrl) -and (-not [string]::IsNullOrWhiteSpace([string]$App.FallbackUrl))) {
        Write-SetupLog -Level Warning -Message ("Winget failed for {0}; trying the configured direct download..." -f $name)
        $fallback = Install-SetupWingetFallback -App $App
        if ($null -ne $fallback) { return $fallback }
    }

    if ($exitCode -eq 1978335217 -or $exitCode -eq -1978335217) {
        Write-SetupLog -Level Warning -Message ("Installer returned exit code {0}: {1}" -f $exitCode, $name)
        Write-SetupLog -Level Warning -Message 'This is a Winget source error ("Failed when opening sources").'
        Write-SetupLog -Level Warning -Message 'Fix: open a new admin PowerShell and run "winget source reset --force", then "winget source update", then rerun.'
        Write-SetupLog -Level Warning -Message 'Also update App Installer: https://aka.ms/getwinget'
        return New-SetupResult -Name $name -Success $false -ExitCode $exitCode `
            -Message 'Winget source error. See the log for the manual fix.'
    }

    Write-SetupLog -Level Warning -Message ("Installer returned exit code {0}: {1}" -f $exitCode, $name)
    return New-SetupResult -Name $name -Success $false -ExitCode $exitCode `
        -Message ("Installer returned exit code {0}." -f $exitCode)
}

function Install-SetupLocalPackage {
    <#
    .SYNOPSIS
        Runs a local .exe/.msi installer, downloading it first when a Url is set.
    #>
    param([Parameter(Mandatory = $true)]$Installer)

    $displayName = [string]$Installer.Name
    $Installer = Get-SetupCatalogEntry -Item $Installer
    $name = [string]$Installer.Name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $displayName }
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
# Software inventory, update and removal
# --------------------------------------------------------------------------

function Get-SetupUninstallRegistryEntries {
    <#
    .SYNOPSIS
        Reads Add/Remove Programs entries from the 64-bit, 32-bit and per-user
        hives.
    #>
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $paths) {
        foreach ($entry in @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)) {
            if ($null -eq $entry) { continue }
            $displayName = [string]$entry.DisplayName
            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
            if ($entry.SystemComponent -eq 1) { continue }
            $releaseType = [string]$entry.ReleaseType
            if ($releaseType -match '(?i)^(Update|Hotfix|Security Update)$') { continue }
            if ($displayName -match '(?i)^(Update for|Security Update for|Hotfix for)') { continue }
            [void]$entries.Add([pscustomobject]@{
                DisplayName          = $displayName.Trim()
                DisplayVersion       = ([string]$entry.DisplayVersion).Trim()
                Publisher            = ([string]$entry.Publisher).Trim()
                UninstallString      = ([string]$entry.UninstallString).Trim()
                QuietUninstallString = ([string]$entry.QuietUninstallString).Trim()
                InstallLocation      = ([string]$entry.InstallLocation).Trim()
                KeyName              = [string]$entry.PSChildName
            })
        }
    }
    return $entries.ToArray()
}

function Find-SetupRegistryEntry {
    <#
    .SYNOPSIS
        Finds the Add/Remove Programs entry that matches a catalog item.
    .DESCRIPTION
        Uses the optional MatchName field first, then the display name. An
        exact name wins, then a prefix, then a word-boundary substring. A
        leading "Microsoft " prefix is ignored on both sides so entries such
        as "Microsoft Visual Studio Code (User)" match "Visual Studio Code".
    #>
    param($Entries, $Item)

    $matchNames = @()
    if ($null -ne $Item.Item) {
        $property = $Item.Item.PSObject.Properties['MatchName']
        if ($null -ne $property) {
            $value = [string]$property.Value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $matchNames = @($value -split '\s*[;|]\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
        }
    }
    if ($matchNames.Count -eq 0) { $matchNames = @([string]$Item.Name) }

    $best = $null
    $bestScore = 0
    foreach ($entry in @($Entries)) {
        $displayName = [string]$entry.DisplayName
        if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
        $displayVariants = @($displayName)
        $displayStripped = $displayName -replace '(?i)^Microsoft\s+', ''
        if ($displayStripped -ne $displayName) { $displayVariants += $displayStripped }

        foreach ($matchName in $matchNames) {
            $nameVariants = @($matchName)
            $nameStripped = $matchName -replace '(?i)^Microsoft\s+', ''
            if ($nameStripped -ne $matchName) { $nameVariants += $nameStripped }

            foreach ($variant in $displayVariants) {
                foreach ($candidate in $nameVariants) {
                    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                    $score = 0
                    if ($variant.Equals($candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $score = 100
                    } elseif ($variant.StartsWith($candidate, [System.StringComparison]::OrdinalIgnoreCase) -and
                        ($variant.Length -eq $candidate.Length -or -not [char]::IsLetterOrDigit($variant[$candidate.Length]))) {
                        # A prefix only counts when the next character is a
                        # separator: "Office 2024 - fr-fr" matches "Office 2024",
                        # but "GitHub CLI" must not match "Git".
                        $score = 80
                    } elseif ($variant -match ('(?i)(^|[^A-Za-z0-9])' + [regex]::Escape($candidate) + '([^A-Za-z0-9]|$)')) {
                        $score = 60
                    }
                    if ($score -gt $bestScore) {
                        $bestScore = $score
                        $best = $entry
                    }
                }
            }
        }
    }
    return $best
}

function ConvertFrom-SetupWingetList {
    <#
    .SYNOPSIS
        Parses the table printed by "winget list" for the requested IDs.
    .DESCRIPTION
        Winget has no JSON output for "list". Column headers are localized and
        can shift, so each matching data line is read from the right: the last
        token is the source, then the available version (when present), then
        the installed version.
    #>
    param(
        [AllowEmptyString()][string]$Text,
        [string[]]$Ids = @()
    )

    $rows = @{}
    $wanted = @($Ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($wanted.Count -eq 0) { return $rows }

    $idPattern = '(?i)(?<![^\s])(' + (($wanted | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?=\s|$)'
    foreach ($rawLine in ($Text -split "\r?\n")) {
        $line = ($rawLine -replace "\x1B\[[0-9;]*[A-Za-z]", '').Trim()
        if ($line.Length -eq 0) { continue }
        $idMatches = [regex]::Matches($line, $idPattern)
        if ($idMatches.Count -eq 0) { continue }
        $idMatch = $idMatches[$idMatches.Count - 1]
        $id = [string]$idMatch.Groups[1].Value
        $rest = $line.Substring($idMatch.Index + $idMatch.Length).Trim()
        if ($rest.Length -eq 0) { continue }

        $tokens = @($rest -split '\s+' | Where-Object { $_ -ne '' })
        if ($tokens.Count -eq 0) { continue }
        $source = ''
        $last = [string]$tokens[$tokens.Count - 1]
        if ($last -eq 'winget' -or $last -eq 'msstore') {
            $source = $last
            if ($tokens.Count -eq 1) { continue }
            $tokens = @($tokens[0..($tokens.Count - 2)])
        }
        if ($tokens.Count -eq 0) { continue }

        $version = ''
        $available = ''
        if ($tokens.Count -ge 3) {
            # Some winget builds add an extra token before the version; the
            # last two values are still installed version and update version.
            $version = [string]$tokens[$tokens.Count - 2]
            $available = [string]$tokens[$tokens.Count - 1]
        } elseif ($tokens.Count -eq 2) {
            $version = [string]$tokens[0]
            $available = [string]$tokens[1]
        } else {
            $version = [string]$tokens[0]
        }

        $key = $id.ToLowerInvariant()
        if (-not $rows.ContainsKey($key) -or ([string]::IsNullOrWhiteSpace([string]$rows[$key].Version) -and -not [string]::IsNullOrWhiteSpace($version))) {
            $rows[$key] = [pscustomobject]@{
                Id        = $id
                Version   = $version
                Available = $available
                Source    = $source
                Line      = $line
            }
        }
    }
    return $rows
}

function Invoke-SetupUninstallCommand {
    <#
    .SYNOPSIS
        Runs an uninstall command taken from the Add/Remove Programs registry.
    #>
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $command = ($CommandLine -replace '\r?\n', ' ').Trim()
    if ($command -match '(?i)^\s*"?MsiExec(?:\.exe)?"?\s+/([IX])\s*(\{[0-9A-Fa-f\-]+\})') {
        $productCode = $matches[2]
        $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') `
            -ArgumentList (@('/x', $productCode, '/qn', '/norestart') -join ' ') `
            -Wait -PassThru -ErrorAction Stop
        return $process.ExitCode
    }

    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') `
        -ArgumentList @('/c', $command) -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    return $process.ExitCode
}

function ConvertTo-SetupVersionParts {
    <#
    .SYNOPSIS
        Extracts the dotted numeric parts of a version string.
    #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '\d+(?:\.\d+)+')
    if (-not $match.Success) { return $null }
    return @($match.Value -split '\.' | ForEach-Object { [long]$_ })
}

function Compare-SetupVersionText {
    <#
    .SYNOPSIS
        Compares two version strings numerically.
    .OUTPUTS
        -1 when Left is older, 0 when equal, 1 when Left is newer, or $null when
        either value has no dotted numeric version.
    #>
    param([string]$Left, [string]$Right)

    $a = ConvertTo-SetupVersionParts -Text $Left
    $b = ConvertTo-SetupVersionParts -Text $Right
    if ($null -eq $a -or $null -eq $b) { return $null }
    $length = [Math]::Max($a.Count, $b.Count)
    for ($index = 0; $index -lt $length; $index++) {
        $x = if ($index -lt $a.Count) { $a[$index] } else { [long]0 }
        $y = if ($index -lt $b.Count) { $b[$index] } else { [long]0 }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

function Get-SetupWingetLatestVersion {
    <#
    .SYNOPSIS
        Returns the version published by the winget source, or an empty string.
    .DESCRIPTION
        "winget list" only shows an installed package under the catalog ID when
        winget manages that installation. Apps installed outside winget (Chrome
        from its MSI, for example) appear under an ARP ID, so their update
        status has to come from the source itself.
    #>
    param(
        [Parameter(Mandatory = $true)]$Winget,
        [string]$Id,
        [hashtable]$Cache = $null
    )

    if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
    if ($null -ne $Cache -and $Cache.ContainsKey($Id)) { return [string]$Cache[$Id] }

    $version = ''
    try {
        $output = & $Winget.Source show --id $Id --exact --source winget `
            --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            # The label is localized (for example "Version :" or "Version: "),
            # so match it loosely and keep the value ASCII.
            $match = [regex]::Match($output, '(?im)^\s*Versi\S*\s*:\s*(\S+)')
            if (-not $match.Success) {
                # Locales such as Russian or Japanese use a different label.
                # The package version is the first "field: dotted.version" line.
                $match = [regex]::Match($output, '(?im)^[^:\r\n]+:\s*(\d+(?:\.\d+)+)\s*$')
            }
            if ($match.Success) { $version = $match.Groups[1].Value.Trim() }
        }
    } catch {
        $version = ''
    }
    if ($null -ne $Cache) { $Cache[$Id] = $version }
    return $version
}

function Get-SetupWingetVersions {
    <#
    .SYNOPSIS
        Returns the versions published by the winget source, newest first.
    .DESCRIPTION
        "winget show --versions" prints a localized table. Only the dotted
        numeric version column is kept, so headers and separators in any
        language are ignored. Results are cached per check because one call
        per package is enough.
    #>
    param(
        $Winget = $null,
        [string]$Id,
        [hashtable]$Cache = $null
    )

    if ([string]::IsNullOrWhiteSpace($Id)) { return @() }
    if ($null -eq $Winget) { $Winget = Get-WingetCommand }
    if ($null -eq $Winget) { return @() }
    if ($null -ne $Cache -and $Cache.ContainsKey($Id)) { return @($Cache[$Id]) }

    $versions = @()
    try {
        $output = & $Winget.Source show --id $Id --exact --source winget --versions `
            --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $seen = @{}
            foreach ($line in ($output -split '\r?\n')) {
                $text = $line.Trim()
                if ($text -notmatch '^\d+(?:\.\d+)+$') { continue }
                if ($seen.ContainsKey($text)) { continue }
                $seen[$text] = $true
                $versions += $text
            }
        }
    } catch {
        $versions = @()
    }
    if ($null -ne $Cache) { $Cache[$Id] = $versions }
    return $versions
}

function Get-SetupInstalledSoftware {
    <#
    .SYNOPSIS
        Checks every enabled catalog entry for its installed version and any
        available winget update.
    .DESCRIPTION
        Installed versions come from the Windows uninstall registry and, for
        winget-managed packages, from "winget list". Update information is only
        reported when winget recognises the catalog ID, so the GUI never offers
        an update it cannot actually perform.
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $catalog = @(Get-SoftwareCatalog -Config $Config)
    $registryEntries = @(Get-SetupUninstallRegistryEntries)
    $wingetRows = @{}
    $winget = Get-WingetCommand
    $wingetAvailable = ($null -ne $winget)

    Write-SetupLog -Level Task -Message 'Checking installed software versions and updates ...'
    if ($wingetAvailable) {
        try {
            $output = & $winget.Source list --accept-source-agreements --disable-interactivity 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                Write-SetupLog -Level Warning -Message ("winget list returned exit code {0}; some versions may be missing." -f $exitCode)
            }
            $wingetIds = @($catalog | Where-Object { $_.Kind -eq 'winget' } | ForEach-Object { [string]$_.Id })
            $wingetRows = ConvertFrom-SetupWingetList -Text $output -Ids $wingetIds
        } catch {
            Write-SetupLog -Level Warning -Message ("Could not query winget: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-SetupLog -Level Warning -Message 'winget is not available; only the Windows uninstall registry will be checked.'
    }

    $packages = [System.Collections.Generic.List[object]]::new()
    $installedCount = 0
    $updateCount = 0
    $latestVersionCache = @{}
    $versionPickerCache = @{}

    foreach ($item in $catalog) {
        $itemSource = Get-SetupCatalogSource -Item $item
        $registryEntry = $null
        if ($registryEntries.Count -gt 0) {
            $registryEntry = Find-SetupRegistryEntry -Entries $registryEntries -Item $item
        }
        $wingetRow = $null
        if ($item.Kind -eq 'winget') {
            $key = ([string]$item.Id).ToLowerInvariant()
            if ($wingetRows.ContainsKey($key)) { $wingetRow = $wingetRows[$key] }
        }

        $installed = ($null -ne $registryEntry) -or ($null -ne $wingetRow)
        $version = ''
        if ($null -ne $registryEntry) { $version = [string]$registryEntry.DisplayVersion }
        if ([string]::IsNullOrWhiteSpace($version) -and $null -ne $wingetRow) {
            $version = [string]$wingetRow.Version
        }

        $pinned = ($null -ne $item.PSObject.Properties['Pinned']) -and [bool]$item.Pinned
        $pinnedVersion = ''
        if ($null -ne $item.PSObject.Properties['Version']) { $pinnedVersion = [string]$item.Version }

        $versionPicker = ($null -ne $item.PSObject.Properties['VersionPicker']) -and [bool]$item.VersionPicker
        if ($itemSource -ne 'winget') { $versionPicker = $false }
        $versions = @()
        if ($versionPicker) {
            if ($null -ne $winget) {
                $versions = @(Get-SetupWingetVersions -Winget $winget -Id ([string]$item.Id) -Cache $versionPickerCache)
            }
            if ($versions.Count -gt 0) {
                Write-SetupLog -Level Detail -Message ("{0}: {1} version(s) available online." -f [string]$item.Name, $versions.Count)
            } else {
                Write-SetupLog -Level Warning -Message ("Could not read the list of available versions for {0}." -f [string]$item.Name)
            }
        }

        $available = ''
        $updateKnown = $false
        $updateSource = ''
        $updateMethod = ''
        if ($pinned) {
            # Pinned entries stay on the requested version by design.
            $updateKnown = $true
        } elseif ($null -ne $wingetRow) {
            $available = [string]$wingetRow.Available
            $updateSource = [string]$wingetRow.Source
            # "winget list" also reports Microsoft Store packages. Updates are
            # only offered for the winget source because the Microsoft Store
            # keeps those applications up to date itself.
            $updateKnown = ($updateSource -eq 'winget')
        } elseif ($itemSource -eq 'winget' -and $null -ne $registryEntry -and $null -ne $winget) {
            # Installed, but winget does not manage this installation: Chrome
            # from its MSI shows up as an ARP entry. Compare the installed
            # version with the version published by the winget source instead
            # of reporting Unknown for ever.
            $latest = Get-SetupWingetLatestVersion -Winget $winget -Id ([string]$item.Id) -Cache $latestVersionCache
            if (-not [string]::IsNullOrWhiteSpace($latest)) {
                $comparison = Compare-SetupVersionText -Left $version -Right $latest
                if ($null -ne $comparison) {
                    $updateKnown = $true
                    if ($comparison -lt 0) {
                        $available = $latest
                        # "winget upgrade" cannot see this installation; a
                        # forced install of the same package applies the update.
                        $updateMethod = 'install'
                    }
                }
            }
        }

        $updateAvailable = $updateKnown -and (-not [string]::IsNullOrWhiteSpace($available)) -and ($available -ne $version)
        if ($updateAvailable -and [string]::IsNullOrWhiteSpace($updateMethod) -and $null -ne $wingetRow) {
            $updateMethod = 'upgrade'
        }

        $hasRegistryUninstall = ($null -ne $registryEntry) -and (
            (-not [string]::IsNullOrWhiteSpace($registryEntry.UninstallString)) -or
            (-not [string]::IsNullOrWhiteSpace($registryEntry.QuietUninstallString))
        )
        $wingetManaged = ($item.Kind -eq 'winget') -and ($null -ne $wingetRow)
        $uninstallable = $hasRegistryUninstall -or $wingetManaged

        $source = ''
        if ($null -ne $registryEntry) { $source = 'registry' }
        elseif ($null -ne $wingetRow) { $source = 'winget' }

        if ($installed) { $installedCount++ }
        if ($updateAvailable) { $updateCount++ }

        [void]$packages.Add([pscustomobject]@{
            Name            = [string]$item.Name
            Kind            = [string]$item.Kind
            Id              = [string]$item.Id
            Installed       = $installed
            Version         = $version
            Available       = $available
            UpdateAvailable = $updateAvailable
            UpdateKnown     = $updateKnown
            UpdateSource    = $updateSource
            UpdateMethod    = $updateMethod
            Pinned          = $pinned
            PinnedVersion   = $pinnedVersion
            VersionPicker   = $versionPicker
            Versions        = $versions
            WingetManaged   = $wingetManaged
            Uninstallable   = $uninstallable
            Source          = $source
        })
    }

    $result = New-SetupResult -Name 'Installed software' -Success $true `
        -Message ("{0} installed, {1} update(s) available." -f $installedCount, $updateCount) `
        -Data @{
            Packages        = $packages.ToArray()
            WingetAvailable = $wingetAvailable
            InstalledCount  = $installedCount
            UpdateCount     = $updateCount
        }
    Write-SetupLog -Level Success -Message ("Installed software check finished: {0} installed, {1} update(s) available." -f $installedCount, $updateCount)
    return $result
}

function Uninstall-SetupSoftware {
    <#
    .SYNOPSIS
        Uninstalls one catalog item through winget or the Windows uninstall
        registry.
    .DESCRIPTION
        Winget is used when it recognises the package. A winget catalog entry
        that winget does not manage (for example a manually installed Chrome)
        falls back to its Add/Remove Programs entry.
    #>
    param(
        [Parameter(Mandatory = $true)]$CatalogItem,
        [Nullable[bool]]$WingetManaged = $null
    )

    $entry = Get-SetupCatalogEntry -Item $CatalogItem
    $name = [string]$CatalogItem.Name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$entry.Name }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Software' }
    $id = [string]$CatalogItem.Id
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$entry.Id }

    $useWinget = ($CatalogItem.Kind -eq 'winget')
    if ($null -ne $WingetManaged) {
        $useWinget = $useWinget -and [bool]$WingetManaged
    } else {
        $property = $CatalogItem.PSObject.Properties['WingetManaged']
        if ($null -ne $property) { $useWinget = $useWinget -and [bool]$property.Value }
    }

    if ($useWinget) {
        $winget = Get-WingetCommand
        if ($null -eq $winget) {
            Write-SetupLog -Level Warning -Message ("Cannot uninstall {0}: winget is not available." -f $name)
            return New-SetupResult -Name $name -Success $false -Message 'winget is not available.'
        }
        Write-SetupLog -Level Task -Message ("Uninstalling {0} ({1})" -f $name, $id)
        $wingetArgs = @(
            'uninstall', '--id', $id, '--exact', '--all',
            '--silent', '--accept-source-agreements', '--disable-interactivity'
        )
        try {
            $output = & $winget.Source @wingetArgs 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
            if (-not [string]::IsNullOrWhiteSpace($output)) {
                Write-SetupLog -Level Detail -Message $output.TrimEnd()
            }
            if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641) {
                Write-SetupLog -Level Success -Message ("Uninstalled: {0}" -f $name)
                return New-SetupResult -Name $name -Success $true -ExitCode $exitCode `
                    -RestartRequired ($exitCode -in @(3010, 1641)) -Message 'Uninstalled.'
            }
            Write-SetupLog -Level Warning -Message ("Uninstall returned exit code {0}: {1}" -f $exitCode, $name)
            return New-SetupResult -Name $name -Success $false -ExitCode $exitCode `
                -Message ("Uninstall returned exit code {0}." -f $exitCode)
        } catch {
            Write-SetupLog -Level Error -Message ("Could not uninstall {0}: {1}" -f $name, $_.Exception.Message)
            return New-SetupResult -Name $name -Success $false -Message 'Could not launch the uninstaller.'
        }
    }

    $entries = @(Get-SetupUninstallRegistryEntries)
    $entry = Find-SetupRegistryEntry -Entries $entries -Item $CatalogItem
    if ($null -eq $entry) {
        Write-SetupLog -Level Warning -Message ("No uninstall entry was found for {0}." -f $name)
        return New-SetupResult -Name $name -Success $false `
            -Message 'No Add/Remove Programs entry matched this application.'
    }

    $command = [string]$entry.QuietUninstallString
    if ([string]::IsNullOrWhiteSpace($command)) { $command = [string]$entry.UninstallString }
    if ([string]::IsNullOrWhiteSpace($command)) {
        Write-SetupLog -Level Warning -Message ("No uninstall command is registered for {0}." -f $name)
        return New-SetupResult -Name $name -Success $false -Message 'No uninstall command is registered.'
    }

    Write-SetupLog -Level Task -Message ("Uninstalling {0} ({1})" -f $name, $entry.DisplayName)
    Write-SetupLog -Level Detail -Message ("Command: {0}" -f ($command -replace '\s+', ' '))
    try {
        $exitCode = Invoke-SetupUninstallCommand -CommandLine $command
        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641) {
            Write-SetupLog -Level Success -Message ("Uninstalled: {0}" -f $name)
            return New-SetupResult -Name $name -Success $true -ExitCode $exitCode `
                -RestartRequired ($exitCode -in @(3010, 1641)) -Message 'Uninstalled.'
        }
        Write-SetupLog -Level Warning -Message ("Uninstall returned exit code {0}: {1}" -f $exitCode, $name)
        return New-SetupResult -Name $name -Success $false -ExitCode $exitCode `
            -Message ("Uninstall returned exit code {0}." -f $exitCode)
    } catch {
        Write-SetupLog -Level Error -Message ("Could not uninstall {0}: {1}" -f $name, $_.Exception.Message)
        return New-SetupResult -Name $name -Success $false -Message 'Could not launch the uninstaller.'
    }
}

function Update-SetupSoftware {
    <#
    .SYNOPSIS
        Updates one winget catalog item to the latest available version.
    .DESCRIPTION
        Method "upgrade" uses "winget upgrade" and is the normal path.
        Method "install" is for a package winget can see in its source but not
        in its installed list (Chrome from its MSI, for example): a forced
        install of the same package applies the update.
    #>
    param(
        [Parameter(Mandatory = $true)]$CatalogItem,
        [ValidateSet('upgrade', 'install')][string]$Method = 'upgrade'
    )

    $entry = Get-SetupCatalogEntry -Item $CatalogItem
    $name = [string]$CatalogItem.Name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$entry.Name }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Software' }
    $id = [string]$CatalogItem.Id
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$entry.Id }
    $source = Get-SetupCatalogSource -Item $entry

    $pinnedVersion = ''
    if ($null -ne $entry.PSObject.Properties['Version']) { $pinnedVersion = ([string]$entry.Version).Trim() }
    if ($CatalogItem.Kind -ne 'winget') {
        return New-SetupResult -Name $name -Success $true -Skipped $true `
            -Message 'Local installers are updated by running the installer again.'
    }
    if (-not [string]::IsNullOrWhiteSpace($pinnedVersion)) {
        Write-SetupLog -Level Info -Message ("{0} is pinned to version {1}; it is not updated automatically." -f $name, $pinnedVersion)
        return New-SetupResult -Name $name -Success $true -Skipped $true `
            -Message ("Pinned to version {0}." -f $pinnedVersion)
    }

    $winget = Get-WingetCommand
    if ($null -eq $winget) {
        Write-SetupLog -Level Warning -Message ("Cannot update {0}: winget is not available." -f $name)
        return New-SetupResult -Name $name -Success $false -Message 'winget is not available.'
    }

    Write-SetupLog -Level Task -Message ("Updating {0} ({1})" -f $name, $id)
    $wingetArgs = @(
        'upgrade', '--id', $id, '--exact', '--source', $source,
        '--silent', '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($Method -eq 'install') {
        Write-SetupLog -Level Info -Message 'Winget does not manage this installation; reinstalling the latest version from its source.'
        $wingetArgs = @(
            'install', '--id', $id, '--exact', '--source', $source,
            '--silent', '--force', '--accept-package-agreements', '--accept-source-agreements',
            '--disable-interactivity'
        )
    }
    try {
        $output = & $winget.Source @wingetArgs 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        if (-not [string]::IsNullOrWhiteSpace($output)) {
            Write-SetupLog -Level Detail -Message $output.TrimEnd()
        }
        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641) {
            Write-SetupLog -Level Success -Message ("Updated: {0}" -f $name)
            return New-SetupResult -Name $name -Success $true -ExitCode $exitCode `
                -RestartRequired ($exitCode -in @(3010, 1641)) -Message 'Updated.'
        }
        if ($exitCode -eq -1978335189) {
            Write-SetupLog -Level Info -Message ("No update is available for {0}." -f $name)
            return New-SetupResult -Name $name -Success $true -Skipped $true -ExitCode $exitCode `
                -Data @{ NoUpdate = $true } -Message 'No update is available.'
        }
        Write-SetupLog -Level Warning -Message ("Update returned exit code {0}: {1}" -f $exitCode, $name)
        return New-SetupResult -Name $name -Success $false -ExitCode $exitCode `
            -Message ("Update returned exit code {0}." -f $exitCode)
    } catch {
        Write-SetupLog -Level Error -Message ("Could not update {0}: {1}" -f $name, $_.Exception.Message)
        return New-SetupResult -Name $name -Success $false -Message 'Could not launch the update.'
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

function Set-SetupLocalUserEnabled {
    <#
    .SYNOPSIS
        Enables or disables a local user account.
    .DESCRIPTION
        Only changes the account flag: the profile, files and password are
        left untouched. Two cases are refused for safety: disabling the last
        enabled administrator, and disabling the account that launched the
        setup (ProtectedSid, or the current process identity when omitted).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [string]$ProtectedSid = ''
    )

    $account = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($null -eq $account) {
        $message = ("Local user '{0}' was not found." -f $UserName)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name $UserName -Success $false -Message $message
    }

    $state = if ($Enabled) { 'enabled' } else { 'disabled' }
    if ([bool]$account.Enabled -eq $Enabled) {
        $message = ("'{0}' is already {1}." -f $UserName, $state)
        Write-SetupLog -Level Info -Message $message
        return New-SetupResult -Name $UserName -Success $true -Skipped $true -Message $message
    }

    if (-not $Enabled) {
        # Disabling the only enabled administrator would make the PC
        # unrecoverable, so it is refused before touching the account.
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
        if (($enabledAdminSids.Count -eq 1) -and ($enabledAdminSids[0] -eq $account.SID.Value)) {
            $message = ("'{0}' is the only enabled administrator on this PC. Enable or create another administrator before disabling this account." -f $UserName)
            Write-SetupLog -Level Warning -Message $message
            return New-SetupResult -Name $UserName -Success $false -Message $message
        }

        $protected = $ProtectedSid
        if ([string]::IsNullOrWhiteSpace($protected)) {
            try { $protected = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch {}
        }
        if ((-not [string]::IsNullOrWhiteSpace($protected)) -and ($null -ne $account.SID) -and ($account.SID.Value -eq $protected)) {
            $message = ("'{0}' is the account you are signed in with. Disable it from another administrator account." -f $UserName)
            Write-SetupLog -Level Warning -Message $message
            return New-SetupResult -Name $UserName -Success $false -Message $message
        }
    }

    Write-SetupLog -Level Task -Message ("{0} local account '{1}'." -f $(if ($Enabled) { 'Enabling' } else { 'Disabling' }), $UserName)
    try {
        if ($Enabled) {
            Enable-LocalUser -Name $UserName -ErrorAction Stop
        } else {
            Disable-LocalUser -Name $UserName -ErrorAction Stop
        }
        $message = ("Account '{0}' is now {1}." -f $UserName, $state)
        Write-SetupLog -Level Success -Message $message
        return New-SetupResult -Name $UserName -Success $true -Message $message
    } catch {
        # Fallback for editions where the LocalUser cmdlets are unavailable.
        Write-SetupLog -Level Warning -Message ("LocalUser cmdlet failed ({0}), trying 'net user' fallback..." -f $_.Exception.Message)
        try {
            $flag = if ($Enabled) { '/active:yes' } else { '/active:no' }
            $netOutput = & net user $UserName $flag 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                throw ("net user exited with code {0}. {1}" -f $LASTEXITCODE, $netOutput.Trim())
            }
            $check = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
            if (($null -ne $check) -and ([bool]$check.Enabled -ne $Enabled)) {
                throw 'the account state did not change'
            }
            $message = ("Account '{0}' is now {1}." -f $UserName, $state)
            Write-SetupLog -Level Success -Message $message
            return New-SetupResult -Name $UserName -Success $true -Message $message
        } catch {
            $message = ("Could not {0} '{1}': {2}" -f $(if ($Enabled) { 'enable' } else { 'disable' }), $UserName, $_.Exception.Message)
            Write-SetupLog -Level Error -Message $message
            return New-SetupResult -Name $UserName -Success $false -Message $message
        }
    }
}

function New-SetupLocalUser {
    <#
    .SYNOPSIS
        Creates a local Windows account, optionally as an administrator.
    .DESCRIPTION
        The password is required and must be at least 8 characters. The
        password-never-expires and change-at-next-sign-in options are mutually
        exclusive. A restore point can be requested before the account is
        created; a failed checkpoint is reported but does not block creation.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][Security.SecureString]$Password,
        [switch]$Administrator,
        [switch]$PasswordNeverExpires,
        [switch]$RequirePasswordChange,
        [switch]$CreateRestorePoint
    )

    $UserName = $UserName.Trim()
    $validation = Test-LocalAccountName -Name $UserName
    if ($null -ne $validation) {
        return New-SetupResult -Name $UserName -Success $false -Message $validation
    }
    if ($PasswordNeverExpires -and $RequirePasswordChange) {
        return New-SetupResult -Name $UserName -Success $false `
            -Message 'Choose either password-never-expires or change-at-next-sign-in, not both.'
    }

    $plainLength = 0
    try { $plainLength = [System.Net.NetworkCredential]::new('', $Password).Password.Length } catch { $plainLength = $Password.Length }
    if ($plainLength -lt 8) {
        return New-SetupResult -Name $UserName -Success $false -Message 'The password must be at least 8 characters.'
    }

    if ($null -ne (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        return New-SetupResult -Name $UserName -Success $false `
            -Message ("A local account named '{0}' already exists." -f $UserName)
    }

    $restorePoint = $null
    if ($CreateRestorePoint) {
        $restorePoint = New-SetupRestorePoint -Description ("Before creating local user {0}" -f $UserName)
        if (-not $restorePoint.Success) {
            Write-SetupLog -Level Warning -Message ("Continuing without a restore point: {0}" -f $restorePoint.Message)
        }
    }

    Write-SetupLog -Level Task -Message ("Creating local user '{0}'." -f $UserName)
    try {
        $createParameters = @{
            Name               = $UserName
            Password           = $Password
            AccountNeverExpires = $true
            PasswordNeverExpires = [bool]$PasswordNeverExpires
            ErrorAction        = 'Stop'
        }
        New-LocalUser @createParameters | Out-Null

        if ($RequirePasswordChange) {
            $netOutput = & net user $UserName /logonpasswordchg:yes 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-SetupLog -Level Warning -Message ("The account was created, but change-at-next-sign-in could not be set: {0}" -f $netOutput.Trim())
            }
        }

        if ($Administrator) {
            $adminGroup = @(Get-LocalGroup -ErrorAction Stop | Where-Object {
                $null -ne $_.SID -and $_.SID.Value -match '-544$'
            } | Select-Object -First 1)
            if ($adminGroup.Count -eq 0) {
                throw 'The Administrators group was not found.'
            }
            Add-LocalGroupMember -Group $adminGroup[0].Name -Member $UserName -ErrorAction Stop
        }

        $check = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
        if ($null -eq $check) {
            throw 'Windows did not report the new account after creation.'
        }
        $role = if ($Administrator) { 'administrator' } else { 'standard user' }
        $message = ("Created local {0} '{1}'." -f $role, $UserName)
        Write-SetupLog -Level Success -Message $message
        return New-SetupResult -Name $UserName -Success $true -Message $message `
            -Data @{
                UserName             = $UserName
                Administrator        = [bool]$Administrator
                PasswordNeverExpires = [bool]$PasswordNeverExpires
                RequirePasswordChange = [bool]$RequirePasswordChange
                RestorePoint         = $restorePoint
            }
    } catch {
        $message = ("Could not create the local account '{0}': {1}" -f $UserName, $_.Exception.Message)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name $UserName -Success $false -Message $message `
            -Data @{ RestorePoint = $restorePoint }
    }
}

function Remove-SetupLocalUser {
    <#
    .SYNOPSIS
        Deletes a local account. The profile folder and files are kept.
    .DESCRIPTION
        The built-in Administrator, the signed-in account and the last enabled
        administrator are refused. A restore point can be requested first.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [string]$ProtectedSid = '',
        [switch]$CreateRestorePoint
    )

    $account = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($null -eq $account) {
        $message = ("Local user '{0}' was not found." -f $UserName)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name $UserName -Success $false -Message $message
    }

    $sidValue = ''
    if ($null -ne $account.SID) { $sidValue = [string]$account.SID.Value }
    if ($sidValue -match '-500$') {
        $message = 'The built-in Administrator account cannot be deleted here.'
        Write-SetupLog -Level Warning -Message $message
        return New-SetupResult -Name $UserName -Success $false -Message $message
    }

    $protected = $ProtectedSid
    if ([string]::IsNullOrWhiteSpace($protected)) {
        try { $protected = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
    }
    if ((-not [string]::IsNullOrWhiteSpace($protected)) -and ($sidValue -eq $protected)) {
        $message = ("'{0}' is the account you are signed in with. Delete it from another administrator account." -f $UserName)
        Write-SetupLog -Level Warning -Message $message
        return New-SetupResult -Name $UserName -Success $false -Message $message
    }

    $lock = Get-SoleAdminLock -UserName $UserName
    if ($lock.Locked) {
        Write-SetupLog -Level Warning -Message $lock.Message
        return New-SetupResult -Name $UserName -Success $false -Message $lock.Message
    }

    $restorePoint = $null
    if ($CreateRestorePoint) {
        $restorePoint = New-SetupRestorePoint -Description ("Before deleting local user {0}" -f $UserName)
        if (-not $restorePoint.Success) {
            Write-SetupLog -Level Warning -Message ("Continuing without a restore point: {0}" -f $restorePoint.Message)
        }
    }

    Write-SetupLog -Level Task -Message ("Deleting local user '{0}'." -f $UserName)
    try {
        Remove-LocalUser -Name $UserName -ErrorAction Stop
        if ($null -ne (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
            throw 'Windows still reports the account after deletion.'
        }
        $message = ("Deleted local account '{0}'. The profile folder and files were kept." -f $UserName)
        Write-SetupLog -Level Success -Message $message
        return New-SetupResult -Name $UserName -Success $true -Message $message `
            -Data @{ UserName = $UserName; RestorePoint = $restorePoint }
    } catch {
        $message = ("Could not delete the local account '{0}': {1}" -f $UserName, $_.Exception.Message)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name $UserName -Success $false -Message $message `
            -Data @{ RestorePoint = $restorePoint }
    }
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

function Set-SetupDefaultPrinter {
    <#
    .SYNOPSIS
        Sets the default printer for the current user.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $printer = Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $printer) {
        $message = ("Printer '{0}' was not found." -f $Name)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name $Name -Success $false -Message $message
    }
    if ([bool]$printer.Default) {
        return New-SetupResult -Name $Name -Success $true -Skipped $true `
            -Message ("'{0}' is already the default printer." -f $Name)
    }

    try {
        Invoke-CimMethod -InputObject $printer -MethodName SetDefaultPrinter -ErrorAction Stop | Out-Null
    } catch {
        Write-SetupLog -Level Warning -Message ("CIM default-printer call failed ({0}), trying printui.dll..." -f $_.Exception.Message)
        try {
            $process = Start-Process -FilePath 'rundll32.exe' -ArgumentList @('printui.dll,PrintUIEntry', '/y', '/n', $Name) -Wait -PassThru -ErrorAction Stop
            if ($process.ExitCode -ne 0) { throw ("printui.dll returned exit code {0}." -f $process.ExitCode) }
        } catch {
            $message = ("Could not set the default printer: {0}" -f $_.Exception.Message)
            Write-SetupLog -Level Error -Message $message
            return New-SetupResult -Name $Name -Success $false -Message $message
        }
    }

    $defaultName = ''
    try {
        $default = Get-CimInstance -ClassName Win32_Printer -Filter 'Default = TRUE' -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $default) { $defaultName = [string]$default.Name }
    } catch { }
    if ($defaultName -ne $Name) {
        $message = ("Windows did not report '{0}' as the default printer." -f $Name)
        Write-SetupLog -Level Warning -Message $message
        return New-SetupResult -Name $Name -Success $false -Message $message
    }
    $message = ("'{0}' is now the default printer." -f $Name)
    Write-SetupLog -Level Success -Message $message
    return New-SetupResult -Name $Name -Success $true -Message $message
}

function Test-SetupPrinterPage {
    <#
    .SYNOPSIS
        Sends a Windows test page to a printer.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $printer = Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $printer) {
        $message = ("Printer '{0}' was not found." -f $Name)
        Write-SetupLog -Level Error -Message $message
        return New-SetupResult -Name $Name -Success $false -Message $message
    }

    try {
        Invoke-CimMethod -InputObject $printer -MethodName PrintTestPage -ErrorAction Stop | Out-Null
        $message = ("Windows sent a test page to '{0}'." -f $Name)
        Write-SetupLog -Level Success -Message $message
        return New-SetupResult -Name $Name -Success $true -Message $message
    } catch {
        Write-SetupLog -Level Warning -Message ("CIM test-page call failed ({0}), trying printui.dll..." -f $_.Exception.Message)
        try {
            $process = Start-Process -FilePath 'rundll32.exe' -ArgumentList @('printui.dll,PrintUIEntry', '/k', '/n', $Name) -Wait -PassThru -ErrorAction Stop
            if ($process.ExitCode -ne 0) { throw ("printui.dll returned exit code {0}." -f $process.ExitCode) }
            $message = ("Windows sent a test page to '{0}'." -f $Name)
            Write-SetupLog -Level Success -Message $message
            return New-SetupResult -Name $Name -Success $true -Message $message
        } catch {
            $message = ("Could not print a test page: {0}" -f $_.Exception.Message)
            Write-SetupLog -Level Error -Message $message
            return New-SetupResult -Name $Name -Success $false -Message $message
        }
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
    'Get-SetupCategories',
    'Get-SetupProfiles',
    'Get-SetupSystemInfo',
    'Get-SetupWindowsUpdateStatus',
    'Get-SetupSecurityStatus',
    'Get-SetupStorageStatus',
    'Get-SetupNetworkStatus',
    'Get-SetupPowerStatus',
    'Get-SetupFeatureStatus',
    'Get-SetupSystemDashboard',
    'Export-SetupSystemReport',
    'Test-SetupElevated',
    'Set-SetupPowerPlan',
    'Set-SetupHibernation',
    'Set-SetupFastStartup',
    'Set-SetupPowerSettings',
    'Set-SetupDnsPreset',
    'Clear-SetupDnsCache',
    'Test-SetupNetworkPath',
    'Clear-SetupTempFiles',
    'Set-SetupStorageSense',
    'Set-SetupTimeZone',
    'Test-SetupRestorePointSupport',
    'New-SetupRestorePoint',
    'Test-SetupPreflight',
    'Export-SetupReport',
    'Test-LocalAccountName',
    'Repair-SetupWingetSource',
    'Install-SetupWingetApp',
    'Install-SetupLocalPackage',
    'Get-SetupWingetVersions',
    'Get-SetupInstalledSoftware',
    'Uninstall-SetupSoftware',
    'Update-SetupSoftware',
    'Get-BuiltInAdminAccount',
    'Get-CurrentLocalAccount',
    'Enable-BuiltInAdministrator',
    'Rename-SetupLocalAccount',
    'Set-SetupLocalAccountPassword',
    'Get-LocalUserInventory',
    'Set-SetupLocalUserEnabled',
    'New-SetupLocalUser',
    'Remove-SetupLocalUser',
    'Get-LocalGroupNames',
    'Get-SoleAdminLock',
    'Add-SetupLocalGroupMember',
    'Remove-SetupLocalGroupMember',
    'Get-PrinterInventory',
    'Get-PrinterDriverNames',
    'Rename-SetupPrinter',
    'Set-SetupDefaultPrinter',
    'Test-SetupPrinterPage',
    'Get-DriverInfCandidates',
    'Install-SetupNetworkPrinter'
)
