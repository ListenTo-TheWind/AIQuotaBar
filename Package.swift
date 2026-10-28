// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIQuotaBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AIQuotaBar", targets: ["AIQuotaBar"])],
    targets: [
        .executableTarget(name: "AIQuotaBar"),
        .testTarget(name: "AIQuotaBarTests", dependencies: ["AIQuotaBar"]),
    ]
)
