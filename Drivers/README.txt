Place printer driver files here, one subfolder per manufacturer, then check the PrinterDrivers array in ..\Software.json.
Current presets: Drivers\konika_minolta\ (Konica Minolta Universal V4 PCL), Drivers\xerox\ (Xerox Global Print Driver PCL6), Drivers\epson\ (Epson Universal Print Driver).
A vendor package may keep files in architecture subfolders (e.g. Epson uses WINX64\SETUP\...); the installer supports that layout.
Get drivers from the vendor support site, extract the ZIP, and copy the files here (or into the matching preset folder).
Alternatively set the preset's "Url" in Software.json to a direct driver ZIP link and the script will download and extract it.
Online mode also downloads missing preset folders from this repository automatically, into C:\ProgramData\Windows_Auto_Setup_Online\Drivers.
Use only drivers you trust.
