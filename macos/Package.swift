// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HEICConverter",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "HEICConverter", targets: ["HEICConverter"])],
    targets: [
        .target(name: "ConverterKit"),
        .executableTarget(name: "HEICConverter", dependencies: ["ConverterKit"]),
        .testTarget(name: "ConverterKitTests", dependencies: ["ConverterKit"]),
        .testTarget(name: "HEICConverterTests", dependencies: ["HEICConverter", "ConverterKit"]),
    ]
)
