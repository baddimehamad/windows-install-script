param(
    [string]$OriginalUserSid
)

# Windows automatic setup: console front-end.
# All logic lives in Setup.Core.psm1; this file only prompts and renders.
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

Import-Module (Join-Path $scriptRoot 'Setup.Core.psm1') -Force

$script:Results = [System.Collections.Generic.List[object]]::new()

# Core progress goes through this sink. Console colours match the old script.
Set-SetupLogSink {
    param($Level, $Message)
    if ([string]::IsNullOrEmpty($Message)) { return }
    $color = 'White'
    switch ($Level) {
        'Success' { $color = 'Green' }
        'Warning' { $color = 'Yellow' }
        'Error' { $color = 'Red' }
        'Detail' { $color = 'DarkGray' }
        'Task' { $color = 'Cyan' }
        default { $color = 'White' }
    }
    Write-Host $Message -ForegroundColor $color
}

function Show-Result {
    param($Result)
    if ($null -eq $Result) { return }
    [void]$script:Results.Add($Result)
    if ($Result.Skipped) {
        if (-not [string]::IsNullOrWhiteSpace($Result.Message)) {
            Write-Host $Result.Message -ForegroundColor DarkYellow
        }
        return
    }
    if ($Result.Success) {
        if (-not [string]::IsNullOrWhiteSpace($Result.Message)) {
            Write-Host $Result.Message -ForegroundColor Green
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($Result.Message)) {
        Write-Host $Result.Message -ForegroundColor Yellow
    }
}

function Invoke-ConfigureAdministrator {
    Write-Host ''
    $administratorAccount = Get-BuiltInAdminAccount
    if ($null -eq $administratorAccount) {
        Write-Host 'Could not find the built-in Administrator account (SID ending in -500).' -ForegroundColor Red
        Write-Host 'Introuvable : compte administrateur integre (SID se terminant par -500).' -ForegroundColor Red
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
    if ($confirmation -notin @('YES', 'Y', 'OUI', 'O')) {
        Write-Host ("Cancelled (you typed '{0}'). No change was made. / Annule." -f $confirmation) -ForegroundColor DarkYellow
        return
    }

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
            return
        }
    } finally {
        $plainFirst = $null
        $plainConfirm = $null
    }

    Show-Result (Enable-BuiltInAdministrator -Password $securePassword)
    Write-Host 'Use a unique password per machine, especially on business or internet-exposed computers.' -ForegroundColor Yellow
    $securePassword = $null
    $confirmPassword = $null
}

function Invoke-RenameCurrentUser {
    Write-Host ''
    $account = Get-CurrentLocalAccount -Sid $script:OriginalUserSid
    if ($null -eq $account) {
        Write-Host 'The originally signed-in account could not be matched to a local Windows account.' -ForegroundColor Yellow
        Write-Host 'Automatic rename supports local accounts, not domain/Entra ID accounts. No account was changed.' -ForegroundColor Yellow
        return
    }

    Write-Host ("Current local account name: {0}" -f $account.Name)
    Write-Host 'This changes the local account name and display name. It does NOT rename the existing C:\Users profile folder.' -ForegroundColor Yellow
    $newName = ((Read-Host 'Enter the new account name (1-20 characters), or leave blank to cancel') | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host 'Account rename cancelled.' -ForegroundColor DarkYellow
        return
    }

    Show-Result (Rename-SetupLocalAccount -Name $account.Name -NewName $newName)
    Write-Host 'The existing user profile folder was left unchanged.' -ForegroundColor Yellow
}

