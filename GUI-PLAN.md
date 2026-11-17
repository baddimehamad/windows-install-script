# GUI for Windows Automatic Setup — implementation plan

> Goal: a native WPF window for the setup kit, sharing one core module with the
> existing console script.
>
> Decision taken: **full WPF GUI + core refactor**, **two front-ends, one core**.
>
> Status: implemented. The window is now the default launcher; the text menu
> remains available with `Run-Setup.bat console` or `SETUP_GUI=0`.

## Why WPF in PowerShell

| Option | Verdict |
|---|---|
| **WPF + PowerShell** | ✅ Windows 10/11 already ship .NET Framework + WPF, so it runs on a bare fresh install. Same language, same elevation flow, same `Software.json`, no build step. |
| WinForms + PowerShell | ✅ Also works, less markup to learn, uglier (2010 look). Fine fallback. |
| C# / WinUI 3 / Avalonia / MAUI | ❌ Needs .NET SDK + a build pipeline, full rewrite of ~1,500 lines. Overkill. |
| Electron / Tauri / local web server | ❌ Extra runtime, and an HTTP listener running as Administrator is a liability for zero benefit. |
| `ps2exe` on the console script | ❌ Only hides the console; still a text menu. Worth adding *later* to package the GUI. |

## The actual blocker

Every action calls `Read-Host` (`Select-SoftwareToInstall`,
`Configure-BuiltInAdministrator`, `Show-UserMenu`, `Install-NetworkPrinter`…).
A GUI cannot feed answers into `Read-Host` reliably — piping `"1"` into the
script does not work for secure strings or loops. So the work is splitting
logic from presentation.

## Target file layout

```text
windows-install-script/
├─ Setup.Core.psm1            NEW   all logic, zero prompts, zero Write-Host
├─ Install-MyPC.ps1           REWRITE console front-end only (~400 lines, down from 1,490)
├─ Install-MyPC.Gui.ps1       NEW   WPF front-end + embedded XAML
├─ Run-Setup.bat              unchanged
├─ Run-Setup-Gui.bat          NEW   silent launcher (no console flash)
├─ Setup-Online.ps1           EDIT  add 'Setup.Core.psm1' to $NeededFiles
├─ Software.json              unchanged
├─ Tests/Setup.Core.Tests.ps1 NEW   Pester 5
└─ README.md                  EDIT  add a GUI section + screenshots
```

`Setup-Online.ps1` line 40 becomes
`@('Install-MyPC.ps1', 'Software.json', 'Setup.Core.psm1')`.
The module resolves via `$PSScriptRoot`, which already works because the
staging folder is flat.

---

## Phase 1 — extract `Setup.Core.psm1` (the real work)

Two mechanical transformations, no logic rewrites:

1. `Write-Host 'x' -ForegroundColor Yellow` → `Write-SetupLog -Level Warning -Message 'x'`
2. `Read-Host ...` → a **parameter** on the function

**Do not touch** the winget capture logic (`2>&1 | Out-String`, hash-mismatch
regex, exit-code branches), the `pnputil` handling, or the sole-administrator
guard — they are language-dependent and already correct.

### Logging design (works from any runspace)

```powershell
# module scope
$script:LogSink = { param($level, $message) }

function Set-SetupLogSink {
    param([scriptblock]$Sink)
    $script:LogSink = $Sink
}

function Write-SetupLog {
    param(
        [ValidateSet('Info','Success','Warning','Error','Detail')][string]$Level,
        [string]$Message
    )
    & $script:LogSink $Level $Message
}
```

The console front-end registers a coloured `Write-Host` sink. The GUI registers
a sink that appends to the `PSDataCollection` **and** to
`Logs\setup-*.log`. Because each runspace imports its own module instance, the
two sinks never collide. This also replaces `Start-Transcript` for the GUI
path — keep the transcript only in the console front-end.

### Public surface

