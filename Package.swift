// swift-tools-version: 5.9
import PackageDescription

// Binary-only distribution of the LinkTrail iOS SDK. Consumers get the compiled
// XCFramework (public API via .swiftinterface) — no source. The source lives in a
// separate private repository.
let package = Package(
    name: "LinkTrail",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "LinkTrailSDK", targets: ["LinkTrailSDK"]),
    ],
    targets: [
        .binaryTarget(
            name: "LinkTrailSDK",
            path: "LinkTrailSDK.xcframework"
        ),
    ]
)
