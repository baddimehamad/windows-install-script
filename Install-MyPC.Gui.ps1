#Requires -Version 5.1
<#
.SYNOPSIS
    WPF front-end for Windows Automatic Setup.

.DESCRIPTION
    Native window for the setup kit. Requires nothing beyond Windows 10/11:
    Windows PowerShell 5.1 and the .NET Framework/WPF that ship with the OS.

    All actions live in Setup.Core.psm1 and run in a background runspace so
    the window never freezes. Long installs stream their log into the Log tab
    and into Logs\gui-YYYYMMDD-HHMMSS.log.

.PARAMETER OriginalUserSid
    SID of the user who started the process, preserved across the UAC prompt
    so "rename signed-in user" targets the right account.

.PARAMETER NoElevate
    Internal: do not relaunch elevated. Used by the automated smoke test.

.PARAMETER NoShow
    Internal: build and populate the window, then exit. Used by the smoke test.
#>
param(
    [string]$OriginalUserSid,
    [ValidateSet('Software', 'Printers', 'Users', 'Account', 'Log')][string]$StartPage = 'Software',
    [switch]$NoElevate,
    [switch]$NoShow
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Windows PowerShell 5.1 ships DPI-unaware. At 125%/150% Windows then
# bitmap-scales the whole window, which both blurs it and pushes it off the
# screen. Opting into system DPI awareness before the first window exists makes
# WPF lay out at the real size. Harmless if the call is unavailable.
try {
    Add-Type -Namespace SetupNative -Name Dpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
'@ -ErrorAction Stop
    [void][SetupNative.Dpi]::SetProcessDPIAware()
} catch { }

$script:ScriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($script:ScriptPath)) { $script:ScriptPath = $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($OriginalUserSid)) {
    try { $OriginalUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
}

function Get-RelaunchArguments {
    $parts = @('-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $script:ScriptPath))
    if (-not [string]::IsNullOrWhiteSpace($OriginalUserSid)) {
        $parts += @('-OriginalUserSid', ('"{0}"' -f $OriginalUserSid))
    }
    if ($NoShow) { $parts += '-NoShow' }
    if ($NoElevate) { $parts += '-NoElevate' }
    if ($StartPage -ne 'Software') { $parts += @('-StartPage', $StartPage) }
    return ($parts -join ' ')
}

# WPF requires STA. PowerShell 5.1 already runs STA, but a -MTA caller must not
# fail with a cryptic error, so relaunch quietly.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-RelaunchArguments) -Wait | Out-Null
    exit 0
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --------------------------------------------------------------------------
# Language
# --------------------------------------------------------------------------

# Windows UI language decides the window language: French on a French PC,
# English everywhere else. Log lines produced by Setup.Core.psm1 stay in
# English, exactly like the console log.
$script:Language = 'en'
try {
    if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'fr') {
        $script:Language = 'fr'
    }
} catch { }

# Optional override, useful on a French PC that must run in English (or the
# reverse): set SETUP_UI_LANG to en or fr before launching.
try {
    if ($env:SETUP_UI_LANG -eq 'en' -or $env:SETUP_UI_LANG -eq 'fr') {
        $script:Language = $env:SETUP_UI_LANG
    }
} catch { }

# French is written without accents on purpose: the .ps1 files are plain ASCII,
# which keeps Windows PowerShell 5.1 from mis-reading them on any code page.
$script:StringTable = @{
    'App.Title'                 = @{ en = "Windows Automatic Setup"; fr = "Installation automatique Windows" }
    'App.Elevated'              = @{ en = "Administrator"; fr = "Administrateur" }
    'App.NotElevated'           = @{ en = "Not elevated"; fr = "Non administrateur" }
    'App.Subtitle'              = @{ en = "Windows 10 / 11 setup - no installation required"; fr = "Installation Windows 10 / 11 - aucune installation requise" }
    'App.HeaderSubtitle'        = @{ en = "Windows 10 / 11 setup - no installation required  |  Logs: {0}"; fr = "Installation Windows 10 / 11 - aucune installation requise  |  Journaux : {0}" }
    'App.ElevationRequired'     = @{ en = "Administrator permission is required.`r`n`r`nThe UAC prompt was cancelled, so the setup window cannot start."; fr = "Les droits administrateur sont necessaires.`r`n`r`nLa demande UAC a ete annulee : la fenetre d'installation ne peut pas demarrer." }

    'Nav.Software'              = @{ en = "Software"; fr = "Logiciels" }
    'Nav.Printers'              = @{ en = "Printers"; fr = "Imprimantes" }
    'Nav.Users'                 = @{ en = "Users"; fr = "Utilisateurs" }
    'Nav.Account'               = @{ en = "Account"; fr = "Compte" }
    'Nav.Log'                   = @{ en = "Log"; fr = "Journal" }
    'Nav.LogFile'               = @{ en = "Log file"; fr = "Fichier journal" }

    'Software.Title'            = @{ en = "Software"; fr = "Logiciels" }
    'Software.Subtitle'         = @{ en = "Select the applications to install. Winget entries need Internet; local installers must exist in this folder."; fr = "Selectionnez les applications a installer. Les entrees Winget necessitent Internet ; les installateurs locaux doivent etre presents dans ce dossier." }
    'Software.SelectAll'        = @{ en = "Select all"; fr = "Tout selectionner" }
    'Software.Install'          = @{ en = "Install selected"; fr = "Installer la selection" }
    'Software.InstallCount'     = @{ en = "Install selected ({0})"; fr = "Installer la selection ({0})" }
    'Software.Summary'          = @{ en = "{0} application(s) available, {1} selected."; fr = "{0} application(s) disponible(s), {1} selectionnee(s)." }

    'Status.Ready'              = @{ en = "Ready"; fr = "Pret" }
    'Status.Download'           = @{ en = "Will download"; fr = "Sera telecharge" }
    'Status.Missing'            = @{ en = "File missing"; fr = "Fichier manquant" }
    'Status.Queued'             = @{ en = "Queued"; fr = "En attente" }
    'Status.Installing'         = @{ en = "Installing..."; fr = "Installation..." }
    'Status.Installed'          = @{ en = "Installed"; fr = "Installe" }
    'Status.InstalledRestart'   = @{ en = "Installed (restart)"; fr = "Installe (redemarrage)" }
    'Status.Skipped'            = @{ en = "Skipped"; fr = "Ignore" }
    'Status.Failed'             = @{ en = "Failed"; fr = "Echec" }
    'Status.Cancelled'          = @{ en = "Cancelled"; fr = "Annule" }

    'Printers.Title'            = @{ en = "Printers"; fr = "Imprimantes" }
    'Printers.Subtitle'         = @{ en = "Install a network printer over TCP/IP, or rename an existing one. Driver packages come from the Drivers folder or the repository cache."; fr = "Installez une imprimante reseau via TCP/IP, ou renommez-en une. Les pilotes proviennent du dossier Drivers ou du cache du depot." }
    'Printers.Add'              = @{ en = "Add a printer"; fr = "Ajouter une imprimante" }
    'Printers.Manufacturer'     = @{ en = "Manufacturer"; fr = "Fabricant" }
    'Printers.Address'          = @{ en = "IP address or hostname"; fr = "Adresse IP ou nom d'hote" }
    'Printers.Port'             = @{ en = "Port"; fr = "Port" }
    'Printers.NameOptional'     = @{ en = "Printer name (optional)"; fr = "Nom de l'imprimante (optionnel)" }
    'Printers.InfPath'          = @{ en = "Driver INF path (optional)"; fr = "Chemin du pilote .inf (optionnel)" }
    'Printers.Replace'          = @{ en = "Replace an existing printer with the same name"; fr = "Remplacer une imprimante existante du meme nom" }
    'Printers.Install'          = @{ en = "Install printer"; fr = "Installer l'imprimante" }
    'Printers.Installed'        = @{ en = "Installed printers"; fr = "Imprimantes installees" }
    'Printers.Empty'            = @{ en = "No printers installed on this PC."; fr = "Aucune imprimante installee sur ce PC." }
    'Printers.DriverWillImport' = @{ en = "Driver: {0} (will be imported on install)"; fr = "Pilote : {0} (sera importe a l'installation)" }
    'Printers.DriverInstalled'  = @{ en = "Driver: {0} (already installed)"; fr = "Pilote : {0} (deja installe)" }
    'Printers.DriverDetect'     = @{ en = "Driver name will be detected during install."; fr = "Le nom du pilote sera detecte pendant l'installation." }
    'Printers.SelectMake'       = @{ en = "Select a printer manufacturer."; fr = "Selectionnez un fabricant d'imprimante." }
    'Printers.EnterAddress'     = @{ en = "Enter the printer IP address or hostname."; fr = "Saisissez l'adresse IP ou le nom d'hote de l'imprimante." }
    'Printers.InvalidPort'      = @{ en = "The port must be a number between 1 and 65535."; fr = "Le port doit etre un nombre entre 1 et 65535." }
    'Printers.ExistsTitle'      = @{ en = "Printer exists"; fr = "Imprimante existante" }
    'Printers.ExistsText'       = @{ en = "A printer named '{0}' already exists.{1}{1}Replace it?"; fr = "Une imprimante nommee '{0}' existe deja.{1}{1}La remplacer ?" }
    'Printers.NoResult'         = @{ en = "No result was returned by the printer install."; fr = "L'installation n'a renvoye aucun resultat." }
    'Printers.FailedTitle'      = @{ en = "Printer installation failed"; fr = "Echec de l'installation de l'imprimante" }
    'Printers.RenameTitle'      = @{ en = "Rename printer"; fr = "Renommer l'imprimante" }
    'Printers.RenameLabel'      = @{ en = "New name for '{0}'"; fr = "Nouveau nom pour '{0}'" }
    'Printers.Task'             = @{ en = "Installing printer {0}"; fr = "Installation de l'imprimante {0}" }
    'Printers.Title2'           = @{ en = "Printer"; fr = "Imprimante" }

    'Users.Title'               = @{ en = "Users"; fr = "Utilisateurs" }
    'Users.Subtitle'            = @{ en = "Rename a local account, change its password, or edit its group membership. The last enabled administrator is protected."; fr = "Renommez un compte local, changez son mot de passe ou ses groupes. Le dernier administrateur actif est protege." }
    'Users.LocalAccounts'       = @{ en = "Local accounts on this PC"; fr = "Comptes locaux sur ce PC" }
    'Users.Empty'               = @{ en = "No local users found."; fr = "Aucun utilisateur local trouve." }
    'Users.MemberOf'            = @{ en = "Member of: {0}"; fr = "Membre de : {0}" }
    'Users.NoGroups'            = @{ en = "(no groups)"; fr = "(aucun groupe)" }
    'Users.Enabled'             = @{ en = "ENABLED"; fr = "ACTIF" }
    'Users.Disabled'            = @{ en = "DISABLED"; fr = "DESACTIVE" }
    'Users.LastAdmin'           = @{ en = "LAST ADMIN - LOCKED"; fr = "DERNIER ADMIN - VERROUILLE" }
    'Users.Rename'              = @{ en = "Rename"; fr = "Renommer" }
    'Users.Password'            = @{ en = "Password"; fr = "Mot de passe" }
    'Users.Groups'              = @{ en = "Groups"; fr = "Groupes" }
    'Users.RenameTitle'         = @{ en = "Rename user"; fr = "Renommer l'utilisateur" }
    'Users.RenameLabel'         = @{ en = "New name for '{0}' (1-20 characters)"; fr = "Nouveau nom pour '{0}' (1-20 caracteres)" }
    'Users.InvalidName'         = @{ en = "Invalid name"; fr = "Nom invalide" }
    'Users.PasswordTitle'       = @{ en = "Change password"; fr = "Changer le mot de passe" }
    'Users.PasswordLabel'       = @{ en = "New password for '{0}' (minimum 8 characters)"; fr = "Nouveau mot de passe pour '{0}' (8 caracteres minimum)" }
    'Users.AccountTitle'        = @{ en = "User account"; fr = "Compte utilisateur" }
    'Users.GroupsTitle'         = @{ en = "Groups - {0}"; fr = "Groupes - {0}" }
    'Users.GroupsHeader'        = @{ en = "Local groups for '{0}'"; fr = "Groupes locaux pour '{0}'" }
    'Users.AddToGroup'          = @{ en = "Add to group"; fr = "Ajouter au groupe" }
    'Users.RemoveFromGroup'     = @{ en = "Remove from group"; fr = "Retirer du groupe" }
    'Users.Member'              = @{ en = "(member)"; fr = "(membre)" }
    'Users.GroupChangeTitle'    = @{ en = "Group change"; fr = "Changement de groupe" }
    'Users.Locked'              = @{ en = "LOCKED: this is the only enabled administrator. Group membership is frozen."; fr = "VERROUILLE : seul administrateur actif. Les groupes sont figes." }
    'Users.NotMember'           = @{ en = "'{0}' is not a member of '{1}'."; fr = "'{0}' n'est pas membre de '{1}'." }
    'Users.RenameTask'          = @{ en = "Renaming {0} to {1}"; fr = "Renommage de {0} en {1}" }
    'Users.PasswordTask'        = @{ en = "Changing the password for {0}"; fr = "Changement du mot de passe de {0}" }

    'Account.Title'             = @{ en = "Account"; fr = "Compte" }
    'Account.Subtitle'          = @{ en = "Enable the built-in Administrator account, or rename the account you are signed in with."; fr = "Activez le compte administrateur integre, ou renommez le compte utilise pour la session." }
    'Account.AdminTitle'        = @{ en = "Built-in Administrator"; fr = "Administrateur integre" }
    'Account.AdminState'        = @{ en = "Account: {0}  ({1})"; fr = "Compte : {0}  ({1})" }
    'Account.AdminEnabled'      = @{ en = "currently enabled"; fr = "actuellement active" }
    'Account.AdminDisabled'     = @{ en = "currently disabled"; fr = "actuellement desactive" }
    'Account.AdminNotFound'     = @{ en = "Built-in Administrator account not found (SID ending in -500)."; fr = "Compte administrateur integre introuvable (SID se terminant par -500)." }
    'Account.NewPassword'       = @{ en = "New password (minimum 8 characters)"; fr = "Nouveau mot de passe (8 caracteres minimum)" }
    'Account.ConfirmPassword'   = @{ en = "Confirm password"; fr = "Confirmez le mot de passe" }
    'Account.AdminButton'       = @{ en = "Enable and set password"; fr = "Activer et definir le mot de passe" }
    'Account.AdminHint'         = @{ en = "The password is never stored by this tool. Use a unique, strong password per machine."; fr = "Le mot de passe n'est jamais stocke par cet outil. Utilisez un mot de passe unique et solide par machine." }
    'Account.SignedInTitle'     = @{ en = "Signed-in local user"; fr = "Utilisateur local connecte" }
    'Account.SignedIn'          = @{ en = "Signed-in local account: {0}"; fr = "Compte local connecte : {0}" }
    'Account.NotLocal'          = @{ en = "The signed-in account could not be matched to a local account (domain or Entra ID account)."; fr = "Le compte connecte ne correspond a aucun compte local (compte de domaine ou Entra ID)." }
    'Account.NewName'           = @{ en = "New account name (1-20 characters)"; fr = "Nouveau nom du compte (1-20 caracteres)" }
    'Account.RenameButton'      = @{ en = "Rename account"; fr = "Renommer le compte" }
    'Account.RenameHint'        = @{ en = "The C:\Users profile folder is not renamed. A sign-out or restart may be needed for the new name to appear everywhere."; fr = "Le dossier de profil C:\Users n'est pas renomme. Une deconnexion ou un redemarrage peut etre necessaire." }
    'Account.EnterName'         = @{ en = "Enter the new account name."; fr = "Saisissez le nouveau nom du compte." }
    'Account.NotLocalError'     = @{ en = "The signed-in account is not a local account, so it cannot be renamed here."; fr = "Le compte connecte n'est pas un compte local : il ne peut pas etre renomme ici." }
    'Account.RenameConfirm'     = @{ en = "Rename local account '{0}' to '{1}'?{2}{2}The C:\Users profile folder is not renamed."; fr = "Renommer le compte local '{0}' en '{1}' ?{2}{2}Le dossier de profil C:\Users n'est pas renomme." }
    'Account.ConfirmTitle'      = @{ en = "Confirm rename"; fr = "Confirmer le renommage" }
    'Account.EnterPassword'     = @{ en = "Enter a password for the built-in Administrator account."; fr = "Saisissez un mot de passe pour le compte administrateur integre." }
    'Account.PasswordShort'     = @{ en = "The password must be at least 8 characters."; fr = "Le mot de passe doit contenir au moins 8 caracteres." }
    'Account.PasswordMismatch'  = @{ en = "The passwords do not match. Nothing was changed."; fr = "Les mots de passe ne correspondent pas. Aucune modification." }
    'Account.PasswordTitle'     = @{ en = "Password"; fr = "Mot de passe" }
    'Account.ConfirmEnable'     = @{ en = "Enable the built-in Administrator account and set this password?{0}{0}Use a unique, strong password per machine."; fr = "Activer le compte administrateur integre et definir ce mot de passe ?{0}{0}Utilisez un mot de passe unique et solide par machine." }
    'Account.Task'              = @{ en = "Enabling the built-in Administrator..."; fr = "Activation de l'administrateur integre..." }

    'Log.Title'                 = @{ en = "Log"; fr = "Journal" }
    'Log.Copy'                  = @{ en = "Copy"; fr = "Copier" }
    'Log.OpenFolder'            = @{ en = "Open folder"; fr = "Ouvrir le dossier" }
    'Log.Copied'                = @{ en = "Log copied to the clipboard."; fr = "Journal copie dans le presse-papiers." }
    'Log.CopyTitle'             = @{ en = "Copy log"; fr = "Copier le journal" }

    'Common.Clear'              = @{ en = "Clear"; fr = "Effacer" }
    'Common.Refresh'            = @{ en = "Refresh"; fr = "Actualiser" }
    'Common.Cancel'             = @{ en = "Cancel"; fr = "Annuler" }
    'Common.Close'              = @{ en = "Close"; fr = "Fermer" }
    'Common.OK'                 = @{ en = "OK"; fr = "OK" }
    'Common.Confirm'            = @{ en = "Confirm"; fr = "Confirmer" }
    'Common.Error'              = @{ en = "Error"; fr = "Erreur" }
    'Common.WarningTitle'       = @{ en = "Warning"; fr = "Attention" }
    'Common.StatusReady'        = @{ en = "Ready."; fr = "Pret." }
    'Common.Cancelling'         = @{ en = "Cancelling..."; fr = "Annulation..." }
    'Common.TaskRunning'        = @{ en = "A task is already running. Wait for it to finish."; fr = "Une tache est deja en cours. Attendez qu'elle se termine." }
    'Common.CancelTaskTitle'    = @{ en = "Task running"; fr = "Tache en cours" }
    'Common.CancelTaskText'     = @{ en = "A task is still running.{0}{0}Cancel it and exit? A child installer (winget, msiexec) may keep running in the background."; fr = "Une tache est toujours en cours.{0}{0}L'annuler et quitter ? Un programme d'installation (winget, msiexec) peut continuer en arriere-plan." }
    'Common.NoResult'           = @{ en = "No result was returned."; fr = "Aucun resultat renvoye." }
    'Common.CancelledLog'       = @{ en = "Task cancelled."; fr = "Tache annulee." }

    'Install.NothingTitle'      = @{ en = "Nothing selected"; fr = "Aucune selection" }
    'Install.NothingText'       = @{ en = "Select at least one application first."; fr = "Selectionnez d'abord au moins une application." }
    'Install.FinishedTitle'     = @{ en = "Installation finished"; fr = "Installation terminee" }
    'Install.FailedSummary'     = @{ en = "{0} item(s) did not install:{1}{2}{1}{1}See the Log tab for details."; fr = "{0} element(s) n'ont pas ete installes :{1}{2}{1}{1}Voir l'onglet Journal." }
    'Install.Summary'           = @{ en = "Installation finished.{0}{0}Installed: {1}{0}Skipped: {2}"; fr = "Installation terminee.{0}{0}Installes : {1}{0}Ignores : {2}" }
    'Install.Started'           = @{ en = "Software installation started: {0} item(s)."; fr = "Installation demarree : {0} element(s)." }
    'Install.Step'              = @{ en = "Installing {0} ({1}/{2})"; fr = "Installation de {0} ({1}/{2})" }
    'Install.QueueStep'         = @{ en = "[{0}/{1}] {2}"; fr = "[{0}/{1}] {2}" }
    'Install.FinishedLog'       = @{ en = "Software installation finished: {0} installed, {1} failed, {2} skipped."; fr = "Installation terminee : {0} installes, {1} en echec, {2} ignores." }
    'Install.CancelledRest'     = @{ en = "The remaining items were not installed because the task was cancelled."; fr = "Les elements restants n'ont pas ete installes (tache annulee)." }
    'Install.WingetMissing'     = @{ en = "winget is not available. Winget apps will be skipped; local installers can still run."; fr = "winget est indisponible. Les applications Winget seront ignorees ; les installateurs locaux restent possibles." }
    'Install.WingetHint'        = @{ en = "Install Microsoft App Installer from https://aka.ms/getwinget and try again."; fr = "Installez Microsoft App Installer depuis https://aka.ms/getwinget puis reessayez." }
    'Install.CheckingWinget'    = @{ en = "Checking Winget sources..."; fr = "Verification des sources Winget..." }

    # Keys used only by the window code, not by the XAML.
    'Common.TaskFailed'         = @{ en = "The task failed."; fr = "La tache a echoue." }
    'Common.RenameButton'       = @{ en = "Rename"; fr = "Renommer" }
    'Common.SeeLog'             = @{ en = "See the Log tab for details."; fr = "Voir l'onglet Journal pour les details." }
    'Printers.DefaultBadge'     = @{ en = "DEFAULT"; fr = "PAR DEFAUT" }
    'Printers.Detail'           = @{ en = "Driver: {0}  |  Port: {1}  |  Status: {2}"; fr = "Pilote : {0}  |  Port : {1}  |  Etat : {2}" }
    'Users.PasswordMismatch'    = @{ en = "The passwords do not match."; fr = "Les mots de passe ne correspondent pas." }
}

$script:Ui = @{}
foreach ($key in $script:StringTable.Keys) {
    $entry = $script:StringTable[$key]
    $value = $entry[$script:Language]
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $entry['en'] }
    $script:Ui[$key] = $value
}

