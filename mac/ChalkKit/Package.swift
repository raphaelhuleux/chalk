// swift-tools-version:5.9
import PackageDescription

// ChalkKit holds the pure-Foundation logic the shell depends on: the HostPort
// protocol types, the chrome policies, the stores and the fuzzy matcher.
// Keeping it a separate package both enforces that seam (it cannot import
// AppKit or WebKit) and lets it run under `swift test` with only Command Line
// Tools.
let package = Package(
    name: "ChalkKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ChalkKit", targets: ["ChalkKit"]),
    ],
    targets: [
        .target(name: "ChalkKit"),
        .testTarget(name: "ChalkKitTests", dependencies: ["ChalkKit"]),
    ]
)
