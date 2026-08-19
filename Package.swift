// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacMute",
    platforms: [.macOS(.v13)],
    targets: [
        // The muting decisions live here, free of CoreAudio, so they can be tested
        // against devices that misbehave the way real ones do.
        .target(name: "MacMuteCore", path: "Sources/MacMuteCore"),
        .executableTarget(name: "MacMute", dependencies: ["MacMuteCore"], path: "Sources/MacMute"),
        .testTarget(name: "MacMuteCoreTests", dependencies: ["MacMuteCore"],
                    path: "Tests/MacMuteCoreTests"),
    ]
)
