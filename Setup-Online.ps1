#Requires -Version 5.1
<#
.SYNOPSIS
    Online launcher for Windows Automatic Setup.

.DESCRIPTION
    Downloads only the files needed to run (Install-MyPC.Gui.ps1,
    Install-MyPC.ps1, Setup.Core.psm1, Software.json and the application
    logos used by the window) into a shared folder, then runs
    Install-MyPC.Gui.ps1 (window) or Install-MyPC.ps1 (text menu) from disk.
    Running from disk is required because the scripts use their own file
    location for elevation, Software.json lookup, and logging.

    Only ~350 KB is downloaded. The full repo ZIP is NOT used, because it
    contains ~100 MB of printer drivers (Drivers/) that would make every
    first launch slow.

    Uses C:\ProgramData (all admins can read it) instead of $env:TEMP,
    because $env:TEMP often uses 8.3 short names (e.g. C:\Users\M0896~1.BAD\...)
    and is invisible to a different admin account after the UAC prompt.

.USAGE
    Window (default), short:
    irm https://tinyurl.com/27wv3wmc | iex

    Console, short:
    $env:SETUP_GUI=0; irm https://tinyurl.com/27wv3wmc | iex

    Full URL:
    irm https://raw.githubusercontent.com/baddimehamad/windows-install-script/main/Setup-Online.ps1 | iex

    From a downloaded copy:
    .\Setup-Online.ps1            # WPF window (default)
    .\Setup-Online.ps1 -Console   # text menu

.NOTES
    Local files (OfficeSetup.exe, Installers/ content) are not part of the
    online download. Those menu items show FILE NOT FOUND / WILL DOWNLOAD
    unless they carry a Url (downloaded on demand) or you copy files in manually.
    Printer driver folders are downloaded automatically when you install a
    printer, into C:\ProgramData\Windows_Auto_Setup_Online\Drivers (cached).
#>

param(
    [switch]$Console,
    [switch]$Gui
)

# Window by default. Use -Console or SETUP_GUI=0 for the text menu.
$useGui = $true
if ($env:SETUP_GUI -eq '0') { $useGui = $false }
if ($env:SETUP_GUI -eq '1') { $useGui = $true }
if ($Gui) { $useGui = $true }
if ($Console) { $useGui = $false }
$Gui = $useGui

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo    = 'baddimehamad/windows-install-script'
$Branch  = 'main'
$BaseUrl = "https://raw.githubusercontent.com/$Repo/$Branch"
$NeededFiles = @('Install-MyPC.ps1', 'Setup.Core.psm1', 'Software.json')
if ($Gui) { $NeededFiles += 'Install-MyPC.Gui.ps1' }

function Get-StagingBase {
    # Prefer ProgramData: survives UAC elevation to a different admin account.
    # Fall back to the long (non-8.3) temp path if ProgramData is not writable.
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $candidates += (Join-Path $env:ProgramData 'Windows_Auto_Setup_Online')
    }
    try {
        $longTemp = [System.IO.Path]::GetTempPath()
        if (-not [string]::IsNullOrWhiteSpace($longTemp)) {
            $candidates += (Join-Path $longTemp 'Windows_Auto_Setup_Online')
        }
    } catch {}
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $candidates += (Join-Path $env:TEMP 'Windows_Auto_Setup_Online')
    }

    foreach ($dir in $candidates) {
        try {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            # Prove it is writable.
            $probe = Join-Path $dir '.writetest'
            [System.IO.File]::WriteAllText($probe, 'ok')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return [System.IO.Path]::GetFullPath($dir)
        } catch {
            continue
        }
    }
    throw 'Could not create a writable staging folder (tried ProgramData and TEMP).'
}

function Get-FastWebFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    # The default progress bar makes PS 5.1 downloads ~10x slower; hide it.
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $dlParams = @{
            Uri         = $Uri
            OutFile     = $OutFile
            ErrorAction = 'Stop'
        }
        # -UseBasicParsing only exists on Windows PowerShell 5.1.
        if ($PSVersionTable.PSVersion.Major -le 5) {
            $dlParams['UseBasicParsing'] = $true
        }
        Invoke-WebRequest @dlParams
    } finally {
        $ProgressPreference = $savedProgress
    }
}

