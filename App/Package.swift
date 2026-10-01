// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ModelPlayground",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ModelPlayground",
            path: "Sources/ModelPlayground",
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        )
    ]
)
