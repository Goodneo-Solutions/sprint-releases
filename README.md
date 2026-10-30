<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/Goodneo-Solutions/sprint-releases/main/assets/sprint-logo-dark.svg">
  <img src="https://raw.githubusercontent.com/Goodneo-Solutions/sprint-releases/main/assets/sprint-logo.svg" alt="sPrint" height="56">
</picture>

# sPrint

Superroute's printing SDK: find network, USB and Bluetooth printers, detect
their command language (ZPL, TSPL, ESC/POS, CPCL and the vendor dialects),
print labels, PDF, HTML, images and raw bytes, and turn a device into a
Superroute print node — with one engine on every platform.

| Platform | Package |
|---|---|
| Android | Maven repository `https://goodneo-solutions.github.io/sprint-releases/maven`, `ca.superroute:sprint` |
| Swift (iOS 15+, macOS 13+) | Swift Package Manager: `https://github.com/Goodneo-Solutions/sprint-releases`, product `SPrint` |
| Flutter (Android, iOS, macOS, Windows, Linux) | `flutter pub add sprint_flutter` |
| .NET (Windows, macOS, Linux) | `dotnet add package Superroute.SPrint` |
| Python (Linux, macOS, Windows) | `pip install superroute-sprint` |
| C / C++, Go through cgo (Linux, Raspberry Pi, macOS, Windows) | the `sprint-<version>-<os>-<arch>` archives of each [release](https://github.com/Goodneo-Solutions/sprint-releases/releases) |

### Android

```kotlin
// settings.gradle.kts: repositories { maven { url = uri("https://goodneo-solutions.github.io/sprint-releases/maven") } }
dependencies { implementation("ca.superroute:sprint:0.1.0") }

SPrint.init(context)
val printers = PrinterRegistry(File(filesDir, "printers.json").path)
printers.save(TargetPrinter("Labels", "AA:BB:CC:DD:EE:FF", Transports.BLUETOOTH, language = Languages.ZPL))
val result = printers.print(PrintJob(JobTypes.LABEL, label = LabelJob.parse(labelJson)))  // off the main thread
```

### Swift

```swift
import SPrint

let printers = try PrinterRegistry(path: "printers.json")
try printers.save(TargetPrinter(name: "Labels", host: "192.168.1.40", language: Language.zpl))
let label = try LabelJob.parse(labelJSON)
let result = try printers.print(PrintJob(type: JobType.label, label: label))
```

### C

```c
#include "sprint.h"
char *res = sprint_print("{\"name\":\"Labels\",\"host\":\"192.168.1.40\",\"transport\":\"network\",\"language\":\"zpl\"}",
                         "{\"type\":\"raw\",\"data\":\"XlhBXlha\"}");
sprint_free(res);
```

### Go (cgo over the C library)

```go
package main

/*
#cgo CFLAGS: -I${SRCDIR}/sprint/include
#cgo LDFLAGS: -L${SRCDIR}/sprint/lib -lsprint -Wl,-rpath,${SRCDIR}/sprint/lib
#include <stdlib.h>
#include "sprint.h"
*/
import "C"

import (
	"fmt"
	"unsafe"
)

func main() {
	printer := C.CString(`{"name":"Labels","host":"192.168.1.40","transport":"network","language":"zpl"}`)
	job := C.CString(`{"type":"test"}`)
	defer C.free(unsafe.Pointer(printer))
	defer C.free(unsafe.Pointer(job))
	res := C.sprint_print(printer, job) // PrintResult JSON
	defer C.sprint_free(unsafe.Pointer(res))
	fmt.Println(C.GoString(res))
}
```

### Third-party software

On Windows sPrint uses **SumatraPDF 3.5.2** to print PDF documents to a
printer driver. SumatraPDF is a separate program, shipped unmodified next to
sPrint (in the NuGet package) under its own licence, the GNU General Public
License version 3 — see [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) and
[licenses/SumatraPDF-GPL-3.0.txt](licenses/SumatraPDF-GPL-3.0.txt). Its source
code for that version: https://github.com/sumatrapdfreader/sumatrapdf/tree/3.5.2rel.

sPrint is licensed under the [Superroute SDK License](LICENSE).
