// swift-tools-version:5.9
import PackageDescription

// ChalkKit holds the host-agnostic, UIKit-free logic the shell depends on:
// the HostPort protocol types, the quick-open fuzzy matcher, and journal naming.
// Keeping it a separate package both enforces that seam (it cannot import UIKit
// or WebKit) and lets it run under `swift test` with only Command Line Tools.
let package = Package(
    name: "ChalkKit",
    platforms: [
        .iOS(.v17),
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