function Get-UiText {
    <#
    .SYNOPSIS
        Returns one translated string by key.
    #>
    param([Parameter(Mandatory = $true)][string]$Key)
    if ($script:Ui.ContainsKey($Key)) { return $script:Ui[$Key] }
    return $Key
}

function Expand-UiTokens {
    <#
    .SYNOPSIS
        Replaces @@Key@@ placeholders in the XAML with translated text.
    #>
    param([Parameter(Mandatory = $true)][string]$Xaml)
    return [regex]::Replace($Xaml, '@@([A-Za-z0-9_.]+)@@', {
        param($match)
        $key = $match.Groups[1].Value
        if ($script:Ui.ContainsKey($key)) { return $script:Ui[$key] }
        return $match.Value
    })
}

# Elevate before building the window: a half-built window that pops UAC on the
# first click looks broken and loses state.
if ((-not $isAdmin) -and (-not $NoElevate)) {
    try {
        $elevated = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (Get-RelaunchArguments) -PassThru
        $elevated.WaitForExit()
        exit $elevated.ExitCode
    } catch {
        [void][System.Windows.MessageBox]::Show(
            (Get-UiText 'App.ElevationRequired'),
            (Get-UiText 'App.Title'), [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        exit 1
    }
}

# --------------------------------------------------------------------------
# Paths, config and module
# --------------------------------------------------------------------------

$script:Root = Split-Path -Parent $script:ScriptPath
$script:ModulePath = Join-Path $script:Root 'Setup.Core.psm1'
$script:ConfigPath = Join-Path $script:Root 'Software.json'
$script:LogDir = Join-Path $script:Root 'Logs'
New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
$script:LogFile = Join-Path $script:LogDir ('gui-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

Import-Module $script:ModulePath -Force

try {
    $script:Config = Get-SetupConfig -Path $script:ConfigPath
} catch {
    [void][System.Windows.MessageBox]::Show($_.Exception.Message, (Get-UiText 'App.Title'),
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit 1
}

# --------------------------------------------------------------------------
# XAML
# --------------------------------------------------------------------------

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="@@App.Title@@"
        Height="760" Width="1120" MinHeight="540" MinWidth="880"
        WindowStartupLocation="CenterScreen"
        Background="#F4F6F8" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="PageTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#1B1F24"/>
    </Style>
    <Style x:Key="PageSubtitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="#5F6B76"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#E1E5EA"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#5F6B76"/>
      <Setter Property="Margin" Value="0,10,0,4"/>
    </Style>
    <Style x:Key="FieldBox" TargetType="TextBox">
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#D7DCE2"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="#0F6CBD"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#0C5CA5"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#0A4E8C"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#C9D0D7"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#1B1F24"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderBrush" Value="#D7DCE2"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F2F4F7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E7EBF0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#F5F6F8"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#E5E8EC"/>
                <Setter Property="Foreground" Value="#A6AFB8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavButton" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#3A4650"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="3"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="Bar" Grid.Column="0" Background="Transparent" CornerRadius="2" Margin="0,1,9,1"/>
                <ContentPresenter Grid.Column="1" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F2F4F7"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E8F1FA"/>
                <Setter TargetName="Bar" Property="Background" Value="#0F6CBD"/>
                <Setter Property="Foreground" Value="#0B4F82"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#0F2B46" Padding="24,16">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Margin="0,0,16,0">
          <TextBlock Text="@@App.Title@@" Foreground="#FFFFFF" FontSize="20" FontWeight="SemiBold"/>
          <TextBlock x:Name="HeaderSubtitle" Foreground="#A9C3DA" FontSize="12" Margin="0,3,0,0"
                     TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <Border Grid.Column="1" VerticalAlignment="Center" Background="#1D4D74" CornerRadius="12" Padding="12,5">
          <TextBlock x:Name="ElevationBadge" Text="@@App.Elevated@@" Foreground="#CFE6FF" FontSize="11.5"/>
        </Border>
      </Grid>
    </Border>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="212"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#FFFFFF" BorderBrush="#E1E5EA" BorderThickness="0,0,1,0" Padding="10,14">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0">
            <RadioButton x:Name="NavSoftware" Style="{StaticResource NavButton}" GroupName="Nav" Content="@@Nav.Software@@"/>
            <RadioButton x:Name="NavPrinters" Style="{StaticResource NavButton}" GroupName="Nav" Content="@@Nav.Printers@@"/>
            <RadioButton x:Name="NavUsers" Style="{StaticResource NavButton}" GroupName="Nav" Content="@@Nav.Users@@"/>
            <RadioButton x:Name="NavAccount" Style="{StaticResource NavButton}" GroupName="Nav" Content="@@Nav.Account@@"/>
            <RadioButton x:Name="NavLog" Style="{StaticResource NavButton}" GroupName="Nav" Content="@@Nav.Log@@"/>
          </StackPanel>
          <StackPanel Grid.Row="2">
            <Rectangle Height="1" Fill="#EEF0F3" Margin="6,0,6,10"/>
            <TextBlock Text="@@Nav.LogFile@@" FontSize="10.5" Foreground="#93A0AA" Margin="6,0,0,2"/>
            <TextBlock x:Name="NavLogPath" FontSize="10.5" Foreground="#5F6B76" TextWrapping="Wrap" Margin="6,0,6,0"/>
          </StackPanel>
        </Grid>
      </Border>

      <Grid Grid.Column="1" Margin="22,18,22,18">

        <!-- ============================ SOFTWARE ============================ -->
        <Grid x:Name="PageSoftware">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0">
            <TextBlock Text="@@Software.Title@@" Style="{StaticResource PageTitle}"/>
            <TextBlock Text="@@Software.Subtitle@@"
                       Style="{StaticResource PageSubtitle}"/>
          </StackPanel>
          <Grid Grid.Row="1" Margin="0,18,0,12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="SoftwareFilter" Style="{StaticResource FieldBox}" Height="32" VerticalAlignment="Center"/>
            <Button x:Name="SoftwareSelectAll" Grid.Column="1" Content="@@Software.SelectAll@@" Style="{StaticResource SecondaryButton}" Margin="10,0,0,0"/>
            <Button x:Name="SoftwareSelectNone" Grid.Column="2" Content="@@Common.Clear@@" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0"/>
          </Grid>
          <Border Grid.Row="2" Style="{StaticResource Card}" Padding="0">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="SoftwareList"/>
            </ScrollViewer>
          </Border>
          <Grid Grid.Row="3" Margin="0,14,0,0">
            <TextBlock x:Name="SoftwareSummary" VerticalAlignment="Center" Foreground="#5F6B76" FontSize="12.5"/>
            <Button x:Name="SoftwareInstallButton" Content="@@Software.Install@@" HorizontalAlignment="Right"
                    Style="{StaticResource PrimaryButton}" Padding="20,9"/>
          </Grid>
        </Grid>

        <!-- ============================ PRINTERS ============================ -->
        <Grid x:Name="PagePrinters" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0">
            <TextBlock Text="@@Printers.Title@@" Style="{StaticResource PageTitle}"/>
            <TextBlock Text="@@Printers.Subtitle@@"
                       Style="{StaticResource PageSubtitle}"/>
          </StackPanel>
          <Grid Grid.Row="1" Margin="0,18,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="390"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,16,0">
              <StackPanel>
                <TextBlock Text="@@Printers.Add@@" FontWeight="SemiBold" FontSize="14"/>
                <TextBlock Text="@@Printers.Manufacturer@@" Style="{StaticResource FieldLabel}"/>
                <ComboBox x:Name="PrinterMake" Height="32" FontSize="13" DisplayMemberPath="Make"/>
                <TextBlock x:Name="PrinterDriverInfo" FontSize="11.5" Foreground="#5F6B76" TextWrapping="Wrap" Margin="0,6,0,0"/>
                <TextBlock Text="@@Printers.Address@@" Style="{StaticResource FieldLabel}"/>
                <TextBox x:Name="PrinterHost" Style="{StaticResource FieldBox}"/>
                <Grid Margin="0,10,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="112"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0" Margin="0,0,10,0">
                    <TextBlock Text="@@Printers.Port@@" Style="{StaticResource FieldLabel}" Margin="0,0,0,4"/>
                    <TextBox x:Name="PrinterPort" Text="9100" Style="{StaticResource FieldBox}"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1">
                    <TextBlock Text="@@Printers.NameOptional@@" Style="{StaticResource FieldLabel}" Margin="0,0,0,4"/>
                    <TextBox x:Name="PrinterName" Style="{StaticResource FieldBox}"/>
                  </StackPanel>
                </Grid>
                <TextBlock Text="@@Printers.InfPath@@" Style="{StaticResource FieldLabel}"/>
                <TextBox x:Name="PrinterInf" Style="{StaticResource FieldBox}"/>
                <CheckBox x:Name="PrinterReplace" Content="@@Printers.Replace@@"
                          Margin="0,14,0,0" FontSize="12.5"/>
                <Button x:Name="PrinterInstallButton" Content="@@Printers.Install@@" Style="{StaticResource PrimaryButton}"
                        HorizontalAlignment="Left" Margin="0,18,0,0" Padding="18,9"/>
              </StackPanel>
            </Border>
            <Border Grid.Column="1" Style="{StaticResource Card}" Padding="0">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Grid Margin="16,12,16,10">
                  <TextBlock Text="@@Printers.Installed@@" FontWeight="SemiBold" FontSize="14" VerticalAlignment="Center"/>
                  <Button x:Name="PrinterRefreshButton" Content="@@Common.Refresh@@" HorizontalAlignment="Right"
                          Style="{StaticResource SecondaryButton}"/>
                </Grid>
                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="PrinterList"/>
                </ScrollViewer>
              </Grid>
            </Border>
          </Grid>
        </Grid>

        <!-- ============================== USERS ============================= -->
        <Grid x:Name="PageUsers" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0">
            <TextBlock Text="@@Users.Title@@" Style="{StaticResource PageTitle}"/>
            <TextBlock Text="@@Users.Subtitle@@"
                       Style="{StaticResource PageSubtitle}"/>
          </StackPanel>
          <Grid Grid.Row="1" Margin="0,18,0,12">
            <TextBlock Text="@@Users.LocalAccounts@@" FontSize="12.5" Foreground="#5F6B76" VerticalAlignment="Center"/>
            <Button x:Name="UserRefreshButton" Content="@@Common.Refresh@@" HorizontalAlignment="Right" Style="{StaticResource SecondaryButton}"/>
          </Grid>
          <Border Grid.Row="2" Style="{StaticResource Card}" Padding="0">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="UserList"/>
            </ScrollViewer>
          </Border>
        </Grid>

        <!-- ============================= ACCOUNT ============================ -->
        <ScrollViewer x:Name="PageAccount" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Text="@@Account.Title@@" Style="{StaticResource PageTitle}"/>
            <TextBlock Text="@@Account.Subtitle@@"
                       Style="{StaticResource PageSubtitle}"/>

            <Border Style="{StaticResource Card}" Margin="0,18,0,0">
              <StackPanel>
                <TextBlock Text="@@Account.AdminTitle@@" FontWeight="SemiBold" FontSize="14"/>
                <TextBlock x:Name="BuiltInAdminLabel" Margin="0,6,0,0" Foreground="#5F6B76" TextWrapping="Wrap"/>
                <TextBlock Text="@@Account.NewPassword@@" Style="{StaticResource FieldLabel}"/>
                <PasswordBox x:Name="AdminPassword" Padding="8,6" BorderBrush="#D7DCE2" BorderThickness="1"
                             FontSize="13" VerticalContentAlignment="Center"/>
                <TextBlock Text="@@Account.ConfirmPassword@@" Style="{StaticResource FieldLabel}"/>
                <PasswordBox x:Name="AdminPasswordConfirm" Padding="8,6" BorderBrush="#D7DCE2" BorderThickness="1"
                             FontSize="13" VerticalContentAlignment="Center"/>
                <Button x:Name="AdminEnableButton" Content="@@Account.AdminButton@@" Style="{StaticResource PrimaryButton}"
                        HorizontalAlignment="Left" Margin="0,18,0,0" Padding="18,9"/>
                <TextBlock Text="@@Account.AdminHint@@"
                           FontSize="11.5" Foreground="#5F6B76" Margin="0,12,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}" Margin="0,16,0,0">
              <StackPanel>
                <TextBlock Text="@@Account.SignedInTitle@@" FontWeight="SemiBold" FontSize="14"/>
                <TextBlock x:Name="CurrentUserLabel" Margin="0,6,0,0" Foreground="#5F6B76" TextWrapping="Wrap"/>
                <TextBlock Text="@@Account.NewName@@" Style="{StaticResource FieldLabel}"/>
                <TextBox x:Name="RenameNewName" Style="{StaticResource FieldBox}"/>
                <Button x:Name="RenameApplyButton" Content="@@Account.RenameButton@@" Style="{StaticResource PrimaryButton}"
                        HorizontalAlignment="Left" Margin="0,18,0,0" Padding="18,9"/>
                <TextBlock Text="@@Account.RenameHint@@"
                           FontSize="11.5" Foreground="#5F6B76" Margin="0,12,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- =============================== LOG ============================== -->
        <Grid x:Name="PageLog" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid>
            <StackPanel>
              <TextBlock Text="@@Log.Title@@" Style="{StaticResource PageTitle}"/>
              <TextBlock x:Name="LogPathLabel" Style="{StaticResource PageSubtitle}"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
              <Button x:Name="LogCopyButton" Content="@@Log.Copy@@" Style="{StaticResource SecondaryButton}" Margin="0,0,8,0"/>
              <Button x:Name="LogOpenButton" Content="@@Log.OpenFolder@@" Style="{StaticResource SecondaryButton}" Margin="0,0,8,0"/>
              <Button x:Name="LogClearButton" Content="@@Common.Clear@@" Style="{StaticResource SecondaryButton}"/>
            </StackPanel>
          </Grid>
          <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,18,0,0" Padding="0">
            <RichTextBox x:Name="LogView" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                         VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" Padding="10"/>
          </Border>
        </Grid>
      </Grid>
    </Grid>

    <Border Grid.Row="2" Background="#FFFFFF" BorderBrush="#E1E5EA" BorderThickness="0,1,0,0" Padding="20,9">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="StatusLabel" Text="@@Common.StatusReady@@" VerticalAlignment="Center" FontSize="12.5" Foreground="#3A4650"/>
        <ProgressBar x:Name="StatusProgress" Grid.Column="1" Width="170" Height="5" Margin="12,0"
                     IsIndeterminate="True" Visibility="Collapsed" Foreground="#0F6CBD"/>
        <Button x:Name="CancelButton" Grid.Column="2" Content="@@Common.Cancel@@" Style="{StaticResource SecondaryButton}"
                Visibility="Collapsed" Padding="12,5"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$xaml = Expand-UiTokens -Xaml $xaml
$script:Window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new([xml]$xaml))

function Get-Control {
    param([Parameter(Mandatory = $true)][string]$Name)
    $control = $script:Window.FindName($Name)
    if ($null -eq $control) { throw "UI control '$Name' is missing from the XAML." }
    return $control
}

$script:HeaderSubtitle = Get-Control 'HeaderSubtitle'
$script:ElevationBadge = Get-Control 'ElevationBadge'
$script:NavSoftware = Get-Control 'NavSoftware'
$script:NavPrinters = Get-Control 'NavPrinters'
$script:NavUsers = Get-Control 'NavUsers'
$script:NavAccount = Get-Control 'NavAccount'
$script:NavLog = Get-Control 'NavLog'
$script:NavLogPath = Get-Control 'NavLogPath'
$script:PageSoftware = Get-Control 'PageSoftware'
$script:PagePrinters = Get-Control 'PagePrinters'
$script:PageUsers = Get-Control 'PageUsers'
$script:PageAccount = Get-Control 'PageAccount'
$script:PageLog = Get-Control 'PageLog'
$script:SoftwareFilter = Get-Control 'SoftwareFilter'
$script:SoftwareList = Get-Control 'SoftwareList'
$script:SoftwareSummary = Get-Control 'SoftwareSummary'
$script:SoftwareInstallButton = Get-Control 'SoftwareInstallButton'
$script:SoftwareSelectAll = Get-Control 'SoftwareSelectAll'
$script:SoftwareSelectNone = Get-Control 'SoftwareSelectNone'
$script:PrinterMake = Get-Control 'PrinterMake'
$script:PrinterDriverInfo = Get-Control 'PrinterDriverInfo'
$script:PrinterHost = Get-Control 'PrinterHost'
$script:PrinterPort = Get-Control 'PrinterPort'
$script:PrinterName = Get-Control 'PrinterName'
$script:PrinterInf = Get-Control 'PrinterInf'
$script:PrinterReplace = Get-Control 'PrinterReplace'
$script:PrinterInstallButton = Get-Control 'PrinterInstallButton'
$script:PrinterRefreshButton = Get-Control 'PrinterRefreshButton'
$script:PrinterList = Get-Control 'PrinterList'
$script:UserRefreshButton = Get-Control 'UserRefreshButton'
$script:UserList = Get-Control 'UserList'
$script:BuiltInAdminLabel = Get-Control 'BuiltInAdminLabel'
$script:AdminPassword = Get-Control 'AdminPassword'
$script:AdminPasswordConfirm = Get-Control 'AdminPasswordConfirm'
$script:AdminEnableButton = Get-Control 'AdminEnableButton'
$script:CurrentUserLabel = Get-Control 'CurrentUserLabel'
$script:RenameNewName = Get-Control 'RenameNewName'
$script:RenameApplyButton = Get-Control 'RenameApplyButton'
$script:LogPathLabel = Get-Control 'LogPathLabel'
$script:LogView = Get-Control 'LogView'
$script:LogCopyButton = Get-Control 'LogCopyButton'
$script:LogOpenButton = Get-Control 'LogOpenButton'
$script:LogClearButton = Get-Control 'LogClearButton'
$script:StatusLabel = Get-Control 'StatusLabel'
$script:StatusProgress = Get-Control 'StatusProgress'
$script:CancelButton = Get-Control 'CancelButton'
$script:LogDocument = $script:LogView.Document

# --------------------------------------------------------------------------
# Shared state
# --------------------------------------------------------------------------

$script:Brushes = @{}
$script:LevelBrushes = @{}
$script:SoftwareRows = @()
$script:PrinterRows = @()
$script:UserRows = @()
$script:Queue = @()
$script:QueueIndex = 0
$script:QueueTotal = 0
$script:QueueResults = [System.Collections.Generic.List[object]]::new()
$script:CurrentRow = $null
$script:CurrentPS = $null
$script:CurrentResultBag = $null
$script:LogQueue = $null
$script:TaskOnComplete = ''
$script:TaskFinalized = $false
$script:LastResults = @()
$script:Busy = $false
$script:Cancelled = $false
$script:CloseWhenIdle = $false
$script:WingetAvailable = $false
$script:ActionButtons = @()

function Get-Brush {
    param([Parameter(Mandatory = $true)][string]$Hex)
    if (-not $script:Brushes.ContainsKey($Hex)) {
        $script:Brushes[$Hex] = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
    }
    return $script:Brushes[$Hex]
}

$script:LevelBrushes = @{
    Info    = (Get-Brush '#1B1F24')
    Success = (Get-Brush '#107C10')
    Warning = (Get-Brush '#9A6100')
    Error   = (Get-Brush '#C42B1C')
    Detail  = (Get-Brush '#6B7680')
    Task    = (Get-Brush '#0B4F82')
}

# --------------------------------------------------------------------------
# Small UI helpers
# --------------------------------------------------------------------------

function New-UiText {
    param(
        [string]$Text = '',
        [double]$Size = 13,
        [string]$Weight = 'Normal',
        [string]$Color = '#1B1F24',
        [bool]$Wrap = $false
    )
    $block = [System.Windows.Controls.TextBlock]::new()
    $block.Text = $Text
    $block.FontSize = $Size
    switch ($Weight) {
        'SemiBold' { $block.FontWeight = [System.Windows.FontWeights]::SemiBold }
        'Bold' { $block.FontWeight = [System.Windows.FontWeights]::Bold }
        default { $block.FontWeight = [System.Windows.FontWeights]::Normal }
    }
    $block.Foreground = Get-Brush $Color
    if ($Wrap) { $block.TextWrapping = [System.Windows.TextWrapping]::Wrap }
    return $block
}

function New-UiGrid {
    param([string[]]$Columns)
    $grid = [System.Windows.Controls.Grid]::new()
    foreach ($spec in $Columns) {
        $column = [System.Windows.Controls.ColumnDefinition]::new()
        if ($spec -eq '*') {
            $column.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        } elseif ($spec -ieq 'Auto') {
            $column.Width = [System.Windows.GridLength]::Auto
        } elseif ($spec.EndsWith('*')) {
            $column.Width = [System.Windows.GridLength]::new([double]$spec.TrimEnd('*'), [System.Windows.GridUnitType]::Star)
        } else {
            $column.Width = [System.Windows.GridLength]::new([double]$spec)
        }
        [void]$grid.ColumnDefinitions.Add($column)
    }
    return $grid
}

function Add-LogLine {
    param([string]$Level, [string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return }
    $levelKey = $Level
    if (-not $script:LevelBrushes.ContainsKey($levelKey)) { $levelKey = 'Info' }

    $paragraph = [System.Windows.Documents.Paragraph]::new()
    $paragraph.Margin = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $run = [System.Windows.Documents.Run]::new($Message)
    $run.Foreground = $script:LevelBrushes[$levelKey]
    if ($levelKey -eq 'Task') { $run.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $paragraph.Inlines.Add($run)
    [void]$script:LogDocument.Blocks.Add($paragraph)

    # Keep memory bounded on long installs.
    while ($script:LogDocument.Blocks.Count -gt 4000) {
        $script:LogDocument.Blocks.Remove($script:LogDocument.Blocks.FirstBlock)
    }
    $script:LogView.ScrollToEnd()

    try {
        $stamp = (Get-Date).ToString('HH:mm:ss')
        Add-Content -LiteralPath $script:LogFile -Value ("[{0}] {1,-7} {2}" -f $stamp, $levelKey, $Message) -Encoding UTF8
    } catch { }
}

function Show-Message {
    param(
        [string]$Text,
        [string]$Title = '',
        [string]$Icon = 'Information'
    )
    if ([string]::IsNullOrWhiteSpace($Title)) { $Title = Get-UiText 'App.Title' }
    $image = [System.Windows.MessageBoxImage]$Icon
    if ($null -eq $script:Window) {
        [void][System.Windows.MessageBox]::Show($Text, $Title, [System.Windows.MessageBoxButton]::OK, $image)
    } else {
        [void][System.Windows.MessageBox]::Show($script:Window, $Text, $Title, [System.Windows.MessageBoxButton]::OK, $image)
    }
}

function Show-Confirm {
    param([string]$Text, [string]$Title = '')
    if ([string]::IsNullOrWhiteSpace($Title)) { $Title = Get-UiText 'Common.Confirm' }
    if ($null -eq $script:Window) {
        $answer = [System.Windows.MessageBox]::Show($Text, $Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    } else {
        $answer = [System.Windows.MessageBox]::Show($script:Window, $Text, $Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    }
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Invoke-UiAction {
    param([scriptblock]$Action)
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { [void](& $Action) } catch { Show-Message $_.Exception.Message (Get-UiText 'Common.Error') 'Error' }
    finally { $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow }
}

function Get-FirstResult {
    foreach ($entry in @($script:LastResults)) {
        if ($null -eq $entry) { continue }
        if ($null -ne $entry.PSObject.Properties['Success']) { return $entry }
    }
    return $null
}

function Set-UiBusy {
    param([bool]$Busy, [string]$Label = '')
    $script:Busy = $Busy
    if (-not [string]::IsNullOrWhiteSpace($Label)) { $script:StatusLabel.Text = $Label }
    $script:StatusProgress.Visibility = if ($Busy) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $script:CancelButton.Visibility = if ($Busy) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    foreach ($button in $script:ActionButtons) {
        if ($null -ne $button) { $button.IsEnabled = -not $Busy }
    }
    Update-SoftwareActions
}

function Show-Page {
    param([string]$Name)
    $pages = @{
        Software = $script:PageSoftware
        Printers = $script:PagePrinters
        Users    = $script:PageUsers
        Account  = $script:PageAccount
        Log      = $script:PageLog
    }
    foreach ($key in $pages.Keys) {
        $pages[$key].Visibility = if ($key -eq $Name) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
    switch ($Name) {
        'Printers' { Refresh-Printers }
        'Users' { Refresh-Users }
        'Account' { Refresh-Account }
    }
}

# --------------------------------------------------------------------------
# Background task runner
# --------------------------------------------------------------------------

function Start-SetupTask {
    param(
        [string]$Label,
        [string]$Command,
        [hashtable]$Parameters = @{},
        [object]$OnComplete = ''
    )

    if ($script:Busy) {
        Add-LogLine -Level Warning -Message 'A task is already running. Wait for it to finish.'
        return
    }

    $script:Cancelled = $false
    $script:TaskFinalized = $false
    $script:TaskOnComplete = $OnComplete
    $script:LastResults = @()
    Set-UiBusy -Busy $true -Label $Label
    Add-LogLine -Level Detail -Message ('[task] ' + $Label)

    # The background runspace must never touch WPF. Progress goes into a
    # thread-safe queue drained by a UI-thread timer, and results go into a bag
    # read once the pipeline reports completion. Calling Dispatcher.Invoke from
    # the background thread deadlocks instead: the dispatcher then needs the
    # script runspace, which is blocked inside ShowDialog.
    $script:LogQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $script:CurrentResultBag = [System.Collections.ArrayList]::new()

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($modulePath, $commandName, $commandParameters, $logQueue, $resultBag)
        Import-Module $modulePath -Force
        Set-SetupLogSink {
            param($level, $message)
            [void]$logQueue.Enqueue([pscustomobject]@{ Level = $level; Message = $message })
        }
        $output = & $commandName @commandParameters
        if ($null -ne $output) { [void]$resultBag.Add($output) }
    }).AddArgument($script:ModulePath).AddArgument($Command).AddArgument($Parameters).AddArgument($script:LogQueue).AddArgument($script:CurrentResultBag)

    $script:CurrentPS = $ps
    [void]$ps.BeginInvoke()
}

function Read-PendingLogQueue {
    if ($null -eq $script:LogQueue) { return }
    $item = $null
    while ($script:LogQueue.TryDequeue([ref]$item)) {
        if ($null -ne $item) {
            Add-LogLine -Level ([string]$item.Level) -Message ([string]$item.Message)
        }
        $item = $null
    }
}

function Update-TaskState {
    <#
    .SYNOPSIS
        Streams pending progress and finishes the running task.
    .DESCRIPTION
        Called by the dispatcher timer on the UI thread, so it is safe to touch
        controls here.
    #>
    Read-PendingLogQueue

    $ps = $script:CurrentPS
    if ($null -eq $ps -or $script:TaskFinalized) { return }

    $state = $ps.InvocationStateInfo.State
    if ($state -ne 'Completed' -and $state -ne 'Failed' -and $state -ne 'Stopped') { return }

    $script:TaskFinalized = $true
    Read-PendingLogQueue

    $errorText = ''
    if ($null -ne $ps.InvocationStateInfo.Reason) { $errorText = $ps.InvocationStateInfo.Reason.Message }

    $collected = @()
    if ($null -ne $script:CurrentResultBag) {
        foreach ($entry in @($script:CurrentResultBag)) { $collected += $entry }
    }

    $script:LastResults = $collected
    $script:CurrentPS = $null
    $script:CurrentResultBag = $null
    $script:LogQueue = $null
    $script:TaskFinalized = $false
    try { $ps.Dispose() } catch { }

    if (-not [string]::IsNullOrWhiteSpace($errorText)) {
        Add-LogLine -Level Error -Message $errorText
    }
    if ($state -eq 'Stopped') {
        Add-LogLine -Level Warning -Message 'Task cancelled.'
    } elseif ($state -eq 'Failed' -and [string]::IsNullOrWhiteSpace($errorText)) {
        Add-LogLine -Level Error -Message (Get-UiText 'Common.TaskFailed')
    }

    Set-UiBusy -Busy $false -Label (Get-UiText 'Common.StatusReady')
    if (-not [string]::IsNullOrWhiteSpace($script:TaskOnComplete)) {
        $callback = $script:TaskOnComplete
        $script:TaskOnComplete = ''
        & $callback
    }
    if ($script:CloseWhenIdle -and -not $script:Busy) {
        $script:CloseWhenIdle = $false
        $script:Window.Close()
    }
}

# --------------------------------------------------------------------------
# Software tab
# --------------------------------------------------------------------------

function Set-SoftwareState {
    param($Row, [string]$Text, [string]$Tone = 'Muted')
    $map = @{
        Muted  = '#5F6B76'
        Accent = '#0F6CBD'
        Good   = '#107C10'
        Bad    = '#C42B1C'
        Warn   = '#9A6100'
    }
    if (-not $map.ContainsKey($Tone)) { $Tone = 'Muted' }
    $Row.Status.Text = $Text
    $Row.Status.Foreground = Get-Brush $map[$Tone]
}

function New-SoftwareRow {
    param($Item, [string]$StatusText, [string]$StatusTone)

    $container = [System.Windows.Controls.Border]::new()
    $container.Background = Get-Brush '#FFFFFF'
    $container.BorderBrush = Get-Brush '#EFF1F4'
    $container.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $container.Padding = [System.Windows.Thickness]::new(12, 9, 12, 9)

    $grid = New-UiGrid -Columns @('32', '*', '80', '120')

    $checkBox = [System.Windows.Controls.CheckBox]::new()
    $checkBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $checkBox.IsChecked = $false
    [System.Windows.Controls.Grid]::SetColumn($checkBox, 0)
    [void]$grid.Children.Add($checkBox)

    $textStack = [System.Windows.Controls.StackPanel]::new()
    $name = New-UiText -Text $Item.Name -Weight SemiBold
    $name.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $detail = New-UiText -Text $Item.Detail -Size 11.5 -Color '#5F6B76'
    $detail.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    [void]$textStack.Children.Add($name)
    [void]$textStack.Children.Add($detail)
    [System.Windows.Controls.Grid]::SetColumn($textStack, 1)
    [void]$grid.Children.Add($textStack)

    $badge = [System.Windows.Controls.Border]::new()
    $badge.CornerRadius = [System.Windows.CornerRadius]::new(9)
    $badge.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
    $badge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $badge.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    if ($Item.Kind -eq 'winget') {
        $badge.Background = Get-Brush '#E8F1FA'
        $badgeText = New-UiText -Text 'WINGET' -Size 10 -Weight SemiBold -Color '#0B4F82'
    } else {
        $badge.Background = Get-Brush '#F0EDF9'
        $badgeText = New-UiText -Text 'LOCAL' -Size 10 -Weight SemiBold -Color '#4B3A82'
    }
    $badge.Child = $badgeText
    [System.Windows.Controls.Grid]::SetColumn($badge, 2)
    [void]$grid.Children.Add($badge)

    $status = New-UiText -Text $StatusText -Size 11.5 -Color '#5F6B76'
    $status.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $status.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($status, 3)
    [void]$grid.Children.Add($status)

    $container.Child = $grid
    $container.Add_MouseEnter({ param($sender, $e) $sender.Background = Get-Brush '#F8FAFC' })
    $container.Add_MouseLeave({ param($sender, $e) $sender.Background = Get-Brush '#FFFFFF' })
    $checkBox.Add_Checked({ Update-SoftwareActions })
    $checkBox.Add_Unchecked({ Update-SoftwareActions })

    return [pscustomobject]@{
        Kind      = $Item.Kind
        Name      = $Item.Name
        Detail    = $Item.Detail
        Item      = $Item
        Container = $container
        CheckBox  = $checkBox
        Status    = $status
    }
}

function Refresh-SoftwareList {
    $script:SoftwareList.Children.Clear()
    $script:SoftwareRows = @()

    $catalog = @()
    try { $catalog = @(Get-SoftwareCatalog -Config $script:Config) }
    catch { Add-LogLine -Level Error -Message $_.Exception.Message }

    foreach ($item in $catalog) {
        if ($item.Kind -eq 'local' -and (-not $item.Exists) -and (-not $item.WillDownload)) {
            $initialText = Get-UiText 'Status.Missing'
            $tone = 'Bad'
        } elseif ($item.Kind -eq 'local' -and $item.WillDownload) {
            $initialText = Get-UiText 'Status.Download'
            $tone = 'Warn'
        } else {
            $initialText = Get-UiText 'Status.Ready'
            $tone = 'Muted'
        }
        $row = New-SoftwareRow -Item $item -StatusText $initialText -StatusTone $tone
        Set-SoftwareState -Row $row -Text $initialText -Tone $tone
        $script:SoftwareRows += $row
        [void]$script:SoftwareList.Children.Add($row.Container)
    }

    Apply-SoftwareFilter
    Update-SoftwareActions
}

function Apply-SoftwareFilter {
    $query = ([string]$script:SoftwareFilter.Text).Trim()
    foreach ($row in $script:SoftwareRows) {
        $visible = $true
        if (-not [string]::IsNullOrWhiteSpace($query)) {
            $visible = ($row.Name -like "*$query*") -or ($row.Detail -like "*$query*")
        }
        $row.Container.Visibility = if ($visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
}

function Update-SoftwareActions {
    $selected = @($script:SoftwareRows | Where-Object { $_.CheckBox.IsChecked -eq $true }).Count
    if ($selected -gt 0) {
        $script:SoftwareInstallButton.Content = ((Get-UiText 'Software.InstallCount') -f $selected)
    } else {
        $script:SoftwareInstallButton.Content = Get-UiText 'Software.Install'
    }
    $script:SoftwareInstallButton.IsEnabled = ($selected -gt 0) -and (-not $script:Busy)
    $script:SoftwareSummary.Text = ((Get-UiText 'Software.Summary') -f $script:SoftwareRows.Count, $selected)
}

function Start-SoftwareInstall {
    if ($script:Busy) { return }
    $selected = @($script:SoftwareRows | Where-Object { $_.CheckBox.IsChecked -eq $true })
    if ($selected.Count -eq 0) {
        Show-Message (Get-UiText 'Install.NothingText') (Get-UiText 'Install.NothingTitle') 'Warning'
        return
    }

    $script:Queue = $selected
    $script:QueueIndex = 0
    $script:QueueTotal = $selected.Count
    $script:QueueResults.Clear()
    foreach ($row in $selected) { Set-SoftwareState -Row $row -Text (Get-UiText 'Status.Queued') -Tone 'Muted' }

    Add-LogLine -Level Task -Message ("Software installation started: {0} item(s)." -f $selected.Count)
    $script:WingetAvailable = ($null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue))

    $wingetCount = @($selected | Where-Object { $_.Kind -eq 'winget' }).Count
    if ($wingetCount -gt 0 -and -not $script:WingetAvailable) {
        Add-LogLine -Level Warning -Message 'winget is not available. Winget apps will be skipped; local installers can still run.'
        Add-LogLine -Level Warning -Message 'Install Microsoft App Installer from https://aka.ms/getwinget and try again.'
        Start-NextSoftware
    } elseif ($wingetCount -gt 0) {
        Start-SetupTask -Label (Get-UiText 'Install.CheckingWinget') -Command 'Repair-SetupWingetSource' -Parameters @{} -OnComplete 'Start-NextSoftware'
    } else {
        Start-NextSoftware
    }
}

function Start-NextSoftware {
    if ($script:Cancelled -or $script:QueueIndex -ge $script:QueueTotal) {
        Complete-SoftwareRun
        return
    }

    $row = $script:Queue[$script:QueueIndex]
    $script:CurrentRow = $row
    $script:QueueIndex++
    Set-SoftwareState -Row $row -Text (Get-UiText 'Status.Installing') -Tone 'Accent'
    Add-LogLine -Level Info -Message ("[{0}/{1}] {2}" -f $script:QueueIndex, $script:QueueTotal, $row.Name)

    $label = ((Get-UiText 'Install.Step') -f $row.Name, $script:QueueIndex, $script:QueueTotal)
    if ($row.Kind -eq 'winget') {
        Start-SetupTask -Label $label -Command 'Install-SetupWingetApp' -Parameters @{ App = $row.Item } -OnComplete 'Complete-SoftwareStep'
    } else {
        Start-SetupTask -Label $label -Command 'Install-SetupLocalPackage' -Parameters @{ Installer = $row.Item } -OnComplete 'Complete-SoftwareStep'
    }
}

function Complete-SoftwareStep {
    $row = $script:CurrentRow
    if ($null -ne $row) {
        # A cancel stops the pipeline, so a missing result here is expected.
        if ($script:Cancelled) {
            [void]$script:QueueResults.Add((New-SetupResult -Name $row.Name -Success $false -Skipped $true -Message (Get-UiText 'Status.Cancelled')))
            Set-SoftwareState -Row $row -Text (Get-UiText 'Status.Cancelled') -Tone 'Warn'
            Start-NextSoftware
            return
        }
        $result = Get-FirstResult
        if ($null -eq $result) {
            $result = New-SetupResult -Name $row.Name -Success $false -Message (Get-UiText 'Common.NoResult')
        }
        [void]$script:QueueResults.Add($result)

        if ($result.Success -and -not $result.Skipped) {
            if ($result.RestartRequired) { Set-SoftwareState -Row $row -Text (Get-UiText 'Status.InstalledRestart') -Tone 'Warn' }
            else { Set-SoftwareState -Row $row -Text (Get-UiText 'Status.Installed') -Tone 'Good' }
        } elseif ($result.Skipped) {
            Set-SoftwareState -Row $row -Text (Get-UiText 'Status.Skipped') -Tone 'Warn'
        } else {
            Set-SoftwareState -Row $row -Text (Get-UiText 'Status.Failed') -Tone 'Bad'
        }
    }
    Start-NextSoftware
}

function Complete-SoftwareRun {
    $failed = @($script:QueueResults | Where-Object { -not $_.Success -and -not $_.Skipped })
    $installed = @($script:QueueResults | Where-Object { $_.Success -and -not $_.Skipped }).Count
    $skipped = @($script:QueueResults | Where-Object { $_.Skipped }).Count

    Add-LogLine -Level Task -Message ("Software installation finished: {0} installed, {1} failed, {2} skipped." -f $installed, $failed.Count, $skipped)
    if ($script:Cancelled) {
        Add-LogLine -Level Warning -Message 'The remaining items were not installed because the task was cancelled.'
    }

    $script:CurrentRow = $null
    $script:Queue = @()
    $script:QueueIndex = 0
    $script:QueueTotal = 0

    if ($failed.Count -gt 0) {
        $lines = ($failed | ForEach-Object { ' - ' + $_.Name }) -join "`r`n"
        Show-Message ((Get-UiText 'Install.FailedSummary') -f $failed.Count, "`r`n", $lines) (Get-UiText 'Install.FinishedTitle') 'Warning'
    } else {
        Show-Message ((Get-UiText 'Install.Summary') -f "`r`n", $installed, $skipped) (Get-UiText 'Install.FinishedTitle') 'Information'
    }
    Update-SoftwareActions
}

# --------------------------------------------------------------------------
# Printer tab
# --------------------------------------------------------------------------

function Refresh-Printers {
    $script:PrinterList.Children.Clear()
    $script:PrinterRows = @()

    $printers = @()
    try { $printers = @(Get-PrinterInventory) }
    catch { Add-LogLine -Level Error -Message $_.Exception.Message }

    if ($printers.Count -eq 0) {
        $empty = New-UiText -Text (Get-UiText 'Printers.Empty') -Size 12.5 -Color '#5F6B76'
        $empty.Margin = [System.Windows.Thickness]::new(16, 16, 16, 16)
        [void]$script:PrinterList.Children.Add($empty)
        return
    }

    foreach ($printer in $printers) {
        $container = [System.Windows.Controls.Border]::new()
        $container.BorderBrush = Get-Brush '#EFF1F4'
        $container.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
        $container.Padding = [System.Windows.Thickness]::new(16, 10, 16, 10)

        $grid = New-UiGrid -Columns @('*', 'Auto')
        $stack = [System.Windows.Controls.StackPanel]::new()

        $nameLine = [System.Windows.Controls.StackPanel]::new()
        $nameLine.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $nameBlock = New-UiText -Text $printer.Name -Weight SemiBold
        [void]$nameLine.Children.Add($nameBlock)
        if ($printer.IsDefault) {
            $defaultBadge = [System.Windows.Controls.Border]::new()
            $defaultBadge.Background = Get-Brush '#E8F1FA'
            $defaultBadge.CornerRadius = [System.Windows.CornerRadius]::new(9)
            $defaultBadge.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
            $defaultBadge.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
            $defaultBadge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $defaultBadge.Child = New-UiText -Text (Get-UiText 'Printers.DefaultBadge') -Size 10 -Weight SemiBold -Color '#0B4F82'
            [void]$nameLine.Children.Add($defaultBadge)
        }
        [void]$stack.Children.Add($nameLine)

        $detail = New-UiText -Text ((Get-UiText 'Printers.Detail') -f $printer.DriverName, $printer.PortName, $printer.Status) -Size 11.5 -Color '#5F6B76'
        $detail.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        [void]$stack.Children.Add($detail)
        [System.Windows.Controls.Grid]::SetColumn($stack, 0)
        [void]$grid.Children.Add($stack)

        $renameButton = [System.Windows.Controls.Button]::new()
        $renameButton.Content = Get-UiText 'Common.RenameButton'
        $renameButton.Style = $script:Window.Resources['SecondaryButton']
        $renameButton.Padding = [System.Windows.Thickness]::new(12, 5, 12, 5)
        $renameButton.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $renameButton.Tag = $printer.Name
        $renameButton.Add_Click({ param($sender, $e) Invoke-RenamePrinterDialog -PrinterName ([string]$sender.Tag) })
        [System.Windows.Controls.Grid]::SetColumn($renameButton, 1)
        [void]$grid.Children.Add($renameButton)

        $container.Child = $grid
        $script:PrinterRows += $container
        [void]$script:PrinterList.Children.Add($container)
    }
}

function Update-PrinterDriverInfo {
    $preset = $script:PrinterMake.SelectedItem
    if ($null -eq $preset) {
        $script:PrinterDriverInfo.Text = ''
        return
    }
    $hint = [string]$preset.DriverHint
    $installed = @()
    if (-not [string]::IsNullOrWhiteSpace($hint)) {
        $installed = @(Get-PrinterDriverNames | Where-Object { "$_" -ieq $hint })
    }
    if (-not [string]::IsNullOrWhiteSpace($hint)) {
        if ($installed.Count -gt 0) {
            $script:PrinterDriverInfo.Text = ((Get-UiText 'Printers.DriverInstalled') -f $installed[0])
        } else {
            $script:PrinterDriverInfo.Text = ((Get-UiText 'Printers.DriverWillImport') -f $hint)
        }
    } else {
        $script:PrinterDriverInfo.Text = Get-UiText 'Printers.DriverDetect'
    }
}

function Invoke-PrinterInstall {
    if ($script:Busy) { return }
    $preset = $script:PrinterMake.SelectedItem
    if ($null -eq $preset) {
        Show-Message (Get-UiText 'Printers.SelectMake') (Get-UiText 'Printers.Title2') 'Warning'
        return
    }
    $address = ([string]$script:PrinterHost.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($address)) {
        Show-Message (Get-UiText 'Printers.EnterAddress') (Get-UiText 'Printers.Title2') 'Warning'
        $script:PrinterHost.Focus() | Out-Null
        return
    }

    $portNumber = 9100
    $portText = ([string]$script:PrinterPort.Text).Trim()
    if (-not [string]::IsNullOrWhiteSpace($portText)) {
        $parsed = 0
        if (-not [int]::TryParse($portText, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) {
            Show-Message (Get-UiText 'Printers.InvalidPort') (Get-UiText 'Printers.Title2') 'Warning'
            return
        }
        $portNumber = $parsed
    }

    $printerName = ([string]$script:PrinterName.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($printerName)) {
        $printerName = ("{0} {1}" -f $preset.Make, $address)
        $script:PrinterName.Text = $printerName
    }

    $overwrite = ($script:PrinterReplace.IsChecked -eq $true)
    $existing = $null
    if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
        $existing = Get-Printer -Name $printerName -ErrorAction SilentlyContinue
    }
    if (($null -ne $existing) -and (-not $overwrite)) {
        if (-not (Show-Confirm ((Get-UiText 'Printers.ExistsText') -f $printerName, "`r`n") (Get-UiText 'Printers.ExistsTitle'))) { return }
        $overwrite = $true
    }

    $parameters = @{
        Config      = $script:Config
        Make        = [string]$preset.Make
        HostAddress = $address
        Port        = $portNumber
        PrinterName = $printerName
    }
    $inf = ([string]$script:PrinterInf.Text).Trim()
    if (-not [string]::IsNullOrWhiteSpace($inf)) { $parameters['PreferredInf'] = $inf }
    if ($overwrite) { $parameters['Overwrite'] = $true }

    Start-SetupTask -Label ((Get-UiText 'Printers.Task') -f $printerName) `
        -Command 'Install-SetupNetworkPrinter' -Parameters $parameters -OnComplete 'Complete-PrinterInstall'
}

function Complete-PrinterInstall {
    $result = Get-FirstResult
    if ($null -eq $result) {
        Show-Message (Get-UiText 'Printers.NoResult') (Get-UiText 'Printers.Title2') 'Warning'
        Refresh-Printers
        return
    }
    if ($result.Success) {
        Show-Message $result.Message (Get-UiText 'Printers.Title2') 'Information'
        Refresh-Printers
    } else {
        Show-Message ($result.Message + "`r`n`r`n" + (Get-UiText 'Common.SeeLog')) (Get-UiText 'Printers.FailedTitle') 'Error'
    }
}

function Invoke-RenamePrinterDialog {
    param([string]$PrinterName)
    if ($script:Busy) { return }
    $newName = Show-InputBox -Title (Get-UiText 'Printers.RenameTitle') -Label ((Get-UiText 'Printers.RenameLabel') -f $PrinterName)
    if ($null -eq $newName) { return }
    Invoke-UiAction {
        $result = Rename-SetupPrinter -Name $PrinterName -NewName $newName
        Show-Message $result.Message (Get-UiText 'Printers.RenameTitle') $(if ($result.Success) { 'Information' } else { 'Error' })
        Refresh-Printers
    }
}

# --------------------------------------------------------------------------
# Users tab
# --------------------------------------------------------------------------

function Refresh-Users {
    $script:UserList.Children.Clear()
    $script:UserRows = @()

    $users = @()
    try { $users = @(Get-LocalUserInventory) }
    catch { Add-LogLine -Level Error -Message $_.Exception.Message }

    if ($users.Count -eq 0) {
        $empty = New-UiText -Text (Get-UiText 'Users.Empty') -Size 12.5 -Color '#5F6B76'
        $empty.Margin = [System.Windows.Thickness]::new(16)
        [void]$script:UserList.Children.Add($empty)
        return
    }

    foreach ($user in $users) {
        $container = [System.Windows.Controls.Border]::new()
        $container.BorderBrush = Get-Brush '#EFF1F4'
        $container.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
        $container.Padding = [System.Windows.Thickness]::new(16, 10, 16, 10)

        $grid = New-UiGrid -Columns @('*', 'Auto')
        $stack = [System.Windows.Controls.StackPanel]::new()

        $nameLine = [System.Windows.Controls.StackPanel]::new()
        $nameLine.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        [void]$nameLine.Children.Add((New-UiText -Text $user.Name -Weight SemiBold))
        $stateBadge = [System.Windows.Controls.Border]::new()
        $stateBadge.CornerRadius = [System.Windows.CornerRadius]::new(9)
        $stateBadge.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
        $stateBadge.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        $stateBadge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        if ($user.Enabled) {
            $stateBadge.Background = Get-Brush '#E7F4E7'
            $stateBadge.Child = New-UiText -Text (Get-UiText 'Users.Enabled') -Size 10 -Weight SemiBold -Color '#107C10'
        } else {
            $stateBadge.Background = Get-Brush '#F3F4F6'
            $stateBadge.Child = New-UiText -Text (Get-UiText 'Users.Disabled') -Size 10 -Weight SemiBold -Color '#5F6B76'
        }
        [void]$nameLine.Children.Add($stateBadge)

        if ($user.IsSoleAdmin) {
            $lockBadge = [System.Windows.Controls.Border]::new()
            $lockBadge.Background = Get-Brush '#FCE8E6'
            $lockBadge.CornerRadius = [System.Windows.CornerRadius]::new(9)
            $lockBadge.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
            $lockBadge.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
            $lockBadge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $lockBadge.Child = New-UiText -Text (Get-UiText 'Users.LastAdmin') -Size 10 -Weight SemiBold -Color '#C42B1C'
            [void]$nameLine.Children.Add($lockBadge)
        }
        [void]$stack.Children.Add($nameLine)

        $memberOf = if ($user.Groups.Count -gt 0) { $user.Groups -join ', ' } else { (Get-UiText 'Users.NoGroups') }
        $detail = New-UiText -Text ((Get-UiText 'Users.MemberOf') -f $memberOf) -Size 11.5 -Color '#5F6B76'
        $detail.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        [void]$stack.Children.Add($detail)
        [System.Windows.Controls.Grid]::SetColumn($stack, 0)
        [void]$grid.Children.Add($stack)

        $buttons = [System.Windows.Controls.StackPanel]::new()
        $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $buttons.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        $renameButton = [System.Windows.Controls.Button]::new()
        $renameButton.Content = Get-UiText 'Users.Rename'
        $renameButton.Style = $script:Window.Resources['SecondaryButton']
        $renameButton.Padding = [System.Windows.Thickness]::new(11, 5, 11, 5)
        $renameButton.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $renameButton.Tag = $user.Name
        $renameButton.Add_Click({ param($sender, $e) Invoke-RenameUserDialog -UserName ([string]$sender.Tag) })
        [void]$buttons.Children.Add($renameButton)

        $passwordButton = [System.Windows.Controls.Button]::new()
        $passwordButton.Content = Get-UiText 'Users.Password'
        $passwordButton.Style = $script:Window.Resources['SecondaryButton']
        $passwordButton.Padding = [System.Windows.Thickness]::new(11, 5, 11, 5)
        $passwordButton.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $passwordButton.Tag = $user.Name
        $passwordButton.Add_Click({ param($sender, $e) Invoke-UserPasswordDialog -UserName ([string]$sender.Tag) })
        [void]$buttons.Children.Add($passwordButton)

        $groupsButton = [System.Windows.Controls.Button]::new()
        $groupsButton.Content = Get-UiText 'Users.Groups'
        $groupsButton.Style = $script:Window.Resources['SecondaryButton']
        $groupsButton.Padding = [System.Windows.Thickness]::new(11, 5, 11, 5)
        $groupsButton.Tag = $user.Name
        $groupsButton.Add_Click({ param($sender, $e) Show-GroupDialog -UserName ([string]$sender.Tag) })
        [void]$buttons.Children.Add($groupsButton)

        [System.Windows.Controls.Grid]::SetColumn($buttons, 1)
        [void]$grid.Children.Add($buttons)

        $container.Child = $grid
        $script:UserRows += $container
        [void]$script:UserList.Children.Add($container)
    }
}

function Invoke-RenameUserDialog {
    param([string]$UserName)
    if ($script:Busy) { return }
    $newName = Show-InputBox -Title (Get-UiText 'Users.RenameTitle') -Label ((Get-UiText 'Users.RenameLabel') -f $UserName)
    if ($null -eq $newName) { return }
    $validation = Test-LocalAccountName -Name $newName
    if ($null -ne $validation) {
        Show-Message $validation (Get-UiText 'Users.InvalidName') 'Warning'
        return
    }
    Start-SetupTask -Label ((Get-UiText 'Users.RenameTask') -f $UserName, $newName) `
        -Command 'Rename-SetupLocalAccount' -Parameters @{ Name = $UserName; NewName = $newName } -OnComplete 'Complete-UserAction'
}

function Invoke-UserPasswordDialog {
    param([string]$UserName)
    if ($script:Busy) { return }
    $secure = Show-PasswordDialog -Title (Get-UiText 'Users.PasswordTitle') -Label ((Get-UiText 'Users.PasswordLabel') -f $UserName)
    if ($null -eq $secure) { return }
    Start-SetupTask -Label ((Get-UiText 'Users.PasswordTask') -f $UserName) `
        -Command 'Set-SetupLocalAccountPassword' -Parameters @{ UserName = $UserName; Password = $secure } -OnComplete 'Complete-UserAction'
}

function Complete-UserAction {
    $result = Get-FirstResult
    if ($null -eq $result) {
        Show-Message (Get-UiText 'Common.NoResult') (Get-UiText 'Users.AccountTitle') 'Warning'
        Refresh-Users
        return
    }
    $icon = if ($result.Success) { 'Information' } else { 'Warning' }
    Show-Message $result.Message (Get-UiText 'Users.AccountTitle') $icon
    Refresh-Users
}

# --------------------------------------------------------------------------
# Group dialog
# --------------------------------------------------------------------------

function Update-GroupDialog {
    $script:DlgGroupList.Items.Clear()
    $allGroups = @(Get-LocalGroupNames)
    $inventory = @()
    try { $inventory = @(Get-LocalUserInventory) } catch { }
    $currentUser = $inventory | Where-Object { $_.Name -eq $script:DlgUserName } | Select-Object -First 1
    $script:DlgUserGroups = @()
    if ($null -ne $currentUser) { $script:DlgUserGroups = @($currentUser.Groups) }

    foreach ($group in $allGroups) {
        $label = [string]$group
        if ($script:DlgUserGroups -icontains $group) { $label = ("{0}  {1}" -f $group, (Get-UiText 'Users.Member')) }
        [void]$script:DlgGroupList.Items.Add($label)
    }

    $lock = Get-SoleAdminLock -UserName $script:DlgUserName
    $script:DlgLocked = $lock.Locked
    if ($lock.Locked) {
        $script:DlgGroupStatus.Text = Get-UiText 'Users.Locked'
        $script:DlgGroupStatus.Foreground = Get-Brush '#C42B1C'
        $script:DlgAddButton.IsEnabled = $false
        $script:DlgRemoveButton.IsEnabled = $false
    } else {
        $memberOf = if ($script:DlgUserGroups.Count -gt 0) { $script:DlgUserGroups -join ', ' } else { (Get-UiText 'Users.NoGroups') }
        $script:DlgGroupStatus.Text = ((Get-UiText 'Users.MemberOf') -f $memberOf)
        $script:DlgGroupStatus.Foreground = Get-Brush '#5F6B76'
        $script:DlgAddButton.IsEnabled = $true
        $script:DlgRemoveButton.IsEnabled = $true
    }
}

function Show-GroupDialog {
    param([string]$UserName)
    if ($script:Busy) { return }

    $script:DlgUserName = $UserName
    $script:DlgLocked = $false
    $script:DlgUserGroups = @()

    $dialog = [System.Windows.Window]::new()
    $dialog.Title = ((Get-UiText 'Users.GroupsTitle') -f $UserName)
    $dialog.Width = 540
    $dialog.Height = 560
    $dialog.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dialog.ResizeMode = [System.Windows.ResizeMode]::CanResize
    $dialog.Background = Get-Brush '#F4F6F8'
    $dialog.Owner = $script:Window
    $dialog.FontFamily = $script:Window.FontFamily
    $dialog.FontSize = 13

    $root = [System.Windows.Controls.Grid]::new()
    $root.Margin = [System.Windows.Thickness]::new(18)
    foreach ($height in @('Auto', 'Auto', '*', 'Auto')) {
        $rowDefinition = [System.Windows.Controls.RowDefinition]::new()
        if ($height -eq '*') { $rowDefinition.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }
        else { $rowDefinition.Height = [System.Windows.GridLength]::Auto }
        [void]$root.RowDefinitions.Add($rowDefinition)
    }

    $title = New-UiText -Text ((Get-UiText 'Users.GroupsHeader') -f $UserName) -Size 16 -Weight SemiBold
    [System.Windows.Controls.Grid]::SetRow($title, 0)
    [void]$root.Children.Add($title)

    $script:DlgGroupStatus = New-UiText -Text '' -Size 12 -Color '#5F6B76' -Wrap $true
    $script:DlgGroupStatus.Margin = [System.Windows.Thickness]::new(0, 6, 0, 12)
    [System.Windows.Controls.Grid]::SetRow($script:DlgGroupStatus, 1)
    [void]$root.Children.Add($script:DlgGroupStatus)

    $listBorder = [System.Windows.Controls.Border]::new()
    $listBorder.Background = Get-Brush '#FFFFFF'
    $listBorder.BorderBrush = Get-Brush '#E1E5EA'
    $listBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $listBorder.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $listBorder.Padding = [System.Windows.Thickness]::new(4)
    $script:DlgGroupList = [System.Windows.Controls.ListBox]::new()
    $script:DlgGroupList.BorderThickness = [System.Windows.Thickness]::new(0)
    $script:DlgGroupList.FontSize = 13
    $listBorder.Child = $script:DlgGroupList
    [System.Windows.Controls.Grid]::SetRow($listBorder, 2)
    [void]$root.Children.Add($listBorder)

    $buttons = [System.Windows.Controls.StackPanel]::new()
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $buttons.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)

    $script:DlgAddButton = [System.Windows.Controls.Button]::new()
    $script:DlgAddButton.Content = Get-UiText 'Users.AddToGroup'
    $script:DlgAddButton.Style = $script:Window.Resources['PrimaryButton']
    $script:DlgAddButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [void]$buttons.Children.Add($script:DlgAddButton)

    $script:DlgRemoveButton = [System.Windows.Controls.Button]::new()
    $script:DlgRemoveButton.Content = Get-UiText 'Users.RemoveFromGroup'
    $script:DlgRemoveButton.Style = $script:Window.Resources['SecondaryButton']
    $script:DlgRemoveButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [void]$buttons.Children.Add($script:DlgRemoveButton)

    $closeButton = [System.Windows.Controls.Button]::new()
    $closeButton.Content = Get-UiText 'Common.Close'
    $closeButton.Style = $script:Window.Resources['SecondaryButton']
    [void]$buttons.Children.Add($closeButton)

    [System.Windows.Controls.Grid]::SetRow($buttons, 3)
    [void]$root.Children.Add($buttons)
    $dialog.Content = $root

    $script:DlgAddButton.Add_Click({
        if ($script:DlgLocked) { return }
        $selected = [string]$script:DlgGroupList.SelectedItem
        if ([string]::IsNullOrWhiteSpace($selected)) { return }
        $groupName = $selected -replace '\s+\([^)]*\)\s*$', ''
        Invoke-UiAction {
            $result = Add-SetupLocalGroupMember -UserName $script:DlgUserName -GroupName $groupName
            if (-not $result.Success) { Show-Message $result.Message (Get-UiText 'Users.GroupChangeTitle') 'Warning' }
            Update-GroupDialog
        }
    })

    $script:DlgRemoveButton.Add_Click({
        if ($script:DlgLocked) { return }
        $selected = [string]$script:DlgGroupList.SelectedItem
        if ([string]::IsNullOrWhiteSpace($selected)) { return }
        $groupName = $selected -replace '\s+\([^)]*\)\s*$', ''
        if ($script:DlgUserGroups -inotcontains $groupName) {
            Show-Message ((Get-UiText 'Users.NotMember') -f $script:DlgUserName, $groupName) (Get-UiText 'Users.GroupChangeTitle') 'Information'
            return
        }
        Invoke-UiAction {
            $result = Remove-SetupLocalGroupMember -UserName $script:DlgUserName -GroupName $groupName
            if (-not $result.Success) { Show-Message $result.Message (Get-UiText 'Users.GroupChangeTitle') 'Warning' }
            Update-GroupDialog
        }
    })

    $closeButton.Add_Click({ $dialog.Close() })

    Update-GroupDialog
    [void]$dialog.ShowDialog()
    Refresh-Users
}

# --------------------------------------------------------------------------
# Account tab
# --------------------------------------------------------------------------

function Refresh-Account {
    $admin = Get-BuiltInAdminAccount
    if ($null -eq $admin) {
        $script:BuiltInAdminLabel.Text = Get-UiText 'Account.AdminNotFound'
        $script:AdminEnableButton.IsEnabled = $false
    } else {
        $state = Get-UiText 'Account.AdminDisabled'
        if ($null -ne $admin.Enabled) {
            if ($admin.Enabled) { $state = Get-UiText 'Account.AdminEnabled' } else { $state = Get-UiText 'Account.AdminDisabled' }
        }
        $script:BuiltInAdminLabel.Text = ((Get-UiText 'Account.AdminState') -f $admin.Name, $state)
        $script:AdminEnableButton.IsEnabled = -not $script:Busy
    }

    $current = Get-CurrentLocalAccount -Sid $OriginalUserSid
    if ($null -eq $current) {
        $script:CurrentUserLabel.Text = Get-UiText 'Account.NotLocal'
        $script:RenameApplyButton.IsEnabled = $false
    } else {
        $script:CurrentUserLabel.Text = ((Get-UiText 'Account.SignedIn') -f $current.Name)
        $script:RenameApplyButton.IsEnabled = -not $script:Busy
    }
}

function Invoke-AdminEnable {
    if ($script:Busy) { return }
    $first = $script:AdminPassword.SecurePassword
    $second = $script:AdminPasswordConfirm.SecurePassword
    if ($first.Length -eq 0) {
        Show-Message (Get-UiText 'Account.EnterPassword') (Get-UiText 'Account.PasswordTitle') 'Warning'
        return
    }
    if ($first.Length -lt 8) {
        Show-Message (Get-UiText 'Account.PasswordShort') (Get-UiText 'Account.PasswordTitle') 'Warning'
        return
    }
    $plainFirst = [System.Net.NetworkCredential]::new('', $first).Password
    $plainSecond = [System.Net.NetworkCredential]::new('', $second).Password
    $same = ($plainFirst -ceq $plainSecond)
    $plainFirst = $null
    $plainSecond = $null
    if (-not $same) {
        Show-Message (Get-UiText 'Account.PasswordMismatch') (Get-UiText 'Account.PasswordTitle') 'Warning'
        return
    }
    if (-not (Show-Confirm ((Get-UiText 'Account.ConfirmEnable') -f "`r`n") (Get-UiText 'Common.Confirm'))) {
        return
    }
    Start-SetupTask -Label (Get-UiText 'Account.Task') -Command 'Enable-BuiltInAdministrator' `
        -Parameters @{ Password = $first } -OnComplete 'Complete-AdminEnable'
}

function Complete-AdminEnable {
    $script:AdminPassword.Clear()
    $script:AdminPasswordConfirm.Clear()
    $result = Get-FirstResult
    if ($null -eq $result) {
        Show-Message (Get-UiText 'Common.NoResult') (Get-UiText 'Account.AdminTitle') 'Warning'
    } else {
        $icon = if ($result.Success) { 'Information' } else { 'Error' }
        Show-Message $result.Message (Get-UiText 'Account.AdminTitle') $icon
    }
    Refresh-Account
}

function Invoke-RenameCurrentUser {
    if ($script:Busy) { return }
    $newName = ([string]$script:RenameNewName.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Show-Message (Get-UiText 'Account.EnterName') (Get-UiText 'Account.RenameButton') 'Warning'
        return
    }
    $validation = Test-LocalAccountName -Name $newName
    if ($null -ne $validation) {
        Show-Message $validation (Get-UiText 'Users.InvalidName') 'Warning'
        return
    }
    $account = Get-CurrentLocalAccount -Sid $OriginalUserSid
    if ($null -eq $account) {
        Show-Message (Get-UiText 'Account.NotLocalError') (Get-UiText 'Account.RenameButton') 'Warning'
        return
    }
    if (-not (Show-Confirm ((Get-UiText 'Account.RenameConfirm') -f $account.Name, $newName, "`r`n") (Get-UiText 'Account.ConfirmTitle'))) {
        return
    }
    Start-SetupTask -Label ((Get-UiText 'Users.RenameTask') -f $account.Name, $newName) `
        -Command 'Rename-SetupLocalAccount' -Parameters @{ Name = $account.Name; NewName = $newName } -OnComplete 'Complete-RenameCurrent'
}

function Complete-RenameCurrent {
    $result = Get-FirstResult
    if ($null -ne $result) {
        $icon = if ($result.Success) { 'Information' } else { 'Error' }
        Show-Message $result.Message (Get-UiText 'Account.RenameButton') $icon
    }
    $script:RenameNewName.Text = ''
    Refresh-Account
}

# --------------------------------------------------------------------------
# Input dialogs
# --------------------------------------------------------------------------

function Show-InputBox {
    param([string]$Title, [string]$Label)
    $dialog = [System.Windows.Window]::new()
    $dialog.Title = $Title
    $dialog.Width = 470
    $dialog.SizeToContent = [System.Windows.SizeToContent]::Height
    $dialog.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dialog.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dialog.Background = Get-Brush '#F4F6F8'
    $dialog.Owner = $script:Window
    $dialog.FontFamily = $script:Window.FontFamily
    $dialog.FontSize = 13

    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Margin = [System.Windows.Thickness]::new(20)

    $labelBlock = New-UiText -Text $Label -Size 12.5 -Color '#3A4650' -Wrap $true
    $labelBlock.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [void]$panel.Children.Add($labelBlock)

    $box = [System.Windows.Controls.TextBox]::new()
    $box.Style = $script:Window.Resources['FieldBox']
    $box.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    [void]$panel.Children.Add($box)

    $buttons = [System.Windows.Controls.StackPanel]::new()
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

    $okButton = [System.Windows.Controls.Button]::new()
    $okButton.Content = Get-UiText 'Common.OK'
    $okButton.Style = $script:Window.Resources['PrimaryButton']
    $okButton.MinWidth = 92
    $okButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $okButton.IsDefault = $true
    [void]$buttons.Children.Add($okButton)

    $cancelButton = [System.Windows.Controls.Button]::new()
    $cancelButton.Content = Get-UiText 'Common.Cancel'
    $cancelButton.Style = $script:Window.Resources['SecondaryButton']
    $cancelButton.MinWidth = 92
    $cancelButton.IsCancel = $true
    [void]$buttons.Children.Add($cancelButton)

    [void]$panel.Children.Add($buttons)
    $dialog.Content = $panel

    $script:InputDialog = $dialog
    $script:InputDialogBox = $box
    $script:InputDialogResult = $null

    $okButton.Add_Click({
        $script:InputDialogResult = ([string]$script:InputDialogBox.Text).Trim()
        $script:InputDialog.Close()
    })
    $cancelButton.Add_Click({
        $script:InputDialogResult = $null
        $script:InputDialog.Close()
    })
    $dialog.Add_ContentRendered({
        $script:InputDialogBox.Focus() | Out-Null
        $script:InputDialogBox.SelectAll()
    })

    [void]$dialog.ShowDialog()
    $script:InputDialog = $null
    $script:InputDialogBox = $null

    $result = $script:InputDialogResult
    $script:InputDialogResult = $null
    if ([string]::IsNullOrWhiteSpace($result)) { return $null }
    return $result
}

function Show-PasswordDialog {
    param([string]$Title, [string]$Label)

    $dialog = [System.Windows.Window]::new()
    $dialog.Title = $Title
    $dialog.Width = 470
    $dialog.SizeToContent = [System.Windows.SizeToContent]::Height
    $dialog.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dialog.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dialog.Background = Get-Brush '#F4F6F8'
    $dialog.Owner = $script:Window
    $dialog.FontFamily = $script:Window.FontFamily
    $dialog.FontSize = 13

    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Margin = [System.Windows.Thickness]::new(20)

    $labelBlock = New-UiText -Text $Label -Size 12.5 -Color '#3A4650' -Wrap $true
    $labelBlock.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [void]$panel.Children.Add($labelBlock)

    $first = [System.Windows.Controls.PasswordBox]::new()
    $first.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $first.BorderBrush = Get-Brush '#D7DCE2'
    $first.BorderThickness = [System.Windows.Thickness]::new(1)
    [void]$panel.Children.Add($first)

    $confirmLabel = New-UiText -Text (Get-UiText 'Account.ConfirmPassword') -Size 12 -Color '#5F6B76'
    $confirmLabel.Margin = [System.Windows.Thickness]::new(0, 12, 0, 4)
    [void]$panel.Children.Add($confirmLabel)

    $second = [System.Windows.Controls.PasswordBox]::new()
    $second.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $second.BorderBrush = Get-Brush '#D7DCE2'
    $second.BorderThickness = [System.Windows.Thickness]::new(1)
    [void]$panel.Children.Add($second)

    $script:DlgPasswordError = New-UiText -Text '' -Size 11.5 -Color '#C42B1C' -Wrap $true
    $script:DlgPasswordError.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [void]$panel.Children.Add($script:DlgPasswordError)

    $buttons = [System.Windows.Controls.StackPanel]::new()
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $buttons.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)

    $okButton = [System.Windows.Controls.Button]::new()
    $okButton.Content = Get-UiText 'Common.OK'
    $okButton.Style = $script:Window.Resources['PrimaryButton']
    $okButton.MinWidth = 92
    $okButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $okButton.IsDefault = $true
    [void]$buttons.Children.Add($okButton)

    $cancelButton = [System.Windows.Controls.Button]::new()
    $cancelButton.Content = Get-UiText 'Common.Cancel'
    $cancelButton.Style = $script:Window.Resources['SecondaryButton']
    $cancelButton.MinWidth = 92
    $cancelButton.IsCancel = $true
    [void]$buttons.Children.Add($cancelButton)

    [void]$panel.Children.Add($buttons)
    $dialog.Content = $panel

    $script:DlgPassword1 = $first
    $script:DlgPassword2 = $second
    $script:DlgPasswordDialog = $dialog
    $script:PasswordDialogResult = $null

    $okButton.Add_Click({
        $one = $script:DlgPassword1.SecurePassword
        $two = $script:DlgPassword2.SecurePassword
        if ($one.Length -lt 8) {
            $script:DlgPasswordError.Text = Get-UiText 'Account.PasswordShort'
            return
        }
        $plainOne = [System.Net.NetworkCredential]::new('', $one).Password
        $plainTwo = [System.Net.NetworkCredential]::new('', $two).Password
        $same = ($plainOne -ceq $plainTwo)
        $plainOne = $null
        $plainTwo = $null
        if (-not $same) {
            $script:DlgPasswordError.Text = Get-UiText 'Users.PasswordMismatch'
            return
        }
        $script:PasswordDialogResult = $one
        $script:DlgPasswordDialog.Close()
    })
    $cancelButton.Add_Click({
        $script:PasswordDialogResult = $null
        $script:DlgPasswordDialog.Close()
    })
    $dialog.Add_ContentRendered({ $script:DlgPassword1.Focus() | Out-Null })

    [void]$dialog.ShowDialog()
    $script:DlgPasswordDialog = $null
    $script:DlgPassword1 = $null
    $script:DlgPassword2 = $null

    $result = $script:PasswordDialogResult
    $script:PasswordDialogResult = $null
    return $result
}

# --------------------------------------------------------------------------
# Wiring
# --------------------------------------------------------------------------

$script:ActionButtons = @(
    $script:SoftwareInstallButton,
    $script:PrinterInstallButton,
    $script:PrinterRefreshButton,
    $script:UserRefreshButton,
    $script:AdminEnableButton,
    $script:RenameApplyButton
)

$script:NavSoftware.Add_Checked({ Show-Page 'Software' })
$script:NavPrinters.Add_Checked({ Show-Page 'Printers' })
$script:NavUsers.Add_Checked({ Show-Page 'Users' })
$script:NavAccount.Add_Checked({ Show-Page 'Account' })
$script:NavLog.Add_Checked({ Show-Page 'Log' })

$script:SoftwareFilter.Add_TextChanged({ Apply-SoftwareFilter; Update-SoftwareActions })
$script:SoftwareSelectAll.Add_Click({
    foreach ($row in $script:SoftwareRows) {
        if ($row.Container.Visibility -eq [System.Windows.Visibility]::Visible) { $row.CheckBox.IsChecked = $true }
    }
})
$script:SoftwareSelectNone.Add_Click({
    foreach ($row in $script:SoftwareRows) { $row.CheckBox.IsChecked = $false }
})
$script:SoftwareInstallButton.Add_Click({ Start-SoftwareInstall })

$script:PrinterMake.Add_SelectionChanged({ Update-PrinterDriverInfo })
$script:PrinterInstallButton.Add_Click({ Invoke-PrinterInstall })
$script:PrinterRefreshButton.Add_Click({ Refresh-Printers })
$script:UserRefreshButton.Add_Click({ Refresh-Users })
$script:AdminEnableButton.Add_Click({ Invoke-AdminEnable })
$script:RenameApplyButton.Add_Click({ Invoke-RenameCurrentUser })

$script:LogCopyButton.Add_Click({
    try {
        $range = [System.Windows.Documents.TextRange]::new($script:LogDocument.ContentStart, $script:LogDocument.ContentEnd)
        [System.Windows.Clipboard]::SetText($range.Text)
        $script:StatusLabel.Text = Get-UiText 'Log.Copied'
    } catch {
        Show-Message $_.Exception.Message (Get-UiText 'Log.CopyTitle') 'Warning'
    }
})
$script:LogOpenButton.Add_Click({
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:LogDir) }
    catch { Show-Message $_.Exception.Message (Get-UiText 'Log.OpenFolder') 'Warning' }
})
$script:LogClearButton.Add_Click({
    $script:LogDocument.Blocks.Clear()
    [void]$script:LogDocument.Blocks.Add([System.Windows.Documents.Paragraph]::new())
})

$script:CancelButton.Add_Click({
    if ($null -eq $script:CurrentPS) { return }
    $script:Cancelled = $true
    $script:StatusLabel.Text = Get-UiText 'Common.Cancelling'
    try { $script:CurrentPS.Stop() } catch { }
})

$script:Window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:Busy) { return }
    $eventArgs.Cancel = $true
    if (Show-Confirm ((Get-UiText 'Common.CancelTaskText') -f "`r`n") (Get-UiText 'Common.CancelTaskTitle')) {
        $script:Cancelled = $true
        $script:CloseWhenIdle = $true
        if ($null -ne $script:CurrentPS) {
            try { $script:CurrentPS.Stop() } catch { }
        }
    }
})

# One timer drives all task progress: the background runspace only enqueues
# messages, the UI thread drains them. 150 ms stays responsive while idle.
$script:TaskTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:TaskTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:TaskTimer.add_Tick({ Update-TaskState })
$script:TaskTimer.Start()

# --------------------------------------------------------------------------
# Initial population
# --------------------------------------------------------------------------

$script:HeaderSubtitle.Text = ((Get-UiText 'App.HeaderSubtitle') -f $script:LogDir)
if ($isAdmin) {
    $script:ElevationBadge.Text = Get-UiText 'App.Elevated'
} else {
    $script:ElevationBadge.Text = Get-UiText 'App.NotElevated'
}
$script:NavLogPath.Text = $script:LogFile
$script:LogPathLabel.Text = $script:LogFile

# Fit the window to the work area. 1366x768 laptops are common in the field,
# and DPI scaling can make a fixed-size window overflow the screen.
$workArea = [System.Windows.SystemParameters]::WorkArea
$windowWidth = [Math]::Min($script:Window.Width, [Math]::Max($script:Window.MinWidth, $workArea.Width - 24))
$windowHeight = [Math]::Min($script:Window.Height, [Math]::Max($script:Window.MinHeight, $workArea.Height - 24))
$script:Window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
$script:Window.Width = $windowWidth
$script:Window.Height = $windowHeight
$script:Window.Left = $workArea.Left + (($workArea.Width - $windowWidth) / 2)
$script:Window.Top = $workArea.Top + (($workArea.Height - $windowHeight) / 2)

$presets = @(@($script:Config.PrinterDrivers) | Where-Object {
    $null -ne $_ -and $_.Enabled -ne $false -and -not [string]::IsNullOrWhiteSpace([string]$_.Make)
})
$script:PrinterMake.Items.Clear()
foreach ($preset in $presets) { [void]$script:PrinterMake.Items.Add($preset) }
if ($presets.Count -gt 0) { $script:PrinterMake.SelectedIndex = 0 }

Refresh-SoftwareList
Refresh-Printers
Refresh-Users
Refresh-Account

Add-LogLine -Level Info -Message 'Windows Automatic Setup started.'
Add-LogLine -Level Detail -Message ("Root: {0}" -f $script:Root)
Add-LogLine -Level Detail -Message ("PowerShell {0} | {1} | Admin: {2}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString, $isAdmin)
Add-LogLine -Level Detail -Message ("Log file: {0}" -f $script:LogFile)

$script:NavSoftware.IsChecked = $true
Show-Page 'Software'
if ($StartPage -ne 'Software') {
    $navMap = @{
        Software = $script:NavSoftware
        Printers = $script:NavPrinters
        Users    = $script:NavUsers
        Account  = $script:NavAccount
        Log      = $script:NavLog
    }
    $navMap[$StartPage].IsChecked = $true
    Show-Page $StartPage
}

if ($NoShow) {
    # Smoke test path: the whole window was built and every card populated.
    Write-Output ('GUI OK: {0} software item(s), {1} printer(s), {2} user(s).' -f $script:SoftwareRows.Count, $script:PrinterRows.Count, $script:UserRows.Count)
    $script:Window.Close()
    exit 0
}

[void]$script:Window.ShowDialog()
