// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WriteWatch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CNVMeSMART",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "WriteWatchCore"),
        .executableTarget(name: "WriteWatchHelper"),
        .executableTarget(name: "WriteWatch", dependencies: ["CNVMeSMART", "WriteWatchCore"]),
        .testTarget(name: "WriteWatchCoreTests", dependencies: ["WriteWatchCore"]),
    ]
)
