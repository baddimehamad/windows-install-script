#Requires -Version 5.1
<#
.SYNOPSIS
    Online launcher for Windows Automatic Setup.

.DESCRIPTION
    Downloads this repository as a ZIP archive, extracts it to a shared
    folder, and runs Install-MyPC.ps1 from disk. Running from disk is
    required because the main script uses its own file location for
    elevation, Software.json lookup, and logging.

    Uses C:\ProgramData (all admins can read it) instead of $env:TEMP,
    because $env:TEMP often uses 8.3 short names (e.g. C:\Users\M0896~1.BAD\...)
    and is invisible to a different admin account after the UAC prompt.

.USAGE
    Short:
    irm https://tinyurl.com/27wv3wmc | iex

    Full URL:
    irm https://raw.githubusercontent.com/baddimehamad/windows-install-script/main/Setup-Online.ps1 | iex

.NOTES
    Local installers (OfficeSetup.exe, etc.) are not part of the repo,
    so those menu items show FILE NOT FOUND unless you add the files
    manually after download.
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo   = 'baddimehamad/windows-install-script'
$Branch = 'main'
$ZipUrl = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"

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

try {
    $BaseDir = Get-StagingBase
    $WorkDir = Join-Path $BaseDir 'src'
    $ZipPath = Join-Path $BaseDir 'Windows_Auto_Setup.zip'

    Write-Host "Staging folder: $BaseDir" -ForegroundColor DarkGray

    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $WorkDir -Force -ErrorAction Stop | Out-Null

    Write-Host "Downloading $ZipUrl ..." -ForegroundColor Cyan
    $iwrParams = @{
        Uri       = $ZipUrl
        OutFile   = $ZipPath
        ErrorAction = 'Stop'
    }
    # -UseBasicParsing only exists on Windows PowerShell 5.1.
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $iwrParams['UseBasicParsing'] = $true
    }
    Invoke-WebRequest @iwrParams

    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw "Download failed: no file was created at $ZipPath."
    }
    $zipInfo = Get-Item -LiteralPath $ZipPath
    if ($zipInfo.Length -lt 1024) {
        throw ("Download failed: file at {0} is only {1} bytes (expected a multi-KB ZIP)." -f $ZipPath, $zipInfo.Length)
    }
    # A real ZIP starts with PK. If we got HTML (proxy / preview page), fail with a clear message.
    $stream = [System.IO.File]::OpenRead($ZipPath)
    try {
        $sig = New-Object byte[] 2
        [void]$stream.Read($sig, 0, 2)
        if (-not ($sig[0] -eq 0x50 -and $sig[1] -eq 0x4B)) {
            throw ("Downloaded file at {0} is not a ZIP (missing PK signature). Check network/proxy or the repo URL." -f $ZipPath)
        }
    } finally {
        $stream.Close()
    }

    Write-Host 'Extracting...' -ForegroundColor Cyan
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $WorkDir -Force -ErrorAction Stop

    $extracted = Get-ChildItem -LiteralPath $WorkDir -Directory -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $extracted) {
        throw "Downloaded archive did not contain an extracted folder (looked in $WorkDir)."
    }
    $scriptPath = Join-Path $extracted.FullName 'Install-MyPC.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Install-MyPC.ps1 was not found at $scriptPath."
    }

    Write-Host "Running $scriptPath ..." -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
} catch {
    Write-Host ''
    Write-Error ($_ | Out-String)
    Write-Host "Diag: BaseDir=$BaseDir  ZipPath=$ZipPath  TEMP=$env:TEMP  ProgramData=$env:ProgramData" -ForegroundColor DarkGray
    Read-Host 'Press Enter to close'
}
