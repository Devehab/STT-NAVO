// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Navo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Navo", targets: ["Navo"]),
    ],
    targets: [
        .executableTarget(
            name: "Navo",
            path: "Sources/Navo",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
