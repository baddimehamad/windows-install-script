# Windows Automatic Setup — Improvement Plan

Date: 2026-11-18
Repository: `windows-install-script`
Scope: software catalog growth, new Windows services/options, and deployment improvements.

## Context

The app currently has five GUI tabs — Software, Printers, Users, Account, Log — and a matching console menu. It installs Winget and local software, checks installed versions, offers updates/uninstalls, manages printers and local users, and runs online or from a local checkout.

The catalog currently ships 18 enabled/disabled entries, including PuTTY, WinRAR, NAPS2, Windows Scan and OrbitConvert 0.3.7 (confirmed as the latest release).

### Constraints to preserve

- Windows PowerShell 5.1 and WPF only; no PowerShell 7, .NET download or build step for the tool itself.
- Bilingual English/French strings; `.ps1` files remain plain ASCII.
- The GUI never writes `Software.json`.
- Elevation and `-OriginalUserSid` behavior must keep working.
- The online launcher must keep working.
- Security-sensitive options default to off and require confirmation.

## 1. Software to add

Every entry needs a 128×128 logo, a `logo/README.md` source row, and a README catalog entry. Verify each Winget ID with `winget show <id>` before adding it.

### 1.1 Recommended first wave (general-purpose PCs)

| App | Winget ID | Why |
|---|---|---|
| Brave | `Brave.Brave` | Privacy-focused browser |
| Everything | `voidtools.Everything` | Instant file search |
| SumatraPDF | `SumatraPDF.SumatraPDF` | Light PDF reader |
| ShareX | `ShareX.ShareX` | Screenshots and screen recording |
| KeePassXC | `KeePassXCTeam.KeePassXC` | Offline password manager |
| Bitwarden | `Bitwarden.Bitwarden` | Cloud password manager |
| CrystalDiskInfo | `CrystalDewWorld.CrystalDiskInfo` | Disk health check |
| HWiNFO | `REALiX.HWiNFO` | Hardware inventory/monitoring |
| Rufus | `Rufus.Rufus` | Bootable USB creation |
| AnyDesk | `AnyDeskSoftwareGmbH.AnyDesk` | Remote support |
| Tailscale | `Tailscale.Tailscale` | Simple VPN/mesh |
| Slack or Discord | `SlackTechnologies.Slack` / `Discord.Discord` | Communication |

### 1.2 Runtimes — high value after a clean install

- Visual C++ 2015–2022 x64 and x86: `Microsoft.VCRedist.2015+.x64`, `Microsoft.VCRedist.2015+.x86`
- .NET Desktop Runtime 8: `Microsoft.DotNet.DesktopRuntime.8`
- WebView2 Runtime: `Microsoft.EdgeWebView2Runtime`
- DirectX: `Microsoft.DirectX`
- Java JRE: `EclipseAdoptium.Temurin.21.JRE`

### 1.3 Developer set

Windows Terminal, Node.js LTS, Python 3.13, GitHub Desktop, Postman, DBeaver, Docker Desktop, WSL, Azure CLI, AWS CLI.

PowerShell 7 may be offered only as an optional app; the tool itself stays on Windows PowerShell 5.1.

### 1.4 Security, network and media

VeraCrypt, Malwarebytes, TeamViewer, RustDesk, WireGuard, WinSCP, FileZilla, Wireshark, Nmap, OBS Studio, GIMP, Paint.NET, HandBrake, Audacity, Spotify, OnlyOffice, PDF24.

## 2. New services and options

### A. Safety and reliability — best return on effort

1. **System restore point** before installs or system changes, with clear skip/failure reporting.
2. **Preflight checks** — disk space, Internet, Winget present, elevation, pending reboot, OS build.
3. **Winget bootstrap** — offer to install App Installer/Winget when missing.
4. **SHA256 verification** for downloaded URL installers (new `Sha256` field), plus signature checks.
5. **Retry, proxy and resume/cache** support for downloads.
6. **Report export** — CSV/HTML/JSON of installed, failed and skipped items plus system information.
7. **Dry-run / preview** mode showing every change before anything runs.