function Select-SoftwareToInstall {
    param([AllowEmptyCollection()][object[]]$Items)

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
        $response = ((Read-Host 'Software numbers') | ForEach-Object { "$_".Trim() })
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

function Invoke-InstallSoftware {
    param([Parameter(Mandatory = $true)]$Config)

    $availableSoftware = @(Get-SoftwareCatalog -Config $Config)
    $chosenSoftware = @(Select-SoftwareToInstall -Items $availableSoftware)
    if ($chosenSoftware.Count -eq 0) {
        Write-Host 'No software selected.' -ForegroundColor DarkYellow
        return
    }

    $wingetChosen = @($chosenSoftware | Where-Object { $_.Kind -eq 'winget' })
    if ($wingetChosen.Count -gt 0 -and $null -eq (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host 'winget was not found. Winget apps will be skipped, but selected local installers can still run.' -ForegroundColor Yellow
        Write-Host 'Install/update Microsoft App Installer, then rerun the script: https://aka.ms/getwinget' -ForegroundColor Yellow
    } elseif ($wingetChosen.Count -gt 0) {
        Write-Host ''
        Write-Host 'Checking Winget sources...' -ForegroundColor Cyan
        [void](Repair-SetupWingetSource)
    }

    foreach ($chosen in $chosenSoftware) {
        if ($chosen.Kind -eq 'winget') {
            Show-Result (Install-SetupWingetApp -App $chosen.Item)
        } else {
            Show-Result (Install-SetupLocalPackage -Installer $chosen.Item)
        }
    }
}

function Invoke-InstallPrinter {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not (Get-Command Add-Printer -ErrorAction SilentlyContinue)) {
        Write-Host 'Printer cmdlets (PrintManagement) are not available on this Windows edition.' -ForegroundColor Red
        return
    }

    $presets = @(@($Config.PrinterDrivers) | Where-Object {
        $null -ne $_ -and $_.Enabled -ne $false -and -not [string]::IsNullOrWhiteSpace([string]$_.Make)
    })
    if ($presets.Count -eq 0) {
        Write-Host 'No printer driver presets are enabled in Software.json (PrinterDrivers).' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host 'PRINTER MANUFACTURER / FABRICANT :' -ForegroundColor Cyan
    for ($index = 0; $index -lt $presets.Count; $index++) {
        Write-Host (" {0,2}. {1}" -f ($index + 1), $presets[$index].Make)
    }
    Write-Host '  0. Cancel / Annuler'
    $makeChoice = ((Read-Host 'Manufacturer number / Numero') | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($makeChoice) -or $makeChoice -eq '0') {
        Write-Host 'Printer install cancelled. / Annule.' -ForegroundColor DarkYellow
        return
    }
    if ($makeChoice -notmatch '^\d+$' -or [int]$makeChoice -lt 1 -or [int]$makeChoice -gt $presets.Count) {
        Write-Host 'Invalid manufacturer selection.' -ForegroundColor Yellow
        return
    }
    $preset = $presets[[int]$makeChoice - 1]
    Write-Host ("Selected: {0}" -f $preset.Make) -ForegroundColor Green

    $ipAddress = ((Read-Host 'Printer IP address or hostname / Adresse IP ou nom') | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        Write-Host 'Printer install cancelled (no IP/hostname).' -ForegroundColor DarkYellow
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

    $overwrite = $false
    $existing = Get-Printer -Name $printerName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        $answer = ((Read-Host ("A printer named '{0}' already exists. Overwrite? [y/N]" -f $printerName)) | ForEach-Object { "$_".Trim().ToLowerInvariant() })
        if ($answer -notin @('y', 'yes', 'o', 'oui')) {
            Write-Host 'Kept the existing printer unchanged.' -ForegroundColor DarkYellow
            return
        }
        $overwrite = $true
    }

    $params = @{
        Config       = $Config
        Make         = $preset.Make
        HostAddress  = $ipAddress
        Port         = $portNumber
        PrinterName  = $printerName
    }
    if ($overwrite) { $params['Overwrite'] = $true }
    $result = Install-SetupNetworkPrinter @params

    # The core asks for a manual INF or driver name instead of prompting.
    if (-not $result.Success -and $result.Data -and $result.Data.ContainsKey('NeedInf')) {
        Write-Host ("Driver files for '{0}' were not found." -f $preset.Make) -ForegroundColor Yellow
        Write-Host 'Download the universal driver from the vendor site, extract it,' -ForegroundColor Yellow
        Write-Host 'and point Software.json PrinterDrivers Path at the folder (or fill Url).' -ForegroundColor Yellow
        $manualInf = ((Read-Host 'Or enter a full path to an .inf file now (blank to cancel)') | ForEach-Object { "$_".Trim() })
        if (-not [string]::IsNullOrWhiteSpace($manualInf) -and (Test-Path -LiteralPath $manualInf -PathType Leaf)) {
            $params['PreferredInf'] = $manualInf
            $result = Install-SetupNetworkPrinter @params
        } else {
            Write-Host 'Printer install cancelled (no driver INF).' -ForegroundColor DarkYellow
            return
        }
    }

    if (-not $result.Success -and $result.Data -and $result.Data.ContainsKey('NeedDriverName')) {
        $drivers = @($result.Data['Drivers'])
        if ($drivers.Count -gt 0) {
            Write-Host 'Installed printer drivers (last 10):' -ForegroundColor Cyan
            @($drivers | Select-Object -Last 10) | ForEach-Object { Write-Host (" - {0}" -f $_) }
        }
        $typedName = ((Read-Host 'Type the exact driver name from the list above (blank to cancel)') | ForEach-Object { "$_".Trim() })
        if (-not [string]::IsNullOrWhiteSpace($typedName)) {
            $params['PreferredDriverName'] = $typedName
            $result = Install-SetupNetworkPrinter @params
        } else {
            Write-Host 'Printer install cancelled (no driver selected).' -ForegroundColor DarkYellow
            return
        }
    }

    Show-Result $result
}

function Show-PrinterList {
    $printers = @(Get-PrinterInventory)
    if ($printers.Count -eq 0) {
        Write-Host 'No printers installed on this PC. / Aucune imprimante installee.' -ForegroundColor Yellow
        return @()
    }
    Write-Host ''
    Write-Host 'INSTALLED PRINTERS / IMPRIMANTES INSTALLEES :' -ForegroundColor Cyan
    for ($index = 0; $index -lt $printers.Count; $index++) {
        $tag = ''
        if ($printers[$index].IsDefault) { $tag = ' [DEFAULT / DEFAUT]' }
        Write-Host (" {0,2}. {1}{2}" -f ($index + 1), $printers[$index].Name, $tag)
        Write-Host ("     Driver: {0} | Port: {1} | Status: {2}" -f $printers[$index].DriverName, $printers[$index].PortName, $printers[$index].Status)
    }
    return $printers
}

function Invoke-RenamePrinter {
    $printers = @(Show-PrinterList)
    if ($printers.Count -eq 0) { return }
    Write-Host '  0. Cancel / Annuler'
    $choice = ((Read-Host 'Printer number to rename / Numero a renommer') | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '0') {
        Write-Host 'Rename cancelled. / Annule.' -ForegroundColor DarkYellow
        return
    }
    if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $printers.Count) {
        Write-Host 'Invalid printer selection.' -ForegroundColor Yellow
        return
    }
    $oldName = $printers[[int]$choice - 1].Name
    $newName = ((Read-Host ("New name for '{0}' (blank to cancel)" -f $oldName)) | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host 'Rename cancelled.' -ForegroundColor DarkYellow
        return
    }
    Show-Result (Rename-SetupPrinter -Name $oldName -NewName $newName)
}

function Show-PrinterMenu {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not (Get-Command Get-Printer -ErrorAction SilentlyContinue)) {
        Write-Host 'Printer cmdlets (PrintManagement) are not available on this Windows edition.' -ForegroundColor Red
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
            '1' { Invoke-InstallPrinter -Config $Config }
            '2' { [void](Show-PrinterList); Read-Host 'Press Enter to continue / Entree pour continuer' | Out-Null }
            '3' { Invoke-RenamePrinter }
            default { Write-Host 'Invalid printer option. Use 1, 2, 3, or 0.' -ForegroundColor Yellow }
        }
    }
}