| Group | Function | Replaces |
|---|---|---|
| Config | `Get-SetupConfig -Path` | inline `ConvertFrom-Json` block |
| Config | `Get-SoftwareCatalog -Config` | `Get-SelectableSoftware` |
| Config | `Test-LocalAccountName -Name` | duplicate validation in lines 200–213 and in `Rename-ChosenLocalUser` |
| Software | `Install-SetupWingetApp -App` | `Install-WingetApp` |
| Software | `Install-SetupLocalPackage -Installer` | `Install-LocalSoftware` |
| Software | `Repair-SetupWingetSource` | `Repair-WingetSource` |
| Account | `Get-BuiltInAdminAccount` | same (already pure) |
| Account | `Enable-BuiltInAdministrator -Password <SecureString>` | `Configure-BuiltInAdministrator` minus prompts |
| Account | `Get-CurrentLocalAccount` | SID lookup in `Rename-CurrentLocalUser` |
| Account | `Rename-SetupLocalAccount -Name -NewName` | shared by "current user" and "any user" |
| Printers | `Get-PrinterInventory` | `Show-PrinterList` minus rendering |
| Printers | `Install-SetupNetworkPrinter -Config -Make -HostAddress -Port -PrinterName [-PreferredInf]` | `Install-NetworkPrinter` |
| Printers | `Rename-SetupPrinter -Name -NewName` | `Rename-ChosenPrinter` |
| Users | `Get-LocalUserInventory` | `Show-LocalUserList` minus rendering |
| Users | `Set-SetupLocalAccountPassword -Name -Password <SecureString>` | `Set-ChosenLocalUserPassword` |
| Users | `Add/Remove-SetupLocalGroupMember -UserName -GroupName` | `Edit-ChosenLocalUserGroups` |
| Users | `Get-SoleAdminLock -UserName` | the freeze rule, preserved verbatim |

Functions that stay front-end only: `Ask-YesNo`, `Select-SoftwareToInstall`,
`Select-LocalUserByNumber`, `Show-UserMenu`, `Show-PrinterMenu`.

### Return contract

Every action function returns one object instead of mutating `$script:failed`:

```powershell
[pscustomobject]@{
    Name             = 'Google Chrome'
    Success          = $true
    ExitCode         = 0
    RestartRequired  = $false
    Message          = 'Already installed'
}
```

Both front-ends aggregate these into the existing end-of-run summary. This
removes global state, which is what makes the runspace boundary safe.

**Acceptance:** console `Install-MyPC.ps1` output is behaviourally identical to
today; the `irm … | iex` one-liner still runs end to end;
`Select-String Setup.Core.psm1 -Pattern 'Read-Host|Write-Host|Clear-Host'`
returns nothing.

## Phase 2 — rewire the console front-end

Strip the module import + elevation + prompts + renderers. Keep exactly: the
UAC relaunch block (lines 20–33, including `-OriginalUserSid`),
`Start-Transcript`, `$ProgressPreference = 'SilentlyContinue'`, the menu loop,
and the bilingual text. ~400 lines.

**Acceptance:** a full run on a VM matches the current script's log, and
"rename current user" still targets the signed-in user after answering UAC as
a *different* admin.

## Phase 3 — the WPF window

Embed the XAML as a here-string so the GUI stays a single file (matches the
"copy 2 files" distribution model).

### Layout

`TabControl` with five pages plus a persistent status bar:

| Tab | Content |
|---|---|
| **Software** | `DataGrid` with `DataGridCheckBoxColumn` · Name · Source (`Winget`/`Local`) · Status column · filter `TextBox` · Select all / none · **Install selected** |
| **Printers** | Left form: `ComboBox` Make (from `PrinterDrivers`) · IP `TextBox` · port `TextBox` (9100) · name `TextBox` · driver-status label. Right: `DataGrid` of installed printers + Refresh / Rename |
| **Users** | `DataGrid`: Name · Enabled · Groups. Buttons: Rename · Set password · Groups. Shows the sole-admin lock banner when applicable |
| **Account** | Card A: built-in admin (real name from SID `-500`, enabled state, password + confirm `PasswordBox`, Enable). Card B: rename signed-in user (current name prefilled) |
| **Log** | Full run log, Copy / Open log folder |

Status bar: overall `ProgressBar`, current task label, **Cancel**.

### Threading helper

```powershell
function Invoke-CoreTask {
    param([scriptblock]$Body, [object[]]$Arguments, [scriptblock]$OnDone)

    $ps = [powershell]::Create()
    [void]$ps.AddScript("Import-Module '$PSScriptRoot\Setup.Core.psm1' -Force")

    $output = [System.Management.Automation.PSDataCollection[psobject]]::new()
    $output.add_DataAdded({
        param($sender, $e)
        # marshal $sender[$e.Index] to the Dispatcher
    })

    [void]$ps.AddScript({
        param($log, $taskArgs)
        Set-SetupLogSink {
            param($level, $message)
            $log.Add([pscustomobject]@{ Level = $level; Message = $message })
        }
        & $Body @taskArgs          # core function call
    }).AddArgument($output).AddArgument($Arguments)

    $ps.add_InvocationStateChanged({
        # re-enable UI, then $OnDone.Invoke()
    })

    [void]$ps.BeginInvoke($output, $null)
}
```

