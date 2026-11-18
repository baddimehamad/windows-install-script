# Application logos

Small icons shown next to each application in the window front-end
(`Install-MyPC.Gui.ps1`).

Each `Software.json` entry names its image with a `Logo` field:

```json
"Logo": "logo/chrome.png"
```

The path is relative to the script folder. An absolute path also works.
If the field is missing, or the file cannot be loaded, the window shows a
colored tile with the application's first letter instead. A bad logo never
blocks an install.

## Adding your own logo

1. Put a PNG in this folder (square, transparent background recommended).
2. Point the entry at it in `Software.json`:

   ```json
   {
     "Name": "My Application",
     "Type": "winget",
     "Id": "Publisher.PackageId",
     "Logo": "logo/my-application.png",
     "Enabled": true
   }
   ```

3. Rerun the window. No build step or registration is needed.

## Format of the bundled files

- PNG, 128 x 128 pixels, transparent background.
- Original artwork was scaled to fit inside the canvas with its aspect ratio
  preserved and centered; nothing was cropped or recolored.
- The window draws them at 28 x 28 pixels.

## Sources

Most files come from Wikimedia Commons. Several come from the vendors'
public repositories because Commons did not host a suitable square icon.
The Windows Scan glyph comes from the Microsoft Store listing and was
placed on a blue tile so the white artwork stays visible on the window's
white rows.

| File | Source |
|------|--------|
| `chrome.png` | [Google Chrome icon (February 2022)](https://commons.wikimedia.org/wiki/File:Google_Chrome_icon_(February_2022).svg) |
| `firefox.png` | [Firefox logo, 2019](https://commons.wikimedia.org/wiki/File:Firefox_logo,_2019.svg) |
| `7zip.png` | [7-Zip Icon](https://commons.wikimedia.org/wiki/File:7-Zip_Icon.svg) |
| `vlc.png` | [VLC Icon](https://commons.wikimedia.org/wiki/File:VLC_Icon.svg) |
| `acrobat-reader.png` | [Adobe Acrobat Reader icon (2020)](https://commons.wikimedia.org/wiki/File:Adobe_Acrobat_Reader_icon_(2020).svg) |
| `notepad-plus-plus.png` | [Notepad plus plus](https://commons.wikimedia.org/wiki/File:Notepad_plus_plus.svg) |
| `visual-studio-code.png` | [Visual Studio Code 1.35 icon](https://commons.wikimedia.org/wiki/File:Visual_Studio_Code_1.35_icon.svg) |
| `git.png` | [Git icon](https://commons.wikimedia.org/wiki/File:Git_icon.svg) |
| `powertoys.png` | [microsoft/PowerToys (256 px app icon)](https://github.com/microsoft/PowerToys/blob/main/doc/images/icons/PowerToys%20icon/PNG/PowerToysAppList.targetsize-256.png) |
| `zoom.png` | [Zoom meeting app icon](https://commons.wikimedia.org/wiki/File:Zoom_meeting_app_icon.png) |
| `whatsapp.png` | [WhatsApp Logo green](https://commons.wikimedia.org/wiki/File:WhatsApp_Logo_green.svg) |
| `libreoffice.png` | [LibreOffice/core main.png](https://github.com/LibreOffice/core/blob/master/sysui/desktop/icons/hicolor/256x256/apps/main.png) |
| `microsoft-office.png` | [Microsoft 365 (2022)](https://commons.wikimedia.org/wiki/File:Microsoft_365_(2022).svg) |
| `winrar.png` | [WinRAR icon](https://commons.wikimedia.org/wiki/File:WinRAR_icon.svg) |
| `naps2.png` | [cyanfish/naps2 favicon.ico](https://github.com/cyanfish/naps2/blob/master/NAPS2.Lib/Icons/favicon.ico) |
| `windows-scan.png` | [Windows Scan Store listing](https://apps.microsoft.com/detail/9wzdncrfj3pv); white glyph placed on a blue tile for contrast |

## Trademarks

Application names and logos are trademarks or registered trademarks of their
respective owners. They are used here only to identify the software being
installed. This project is not affiliated with, sponsored by, or endorsed by
any of those companies.

The files are redistributed for convenience under the terms attached to each
source page. Check the source page before reusing an image outside this
project.