function Show-LocalUserList {
    try {
        $users = @(Get-LocalUserInventory)
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
    for ($index = 0; $index -lt $users.Count; $index++) {
        $state = if ($users[$index].Enabled) { 'Enabled/Active' } else { 'Disabled/Desactive' }
        $memberOf = if ($users[$index].Groups.Count -gt 0) { $users[$index].Groups -join ', ' } else { '(no groups)' }
        Write-Host (" {0,2}. {1} [{2}]" -f ($index + 1), $users[$index].Name, $state)
        if ($users[$index].IsSoleAdmin) {
            Write-Host '     LOCKED: only enabled administrator / seul administrateur actif' -ForegroundColor Red
        }
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
        return $null
    }
    return $Users[[int]$choice - 1]
}

function Invoke-RenameLocalUser {
    $users = @(Show-LocalUserList)
    if ($users.Count -eq 0) { return }
    $account = Select-LocalUserByNumber -Users $users -Prompt 'User number to rename / Numero a renommer (0 = cancel)'
    if ($null -eq $account) { return }
    $newName = ((Read-Host ("New name for '{0}' (1-20 chars, blank to cancel)" -f $account.Name)) | ForEach-Object { "$_".Trim() })
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host 'Rename cancelled.' -ForegroundColor DarkYellow
        return
    }
    Show-Result (Rename-SetupLocalAccount -Name $account.Name -NewName $newName)
}

function Invoke-SetLocalUserPassword {
    $users = @(Show-LocalUserList)
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
            return
        }
    } finally {
        $plainFirst = $null
        $plainConfirm = $null
    }

    Show-Result (Set-SetupLocalAccountPassword -UserName $account.Name -Password $securePassword)
    $securePassword = $null
    $confirmPassword = $null
}

