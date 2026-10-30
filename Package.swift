// swift-tools-version: 6.0
// sPrint 0.1.0 — written by sPrint's release workflow.
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
            url: "https://github.com/Goodneo-Solutions/sprint-releases/releases/download/0.1.0/CSPrint.xcframework.zip",
            checksum: "512d2ca1ace2fd9c2ab88b7dae383b6fb23d86e3e2a18bfbdfbf4b35c920071b"
        ),
        .target(name: "SPrint", dependencies: ["CSPrint"], path: "Sources/SPrint"),
    ],
    swiftLanguageModes: [.v6]
)
