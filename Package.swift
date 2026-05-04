// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XboxVPNHelper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "XboxVPNHelper", targets: ["XboxVPNHelper"])
    ],
    targets: [
        .executableTarget(
            name: "XboxVPNHelper",
            path: "Sources/XboxVPNHelper",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
