// swift-tools-version: 6.0
// sPrint 0.1.6 — written by sPrint's release workflow.
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
            url: "https://github.com/Goodneo-Solutions/sprint-releases/releases/download/0.1.6/CSPrint.xcframework.zip",
            checksum: "7ca105c7b420ae25ea75ede318ae16d463fa253462070cec348f10e4935da672"
        ),
        .target(name: "SPrint", dependencies: ["CSPrint"], path: "Sources/SPrint"),
    ],
    swiftLanguageModes: [.v6]
)
