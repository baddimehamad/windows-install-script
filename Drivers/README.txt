Place printer driver files here, one subfolder per manufacturer, then check the PrinterDrivers array in ..\Software.json.
Example: Drivers\KonicaMinolta_UPD\  containing the extracted Konica Minolta Universal PCL6 driver (*.inf + .cat + .dll files).
Get it from the vendor support site (Konica Minolta Download Centre -> your model or "Universal Print Driver PCL6"), extract the ZIP, and copy the files here.
Alternatively set the preset's "Url" in Software.json to a direct driver ZIP link and the script will download and extract it.
Use only drivers you trust.