### B. New "System" tab / console option

- **Windows Update**: check/install updates via the Windows Update COM API (no PSWindowsUpdate dependency), pause updates, driver-update toggle.
- **Privacy and debloat**: telemetry, ads/tips, Copilot/Recall toggles, remove selected built-in apps — opt-in, with a restore path.
- **Windows features**: .NET Framework 3.5, WSL, Hyper-V, Sandbox, long paths, Developer Mode; RDP and SMB1 only behind strong warnings and default-off.
- **Power**: power plan, sleep/hibernate, fast startup.
- **Network**: DNS presets (Cloudflare/Google/Quad9), DHCP/static IP, flush DNS, proxy, ping/traceroute.
- **Storage**: temp cleanup, Disk Cleanup, Storage Sense, disk-space report.
- **Services panel**: list/start/stop/set startup type with presets, warnings and "restore defaults".
- **Security report**: BitLocker/TPM/Secure Boot status, Windows edition and activation status (read-only, no activation bypass).
- **Locale**: time zone, region, keyboard layouts.

### C. Software management

- **Profiles/presets**: Office, Developer, Technician, Minimal; saved selections.
- **Categories and search** in the software list: Browsers, Runtimes, Security, Dev, Media, etc.
- **Offline bundle builder**: download selected installers and logos to a USB folder for PCs without Internet.
- **Scheduled update task**: weekly Winget upgrade of catalog apps.
- **Bulk actions**: update all, uninstall selected, select filtered results.
- **Install order and dependencies** per entry, plus an optional post-install command.
- **Import/export** a selection as JSON, or generate a `winget import` file.
- **Installed software report** to CSV/HTML with versions and install dates.

### D. Users and printers

- **Users**: create/delete local accounts, password-never-expires and change-at-logon flags, Remote Desktop Users group, guarded auto-login toggle, profile-folder cleanup.
- **Printers**: set default, print test page, delete printer/port/driver, share a printer, restart the spooler.

### E. UX and automation

- Progress per app with estimated time, and a restart prompt when required.
- In-app EN/FR switch, dark theme, remembered window size.
- Export-report button and clearer remediation links for errors.
- Unattended mode: answer file or `-Profile`, `-Yes`, `-WhatIf`, meaningful exit codes.
- Intune/SCCM detection and install scripts.
- Online launcher: version pinning, checksum, retry/resume, proxy, offline fallback.

## 3. Suggested phases

### Phase 1 — quick wins (low risk)

- [ ] Add 12 catalog apps and the runtime set.
- [ ] Create a system restore point before changes.
- [ ] Add preflight checks.
- [ ] Add CSV/HTML report export.
- [ ] Add software categories and selection profiles.
- [ ] Add default-printer and test-page actions.
- [ ] Add create/delete local user actions.

### Phase 2 — medium effort

- [ ] Windows Update panel.
- [ ] Windows features/privacy toggles with backup.
- [ ] Offline bundle builder.
- [ ] SHA256 verification for URL installers.
- [ ] Scheduled update task.
- [ ] Unattended mode and answer file.

### Phase 3 — higher risk

- [ ] Services panel.
- [ ] BitLocker/RDP/domain join.
- [ ] Debloat with a restore path.
- [ ] Install rollback.

## 4. Acceptance criteria

- Both front-ends expose the same new capabilities, or the GUI-only exception is documented.
- All changed `.ps1` files parse under Windows PowerShell 5.1 and remain ASCII.
- GUI language tables cover every new string in EN and FR.
- New catalog entries have a working `winget show` ID, a 128×128 PNG, and a README/logo-source row.
- Safety options are confirmed, logged, and reversible where practical.
- Existing tests (`verify-setup.ps1`, core toggle test, GUI self-test, EN/FR renders) still pass.

## 5. Open questions

1. Start with more software, the System/Windows configuration tab, or profiles/offline deployment?
2. Should the System tab be GUI-only first, or mirrored in the console immediately?
3. Are third-party antivirus/remote-access tools allowed in the default catalog, or should those entries ship disabled?
4. Should settings changes create a restore point automatically, or only on request?
