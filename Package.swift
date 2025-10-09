// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ikyo",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics", from: "1.3.0")
    ],
    targets: [
        .systemLibrary(
            name: "CGLFW",
            path: "Libraries/CGLFW",
            pkgConfig: nil
        ),
        .executableTarget(
            name: "ikyo",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                "CGLFW"
            ],
            path: "Source",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/Users/asdf/work/ikyo/Libraries/CGLFW/bin/lib-arm64"]),
                .linkedFramework("Cocoa"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("OpenGL"),
                .linkedFramework("AppKit")
            ]
        ),
    ]
)
