// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AuvProfile",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AuvProfile", targets: ["AuvProfile"])],
    targets: [
        .executableTarget(name: "AuvProfile"),
        .testTarget(name: "AuvProfileTests", dependencies: ["AuvProfile"])
    ]
)
