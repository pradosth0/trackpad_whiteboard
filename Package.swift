// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrackpadBoard",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Renders LaTeX natively (used to typeset recognized lines).
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3")
    ],
    targets: [
        .executableTarget(name: "TrackpadBoard",
                          dependencies: [.product(name: "SwiftMath", package: "SwiftMath")],
                          path: "Sources/TrackpadBoard")
    ]
)
