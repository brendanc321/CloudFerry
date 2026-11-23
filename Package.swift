// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudFerry",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CloudFerry",
            path: "Sources/CloudFerry"
        )
    ],
    swiftLanguageModes: [.v5]
)
