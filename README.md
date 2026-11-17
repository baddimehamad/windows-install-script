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

Prefer a real window instead of the console menu? Same command, one flag:

```powershell
$env:SETUP_GUI=1; irm https://tinyurl.com/27wv3wmc | iex
```

---

## 🪟 Window mode (GUI)

Both front-ends do exactly the same things; pick whichever you prefer.

- **Console:** `Run-Setup.bat` or the one-liner above.
- **Window:** `Run-Setup-Gui.bat`, or `.\Install-MyPC.Gui.ps1`, or the `SETUP_GUI=1` one-liner.

The window has five tabs:

| Tab | What you can do |
|-----|-----------------|
| **Software** | Filter the list, tick applications, then **Install selected**. Each row shows `Ready`, `Will download`, `File missing`, `Installing...`, `Installed`, `Installed (restart)`, `Skipped` or `Failed`. |
| **Printers** | Pick a manufacturer, type the IP/hostname, port and optional name, then **Install printer**. The right-hand list shows installed printers and lets you rename one. |
| **Users** | Rename a local account, change its password, or add/remove group membership. The only enabled administrator is marked `LAST ADMIN - LOCKED` and cannot be changed. |
| **Account** | Enable the built-in Administrator (password typed twice, never stored), or rename the account you are signed in with. |
| **Log** | Live progress from the current install, with **Copy**, **Open folder** and **Clear**. |

Notes:

- **Nothing to install.** The window uses WPF and Windows PowerShell 5.1, both part of Windows 10 and 11. No PowerShell 7, no .NET download, no Python.
- **English or French, automatically.** The window follows the Windows display language: French on a French PC, English everywhere else. Set `SETUP_UI_LANG=en` or `SETUP_UI_LANG=fr` before launching to force one. Log lines stay in English, like the console log. French text is written without accented characters so the scripts remain plain ASCII and safe on any Windows code page.
- **Same elevation.** The window relaunches itself with UAC on start, and still passes the original user's SID, so "rename signed-in user" targets the right account.
- **The window never freezes.** Installs run in a background runspace; a **Cancel** button appears in the status bar while something is running.
- **Logs:** `Logs\gui-YYYYMMDD-HHMMSS.log`, one per window session.
- The GUI does **not** write `Software.json` — it is read-only. Edit the file by hand to change the catalog.
- Closing the window during an install asks for confirmation; a child installer (winget, msiexec) may keep running in the background.

---

## ✨ What it does

When you run the console version you get a main menu; the window version exposes the same actions as tabs.

| # | Action | Description |
|---|--------|-------------|
| 1 | **Enable built-in Administrator** | Enables the hidden Administrator account (SID ending in `-500`, so `Administrator` or `Administrateur`) and prompts you to enter a new password. Type `YES`/`OUI` (any case) to confirm. |
| 2 | **Rename current local user** | Renames the local account you were signed in with (name + display name). Does **not** rename `C:\Users\OldName`. |
| 3 | **Install software** | Shows a numbered list from `Software.json`. Install only what you pick, e.g. `1,3,5`, or `A` for all, `0` to skip. |
| 4 | **Printers** | Submenu: install a printer (pick manufacturer, then IP/hostname, port, name), list installed printers (driver, port, status, default), or rename any printer. |
| 5 | **Users** | Submenu: list local users (with member-of groups), rename any user, change any user's password, or change group membership (add/remove, e.g. Administrators). The only enabled administrator is fully locked: its group membership cannot be changed at all. |
| 6 | **Run all** | Runs 1 + 2 + 3 + 4 + 5 in order. |
| 0 | **Exit** | Exit without further changes. |

After each step finishes you return to this menu: press **Enter** for home, or `0` to exit.

You can also combine options, e.g. `1,3`.

### 📦 Default software list

All installed via [Winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/), except Office:

1. Google Chrome
2. Mozilla Firefox
3. 7-Zip
4. VLC media player
5. Adobe Acrobat Reader
6. Notepad++
7. Visual Studio Code
8. Git
9. Microsoft PowerToys
10. Zoom Workplace
11. WhatsApp
12. LibreOffice
13. Microsoft Office (`OfficeSetup.exe` — you provide the file, see below)
14. Microsoft Office Home Business 2024 (Français) — auto-downloaded from Microsoft (~7 MB Click-to-Run setup)

> The numbers are generated from entries with `"Enabled": true` in `Software.json`. Disable/add an entry and the numbers shift automatically.

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
3. **Run:** double-click **`Run-Setup.bat`** (console) or **`Run-Setup-Gui.bat`** (window) → approve the UAC prompt.
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

This downloads 3 small files (`Install-MyPC.ps1`, `Setup.Core.psm1` + `Software.json`, ~100 KB) to a staging folder and starts the setup. Add `Setup-Online.ps1 -Gui` (or set `$env:SETUP_GUI=1`) to also download and open the window version. Approve the UAC prompt when it appears.

> Note: local-only files are not downloaded up front: `OfficeSetup.exe` and `Installers/` content show `FILE NOT FOUND` unless they carry a `Url` (downloaded on demand, e.g. French Office, Chrome fallback) or you copy them in manually. Printer driver folders (`Drivers/`) **are fetched automatically on demand** into `C:\ProgramData\Windows_Auto_Setup_Online\Drivers` the first time you install a printer (cached for later runs). Winget apps work normally.

Example session:

