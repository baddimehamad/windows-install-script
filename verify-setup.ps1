#Requires -Version 5.1
<#
.SYNOPSIS
    Acceptance tests for Windows Automatic Setup.

.DESCRIPTION
    Read-only verification of the repository state and both front-ends:
    parsing, ASCII sources, Software.json, logos, bilingual string coverage,
    core actions, report export and the GUI smoke test in English and French.

    The script never installs software, never creates or deletes accounts and
    never changes a printer. The only writes are temporary report files and a
    temporary test folder under the user's temp directory, removed at the end.

.PARAMETER SkipGui
    Skip the two GUI smoke tests (useful on a machine without an interactive
    desktop, for example a CI agent running as a service).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-setup.ps1
#>
param(
    [switch]$SkipGui
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $root

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:PassCount = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$Detail = ''
    )
    if ($Condition) {
        $script:PassCount++
        Write-Host ("  PASS  {0}" -f $Label) -ForegroundColor Green
    } else {
        $message = $Label
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { $message = $message + ' - ' + $Detail }
        $script:Failures.Add($message)
        Write-Host ("  FAIL  {0}" -f $message) -ForegroundColor Red
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
}

function Read-Bytes {
    param([string]$Path)
    return [System.IO.File]::ReadAllBytes($Path)
}

# --------------------------------------------------------------------------
# 1. Parsing and ASCII sources
# --------------------------------------------------------------------------

Write-Section 'Source files'

$sourceFiles = @(Get-ChildItem -LiteralPath $root -File | Where-Object {
    $_.Extension -in @('.ps1', '.psm1')
})
Assert-True ($sourceFiles.Count -ge 4) 'Front-end and module sources are present' ("found {0}" -f $sourceFiles.Count)

foreach ($file in $sourceFiles) {
    $errors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) ("{0} parses" -f $file.Name) (($errors | ForEach-Object { $_.Message }) -join '; ')

    $bytes = Read-Bytes -Path $file.FullName
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 })
    Assert-True ($nonAscii.Count -eq 0) ("{0} is plain ASCII" -f $file.Name) ("{0} non-ASCII byte(s)" -f $nonAscii.Count)
}

# --------------------------------------------------------------------------
# 2. Software.json
# --------------------------------------------------------------------------

Write-Section 'Software.json'

$configPath = Join-Path $root 'Software.json'
Assert-True (Test-Path -LiteralPath $configPath -PathType Leaf) 'Software.json exists'

$config = $null
try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json }
catch { Assert-True $false 'Software.json is valid JSON' $_.Exception.Message }
Assert-True ($null -ne $config) 'Software.json parsed'

$apps = @(@($config.Apps) | Where-Object { $null -ne $_ })
$enabledApps = @($apps | Where-Object { $_.Enabled -ne $false })
$localInstallers = @(@($config.LocalInstallers) | Where-Object { $null -ne $_ })
$enabledLocal = @($localInstallers | Where-Object { $_.Enabled -ne $false })
$categories = @(@($config.Categories) | Where-Object { $null -ne $_ })
$profiles = @(@($config.Profiles) | Where-Object { $null -ne $_ })

Assert-True ($enabledApps.Count -eq 32) 'Catalog contains 32 enabled package entries' ("found {0}" -f $enabledApps.Count)
Assert-True ($enabledLocal.Count -eq 2) 'Both local installers are enabled' ("found {0}" -f $enabledLocal.Count)
Assert-True ($categories.Count -eq 10) 'Ten categories are defined' ("found {0}" -f $categories.Count)
Assert-True ($profiles.Count -eq 4) 'Four profiles are defined' ("found {0}" -f $profiles.Count)

$knownCategories = @($categories | ForEach-Object { [string]$_.Id })
$missingCategory = @($enabledApps | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Category) -or $knownCategories -notcontains [string]$_.Category })
Assert-True ($missingCategory.Count -eq 0) 'Every enabled application has a known category' (($missingCategory | ForEach-Object { $_.Name }) -join ', ')
$missingLocalCategory = @($enabledLocal | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Category) -or $knownCategories -notcontains [string]$_.Category })
Assert-True ($missingLocalCategory.Count -eq 0) 'Every local installer has a known category' (($missingLocalCategory | ForEach-Object { $_.Name }) -join ', ')

$missingIds = @($enabledApps | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Id) })
Assert-True ($missingIds.Count -eq 0) 'Every enabled application has a Winget or Store ID' (($missingIds | ForEach-Object { $_.Name }) -join ', ')

