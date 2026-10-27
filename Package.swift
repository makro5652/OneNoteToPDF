// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OneNoteToPDF",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "OneNoteToPDF", path: "Sources/OneNoteToPDF")
    ]
)