```text
========================================================
              WINDOWS AUTOMATIC SETUP
========================================================
Choose what you want to do:
  1. Enable built-in Administrator and set a new password (you will enter it)
  2. Rename the currently signed-in local user account
  3. Choose software to install from a numbered list
  4. Printers (install / list / rename)
  5. Users (list / rename / password / groups)
  6. Run all options (1+2+3+4+5)
  0. Exit

Enter option number(s): 1,3

SOFTWARE LIST — enter numbers separated by commas (example: 1,3,5).
Enter A to select all enabled items, or 0 to skip software installation.
  1. [Winget] Google Chrome — Winget ID: Google.Chrome
  2. [Winget] Mozilla Firefox — Winget ID: Mozilla.Firefox
  ...
Software numbers: 1,3,5
```

---

## 📁 What's in the folder?

```text
windows-install-script/
├── Run-Setup.bat      ← double-click to start (console menu)
├── Run-Setup-Gui.bat  ← double-click to start (window)
├── Install-MyPC.ps1   ← console front-end (auto-elevates to admin)
├── Install-MyPC.Gui.ps1 ← window front-end (auto-elevates to admin)
├── Setup.Core.psm1    ← shared logic used by both front-ends
├── Setup-Online.ps1   ← web launcher for `irm ... | iex`
├── Software.json      ← edit this to add/remove apps
├── Installers/        ← optional folder for your own .exe / .msi files
│   └── README.txt
├── Drivers/           ← printer driver folders (konika_minolta, xerox, epson)
│   └── README.txt
└── Logs/              ← created automatically, one log per run
```

- **`Run-Setup.bat`** — launcher that runs the console script with bypassed execution policy and pauses so you can read the result.
- **`Run-Setup-Gui.bat`** — launcher for the window version; it starts detached, so no console window stays open.
- **`Install-MyPC.ps1`** — console front-end: prompts, menus and colours.
- **`Install-MyPC.Gui.ps1`** — window front-end (WPF, embedded XAML).
- **`Setup.Core.psm1`** — every action (Winget, local installers, printers, users, Administrator). Both front-ends call it, so a fix applies to both. It never prompts and never writes to the console.
- **`Software.json`** — the only file you normally need to edit.

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

### Add your own `.exe` / `.msi` installer

1. Put the file in the `Installers/` folder (or next to the script).
2. Add an entry to `LocalInstallers` in `Software.json`:

```json
{
  "Name": "My Custom App",
  "Path": "Installers\\MyCustomAppSetup.exe",
  "Arguments": [],
  "Enabled": true
}
```

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

### Microsoft Office (`OfficeSetup.exe`)

Default entry in `Software.json`:

```json
{
  "Name": "Microsoft Office (OfficeSetup.exe)",
  "Path": "OfficeSetup.exe",
  "Arguments": [],
  "Enabled": true
}
```

- Copy `OfficeSetup.exe` next to the scripts. The menu shows `[FILE NOT FOUND]` until it's there.
- The script launches it as-is. Unattended install depends on your specific Office installer.
- Activation still needs a valid license / Microsoft 365 account — this script does not bypass licensing.

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

Option 5 opens a submenu: **1 = list** all local users (enabled state + member-of groups), **2 = rename** any user (same 20-char/character rules, profile folder untouched), **3 = change password** (hidden input, min 8 chars, must confirm), **4 = groups** (pick a user, then add to or remove from any local group — groups are listed by their real localized names, e.g. `Administrateurs` on French Windows).

Safety: if only one enabled administrator is left on the PC, its group membership is completely frozen — the script refuses any change to it (no override). Create or enable another admin first.

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
| `Software.json could not be parsed` | You broke the JSON (missing comma/quote). Validate it at https://jsonlint.com |
| Local installer `FILE NOT FOUND` | Check the `Path` in `Software.json` — relative to the script folder. |
| Nothing happens after double-click | Right-click `Run-Setup.bat` → **Run as administrator**, and approve UAC. Check `Logs\setup-*.log`. |
| `Failed when opening sources` / exit `1978335217` | Corrupt Winget source DB (the script now auto-resets once). Manual fix: `winget source reset --force`, then `winget source update`, then rerun. Update App Installer: https://aka.ms/getwinget. If logged in as built-in Administrator, try a regular admin account instead. |
| Installer hash mismatch (can't override as admin) | Stale Winget manifest. The script now falls back to the vendor's direct download when `FallbackUrl` is set (Chrome included). Or wait a day and rerun after `winget source update`. |
| Printer: driver did not register | `pnputil` "already exists" results are accepted automatically; a real failure prints its output. Check the INF matches this Windows (x64 `NTamd64`), or let the `printui` fallback run. |
| Printer: no driver presets | Enable entries in `PrinterDrivers` in `Software.json`, or type an `.inf` path when asked. |
| Password change rejected | Windows complexity policy may have refused it (or the account is not local). Try a longer password with mixed case, digits and symbols. |
| New username doesn't show | Sign out and back in, or restart. |
| Window doesn't open | The window needs WPF, which is part of Windows 10/11. Check `Logs\gui-*.log`; if the file is empty, run `powershell.exe -Sta -File .\Install-MyPC.Gui.ps1` from a console to see the error. |
| Window opens behind other windows | Approve the UAC prompt first: the elevated window cannot take focus while UAC is waiting. Click the taskbar entry if needed. |
| GUI install does nothing | Check the **Log** tab: a task that never starts usually means a missing `Setup.Core.psm1` next to `Install-MyPC.Gui.ps1`. |

Logs are in `Logs\setup-YYYYMMDD-HHMMSS.log` for the console and `Logs\gui-YYYYMMDD-HHMMSS.log` for the window.

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
