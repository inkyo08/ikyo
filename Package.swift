// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
  // 디버그
  .define("DEBUG", .when(configuration: .debug)),

  // 릴리즈
  .define("RELEASE", .when(configuration: .release)),
  .define("NDEBUG", .when(configuration: .release)),
  .unsafeFlags([
    "-Ounchecked",
    "-whole-module-optimization",
    "-enforce-exclusivity=unchecked",
    "-enable-bare-slash-regex",
    "-cross-module-optimization"
  ], .when(configuration: .release))
]

let package = Package(
  name: "Ikyo",
  products: [
    .executable(name: "Ikyo", targets: ["Game"])
  ],
  targets: [
    .target(
      name: "Common",
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "Game",
      dependencies: ["Common"],
      swiftSettings: swiftSettings
    )
  ]
)