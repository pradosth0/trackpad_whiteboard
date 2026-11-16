// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrackpadBoard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TrackpadBoard", path: "Sources/TrackpadBoard")
    ]
)
