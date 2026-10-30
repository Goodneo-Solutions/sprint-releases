# 0.1.2

## Printing

### Every package except the browser
- **LAN peer printing**: share chosen printers with other devices on the same network and print to theirs, with no server involved. Sharing is off until it is turned on and nothing is shared until each printer is chosen; peers are let in openly, with a password or after approval, approved devices are kept on a trust list that can be revoked at any time, and every device is checked by its own key. Devices find each other on the network, and a connected device's printers can be added to the printer list so print node jobs reach them. Works with SuperPrinter devices on the same network.

# 0.1.1

## Printing

### C
- **C library**: Visual C++ can link the Windows library directly.

### Browser
- **sPrint in the browser**: encode labels in every printer language, preview them, encode image pages and work out a printer's language in the browser, and print to Bluetooth LE, USB and serial printers from Chrome and Edge.

# 0.1.0

## Printing

### Every package
- **Printers and print jobs**: keep printers on the network, USB, Bluetooth and Bluetooth LE or system print queues, and print labels, PDF, HTML, images, raw bytes and a self-test to them in ZPL, TSPL, ESC/POS, CPCL and the HPRT, Xprinter, XPP, PL and TP-108 dialects — byte for byte what the SuperPrinter agent sends.
- **Finding printers**: scan a network for printers and name them by make and model, list system queues, USB, Bluetooth and Bluetooth LE printers, and work out a printer's language from its name, its own device ID or a question that uses no paper.
- **Fallback for labels**: when switched on, a label that cannot go out one way tries the next (the printer's language, the queue, its driver, the label's HTML) and a way that keeps failing is left aside until the printer is back.
- **Print node**: pair a device with Superroute, report its printers and their health, print and acknowledge jobs as soon as they are sent, and answer the Print Nodes page's diagnostics, probe report and scan-confirmed protocol check.

### .NET
- **Superroute.SPrint**: the SDK for .NET 8 on Windows, macOS and Linux, with the native libraries and the Windows helpers for PDF and Bluetooth LE printing included.

### Swift
- **SPrint for macOS**: the SDK as a Swift package for macOS 13 and later, with the print node's events as an asynchronous stream.
- **SPrint for iOS**: the same Swift package on iOS 15 and later, printing to Bluetooth LE printers and drawing PDF and HTML pages on the device.

### Android
- **sPrint for Android**: the SDK for Android 7 and later, with classic Bluetooth, Bluetooth LE and USB printers and PDF and HTML pages drawn on the device.

### Flutter
- **sprint_flutter**: the SDK for Flutter apps on Android, iOS, macOS, Windows and Linux.

### Python
- **superroute-sprint**: the SDK for Python on Linux, macOS and Windows, installed with pip without compiling anything.

### C
- **C library**: the SDK as a shared and static library with one header for macOS, Linux, Raspberry Pi and Windows, usable from C, C++ and Go.

### Windows
- **SumatraPDF notice**: the PDF printing program shipped for Windows comes with its own licence and a notice saying where its source code is.

## Licence

### Every package
- **Superroute SDK License**: the packages are licensed under the Superroute SDK License — see `LICENSE` and [open.superroute.ca/developer/license](https://open.superroute.ca/developer/license).
