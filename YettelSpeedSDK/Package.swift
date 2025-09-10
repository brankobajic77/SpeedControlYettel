
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YettelSpeedSDK",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "YettelSpeedSDK", targets: ["YettelSpeedSDK"])
    ],
    targets: [
        .target(
            name: "YettelSpeedSDK",
            path: "Sources/YettelSpeedSDK"
        )
    ]
)
