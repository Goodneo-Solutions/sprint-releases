// swift-tools-version: 6.0
// sPrint 0.1.1 — written by sPrint's release workflow.
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
            url: "https://github.com/Goodneo-Solutions/sprint-releases/releases/download/0.1.1/CSPrint.xcframework.zip",
            checksum: "84d0287a8d544cf979c7d5a59f0112264c72f127a1058490627d5edc7801ced2"
        ),
        .target(name: "SPrint", dependencies: ["CSPrint"], path: "Sources/SPrint"),
    ],
    swiftLanguageModes: [.v6]
)