function Get-CatalogLogoFiles {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    # Returns the unique file names used by the catalog's "Logo" fields.
    # Only the leaf name is kept: logos always live in the logo folder.
    $names = [System.Collections.Generic.List[string]]::new()
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $names
    }
    foreach ($entry in (@($config.Apps) + @($config.LocalInstallers))) {
        if ($null -eq $entry) { continue }
        $logo = [string]$entry.Logo
        if ([string]::IsNullOrWhiteSpace($logo)) { continue }
        $leaf = [System.IO.Path]::GetFileName($logo)
        if ([string]::IsNullOrWhiteSpace($leaf)) { continue }
        if (-not ($names -contains $leaf)) { [void]$names.Add($leaf) }
    }
    return $names
}

try {
    $BaseDir = Get-StagingBase

    # Use a fresh subfolder per run. The window runs elevated and writes its
    # log inside this folder; those files are then read-only for a later
    # non-elevated launcher, which made a fixed "src" folder impossible to
    # reuse. Old folders are pruned best-effort but never required.
    Get-ChildItem -LiteralPath $BaseDir -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'src' -or $_.Name -like 'src-*' } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    $WorkDir = Join-Path $BaseDir ('src-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

    Write-Host "Staging folder: $BaseDir" -ForegroundColor DarkGray

    New-Item -ItemType Directory -Path $WorkDir -Force -ErrorAction Stop | Out-Null

    foreach ($file in $NeededFiles) {
        $url = "$BaseUrl/$file"
        $dest = Join-Path $WorkDir $file
        Write-Host "Downloading $file ..." -ForegroundColor Cyan
        Get-FastWebFile -Uri $url -OutFile $dest
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
            throw "Download failed: no file was created at $dest."
        }
    }
    $scriptPath = Join-Path $WorkDir 'Install-MyPC.ps1'
    $configPath = Join-Path $WorkDir 'Software.json'
    $modulePath = Join-Path $WorkDir 'Setup.Core.psm1'
    $scriptInfo = Get-Item -LiteralPath $scriptPath
    if ($scriptInfo.Length -lt 1024) {
        throw "Downloaded Install-MyPC.ps1 looks wrong (only $($scriptInfo.Length) bytes)."
    }
    $moduleInfo = Get-Item -LiteralPath $modulePath
    if ($moduleInfo.Length -lt 4096) {
        throw "Downloaded Setup.Core.psm1 looks wrong (only $($moduleInfo.Length) bytes)."
    }

    if ($Gui) {
        $scriptPath = Join-Path $WorkDir 'Install-MyPC.Gui.ps1'
        $guiInfo = Get-Item -LiteralPath $scriptPath
        if ($guiInfo.Length -lt 4096) {
            throw "Downloaded Install-MyPC.Gui.ps1 looks wrong (only $($guiInfo.Length) bytes)."
        }

        # Logos are cosmetic: a failed download must never block the window.
        $logoNames = @(Get-CatalogLogoFiles -ConfigPath $configPath)
        if ($logoNames.Count -gt 0) {
            $logoDir = Join-Path $WorkDir 'logo'
            New-Item -ItemType Directory -Path $logoDir -Force -ErrorAction Stop | Out-Null
            Write-Host "Downloading $($logoNames.Count) application logo(s) ..." -ForegroundColor Cyan
            foreach ($logoName in $logoNames) {
                $logoUrl = "$BaseUrl/logo/$([uri]::EscapeDataString($logoName))"
                $logoPath = Join-Path $logoDir $logoName
                try {
                    Get-FastWebFile -Uri $logoUrl -OutFile $logoPath
                } catch {
                    Write-Host "Logo $logoName unavailable; the window will show an initial tile instead." -ForegroundColor DarkYellow
                }
            }
        }
    }

    Write-Host "Running $scriptPath ..." -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
} catch {
    Write-Host ''
    Write-Error ($_ | Out-String)
    Write-Host "Diag: BaseDir=$BaseDir TEMP=$env:TEMP ProgramData=$env:ProgramData" -ForegroundColor DarkGray
    Read-Host 'Press Enter to close'
}
