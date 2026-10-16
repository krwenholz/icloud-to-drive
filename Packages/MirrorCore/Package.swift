// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MirrorCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "MirrorCore", targets: ["MirrorCore"]),
    .executable(name: "mirrorctl", targets: ["mirrorctl"]),
  ],
  targets: [
    .target(name: "MirrorCore"),
    .executableTarget(name: "mirrorctl", dependencies: ["MirrorCore"]),
    .testTarget(
      name: "MirrorCoreTests",
      dependencies: ["MirrorCore"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