function Invoke-EditUserGroups {
    $users = @(Show-LocalUserList)
    if ($users.Count -eq 0) { return }
    $account = Select-LocalUserByNumber -Users $users -Prompt 'User number for group change / Numero (0 = cancel)'
    if ($null -eq $account) { return }

    # Safety: the sole enabled administrator cannot be changed at all.
    $lock = Get-SoleAdminLock -UserName $account.Name
    if ($lock.Locked) {
        Write-Host $lock.Message -ForegroundColor Red
        Write-Host 'Verrouille : dernier administrateur actif. Adhesions bloquees.' -ForegroundColor Red
        return
    }

    $allGroups = @(Get-LocalGroupNames)
    if ($allGroups.Count -eq 0) {
        Write-Host 'Could not list local groups.' -ForegroundColor Red
        return
    }
    $current = @($account.Groups)
    Write-Host ("'{0}' is a member of / est membre de : {1}" -f $account.Name, $(if ($current.Count -gt 0) { $current -join ', ' } else { '(no groups)' })) -ForegroundColor Cyan

    $mode = ((Read-Host '[A]dd to a group / Ajouter, [R]emove from a group / Retirer (0 = cancel)') | ForEach-Object { "$_".Trim().ToLowerInvariant() })
    if ([string]::IsNullOrWhiteSpace($mode) -or $mode -in @('0', 'q', 'quit', 'exit')) {
        Write-Host 'Group change cancelled.' -ForegroundColor DarkYellow
        return
    }

    if ($mode -in @('a', 'add', 'ajouter')) {
        Write-Host ''
        Write-Host 'LOCAL GROUPS / GROUPES LOCAUX :' -ForegroundColor Cyan
        for ($index = 0; $index -lt $allGroups.Count; $index++) {
            $tag = if ($current -icontains $allGroups[$index]) { ' [already member]' } else { '' }
            Write-Host (" {0,2}. {1}{2}" -f ($index + 1), $allGroups[$index], $tag)
        }
        Write-Host '  0. Cancel / Annuler'
        $groupChoice = ((Read-Host 'Group number / Numero') | ForEach-Object { "$_".Trim() })
        if ([string]::IsNullOrWhiteSpace($groupChoice) -or $groupChoice -eq '0') {
            Write-Host 'Group change cancelled.' -ForegroundColor DarkYellow
            return
        }
        if ($groupChoice -notmatch '^\d+$' -or [int]$groupChoice -lt 1 -or [int]$groupChoice -gt $allGroups.Count) {
            Write-Host 'Invalid group selection.' -ForegroundColor Yellow
            return
        }
        $group = $allGroups[[int]$groupChoice - 1]
        if ($current -icontains $group) {
            Write-Host ("'{0}' is already a member of '{1}'." -f $account.Name, $group) -ForegroundColor DarkYellow
            return
        }
        Show-Result (Add-SetupLocalGroupMember -UserName $account.Name -GroupName $group)
    } elseif ($mode -in @('r', 'remove', 'retirer', 'retire')) {
        if ($current.Count -eq 0) {
            Write-Host ("'{0}' is not a member of any group." -f $account.Name) -ForegroundColor DarkYellow
            return
        }
        Write-Host 'Current groups:' -ForegroundColor Cyan
        for ($index = 0; $index -lt $current.Count; $index++) {
            Write-Host (" {0,2}. {1}" -f ($index + 1), $current[$index])
        }
        Write-Host '  0. Cancel / Annuler'
        $groupChoice = ((Read-Host 'Group number to remove from / Numero') | ForEach-Object { "$_".Trim() })
        if ([string]::IsNullOrWhiteSpace($groupChoice) -or $groupChoice -eq '0') {
            Write-Host 'Group change cancelled.' -ForegroundColor DarkYellow
            return
        }
        if ($groupChoice -notmatch '^\d+$' -or [int]$groupChoice -lt 1 -or [int]$groupChoice -gt $current.Count) {
            Write-Host 'Invalid group selection.' -ForegroundColor Yellow
            return
        }
        Show-Result (Remove-SetupLocalGroupMember -UserName $account.Name -GroupName $current[[int]$groupChoice - 1])
    } else {
        Write-Host 'Type A to add or R to remove. Nothing was changed.' -ForegroundColor Yellow
    }
}