$duplicateIds = @($enabledApps | Group-Object Id | Where-Object { $_.Count -gt 1 })
Assert-True ($duplicateIds.Count -eq 0) 'Enabled application IDs are unique' (($duplicateIds | ForEach-Object { $_.Name }) -join ', ')

$anyDesk = @($apps | Where-Object { $_.Id -eq 'AnyDesk.AnyDesk' })
$tailscale = @($apps | Where-Object { $_.Id -eq 'Tailscale.Tailscale' })
Assert-True (($anyDesk.Count -eq 1) -and ($anyDesk[0].Enabled -eq $false)) 'AnyDesk is present and disabled by default'
Assert-True (($tailscale.Count -eq 1) -and ($tailscale[0].Enabled -eq $false)) 'Tailscale is present and disabled by default'

$whatsApp = @($apps | Where-Object { $_.Name -eq 'WhatsApp' })
Assert-True (($whatsApp.Count -eq 1) -and ($whatsApp[0].Id -eq '9NKSQGP7F2NH') -and ($whatsApp[0].Source -eq 'msstore')) 'WhatsApp uses the current Microsoft Store package'

# --------------------------------------------------------------------------
# 3. Logos
# --------------------------------------------------------------------------

Write-Section 'Logos'

Add-Type -AssemblyName System.Drawing

$logoItems = @()
foreach ($app in @($enabledApps + $enabledLocal)) {
    if ($null -eq $app.PSObject.Properties['Logo']) { continue }
    $logoItems += [pscustomobject]@{ Name = [string]$app.Name; Logo = [string]$app.Logo }
}
Assert-True ($logoItems.Count -ge 34) 'Every catalog item references a logo' ("found {0}" -f $logoItems.Count)

$badLogos = [System.Collections.Generic.List[string]]::new()
foreach ($item in $logoItems) {
    $logoPath = [string]$item.Logo
    if ([string]::IsNullOrWhiteSpace($logoPath)) {
        $badLogos.Add(("{0}: missing Logo field" -f $item.Name))
        continue
    }
    if (-not [System.IO.Path]::IsPathRooted($logoPath)) { $logoPath = Join-Path $root $logoPath }
    if (-not (Test-Path -LiteralPath $logoPath -PathType Leaf)) {
        $badLogos.Add(("{0}: file not found ({1})" -f $item.Name, $item.Logo))
        continue
    }
    try {
        $image = [System.Drawing.Image]::FromFile($logoPath)
        if ($image.Width -ne 128 -or $image.Height -ne 128) {
            $badLogos.Add(("{0}: {1}x{2}" -f $item.Name, $image.Width, $image.Height))
        }
        $image.Dispose()
    } catch {
        $badLogos.Add(("{0}: unreadable image" -f $item.Name))
    }
}
Assert-True ($badLogos.Count -eq 0) 'Every referenced logo is a readable 128x128 PNG' (($badLogos | Select-Object -First 8) -join '; ')

$logoReadme = Join-Path $root 'logo\README.md'
Assert-True (Test-Path -LiteralPath $logoReadme -PathType Leaf) 'logo/README.md documents logo sources'
if (Test-Path -LiteralPath $logoReadme -PathType Leaf) {
    $readmeText = Get-Content -LiteralPath $logoReadme -Raw
    $missingSourceRows = @($logoItems | Where-Object {
        $fileName = Split-Path -Leaf $_.Logo
        $readmeText -notmatch [regex]::Escape($fileName)
    })
    Assert-True ($missingSourceRows.Count -eq 0) 'Every logo has a source row in logo/README.md' (($missingSourceRows | ForEach-Object { $_.Logo }) -join ', ')
}

# --------------------------------------------------------------------------
# 4. Bilingual string coverage
# --------------------------------------------------------------------------

Write-Section 'Bilingual strings'

$guiPath = Join-Path $root 'Install-MyPC.Gui.ps1'
$guiText = Get-Content -LiteralPath $guiPath -Raw

