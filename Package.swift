// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorkbenchCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WorkbenchCore", targets: ["WorkbenchCore"])],
    targets: [
        .target(name: "WorkbenchCore", path: "Workbench/Networking"),
        .testTarget(name: "WorkbenchCoreTests", dependencies: ["WorkbenchCore"], path: "Tests")
    ]
)
