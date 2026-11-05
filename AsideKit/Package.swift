// swift-tools-version: 6.2
import PackageDescription

// AsideKit is the platform-independent heart of Aside: language understanding,
// turn-taking, policy, memory, reasoning and orchestration. It depends only on
// Foundation and Observation so it can be unit-tested anywhere and so every
// Apple-framework integration stays a thin, replaceable adapter in the apps.
let package = Package(
    name: "AsideKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AsideKit", targets: ["AsideKit"]),
    ],
    targets: [
        .target(name: "AsideKit", path: "Sources/AsideKit"),
        .testTarget(name: "AsideKitTests", dependencies: ["AsideKit"], path: "Tests/AsideKitTests"),
    ]
)