$xamlMatch = [regex]::Match($guiText, "(?s)\`$xaml\s*=\s*@'(.*?)'@")
Assert-True ($xamlMatch.Success) 'The XAML block was found'
$tokenKeys = @()
if ($xamlMatch.Success) {
    $tokenKeys = @([regex]::Matches($xamlMatch.Groups[1].Value, '@@([A-Za-z0-9_.]+)@@') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}
Assert-True ($tokenKeys.Count -ge 50) 'The XAML uses translated placeholders' ("found {0}" -f $tokenKeys.Count)

$missingStrings = @($tokenKeys | Where-Object {
    $guiText -notmatch ("'" + [regex]::Escape($_) + "'\s*=\s*@\{")
})
Assert-True ($missingStrings.Count -eq 0) 'Every XAML placeholder has an English/French string' ($missingStrings -join ', ')

$stringLines = [regex]::Matches($guiText, "'([A-Za-z0-9_.]+)'\s*=\s*@\{[^\r\n]*\}") |
    ForEach-Object { $_.Value }
$missingFrench = @($stringLines | Where-Object { $_ -notmatch '\bfr\s*=' })
Assert-True ($missingFrench.Count -eq 0) 'Every string table entry has a French translation' ($missingFrench -join '; ')

$missingEnglish = @($stringLines | Where-Object { $_ -notmatch '\ben\s*=' })
Assert-True ($missingEnglish.Count -eq 0) 'Every string table entry has an English translation' ($missingEnglish -join '; ')

$coreText = Get-Content -LiteralPath (Join-Path $root 'Setup.Core.psm1') -Raw
$systemKeys = @([regex]::Matches($coreText, "'(System\.(?:Row|Value|Section)\.[A-Za-z0-9]+)'") |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Assert-True ($systemKeys.Count -ge 60) 'The System dashboard exposes label and value keys' ("found {0}" -f $systemKeys.Count)
$missingSystemStrings = @($systemKeys | Where-Object {
    $guiText -notmatch ("'" + [regex]::Escape($_) + "'\s*=\s*@\{")
})
Assert-True ($missingSystemStrings.Count -eq 0) 'Every System dashboard key has an English/French string' ($missingSystemStrings -join ', ')

# --------------------------------------------------------------------------
# 5. Core module (read-only)
# --------------------------------------------------------------------------

Write-Section 'Core module'

Import-Module (Join-Path $root 'Setup.Core.psm1') -Force

$coreConfig = Get-SetupConfig -Path $configPath
Assert-True ($null -ne $coreConfig) 'Get-SetupConfig loads Software.json'

$catalog = @(Get-SoftwareCatalog -Config $coreConfig)
Assert-True ($catalog.Count -eq 34) 'Catalog exposes 32 package + 2 local entries' ("found {0}" -f $catalog.Count)
Assert-True (@($catalog | Where-Object { $_.CategoryId -eq 'runtimes' }).Count -eq 6) 'Six runtime entries are categorized as runtimes'
Assert-True (@(Get-SetupCategories -Config $coreConfig).Count -eq 10) 'Get-SetupCategories returns the categories'
Assert-True (@(Get-SetupProfiles -Config $coreConfig).Count -eq 4) 'Get-SetupProfiles returns the profiles'

$catalogCategoryOrder = @($catalog | ForEach-Object { [string]$_.CategoryId } | Select-Object -Unique)
$expectedCategoryOrder = @($coreConfig.Categories | Where-Object { $catalogCategoryOrder -contains [string]$_.Id } | ForEach-Object { [string]$_.Id })
Assert-True (($catalogCategoryOrder -join ',') -eq ($expectedCategoryOrder -join ',')) 'Catalog entries are grouped in category order' (($catalogCategoryOrder -join ', '))

$profileResolution = @{}
foreach ($profile in @(Get-SetupProfiles -Config $coreConfig)) {
    $count = @($catalog | Where-Object {
        $row = $_
        @($profile.Apps | Where-Object { $_ -eq [string]$row.Name -or $_ -eq [string]$row.Id }).Count -gt 0
    }).Count
    $profileResolution[$profile.NameEn] = $count
}
Assert-True ($profileResolution['Office'] -eq 12) 'The Office profile resolves 12 applications' ("found {0}" -f $profileResolution['Office'])
Assert-True ($profileResolution['Developer'] -eq 10) 'The Developer profile resolves 10 applications' ("found {0}" -f $profileResolution['Developer'])
Assert-True ($profileResolution['Technician'] -eq 9) 'The Technician profile resolves 9 enabled applications' ("found {0}" -f $profileResolution['Technician'])
Assert-True ($profileResolution['Minimal'] -eq 8) 'The Minimal profile resolves 8 applications' ("found {0}" -f $profileResolution['Minimal'])

$systemInfo = Get-SetupSystemInfo
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$systemInfo.ComputerName)) 'Get-SetupSystemInfo reports the computer name'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$systemInfo.OSName)) 'Get-SetupSystemInfo reports the operating system'
Assert-True ($null -ne $systemInfo.PSObject.Properties['PendingReboot']) 'Get-SetupSystemInfo reports pending restarts'
Assert-True ($null -ne $systemInfo.PSObject.Properties['Manufacturer']) 'Get-SetupSystemInfo reports the manufacturer'
Assert-True ($null -ne $systemInfo.PSObject.Properties['CPUName']) 'Get-SetupSystemInfo reports the processor'
Assert-True ($null -ne $systemInfo.PSObject.Properties['RAMGB']) 'Get-SetupSystemInfo reports the memory'
Assert-True ($null -ne $systemInfo.PSObject.Properties['UptimeHours']) 'Get-SetupSystemInfo reports the uptime'

