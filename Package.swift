// swift-tools-version: 5.7
import PackageDescription

let package = Package(name: "BatterySaver", platforms: [.macOS(.v12)], products: [
    .executable(name: "BatterySaver", targets: ["BatterySaver"]),
    .executable(name: "battery-saver-helper", targets: ["BatterySaverHelper"])
], targets: [
    .target(name: "SMCBridge", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
    .target(name: "BatteryCore", dependencies: ["SMCBridge"], linkerSettings: [.linkedFramework("IOKit")]),
    .executableTarget(name: "BatterySaver", dependencies: ["BatteryCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]),
    .executableTarget(name: "BatterySaverHelper", dependencies: ["BatteryCore"]),
    .testTarget(name: "BatteryCoreTests", dependencies: ["BatteryCore"])
])
