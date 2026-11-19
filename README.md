# Windows Automatic Setup 🖥️

A simple, reusable kit to set up a fresh **Windows 10 / 11** PC in minutes.

Pick what you want from a menu — enable the built-in Administrator account, rename the current local user, and install only the software you select. No bloat, no unwanted apps.

![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Winget](https://img.shields.io/badge/Package%20Manager-Winget-green)
![License](https://img.shields.io/badge/License-MIT-lightgrey)

## 🌐 Run directly from the web (no download)

On any PC with internet, open PowerShell and run:

```powershell
irm https://tinyurl.com/27wv3wmc | iex
```

This opens the **window** version by default. Prefer the text menu? Same command, one setting:

```powershell
$env:SETUP_GUI=0; irm https://tinyurl.com/27wv3wmc | iex
```

---

## 🪟 Window mode (GUI)

Both front-ends install software, set up printers, manage local accounts and show a read-only system status. The window additionally checks installed versions, offers Winget updates and uninstalls applications. Pick whichever you prefer; the window is the default.

- **Window (default):** `Run-Setup.bat`, `Run-Setup-Gui.bat`, `.\Install-MyPC.Gui.ps1`, or the one-liner above.
- **Console:** `Run-Setup.bat console`, `.\Install-MyPC.ps1`, or the `SETUP_GUI=0` one-liner.

From the window, the **Open console** button in the header switches to the text menu: it opens `Install-MyPC.ps1` in a new PowerShell window (already elevated) and closes the window. It is disabled while an install is running.

The window has six tabs:

| Tab | What you can do |
|-----|-----------------|
| **Software** | Filter the list, narrow it by **Category**, or pick a **Profile** (Office, Developer, Technician, Minimal) to tick a preset selection. **Install selected** opens a confirmation preview listing every item and an optional **Create a System Restore point** checkbox, then runs preflight checks; a blocking problem stops the install. **Check versions and updates** fills the *Installed version* and *Available update* columns from Windows and Winget, and refreshes the *Install version* dropdown on every unpinned Winget-source entry; each dropdown also has a small recycle icon that reloads just that application's versions. The update column shows `Up to date`, `Pinned`, `Manual`, `Unknown` or the newer version. Select installed apps to **Update selected** (Winget only) or **Uninstall selected** (after a confirmation). **Preflight checks** shows elevation, PowerShell, Windows build, disk space, Internet, winget, pending restart and System Restore status. **Export report** writes an HTML report with the system information and every action attempted in this session. Each row shows the application logo, the `WINGET`/`LOCAL` badge and a status such as `Ready`, `Not installed`, `Installed`, `Update available`, `Installing...`, `Installed (restart)`, `Skipped`, `Updated`, `Uninstalled` or `Failed`. The chevron at the end of each row opens a dropdown with **Open software** and **Open file location**; the folder action selects the executable in Explorer when one can be found, and Store apps report that no file location is available. |
| **System** | Read-only dashboard: computer and Windows version, uptime, memory, Windows Update service, security (Defender, firewall, Secure Boot, TPM, BitLocker, UAC, activation), storage, network, power and optional-feature status. **Refresh** reloads the status, **Check for updates** runs an opt-in online Windows Update search (it can take several minutes), and **Export report** writes the dashboard to `Logs\system-report-*.html`. The dashboard itself never changes the PC. Below it, **maintenance actions** change the power plan, hibernation, fast startup, DNS servers, Storage Sense, temporary files and time zone. Each action asks for confirmation and is logged; DNS can be restored with the Automatic (DHCP) preset. |
| **Printers** | Pick a manufacturer, type the IP/hostname, port and optional name, then **Install printer**. The right-hand list shows installed printers and lets you rename one, **Set default** or send a **Test page**. |
| **Users** | Rename a local account, change its password, add/remove group membership, enable/disable it, **Create user** (standard or administrator, with an optional restore point) or **Delete** it (the profile folder is kept, and an optional restore point is offered). The only enabled administrator is marked `LAST ADMIN - LOCKED` and cannot be changed, disabled or deleted; the account you are signed in with cannot be disabled or deleted either. |
| **Account** | Enable the built-in Administrator (password typed twice, never stored), or rename the account you are signed in with. |
| **Log** | Live progress from the current install, with **Copy**, **Open folder** and **Clear**. |

Notes:

- **Nothing to install.** The window uses WPF and Windows PowerShell 5.1, both part of Windows 10 and 11. No PowerShell 7, no .NET download, no Python.
- **English or French, automatically.** The window follows the Windows display language: French on a French PC, English everywhere else. Set `SETUP_UI_LANG=en` or `SETUP_UI_LANG=fr` before launching to force one. Log lines stay in English, like the console log. French text is written without accented characters so the scripts remain plain ASCII and safe on any Windows code page.
- **Same elevation.** The window relaunches itself with UAC on start, and still passes the original user's SID, so "rename signed-in user" targets the right account.
- **The window never freezes.** Installs, updates and uninstalls run in a background runspace; a **Cancel** button appears in the status bar while something is running.
- **Logs:** `Logs\gui-YYYYMMDD-HHMMSS.log`, one per window session.
- **Safety first.** Every install runs read-only preflight checks before touching the PC. A blocking problem (not elevated, too little disk space, unsupported PowerShell) stops the run; warnings (no Internet, pending restart, no restore point) are shown but do not block. **Install selected** offers an optional System Restore checkpoint, and user creation/deletion offers one by default. Restore points are reported as skipped instead of failing when System Protection is disabled.
- **Reports:** **Export report** writes an HTML file to `Logs\` with the machine information and every action attempted in the window session. The **System** tab can export its own dashboard to `Logs\system-report-*.html` (HTML, JSON or CSV when called from the module).
- **Logos:** each software row shows the image named by its `Logo` field in `Software.json` (for example `logo/chrome.png`). The files live in the `logo` folder. If an image is missing or unreadable, the row shows a colored tile with the application's first letter instead, so a bad logo never blocks an install.
- **Installed checker (window only).** **Check versions and updates** reads the 32-bit, 64-bit and per-user Add/Remove Programs entries and, for `WINGET` rows, the package list reported by Winget. The *Installed version* column shows the registry version when one exists. An update is offered only when Winget recognises the catalog ID in its `winget` source, so the window never proposes an update it cannot perform. Applications Winget does not manage, such as Chrome installed from its MSI, are compared with the version published by the Winget source and show `Up to date` when they match; when the source has a newer version, the window updates the app by reinstalling that version. Unrecognised Winget IDs show `Unknown`, pinned entries show `Pinned`, and local installers show `Manual`. The same check refreshes the *Install version* dropdown on every unpinned Winget-source entry: choose `Latest` or an exact release before **Install selected**. Because it queries each application separately, the full check takes longer as the catalog grows; the recycle icon next to a dropdown reloads only that application. **Uninstall selected** uses `winget uninstall` when Winget manages the package and falls back to the registered uninstaller otherwise. A check runs automatically after every install, update or uninstall.
- The GUI does **not** write `Software.json` — it is read-only. Edit the file by hand to change the catalog.
- Closing the window during a task asks for confirmation; a child installer (winget, msiexec) may keep running in the background.

---

## ✨ What it does

When you run the console version you get a main menu; the window version exposes the same actions as tabs.

| # | Action | Description |
|---|--------|-------------|
| 1 | **Enable built-in Administrator** | Enables the hidden Administrator account (SID ending in `-500`, so `Administrator` or `Administrateur`) and prompts you to enter a new password. Type `YES`/`OUI` (any case) to confirm. |
| 2 | **Rename current local user** | Renames the local account you were signed in with (name + display name). Does **not** rename `C:\Users\OldName`. |
| 3 | **Install software** | Shows a numbered list from `Software.json` grouped by category. Install only what you pick, e.g. `1,3,5`, `A` for all, `P` for a profile, `0` to skip. A preview lists the selection, then preflight checks run and an optional restore point is offered before installing. |
| 4 | **Printers** | Submenu: install a printer (pick manufacturer, then IP/hostname, port, name), list installed printers (driver, port, status, default), rename any printer, set the default printer, or send a test page. |
| 5 | **Users** | Submenu: list local users (with member-of groups), rename any user, change any user's password, change group membership (add/remove, e.g. Administrators), enable/disable an account, create a local user (standard or administrator), or delete one (profile folder kept). The only enabled administrator is fully locked: its group membership cannot be changed and it cannot be disabled or deleted; the account you are signed in with cannot be disabled or deleted either. |
| 6 | **Run all** | Runs 1 + 2 + 3 + 4 + 5 in order. |
| 7 | **Preflight checks** | Shows elevation, PowerShell version, Windows build, free disk space, Internet, winget, pending restart and System Restore status. |
| 8 | **Create a restore point** | Creates a Windows System Restore checkpoint on request and reports when System Protection is unavailable. |
| 9 | **Export an HTML report** | Writes the system information and every action attempted in this session to `Logs\setup-report-*.html`. |
| 10 | **System status report (read-only)** | Prints the computer, Windows Update, security, storage, network, power and optional-feature status. Asks before running an online Windows Update search, then offers to export the dashboard to `Logs\system-report-*.html`. Nothing is changed. |
| 11 | **System maintenance** | Submenu: power plan, hibernation, fast startup, DNS presets (Cloudflare, Google, Quad9 or automatic), DNS flush, ping with optional traceroute, temp-file preview and cleanup, and time zone. Every change asks for confirmation and is logged. |
| 0 | **Exit** | Exit without further changes. |

After each step finishes you return to this menu: press **Enter** for home, or `0` to exit.

You can also combine options, e.g. `1,3`.

### 📦 Default software list

The catalog ships 34 enabled entries plus two disabled remote-access tools (AnyDesk, Tailscale). Every application is installed through [Winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/) (Windows Scan and WhatsApp come from the Microsoft Store source), except the local installers marked below. Entries are grouped by category in the window and the console list.

**Browsers**

1. Google Chrome
2. Mozilla Firefox
3. Brave

**Communication**

4. Slack
5. Zoom Workplace
6. WhatsApp

**Development**

7. Notepad++
8. Visual Studio Code
9. Git
10. Microsoft PowerToys

**Diagnostics**

11. CrystalDiskInfo
12. HWiNFO

**Media**

13. ShareX
14. VLC media player

**Office and PDF**

15. SumatraPDF
16. Adobe Acrobat Reader
17. LibreOffice
18. Microsoft Office Home Business 2024 (Français) — auto-downloaded from Microsoft (~7 MB Click-to-Run setup)

**Runtimes**

19. Microsoft Visual C++ 2015-2022 Redistributable (x64)
20. Microsoft Visual C++ 2015-2022 Redistributable (x86)
21. Microsoft .NET Desktop Runtime 8
22. Microsoft Edge WebView2 Runtime
23. Microsoft DirectX End-User Runtime
24. Eclipse Temurin JRE 21

**Security**

25. KeePassXC
26. Bitwarden

**Utilities**

27. 7-Zip
28. Everything
29. PuTTY
30. Rufus
31. WinRAR
32. NAPS2
33. Windows Scan
34. OrbitConvert — auto-downloaded from GitHub releases (~92 MB per-user MSI)

Disabled by default: **AnyDesk** and **Tailscale** (remote access). Enable them in `Software.json` when a machine needs remote support.

Profiles in `Software.json` preselect a group of these entries: **Office** (12 apps), **Developer** (10), **Technician** (9 available, 11 when AnyDesk and Tailscale are enabled) and **Minimal** (8).

> The numbers are generated from entries with `"Enabled": true` in `Software.json`. Disable/add an entry and the numbers shift automatically. Profiles are matched by `Id` or `Name`.

---

## 🚀 Quick start (for normal users)

### Requirements

- Windows 10 or Windows 11 (64-bit recommended)
- Administrator rights (you'll get a UAC prompt — click **Yes**)
- Internet connection (for Winget downloads)

### Steps

1. **Download this repo:**
   - Click **Code → Download ZIP** on GitHub, then extract it, e.g. to `C:\Tools\Windows_Auto_Setup`
   - Or clone it:
     ```powershell
     git clone https://github.com/baddimehamad/windows-install-script.git
     ```
2. **(Optional) Add Office:** copy your `OfficeSetup.exe` next to `Install-MyPC.ps1` (same folder as `Run-Setup.bat`).
3. **Run:** double-click **`Run-Setup.bat`** (the window opens) → approve the UAC prompt. For the text menu, open a Command Prompt in this folder and run **`Run-Setup.bat console`**, or double-click **`Run-Setup-Gui.bat`** for the window.
4. **Choose:** enter e.g. `6` to run everything, or `1,3` for Administrator + software only. In the window, pick a tab and use its buttons.
   - If you chose option 1, type `YES`/`OUI` (any case: yes, Yes, oui...) to confirm, then enter a new password when asked (minimum 8 characters), then confirm it. Leave blank to cancel.
5. **Pick software:** enter numbers like `1,3,5`, or `A` for all, or `0` to skip.
6. **Done:** check the summary at the end. If anything failed, open the `Logs` folder.

### 🌐 Run directly from the web (no download) — details

Same one-liner as at the top: `irm https://tinyurl.com/27wv3wmc | iex`

<details>
<summary>Full URL and custom alias</summary>

Full URL (same script, no shortener):

```powershell
irm https://raw.githubusercontent.com/baddimehamad/windows-install-script/main/Setup-Online.ps1 | iex
```

Want your own memorable word? Paste the full URL into https://tinyurl.com and create an alias (e.g. `mypc-setup-baddi`), then run `irm https://tinyurl.com/mypc-setup-baddi | iex`.

</details>

This downloads the two front-ends, the shared module, `Software.json` and the application logos from `logo/` (about 350 KB), then opens the window by default. Add `-Console` (or set `$env:SETUP_GUI=0`) to use the text menu instead; console mode does not download logos. Approve the UAC prompt when it appears.

> Note: local-only files are not downloaded up front: `OfficeSetup.exe` and `Installers/` content show `FILE NOT FOUND` unless they carry a `Url` (downloaded on demand, e.g. French Office, Chrome fallback) or you copy them in manually. Printer driver folders (`Drivers/`) **are fetched automatically on demand** into `C:\ProgramData\Windows_Auto_Setup_Online\Drivers` the first time you install a printer (cached for later runs). Winget apps work normally.

Example session:

```text
========================================================
              WINDOWS AUTOMATIC SETUP
========================================================
Choose what you want to do:
  1. Enable built-in Administrator and set a new password (you will enter it)
  2. Rename the currently signed-in local user account
  3. Choose software to install from a numbered list or a profile
  4. Printers (install / list / rename / default / test page)
  5. Users (list / rename / password / groups / enable-disable / create / delete)
  6. Run all options (1+2+3+4+5)
  7. Preflight checks and system information
  8. Create a System Restore point
  9. Export an HTML report
 10. System status report (read-only)
 11. System maintenance (power, DNS, temp files, time zone)
  0. Exit

Enter option number(s): 1,3

SOFTWARE LIST — enter numbers separated by commas (example: 1,3,5).
Enter A to select all enabled items, P for a profile, or 0 to skip software installation.
Profiles: Office, Developer, Technician, Minimal
  1. [Winget][Browsers] Google Chrome — Winget ID: Google.Chrome
  2. [Winget][Browsers] Mozilla Firefox — Winget ID: Mozilla.Firefox
  ...
Software numbers: 1,3,5
```

---

## 📁 What's in the folder?

```text
windows-install-script/
├── Run-Setup.bat      ← double-click to start (window; "console" for text menu)
├── Run-Setup-Gui.bat  ← direct shortcut to the window
├── Install-MyPC.ps1   ← console front-end (auto-elevates to admin)
├── Install-MyPC.Gui.ps1 ← window front-end (auto-elevates to admin)
├── Setup.Core.psm1    ← shared logic used by both front-ends
├── Setup-Online.ps1   ← web launcher for `irm ... | iex`
├── Software.json      ← edit this to add/remove apps
├── verify-setup.ps1   ← read-only acceptance checks (catalog, logos, EN/FR, GUI)
├── logo/              ← one PNG per application (shown in the window)
│   └── README.md      ← sources, format and trademark note
├── Installers/        ← optional folder for your own .exe / .msi files
│   └── README.txt
├── Drivers/           ← printer driver folders (konika_minolta, xerox, epson)
│   └── README.txt
└── Logs/              ← created automatically, one log per run
```

- **`Run-Setup.bat`** — default launcher: starts the window detached (no console window stays open). Pass `console` to run the text menu in the current window instead.
- **`Run-Setup-Gui.bat`** — direct shortcut to the window version; same detached start as `Run-Setup.bat`.
- **`Install-MyPC.ps1`** — console front-end: prompts, menus and colours. Also started by the window's **Open console** button.
- **`Install-MyPC.Gui.ps1`** — window front-end (WPF, embedded XAML).
- **`Setup.Core.psm1`** — every action (Winget, local installers, printers, users, Administrator). Both front-ends call it, so a fix applies to both. It never prompts and never writes to the console.
- **`Software.json`** — the only file you normally need to edit.
- **`verify-setup.ps1`** — read-only acceptance checks: parsing, ASCII sources, catalog IDs, 128×128 logos, EN/FR string coverage, core safety actions, report export and both GUI smoke tests. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-setup.ps1` (add `-SkipGui` on a machine without an interactive desktop).
- **`logo/`** — application icons for the window (PNG). See `logo/README.md` for sources and reuse notes.

---

## ⚙️ Customize the software list

You don't need to know PowerShell — just edit `Software.json` with Notepad.

### Add / remove a Winget app

Add an object to the `Apps` array:

```json
{
  "Name": "Example Application",
  "Type": "winget",
  "Id": "Publisher.PackageId",
  "Enabled": true
}
```

- Find the ID with: `winget search <app-name>` (e.g. `winget search vlc` → `VideoLAN.VLC`)
- Set `"Enabled": false` to hide it from the menu without deleting it.
- Optional `"FallbackUrl"`: direct vendor download used automatically if Winget fails (e.g. hash mismatch, which Winget won't override as admin). Chrome already has one:
  ```json
  {
    "Name": "Google Chrome",
    "Type": "winget",
    "Id": "Google.Chrome",
    "FallbackUrl": "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi",
    "Enabled": true
  }
  ```
- Keep valid JSON: double quotes, commas between objects.

### Install a specific Winget version

Add `Version` to a Winget entry to pin it:

```json
{
  "Name": "Mozilla Firefox 151.0",
  "Type": "winget",
  "Id": "Mozilla.Firefox",
  "Version": "151.0",
  "Logo": "logo/firefox.png",
  "Enabled": true
}
```

- List the versions Winget still publishes: `winget show Mozilla.Firefox --versions`. Old versions are often removed from the source, and a pin only works for a version that is listed there.
- `Software.json` ships a disabled `Mozilla Firefox 151.0 (pinned example)` entry. Set its `"Enabled": true` and change `Version`, or add `Version` to the normal Firefox entry. The example uses the same Winget ID as the normal Firefox entry, so enable only one of the two.
- A pinned entry is installed with `winget install --version <version> --force`, so the requested version replaces whatever is already installed.
- The window shows `Pinned` in the *Available update* column and never includes that entry in **Update selected**. Remove `Version` to follow the latest release again.
- Direct-download fallbacks are skipped for pinned entries because they install the vendor's latest build.

### Install a Microsoft Store app

Add `"Source": "msstore"` to a Winget entry and use the Store product ID:

```json
{
  "Name": "Windows Scan",
  "Type": "winget",
  "Source": "msstore",
  "Id": "9WZDNCRFJ3PV",
  "Logo": "logo/windows-scan.png",
  "Enabled": true
}
```

- Find the product ID with `winget search --source msstore <name>`.
- Installs use `winget install --source msstore`, and the row shows `Store ID` instead of `Winget ID`.
- The Microsoft Store does not publish a usable version list, so these entries never get an *Install version* dropdown. A `Version` pin is ignored for this source.
- The Store keeps its apps up to date itself, so the window detects the app as installed but does not offer it in **Update selected**.

### Choose the version to install (window)

Every unpinned entry from the `winget` source ships with `"VersionPicker": true`, so each row has an *Install version* dropdown:

```json
{
  "Name": "Mozilla Firefox",
  "Type": "winget",
  "Id": "Mozilla.Firefox",
  "VersionPicker": true,
  "Logo": "logo/firefox.png",
  "Enabled": true
}
```

- The dropdown is filled from `winget show <id> --exact --source winget --versions`. **Check versions and updates** reloads every application, which takes longer as the catalog grows; the small recycle icon beside one dropdown reloads only that application. The list is cached until the next check or per-row refresh.
- `Latest` (the default) keeps following the newest release. Choosing a specific version installs it with `winget install --version <version> --force`, exactly like a pinned entry.
- The dropdown only affects **Install selected**. **Update selected** still installs the latest release, and the choice is never written to `Software.json`.
- If a selected version later disappears from the Winget source, it stays selected and the log warns, so the choice never changes silently. The install then fails explicitly with `--version` and the log shows why; pick another version and retry.
- Set `"VersionPicker": false` or remove the flag to hide the dropdown for one entry. A pinned entry always hides it because its version is already fixed, so `VersionPicker` cannot be combined with `Version`; use one or the other.
- To see the available versions by hand: `winget show Mozilla.Firefox --exact --source winget --versions`.

### Add an application logo

The window front-end shows a small logo next to every enabled `Apps` and
`LocalInstallers` entry. Point the entry at a PNG in the `logo` folder:

```json
{
  "Name": "Example Application",
  "Type": "winget",
  "Id": "Publisher.PackageId",
  "Logo": "logo/example-application.png",
  "Enabled": true
}
```

- Use a square PNG (the bundled files are 128 x 128) with a transparent background. The window draws it at 28 x 28.
- `Logo` may be relative to the script folder (as above) or an absolute path.
- If `Logo` is missing, the file is absent, or the image cannot be read, the row shows a colored tile with the application's first letter. Nothing fails.
- The console front-end ignores logos.
- In online mode, `Setup-Online.ps1` downloads only the files referenced by the catalog, best-effort. Add a new logo to the repo before referencing it there.
- See [`logo/README.md`](logo/README.md) for the bundled icons, their sources and the trademark note.

### Add your own `.exe` / `.msi` installer

1. Put the file in the `Installers/` folder (or next to the script).
2. Add an entry to `LocalInstallers` in `Software.json`:

```json
{
  "Name": "My Custom App",
  "Path": "Installers\\MyCustomAppSetup.exe",
  "MatchName": "My Custom App",
  "Arguments": [],
  "Enabled": true
}
```

- Optional `MatchName` tells the window's checker which Add/Remove Programs name to look for. Use it when the catalog name differs from the name the vendor registers, for example `"Microsoft Office Home and Business 2024"` for the French Office entry. Without it, the checker matches on `Name`.
- A local installer has no update feed. The window shows `Manual` in the *Available update* column; run the installer again to update it.

### Add an installer that downloads from a URL

Add `Url` plus the save location in `Path`. If the file is missing, the script downloads it first, then runs it:

```json
{
  "Name": "Microsoft Office Home Business 2024 (Francais)",
  "Path": "Installers\\Office_HomeBusiness2024_FR_x64.exe",
  "Url": "https://c2rsetup.officeapps.live.com/c2r/download.aspx?ProductreleaseID=HomeBusiness2024Retail&platform=x64&language=fr-fr&version=O16GA",
  "Arguments": [],
  "Enabled": true
}
```

The menu shows `[WILL DOWNLOAD]` for these until the file exists.

- `Path` can be relative (as above) or absolute (`C:\Tools\MyApp.exe`).
- `Arguments` are passed to the installer. Leave `[]` for default / interactive install.
- For silent MSI install:
  ```json
  {
    "Name": "My MSI App",
    "Path": "Installers\\MyApp.msi",
    "Arguments": ["/qn", "/norestart"],
    "Enabled": true
  }
  ```
  (`.msi` files run via `msiexec /i`)

> Tip: only use installers you trust. Silent switches depend on the vendor — don't assume `/quiet` works everywhere.

### Microsoft Office

The shipped entry downloads the French Microsoft 365 / Office Home & Business 2024 bootstrapper on first use:

```json
{
  "Name": "Microsoft Office Home Business 2024 (Francais)",
  "Path": "Installers\\Office_HomeBusiness2024_FR_x64.exe",
  "MatchName": "Microsoft Office Home and Business 2024",
  "Url": "https://c2rsetup.officeapps.live.com/c2r/download.aspx?ProductreleaseID=HomeBusiness2024Retail&platform=x64&language=fr-fr&version=O16GA",
  "Arguments": [],
  "Enabled": true
}
```

- `MatchName` lets **Check versions and updates** find the Add/Remove Programs entry, whose vendor name includes "and" and a language suffix.
- To use a different Office edition, change `ProductreleaseID` and `language` in the URL (or point `Path` at your own `OfficeSetup.exe`). The installer also needs `MatchName` if its registered name differs from `Name`.
- The script launches it as-is. Unattended install depends on your specific Office installer.
- Activation still needs a valid license / Microsoft 365 account — this script does not bypass licensing.

### OrbitConvert

OrbitConvert has no Winget package, so the shipped entry downloads its MSI from GitHub releases:

```json
{
  "Name": "OrbitConvert",
  "Path": "Installers\\OrbitConvert-0.3.7-win-x64.msi",
  "MatchName": "OrbitConvert",
  "Url": "https://github.com/AbdlrhmanDev/OrbitConvert/releases/download/v0.3.7/OrbitConvert-0.3.7-win-x64.msi",
  "Arguments": ["/qn", "/norestart"],
  "Enabled": true
}
```

- The download (~92 MB) is cached at `Path` and reused on later runs.
- The MSI installs per-user and does not require administrator rights. OrbitConvert updates itself from **Settings → Updates**, so the catalog reports `Manual` for this entry like any other local installer.
- Release file names contain the version. To ship a newer build, change both `Path` and `Url` to the matching asset; Windows on ARM can use the `win-arm64.msi` release.
- Releases are unsigned for now, so SmartScreen may warn about an unknown publisher.

### 🖨️ Printers (option 4)

Option 4 opens a submenu: **1 = install** a printer, **2 = list** installed printers, **3 = rename** a printer, **0 = back**.

Install asks: **manufacturer → printer IP/hostname → port (Enter = 9100) → printer name** (default: `<manufacturer> <IP>`). It creates a local TCP/IP port (`TCP_<IP>`) and installs the printer on this PC. List shows name, driver, port, status and the default printer. Rename lists printers by number and renames the one you pick.

Driver presets live in the `PrinterDrivers` array in `Software.json`. The current list is:

1. Konica Minolta (Universal V4 PCL)
2. Xerox (Global Print Driver PCL6)
3. Epson (Universal Print Driver)

```json
{
  "Make": "Konica Minolta (Universal V4 PCL)",
  "DriverHint": "KONICA MINOLTA Universal V4 PCL",
  "Path": "Drivers\\konika_minolta",
  "Url": "",
  "Enabled": true
}
```

- `Path` is a folder holding the extracted driver (`.inf` + `.cat` + `.dll`). If the folder is missing (typical in online mode), the script downloads it from the repository into `C:\ProgramData\Windows_Auto_Setup_Online\Drivers\<folder>` automatically, verifies every file size, and reuses it on later runs. If the driver is already installed, no download is needed at all.
- Packages with architecture subfolders are supported (Epson stores files in `WINX64\SETUP\...`); on a 64-bit PC the x86 and ARM64 copies are skipped to save download size.
- Or set `Url` to a direct driver ZIP link and the script downloads + extracts it.
- Or type an `.inf` path directly when asked.
- The driver is imported with `pnputil`, and its real name is auto-detected (works on French and English Windows). `DriverHint` is only a fallback.
- Set `"Enabled": false` to hide a manufacturer without deleting it.

### Manage local users (option 5)

Option 5 opens a submenu: **1 = list** all local users (enabled state + member-of groups), **2 = rename** any user (same 20-char/character rules, profile folder untouched), **3 = change password** (hidden input, min 8 chars, must confirm), **4 = groups** (pick a user, then add to or remove from any local group — groups are listed by their real localized names, e.g. `Administrateurs` on French Windows), **5 = enable or disable** a user (the account flag only: profile, files and password are kept, and the user can sign in again once re-enabled). The window exposes the same action as an **Enable**/**Disable** button on each row.

Safety: if only one enabled administrator is left on the PC, its group membership and its enabled state are completely frozen — the script refuses any change to it (no override). The account you are signed in with can never be disabled from this session either, so a mistaken click cannot lock you out. Create or enable another admin, and disable the other account from a different administrator session.

---

## 🔒 Important security notes

> Please read this before using option 1 on real machines.

- The script never contains a hardcoded password. You enter the Administrator password yourself during setup (input is hidden, minimum 8 characters, must confirm). No password is stored in the repo.
- Use a **unique, strong password per machine**, especially on business or internet-exposed PCs. Example to change it later:
  ```powershell
  net user Administrator "Your-New-Strong-Password"
  ```
- The script finds the built-in account by its SID ending in `-500`, even if Windows renamed it.
- Rename (option 2) works only for **local** accounts, not domain / Entra ID accounts.
- Rename does **not** rename the profile folder (`C:\Users\OldName`). Do not rename that folder manually — it breaks the profile. A sign-out/restart may be needed for the new name to show everywhere.

---

## 🛠️ Troubleshooting

| Problem | Fix |
|---------|-----|
| `winget is not available` | Install/update **App Installer** from https://aka.ms/getwinget, then rerun. Local installers still work without Winget. |
| App shows wrong version / fails | Verify the Winget ID with `winget search <name>` and update `Software.json`. Vendors rename IDs sometimes. |
| Checker says `Not installed` but the app is there | The Add/Remove Programs name differs from the catalog name. Add `"MatchName": "<exact registered name>"` to the entry, or set it to a distinctive prefix. Per-user installs are checked too, but portable apps with no uninstall entry cannot be detected. |
| No update shown for an installed app | Winget only reports updates for IDs it recognises. Compare `winget list --id <id> --exact` with the catalog ID; if Winget shows a different ID (for example `Google.Chrome.Beta.EXE`), update `Software.json` or update the app manually. An app installed outside Winget (Chrome from its MSI, for example) is still compared with the version published by the Winget source and shows `Up to date` when it matches. Local installers never show an update. |
| **Update** / **Uninstall** stays disabled | Click **Check versions and updates** first and tick an installed application. Update needs an available Winget update; Uninstall needs a Winget-managed package or an Add/Remove Programs entry. A pinned entry has no update by design. |
| A pinned app is never updated | That is intentional: `Version` holds the entry on one release. Remove the `Version` field from `Software.json`, click **Check versions and updates**, then **Update selected** to follow the latest release again. |
| Version dropdown is empty or only shows `Latest` | Click the recycle icon beside the dropdown (that application only) or **Check versions and updates** (all applications). If it stays empty, check the Winget ID and the Internet connection, then run `winget show <id> --exact --source winget --versions` in a terminal. Offline checks keep the previously loaded list. |
| `--version` install fails | The requested version is no longer in the Winget source. Click the recycle icon beside the dropdown (or **Check versions and updates** for every application) and pick a version from the refreshed list, run `winget show <id> --versions` to check by hand, or use a `LocalInstallers` entry with the vendor's archive URL for anything older. |
| Uninstall fails or leaves the app behind | Run the window as administrator, check the **Log** tab, and use Windows **Settings → Apps** if the vendor's uninstaller requires interaction. The script uses `QuietUninstallString` when available, then `UninstallString`. |
| `Software.json could not be parsed` | You broke the JSON (missing comma/quote). Validate it at https://jsonlint.com |
| Local installer `FILE NOT FOUND` | Check the `Path` in `Software.json` — relative to the script folder. |
| Logo missing / letter tile shown | Check the `Logo` path in `Software.json` (relative to the scripts) and that the file is a PNG the window can read. Online mode downloads logos best-effort; a failed download falls back to the initial tile and does not block the install. |
| Nothing happens after double-click | Right-click `Run-Setup.bat` → **Run as administrator**, and approve UAC. Check `Logs\gui-*.log`. For the text menu, run `Run-Setup.bat console` in a Command Prompt. |
| `Failed when opening sources` / exit `1978335217` | Corrupt Winget source DB (the script now auto-resets once). Manual fix: `winget source reset --force`, then `winget source update`, then rerun. Update App Installer: https://aka.ms/getwinget. If logged in as built-in Administrator, try a regular admin account instead. |
| Installer hash mismatch (can't override as admin) | Stale Winget manifest. The script now falls back to the vendor's direct download when `FallbackUrl` is set (Chrome included). Or wait a day and rerun after `winget source update`. |
| Printer: driver did not register | `pnputil` "already exists" results are accepted automatically; a real failure prints its output. Check the INF matches this Windows (x64 `NTamd64`), or let the `printui` fallback run. |
| Printer: no driver presets | Enable entries in `PrinterDrivers` in `Software.json`, or type an `.inf` path when asked. |
| Password change rejected | Windows complexity policy may have refused it (or the account is not local). Try a longer password with mixed case, digits and symbols. |
| New username doesn't show | Sign out and back in, or restart. |
| Window doesn't open | The window needs WPF, which is part of Windows 10/11. Check `Logs\gui-*.log`; if the file is empty, run `powershell.exe -Sta -File .\Install-MyPC.Gui.ps1` from a console to see the error. |
| Window opens behind other windows | Approve the UAC prompt first: the elevated window cannot take focus while UAC is waiting. Click the taskbar entry if needed. |
| GUI install does nothing | Check the **Log** tab: a task that never starts usually means a missing `Setup.Core.psm1` next to `Install-MyPC.Gui.ps1`. |
| **Open console** reports a missing file | Keep `Install-MyPC.ps1` next to `Install-MyPC.Gui.ps1`. Re-extract the kit, or use `Run-Setup.bat console` from the full folder. |

Logs are in `Logs\setup-YYYYMMDD-HHMMSS.log` for the console and `Logs\gui-YYYYMMDD-HHMMSS.log` for the window.

---

## 🗺️ Future updates

These controls are deliberately **not** in the current version. They change security, connectivity or boot behaviour, so they are planned for later releases with their own confirmations and rollback path:

- **Windows features**: .NET 3.5, WSL, Hyper-V, Windows Sandbox, long paths, Developer Mode, RDP and SMB1.
- **Privacy and debloat**: telemetry/advertising toggles and removal of built-in apps.
- **Services panel**: start mode changes for Windows services.
- **Windows Update control**: pause updates, driver-update toggle and forced installs.
- **Network addressing**: static IP and proxy configuration (only DNS presets are available today).
- **Regional settings**: region and keyboard layouts.
- **Disk Cleanup**: scheduled cleanup tasks.

Nothing in the current System tab or maintenance menu depends on these items.

---

## 🤝 Contributing

Found a bad Winget ID or want to add a useful app? Pull requests welcome:

1. Fork the repo
2. Edit `Software.json` / scripts
3. Test on a Windows 10/11 VM if possible
4. Open a PR with what you changed and why

---

## 📄 License

MIT — free to use and modify. See [LICENSE](LICENSE) if added.

## 🔗 References

- Winget install: https://learn.microsoft.com/en-us/windows/package-manager/winget/install
- Office Deployment Tool: https://learn.microsoft.com/en-us/microsoft-365-apps/deploy/overview-office-deployment-tool