$updateStatus = Get-SetupWindowsUpdateStatus
Assert-True ($null -ne $updateStatus.PSObject.Properties['Searched']) 'Get-SetupWindowsUpdateStatus reports whether a search ran'
Assert-True ($updateStatus.Searched -eq $false) 'Windows Update is not searched by default'
Assert-True ($null -ne $updateStatus.PSObject.Properties['Updates']) 'Get-SetupWindowsUpdateStatus returns an update list'

$dashboard = Get-SetupSystemDashboard -SkipInternet
Assert-True ($null -ne $dashboard.PSObject.Properties['Sections']) 'Get-SetupSystemDashboard returns sections'
Assert-True ($null -ne $dashboard.PSObject.Properties['Summary']) 'Get-SetupSystemDashboard returns a summary'
Assert-True (@($dashboard.Sections).Count -eq 7) 'The system dashboard has seven sections' ("found {0}" -f @($dashboard.Sections).Count)
$dashboardRows = @($dashboard.Sections | ForEach-Object { @($_.Rows) })
Assert-True ($dashboardRows.Count -ge 35) 'The system dashboard has a useful number of rows' ("found {0}" -f $dashboardRows.Count)
$badRowLabels = @($dashboardRows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.LabelKey) -and [string]::IsNullOrWhiteSpace([string]$_.Label) })
Assert-True ($badRowLabels.Count -eq 0) 'Every system row has a label'
$badRowValues = @($dashboardRows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Value) -and [string]::IsNullOrWhiteSpace([string]$_.ValueKey) })
Assert-True ($badRowValues.Count -eq 0) 'Every system row has a value'
$badRowTones = @($dashboardRows | Where-Object { [string]$_.Tone -notin @('Info', 'Ok', 'Warning', 'Error', 'Muted') })
Assert-True ($badRowTones.Count -eq 0) 'Every system row uses a known tone'
Assert-True ($dashboard.Network.Internet -eq 'NotChecked') 'The Internet probe can be skipped for offline checks'
Assert-True (@($dashboard.Features.Features).Count -eq 5) 'The feature report covers five optional features'
Assert-True ($dashboard.WindowsUpdate.Searched -eq $false) 'The dashboard does not search Windows Update by default'

$elevation = Test-SetupElevated
Assert-True ($elevation -is [bool]) 'Test-SetupElevated reports a boolean'

$planPreview = Set-SetupPowerPlan -Name Balanced -DryRun
Assert-True ($null -ne $planPreview.PSObject.Properties['Success']) 'Set-SetupPowerPlan returns a result in dry-run mode'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$planPreview.Message)) 'Set-SetupPowerPlan previews the change'

$hibernatePreview = Set-SetupHibernation -State Off -DryRun
Assert-True ($null -ne $hibernatePreview.PSObject.Properties['Success']) 'Set-SetupHibernation returns a result in dry-run mode'
Assert-True ($hibernatePreview.Message -match 'Preview|already') 'Hibernation previews or reports the current state'

$fastPreview = Set-SetupFastStartup -State Off -DryRun
Assert-True ($fastPreview.Message -match 'Preview|already|Turn hibernation') 'Fast startup previews or explains the dependency'

$powerPreview = Set-SetupPowerSettings -Plan Balanced -Hibernate Keep -FastStartup Keep -DryRun
Assert-True (($null -ne $powerPreview.PSObject.Properties['Data']) -and $powerPreview.Data.DryRun) 'The combined power action keeps dry-run mode'

