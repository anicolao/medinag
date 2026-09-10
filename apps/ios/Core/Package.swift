// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "MediNagCore",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "MediNagCore", targets: ["MediNagCore"]),
    .executable(name: "MediNagCoreChecks", targets: ["MediNagCoreChecks"]),
  ],
  targets: [
    .target(name: "MediNagCore"),
    .executableTarget(
      name: "MediNagCoreChecks",
      dependencies: ["MediNagCore"]
    ),
  ]
)
