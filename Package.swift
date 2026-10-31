// swift-tools-version:5.10
// For editors. Build with scripts/build.sh: SwiftPM fails to link manifests with some
// Command Line Tools installs, so the script calls swiftc directly.
import PackageDescription

let package = Package(
    name: "Notchmaxx",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notchmaxx",
            path: "Sources/Notchmaxx",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