$dnsMissing = Set-SetupDnsPreset -AdapterName 'SetupVerifyMissingAdapter' -Preset Cloudflare -DryRun
Assert-True (-not $dnsMissing.Success) 'Set-SetupDnsPreset refuses a missing adapter'
$dnsAdapters = @($dashboard.Network.Adapters)
if ($dnsAdapters.Count -gt 0) {
    $dnsPreview = Set-SetupDnsPreset -AdapterName ([string]$dnsAdapters[0].Name) -Preset Cloudflare -DryRun
    Assert-True ($dnsPreview.Message -match 'Preview|already') 'The DNS preset previews or reports the current state'
}

$flushPreview = Clear-SetupDnsCache -DryRun
Assert-True ($flushPreview.Success -and ($flushPreview.Message -match 'Preview')) 'Clear-SetupDnsCache supports a preview'

$ping = Test-SetupNetworkPath -Target '127.0.0.1' -Count 1
Assert-True ($ping.Success) 'Test-SetupNetworkPath reaches the loopback address'
Assert-True (@($ping.Data.Path).Count -eq 0) 'Traceroute stays opt-in'

$sensePreview = Set-SetupStorageSense -State Off -DryRun
Assert-True ($sensePreview.Message -match 'Preview|already') 'Storage Sense previews or reports the current state'

