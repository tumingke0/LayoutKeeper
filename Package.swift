// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import PackageDescription
let package = Package(name: "LayoutKeeper", platforms: [.macOS(.v14)], products: [
    .executable(name: "LayoutKeeper", targets: ["SpacePort"]),
    .executable(name: "layoutkeeperctl", targets: ["spaceportctl"])
], dependencies: [
    // Sparkle 2 (MIT) for in-app updates; see THIRD_PARTY_NOTICES.md.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
], targets: [
    .target(name: "LayoutCore"),
    .target(name: "MacAdapters", dependencies: ["LayoutCore"]),
    .target(name: "SpaceProbe", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
    .executableTarget(name: "SpacePort", dependencies: ["LayoutCore", "MacAdapters", "SpaceProbe", .product(name: "Sparkle", package: "Sparkle")]),
    .executableTarget(name: "spaceportctl", dependencies: ["LayoutCore", "MacAdapters"]),
    .testTarget(name: "LayoutCoreTests", dependencies: ["LayoutCore"]),
    .testTarget(name: "MacAdaptersTests", dependencies: ["MacAdapters", "LayoutCore", "SpaceProbe"])
], swiftLanguageModes: [.v5])