function Invoke-SetUserEnabled {
    $users = @(Show-LocalUserList)
    if ($users.Count -eq 0) { return }
    $account = Select-LocalUserByNumber -Users $users -Prompt 'User number to enable/disable / Numero (0 = cancel)'
    if ($null -eq $account) { return }

    if ($account.Enabled -and $account.IsSoleAdmin) {
        Write-Host ("Cannot disable '{0}': it is the only enabled administrator on this PC." -f $account.Name) -ForegroundColor Red
        Write-Host 'Impossible : dernier administrateur actif. Activez-en un autre d''abord.' -ForegroundColor Red
        return
    }
    if ($account.Enabled -and -not [string]::IsNullOrWhiteSpace($script:OriginalUserSid) -and ($account.SID -eq $script:OriginalUserSid)) {
        Write-Host ("Cannot disable '{0}': it is the account you are signed in with." -f $account.Name) -ForegroundColor Red
        Write-Host 'Utilisez un autre compte administrateur pour le desactiver.' -ForegroundColor Red
        return
    }

    $newState = -not $account.Enabled
    $verb = if ($newState) { 'enable' } else { 'disable' }
    $currentState = if ($account.Enabled) { 'enabled' } else { 'disabled' }
    $answer = ((Read-Host ("'{0}' is currently {1}. Type {2} to {2} it, or press Enter to cancel / Tapez {2}" -f $account.Name, $currentState, $verb)) | ForEach-Object { "$_".Trim().ToLowerInvariant() })
    if ($answer -ne $verb) {
        Write-Host 'Account state change cancelled.' -ForegroundColor DarkYellow
        return
    }

    Show-Result (Set-SetupLocalUserEnabled -UserName $account.Name -Enabled $newState -ProtectedSid $script:OriginalUserSid)
}

function Show-UserMenu {
    if (-not (Get-Command Get-LocalUser -ErrorAction SilentlyContinue)) {
        Write-Host 'Local user cmdlets are not available on this Windows edition.' -ForegroundColor Red
        return
    }
    while ($true) {
        Write-Host ''
        Write-Host 'USERS / UTILISATEURS :' -ForegroundColor Cyan
        Write-Host '  1. List local users (details + member of)'
        Write-Host '  2. Rename a user'
        Write-Host "  3. Change a user's password"
        Write-Host "  4. Change a user's groups (member of)"
        Write-Host '  5. Enable or disable a user'
        Write-Host '  0. Back to main menu / Retour'
        $sub = ((Read-Host 'Users option') | ForEach-Object { "$_".Trim() })
        if ($sub -match '^(?i:0|q|quit|exit|b|back)$' -or [string]::IsNullOrWhiteSpace($sub)) {
            return
        }
        switch ($sub) {
            '1' { [void](Show-LocalUserList); Read-Host 'Press Enter to continue / Entree pour continuer' | Out-Null }
            '2' { Invoke-RenameLocalUser }
            '3' { Invoke-SetLocalUserPassword }
            '4' { Invoke-EditUserGroups }
            '5' { Invoke-SetUserEnabled }
            default { Write-Host 'Invalid users option. Use 1, 2, 3, 4, 5, or 0.' -ForegroundColor Yellow }
        }
    }
}

try {
    $configPath = Join-Path $scriptRoot 'Software.json'
    $config = Get-SetupConfig -Path $configPath

    while ($true) {
        $script:Results.Clear()
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
        Write-Host '  5. Users (list / rename / password / groups / enable-disable)'
        Write-Host '  6. Run all options (1+2+3+4+5)'
        Write-Host '  0. Exit / Quitter'
        Write-Host ''
        Write-Host 'You can choose more than one option, for example: 1,3'

        $mainChoice = ((Read-Host 'Enter option number(s)') | ForEach-Object { "$_".Trim() })
        if ($mainChoice -match '^(?i:0|q|quit|exit)$') {
            Write-Host 'Exiting without further changes. / Fin.' -ForegroundColor DarkYellow
            break
        }
        if ([string]::IsNullOrWhiteSpace($mainChoice)) { continue }

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

        if ($actions -contains '1') { Invoke-ConfigureAdministrator }
        if ($actions -contains '2') { Invoke-RenameCurrentUser }
        if ($actions -contains '3') { Invoke-InstallSoftware -Config $config }
        if ($actions -contains '4') { Show-PrinterMenu -Config $config }
        if ($actions -contains '5') { Show-UserMenu }

        Write-Host ''
        Write-Host '--------------------------------------------------------' -ForegroundColor Cyan
        Write-Host 'STEP FINISHED / ETAPE TERMINEE' -ForegroundColor Green
        Write-Host ("Log file: {0}" -f $logFile)
        $failures = @($script:Results | Where-Object { -not $_.Success -and -not $_.Skipped })
        if ($failures.Count -gt 0) {
            Write-Host 'Some actions or applications may not have completed:' -ForegroundColor Yellow
            foreach ($failure in $failures) {
                Write-Host (" - {0}" -f $failure.Name) -ForegroundColor Yellow
            }
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
    }
} catch {
    Write-Host ("SETUP ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Log file: {0}" -f $logFile)
    Read-Host 'Press Enter to close'
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
