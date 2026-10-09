// swift-tools-version:5.9
// Linux test build only. The app itself builds from Libre.xcodeproj and uses CryptoKit.
// On Linux, CryptoKit is not available, so the pure-Swift core is tested against Apple's
// open-source swift-crypto (module `Crypto`, Apache 2.0), which has the same API.
import PackageDescription

let package = Package(
    name: "PasaCoreTests",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "PasaCoreTests",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            path: ".",
            sources: ["Libre/Sources/Core", "Libre/Sources/AI", "Tests/CoreTests"]
        ),
    ]
)
