// swift-tools-version: 6.0
// Swift package used by xtool (build + install from Windows/WSL or Linux).
// The Mac/Xcode route uses project.yml instead; both share the same sources in Forge/.

import PackageDescription

let package = Package(
    name: "Forge",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Forge", targets: ["Forge"])
    ],
    targets: [
        .target(
            name: "Forge",
            path: "Forge",
            exclude: ["Assets.xcassets"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
