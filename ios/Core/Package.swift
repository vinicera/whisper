// swift-tools-version:5.9
import PackageDescription

// Logica pura (sem UIKit): contratos e sanitizador de fala.
// Testavel com `swift test` no macOS do CI ou no toolchain Swift para Windows.
let package = Package(
    name: "Core",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "Core"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
