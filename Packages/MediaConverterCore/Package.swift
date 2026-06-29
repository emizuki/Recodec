// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MediaConverterCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MediaConverterCore", targets: ["MediaConverterCore"]),
    ],
    targets: [
        .target(name: "MediaConverterCore"),
        .testTarget(name: "MediaConverterCoreTests", dependencies: ["MediaConverterCore"]),
    ]
)
