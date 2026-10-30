// swift-tools-version: 6.0
// sPrint 0.1.5 — written by sPrint's release workflow.
import PackageDescription

let package = Package(
    name: "SPrint",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "SPrint", targets: ["SPrint"]),
    ],
    targets: [
        .binaryTarget(
            name: "CSPrint",
            url: "https://github.com/Goodneo-Solutions/sprint-releases/releases/download/0.1.5/CSPrint.xcframework.zip",
            checksum: "098747196da93ade15c519236b0ac64b0bad9e566ef13f93e51181bce981bd3e"
        ),
        .target(name: "SPrint", dependencies: ["CSPrint"], path: "Sources/SPrint"),
    ],
    swiftLanguageModes: [.v6]
)
