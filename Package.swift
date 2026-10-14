// swift-tools-version:5.9
import PackageDescription

// NearSignerCore is platform independent: it builds for iOS (the app), macOS and Linux
// (the `near-signer-sim` device emulator and the unit tests).
// On Apple platforms it uses CryptoKit. On Linux it uses swift-crypto, which exposes the same API.
#if os(Linux)
let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
]
let cryptoDependencies: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto"),
]
#else
let packageDependencies: [Package.Dependency] = []
let cryptoDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "NearSigner",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NearSignerCore", targets: ["NearSignerCore"]),
        .executable(name: "near-signer-sim", targets: ["near-signer-sim"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(name: "NearSignerCore", dependencies: cryptoDependencies),
        .executableTarget(name: "near-signer-sim", dependencies: ["NearSignerCore"]),
        .testTarget(name: "NearSignerCoreTests", dependencies: ["NearSignerCore"]),
    ]
)