$zonePreview = Set-SetupTimeZone -Id ([TimeZoneInfo]::Local.Id) -DryRun
Assert-True ($zonePreview.Success -and $zonePreview.Skipped) 'Set-SetupTimeZone treats the current zone as a no-op'
$zoneMissing = Set-SetupTimeZone -Id 'Setup Verify Missing Zone' -DryRun
Assert-True (-not $zoneMissing.Success) 'Set-SetupTimeZone refuses an unknown time zone'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('setup-verify-temp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$oldStamp = (Get-Date).AddDays(-3)
$oldFileA = Join-Path $tempRoot 'old-a.tmp'
$oldFileB = Join-Path $tempRoot 'old-b.log'
$newFile = Join-Path $tempRoot 'keep.txt'
try {
    Set-Content -LiteralPath $oldFileA -Value ('a' * 256) -Encoding ASCII
    Set-Content -LiteralPath $oldFileB -Value ('b' * 128) -Encoding ASCII
    Set-Content -LiteralPath $newFile -Value 'keep' -Encoding ASCII
    (Get-Item -LiteralPath $oldFileA).LastWriteTime = $oldStamp
    (Get-Item -LiteralPath $oldFileB).LastWriteTime = $oldStamp

    $tempPreview = Clear-SetupTempFiles -Path $tempRoot -OlderThanDays 1 -DryRun
    Assert-True ($tempPreview.Success -and ($tempPreview.Data.Files -eq 2)) 'Temp cleanup counts the old files in preview' ("found {0}" -f $tempPreview.Data.Files)
    Assert-True ((Test-Path -LiteralPath $oldFileA) -and (Test-Path -LiteralPath $oldFileB)) 'The temp preview does not delete anything'

    $tempClean = Clear-SetupTempFiles -Path $tempRoot -OlderThanDays 1
    Assert-True ($tempClean.Success -and ($tempClean.Data.Deleted -eq 2)) 'Temp cleanup removes the old files' ("deleted {0}" -f $tempClean.Data.Deleted)
    Assert-True ((-not (Test-Path -LiteralPath $oldFileA)) -and (-not (Test-Path -LiteralPath $oldFileB)) -and (Test-Path -LiteralPath $newFile)) 'Temp cleanup keeps recent files'

    $tempGuard = Clear-SetupTempFiles -Path (Join-Path $env:USERPROFILE 'setup-verify-temp-guard') -DryRun
    Assert-True (-not $tempGuard.Success) 'Temp cleanup refuses a path outside the temp directories'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$restoreSupport = Test-SetupRestorePointSupport
Assert-True ($null -ne $restoreSupport.PSObject.Properties['Supported']) 'Test-SetupRestorePointSupport reports support'
Assert-True ($null -ne $restoreSupport.PSObject.Properties['Enabled']) 'Test-SetupRestorePointSupport reports the enabled state'

$dryRestore = New-SetupRestorePoint -DryRun
Assert-True ($null -ne $dryRestore) 'New-SetupRestorePoint -DryRun returns a result'
Assert-True ($null -ne $dryRestore.PSObject.Properties['Skipped']) 'The dry restore point is reported as a preview'

$preflight = Test-SetupPreflight -SkipInternet
Assert-True (@($preflight.Checks).Count -ge 7) 'Test-SetupPreflight returns the expected checks' ("found {0}" -f @($preflight.Checks).Count)
Assert-True ($null -ne $preflight.PSObject.Properties['Success']) 'Test-SetupPreflight returns a success flag'

$shortPassword = ConvertTo-SecureString 'x' -AsPlainText -Force
$shortUserResult = New-SetupLocalUser -UserName 'SetupVerifyNoCreate' -Password $shortPassword
Assert-True ((-not $shortUserResult.Success) -and ($shortUserResult.Message -match 'at least 8')) 'New-SetupLocalUser refuses a short password'
$shortPassword.Dispose()

$deleteMissing = Remove-SetupLocalUser -UserName 'SetupVerifyNoExist'
Assert-True (-not $deleteMissing.Success) 'Remove-SetupLocalUser refuses a missing account'

$defaultMissing = Set-SetupDefaultPrinter -Name 'Setup Verify Missing Printer'
Assert-True (-not $defaultMissing.Success) 'Set-SetupDefaultPrinter refuses a missing printer'
$testMissing = Test-SetupPrinterPage -Name 'Setup Verify Missing Printer'
Assert-True (-not $testMissing.Success) 'Test-SetupPrinterPage refuses a missing printer'

$launchShape = Get-SetupSoftwareLaunchInfo -CatalogItem $catalog[0]
Assert-True (($null -ne $launchShape.PSObject.Properties['CanLaunch']) -and ($null -ne $launchShape.PSObject.Properties['CanOpenFolder'])) 'Get-SetupSoftwareLaunchInfo reports launch and folder flags'

$missingSoftware = [pscustomobject]@{
    Kind = 'winget'
    Name = 'Setup Verify Missing Software 9f3c'
    Id   = 'Setup.Verify.NoSuchPackage'
    Item = [pscustomobject]@{ Type = 'winget'; Name = 'Setup Verify Missing Software 9f3c'; Id = 'Setup.Verify.NoSuchPackage' }
}
$missingInfo = Get-SetupSoftwareLaunchInfo -CatalogItem $missingSoftware
Assert-True ((-not $missingInfo.Success) -and (-not $missingInfo.CanLaunch) -and (-not $missingInfo.CanOpenFolder)) 'The launch lookup refuses an unknown application'
$missingLaunch = Invoke-SetupSoftwareLaunch -CatalogItem $missingSoftware
Assert-True (-not $missingLaunch.Success) 'Invoke-SetupSoftwareLaunch refuses an unknown application'
$missingFolder = Show-SetupSoftwareFolder -CatalogItem $missingSoftware
Assert-True (-not $missingFolder.Success) 'Show-SetupSoftwareFolder refuses an unknown application'
$missingShortcut = New-SetupSoftwareShortcut -CatalogItem $missingSoftware -DesktopPath (Join-Path $env:TEMP 'setup-verify-shortcuts')
Assert-True (-not $missingShortcut.Success) 'New-SetupSoftwareShortcut refuses an unknown application'
$desktopFolder = Get-SetupUserDesktopPath
Assert-True (-not [string]::IsNullOrWhiteSpace($desktopFolder)) 'Get-SetupUserDesktopPath returns a desktop folder'

# --------------------------------------------------------------------------
# 6. Report export
# --------------------------------------------------------------------------

Write-Section 'Reports'

$reportDir = Join-Path ([System.IO.Path]::GetTempPath()) ("setup-verify-{0}" -f $PID)
$sampleResults = @(
    (New-SetupResult -Name 'Verification sample' -Success $true -Message 'Sample success'),
    (New-SetupResult -Name 'Verification skipped' -Success $true -Skipped $true -Message 'Sample skip')
)
try {
    $jsonReport = Export-SetupReport -Results $sampleResults -Config $coreConfig -Directory $reportDir -Format Json
    Assert-True ($jsonReport.Success -and (Test-Path -LiteralPath $jsonReport.Data.Path -PathType Leaf)) 'JSON report is written'
    if ($jsonReport.Success) {
        $reportObject = Get-Content -LiteralPath $jsonReport.Data.Path -Raw | ConvertFrom-Json
        Assert-True (@($reportObject.Results).Count -eq 2) 'JSON report contains every result'
        Assert-True ($reportObject.Summary.Skipped -eq 1) 'JSON report counts skipped results'
    }

    $htmlReport = Export-SetupReport -Results $sampleResults -Config $coreConfig -Directory $reportDir -Format Html
    Assert-True ($htmlReport.Success -and (Test-Path -LiteralPath $htmlReport.Data.Path -PathType Leaf)) 'HTML report is written'
    if ($htmlReport.Success) {
        $html = Get-Content -LiteralPath $htmlReport.Data.Path -Raw
        Assert-True ($html -match '<!DOCTYPE html>' -and $html -match 'Verification sample') 'HTML report contains the results table'
    }

    $csvReport = Export-SetupReport -Results $sampleResults -Config $coreConfig -Directory $reportDir -Format Csv
    Assert-True ($csvReport.Success -and (Test-Path -LiteralPath $csvReport.Data.Path -PathType Leaf)) 'CSV report is written'

    $systemHtml = Export-SetupSystemReport -Dashboard $dashboard -Directory $reportDir -Format Html
    Assert-True ($systemHtml.Success -and (Test-Path -LiteralPath $systemHtml.Data.Path -PathType Leaf)) 'System HTML report is written'
    if ($systemHtml.Success) {
        $systemHtmlText = Get-Content -LiteralPath $systemHtml.Data.Path -Raw
        Assert-True ($systemHtmlText -match 'System report' -and $systemHtmlText -match '<h2>Security</h2>' -and $systemHtmlText -match '<h2>Storage</h2>') 'System HTML report contains the grouped sections'
    }

    $systemJson = Export-SetupSystemReport -Dashboard $dashboard -Directory $reportDir -Format Json
    Assert-True ($systemJson.Success -and (Test-Path -LiteralPath $systemJson.Data.Path -PathType Leaf)) 'System JSON report is written'
    if ($systemJson.Success) {
        $systemObject = Get-Content -LiteralPath $systemJson.Data.Path -Raw | ConvertFrom-Json
        Assert-True (@($systemObject.Sections).Count -eq 7) 'System JSON report contains every section'
    }

    $systemCsv = Export-SetupSystemReport -Dashboard $dashboard -Directory $reportDir -Format Csv
    Assert-True ($systemCsv.Success -and (Test-Path -LiteralPath $systemCsv.Data.Path -PathType Leaf)) 'System CSV report is written'
} finally {
    if (Test-Path -LiteralPath $reportDir) { Remove-Item -LiteralPath $reportDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------------------
# 7. Front-end contracts
# --------------------------------------------------------------------------

Write-Section 'Front-end contracts'

$consolePath = Join-Path $root 'Install-MyPC.ps1'
$consoleText = Get-Content -LiteralPath $consolePath -Raw

Assert-True ($guiText -match '\-OriginalUserSid') 'The window preserves -OriginalUserSid'
Assert-True ($consoleText -match '\-OriginalUserSid') 'The console preserves -OriginalUserSid'
Assert-True ($guiText -match 'New-SetupLocalUser' -and $guiText -match 'Remove-SetupLocalUser') 'The window exposes user create/delete'
Assert-True ($consoleText -match 'New-SetupLocalUser' -and $consoleText -match 'Remove-SetupLocalUser') 'The console exposes user create/delete'
Assert-True ($guiText -match 'Set-SetupDefaultPrinter' -and $guiText -match 'Test-SetupPrinterPage') 'The window exposes printer default/test'
Assert-True ($consoleText -match 'Set-SetupDefaultPrinter' -and $consoleText -match 'Test-SetupPrinterPage') 'The console exposes printer default/test'
Assert-True ($guiText -match 'Test-SetupPreflight' -and $consoleText -match 'Test-SetupPreflight') 'Both front-ends run preflight checks'
Assert-True ($guiText -match 'New-SetupRestorePoint' -and $consoleText -match 'New-SetupRestorePoint') 'Both front-ends can create restore points'
Assert-True ($guiText -match 'Export-SetupReport' -and $consoleText -match 'Export-SetupReport') 'Both front-ends can export a report'
Assert-True ($guiText -match 'Get-SetupProfiles' -and $consoleText -match 'Get-SetupProfiles') 'Both front-ends expose profiles'
Assert-True ($guiText -match 'Get-SetupSystemDashboard' -and $consoleText -match 'Get-SetupSystemDashboard') 'Both front-ends expose the read-only system status'
Assert-True ($guiText -match 'Export-SetupSystemReport' -and $consoleText -match 'Export-SetupSystemReport') 'Both front-ends can export a system report'
Assert-True ($guiText -match 'CheckWindowsUpdate' -and $consoleText -match 'CheckWindowsUpdate') 'Windows Update searching is shared and opt-in'
Assert-True ($guiText -match 'x:Name="NavSystem"' -and $guiText -match 'x:Name="PageSystem"') 'The window has a System navigation entry and page'
Assert-True ($guiText -match 'SystemPowerApply' -and $guiText -match 'SystemDnsApply' -and $guiText -match 'SystemTempClean') 'The window exposes the maintenance actions'
Assert-True ($consoleText -match 'Show-SystemMaintenance' -and $consoleText -match 'Set-SetupDnsPreset' -and $consoleText -match 'Clear-SetupTempFiles') 'The console exposes the maintenance actions'
Assert-True ($guiText -match 'Set-SetupPowerSettings' -and $consoleText -match 'Set-SetupPowerPlan') 'Both front-ends share the power actions'
Assert-True ($guiText -match 'Software.Action.Open' -and $guiText -match 'Software.Action.Location' -and $guiText -match 'Start-SoftwareOpen') 'The window offers open software and folder actions'
Assert-True ($guiText -match 'Invoke-SetupSoftwareLaunch' -and $guiText -match 'Show-SetupSoftwareFolder') 'The window uses the shared launch actions'
Assert-True ($guiText -match 'Software.PreviewShortcut' -and $guiText -match 'New-SetupSoftwareShortcut') 'The window offers a desktop shortcut option'
Assert-True ($consoleText -match 'New-SetupSoftwareShortcut') 'The console creates desktop shortcuts'

$guardedWrite = [regex]::Match($guiText, '(?s)(Set-Content|Out-File|Export-Csv|ConvertTo-Json)[^\r\n]{0,200}Software\.json')
Assert-True (-not $guardedWrite.Success) 'The window never writes Software.json'

$launcherPath = Join-Path $root 'Setup-Online.ps1'
$launcherText = Get-Content -LiteralPath $launcherPath -Raw
foreach ($required in @('Install-MyPC.Gui.ps1', 'Install-MyPC.ps1', 'Setup.Core.psm1', 'Software.json')) {
    Assert-True ($launcherText -match [regex]::Escape($required)) ("The online launcher references {0}" -f $required)
}
Assert-True ($launcherText -match 'Get-CatalogLogoFiles' -and $launcherText -match 'logo/') 'The online launcher reads logo file names from the catalog'

# --------------------------------------------------------------------------
# 8. GUI smoke test (EN and FR)
# --------------------------------------------------------------------------

if (-not $SkipGui) {
    Write-Section 'GUI smoke test'

    $previousLanguage = $env:SETUP_UI_LANG
    try {
        foreach ($language in @('en', 'fr')) {
            $env:SETUP_UI_LANG = $language
            $output = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $guiPath -NoElevate -NoShow 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
            $label = if ($language -eq 'en') { 'English' } else { 'French' }
            Assert-True (($exitCode -eq 0) -and ($output -match 'GUI OK')) ("The window builds and populates in {0}" -f $label) (($output.Trim() -split "`r?`n" | Select-Object -Last 3) -join ' | ')
            Assert-True ($output -match 'GUI OK: \d+ software item\(s\), 9 categories, 4 profiles, \d+ printer\(s\), \d+ user\(s\), 7 system section\(s\)') ("The category and profile filters are populated in {0}" -f $label) (($output.Trim() -split "`r?`n" | Select-Object -Last 1))
        }
    } finally {
        if ($null -eq $previousLanguage) { Remove-Item Env:SETUP_UI_LANG -ErrorAction SilentlyContinue }
        else { $env:SETUP_UI_LANG = $previousLanguage }
    }
} else {
    Write-Host ''
    Write-Host 'GUI smoke test skipped (-SkipGui).' -ForegroundColor DarkYellow
}

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

Write-Host ''
Write-Host '========================================================' -ForegroundColor Cyan
if ($script:Failures.Count -eq 0) {
    Write-Host ("VERIFICATION PASSED: {0} check(s)." -f $script:PassCount) -ForegroundColor Green
    exit 0
}
Write-Host ("VERIFICATION FAILED: {0} failure(s), {1} check(s) passed." -f $script:Failures.Count, $script:PassCount) -ForegroundColor Red
foreach ($failure in $script:Failures) {
    Write-Host (" - {0}" -f $failure) -ForegroundColor Red
}
exit 1
