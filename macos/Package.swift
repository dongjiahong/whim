// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Whim",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Whim", targets: ["Whim"])
    ],
    targets: [
        .systemLibrary(
            name: "CWhimCore",
            path: "Sources/CWhimCore"
        ),
        .executableTarget(
            name: "Whim",
            dependencies: ["CWhimCore"],
            path: "Sources/Whim",
            linkerSettings: [
                .unsafeFlags(["-LSources/CWhimCore", "-lwhimcore"]),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
