// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypelessLite",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TypelessLite", targets: ["TypelessLite"])
    ],
    targets: [
        .executableTarget(
            name: "TypelessLite",
            path: "Sources/TypelessLite"
        ),
        .testTarget(
            name: "TypelessLiteTests",
            dependencies: ["TypelessLite"],
            path: "Tests/TypelessLiteTests"
        )
    ]
)
