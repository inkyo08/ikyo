// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ikyo",
    targets: [
        .systemLibrary(
            name: "CGLFW",
            path: "include",
            pkgConfig: "glfw3"
        ),
        .executableTarget(
            name: "ikyo",
            dependencies: ["CGLFW"],
            path: "Source",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(Context.packageDirectory)/Libraries/GLFW/mac/arm64"], .when(platforms: [.macOS])),
                .linkedLibrary("glfw3", .when(platforms: [.macOS])),
                .linkedFramework("Cocoa", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreVideo", .when(platforms: [.macOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
                .unsafeFlags(["-L\(Context.packageDirectory)/Libraries/GLFW/windows/x64"], .when(platforms: [.windows]))
            ]
        ),
    ]
)