Key rules:

- One runspace per **task**, created fresh (simplest correct model).
- `SecureString` from `PasswordBox.SecurePassword` passes straight through as
  an argument — no plaintext conversion, no `.Password`.
- `$ps.Stop()` on Cancel, with an on-screen note that a winget / msiexec child
  may finish anyway.
- Disable the initiating control while a task runs, never the whole window
  (the Log tab stays usable).

### Two things that will bite you if skipped

- **STA guard.** WPF needs an STA thread. PS 5.1 is STA by default, but a
  `-MTA` caller breaks it. Add a 5-line check at the top that relaunches with
  `-Sta` if `[Threading.Thread]::CurrentThread.GetApartmentState()` isn't
  `STA`.
- **Elevate before the window.** A non-elevated window that pops UAC on the
  first click loses its runspace state and looks broken. Reuse the existing
  re-launch block, passing `-OriginalUserSid`, and build the window afterwards.

### Minimal skeleton (shape, not production)

```powershell
Add-Type -AssemblyName PresentationFramework

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Setup" Height="620" Width="900" WindowStartupLocation="CenterScreen">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
      <RowDefinition Height="120"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Select software" FontSize="18" FontWeight="SemiBold"/>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="AppList"/>
    </ScrollViewer>
    <TextBox x:Name="LogBox" Grid.Row="2" IsReadOnly="True" FontFamily="Consolas"
             VerticalScrollBarVisibility="Auto" Margin="0,8"/>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="RunButton" Content="Install selected" Padding="16,6" Margin="0,0,8,0"/>
      <Button x:Name="CloseButton" Content="Close" Padding="16,6"/>
    </StackPanel>
  </Grid>
</Window>
'@

$window    = [Windows.Markup.XamlReader]::Load([xml]$xaml)
$appList   = $window.FindName('AppList')
$logBox    = $window.FindName('LogBox')
$runButton = $window.FindName('RunButton')

# Fill the checkbox list from Software.json
$config = Get-Content (Join-Path $PSScriptRoot 'Software.json') -Raw | ConvertFrom-Json
foreach ($app in $config.Apps) {
    if ($app.Enabled -eq $false) { continue }
    $cb = [System.Windows.Controls.CheckBox]::new()
    $cb.Content = "$($app.Name)  ($($app.Id))"
    $cb.Tag = $app
    [void]$appList.Children.Add($cb)
}

$runButton.Add_Click({
    $apps = @($appList.Children | Where-Object IsChecked | ForEach-Object Tag)
    if ($apps.Count -eq 0) { return }
    $runButton.IsEnabled = $false

    # Heavy work on a background runspace so the window never freezes
    $ps = [powershell]::Create()
    [void]$ps.AddScript("Import-Module '$PSScriptRoot\Setup.Core.psm1' -Force")
    [void]$ps.AddScript({
        param($selected)
        foreach ($app in $selected) {
            Write-Output "--- $($app.Name) ---"
            Install-SetupWingetApp -App $app
        }
    }).AddArgument($apps)

    $output = [System.Management.Automation.PSDataCollection[psobject]]::new()
    $output.add_DataAdded({
        param($sender, $e)
        $line = $sender[$e.Index]
        $window.Dispatcher.Invoke([action]{
            $logBox.AppendText("$line`r`n")
            $logBox.ScrollToEnd()
        })
    })
    $ps.add_InvocationStateChanged({
        if ($_.InvocationStateInfo.State -eq 'Completed') {
            $window.Dispatcher.Invoke([action]{ $runButton.IsEnabled = $true })
        }
    })
    [void]$ps.BeginInvoke($output, $null)
})

$window.FindName('CloseButton').Add_Click({ $window.Close() })
[void]$window.ShowDialog()
```

### Localisation

One `$ui` hashtable keyed by
`[CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName`, with `en` and `fr`
entries. Same strings feed `MessageBox` titles.

**Acceptance:** window opens on a fresh Win11 VM, installs 3 apps with the UI
responsive throughout, Cancel aborts between apps, disk log matches the GUI log.

## Phase 4 — launchers and packaging

`Run-Setup-Gui.bat`:

```bat
@echo off
start "" powershell.exe -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Install-MyPC.Gui.ps1"
```

Then an optional `Build-Exe.ps1` calling
`ps2exe -requireAdmin -icon app.ico`. Keep the `.ps1` beside the exe: AV false
positives on `ps2exe` output are common, and the script path is the fallback.

## Phase 5 — tests

Pester 5, no admin and no network required:

| Test | Asserts |
|---|---|
| `Test-LocalAccountName` | >20 chars rejected, each invalid char rejected, empty rejected |
| `Get-SoftwareCatalog` | `Enabled:false` hidden, `[WILL DOWNLOAD]` vs `[FILE NOT FOUND]` labels correct |
| `Resolve-DriverInfPath` | 0 / 1 / many `.inf` in a temp folder (the "many" case must now *return* a list, not prompt) |
| `Get-SoleAdminLock` | freezes membership for the last enabled admin |
| Source hygiene | `Select-String` proves no `Read-Host` / `Write-Host` / `Clear-Host` in the module |
| `Set-SetupLogSink` | a capture sink receives every level |

Plus a manual VM checklist: Win10 22H2 EN, Win11 24H2 FR, standard user → UAC,
run as built-in Administrator (winget source caveat), no Internet, printer
install with a cached driver.

---

## Mapping: console → GUI

| Current | GUI control |
|---|---|
| Menu `1,3` / `A` / `0` | `TabControl`: Software · Printers · Users · Account · Log |
| Numbered software list | `ScrollViewer` + `CheckBox` list bound to `Software.json`, plus a name filter |
| Printer submenu | `ComboBox` (Make) · `TextBox` IP · `TextBox` port · `TextBox` name · `DataGrid` of `Get-Printer` |
| Users submenu | `DataGrid` (Name / Enabled / Groups) + buttons Rename · Password · Groups |
| `Read-Host -AsSecureString` | `PasswordBox` ×2, pass `PasswordBox.SecurePassword` |
| `YES` / `OUI` confirm | Modal `MessageBox` |
| Coloured `Write-Host` | `RichTextBox` or read-only `TextBox`, one line per entry, colour by level + still write to `Logs\setup-*.log` |

---

## Effort and risk

| Phase | Effort |
|---|---|
| 1 — core module | 1 day |
| 2 — console front-end | 0.5 day |
| 3 — WPF window | 1.5 days |
| 4 — launchers / exe | 0.5 day |
| 5 — tests + VM matrix | 0.5 day |
| **Total** | **~4 days** |

Main risk: regressing the one path that currently works. Mitigated by phase 1
being mechanical (no logic edits), the Pester hygiene test, and keeping the
console front-end as the reference implementation until the GUI passes the same
VM checklist.

Optional extra: add `-DryRun` to every core action that logs instead of
executing — 1 hour, and it makes GUI testing painless.

## Pitfalls specific to this script

1. **`OriginalUserSid` must survive the elevation hop.** The current re-launch
   passes `-OriginalUserSid` so "rename current user" targets the *signed-in*
   account, not the admin who answered UAC. The GUI needs the identical logic.
2. **Keep `$ProgressPreference = 'SilentlyContinue'`.** It is a genuine ~10×
   download speed fix. Use a WPF `ProgressBar` with known step counts instead
   of `Write-Progress`.
3. **Winget output is buffered** via `2>&1 | Out-String`, so the GUI gets one
   blob per app. Fine for v1; switch to `| ForEach-Object { Write-Output $_ }`
   if live lines are wanted.
4. **Interactive installers** (`OfficeSetup.exe`, Office C2R) still pop their
   own windows over the GUI. Only `Apps` are silent
   (`--silent --disable-interactivity` is already there).
5. **`Start-Transcript`** keeps working in console mode; the GUI logs through
   the sink instead.
6. **Do not let the GUI write `Software.json`** in v1. Read-only is enough; a
   bad write breaks every future run.
7. **`ps2exe` output is sometimes flagged by antivirus.** Ship the `.ps1`
   beside it.
8. **Bilingual labels** — one `$ui` hashtable rather than hardcoded EN/FR
   everywhere.

## Cheaper alternative (rejected, for the record)

Keep the console script untouched and add an answer-file mode:
`Install-MyPC.ps1 -AnswerFile answers.json`, where each `Read-Host` becomes
`Read-Answer -Key 'software'`. The GUI then writes `answers.json` and launches
the console elevated. **~3–4 hours**, but a console window is still visible and
it is not a real GUI.
