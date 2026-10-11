// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import PackageDescription
let package = Package(name: "LayoutKeeper", platforms: [.macOS(.v14)], products: [
    .executable(name: "LayoutKeeper", targets: ["SpacePort"]),
    .executable(name: "layoutkeeperctl", targets: ["spaceportctl"])
], targets: [
    .target(name: "LayoutCore"),
    .target(name: "MacAdapters", dependencies: ["LayoutCore"]),
    .target(name: "SpaceProbe", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
    .executableTarget(name: "SpacePort", dependencies: ["LayoutCore", "MacAdapters", "SpaceProbe"]),
    .executableTarget(name: "spaceportctl", dependencies: ["LayoutCore", "MacAdapters"]),
    .testTarget(name: "LayoutCoreTests", dependencies: ["LayoutCore"]),
    .testTarget(name: "MacAdaptersTests", dependencies: ["MacAdapters", "LayoutCore", "SpaceProbe"])
], swiftLanguageModes: [.v5])
