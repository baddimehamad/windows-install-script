#Requires -Version 5.1
<#
.SYNOPSIS
    Online launcher for Windows Automatic Setup.

.DESCRIPTION
    Downloads this repository as a ZIP archive, extracts it to the temp
    folder, and runs Install-MyPC.ps1 from disk. Running from disk is
    required because the main script uses its own file location for
    elevation, Software.json lookup, and logging.

.USAGE
    irm https://raw.githubusercontent.com/baddimehamad/windows-install-script/main/Setup-Online.ps1 | iex

.NOTES
    Local installers (OfficeSetup.exe, etc.) are not part of the repo,
    so those menu items show FILE NOT FOUND unless you add the files
    manually after download.
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo    = 'baddimehamad/windows-install-script'
$Branch  = 'main'
$ZipUrl  = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
$WorkDir = Join-Path $env:TEMP 'Windows_Auto_Setup_Online'
$ZipPath = Join-Path $env:TEMP 'Windows_Auto_Setup.zip'

try {
    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    Write-Host "Downloading $ZipUrl ..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing

    Write-Host 'Extracting...' -ForegroundColor Cyan
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $WorkDir -Force

    $extracted = Get-ChildItem -LiteralPath $WorkDir -Directory | Select-Object -First 1
    if ($null -eq $extracted) {
        throw 'Downloaded archive did not contain an extracted folder.'
    }
    $scriptPath = Join-Path $extracted.FullName 'Install-MyPC.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw 'Install-MyPC.ps1 was not found in the downloaded archive.'
    }

    Write-Host "Running $scriptPath ..." -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
} catch {
    Write-Error $_.Exception.Message
    Read-Host 'Press Enter to close'
}
