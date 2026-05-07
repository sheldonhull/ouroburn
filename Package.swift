// swift-tools-version: 6.0
import PackageDescription

// NOTE: When running without Xcode (Command Line Tools only), swift-testing's framework lives
// outside the default rpath. The `mise run test` task (or hk pre-push) supplies the necessary
// `-Xswiftc -F` and `-Xlinker -rpath` flags. Putting them in `unsafeFlags` here causes
// `swift test` to silently skip running the test bundle on Swift 6.3, so they must stay on the
// command line. With Xcode installed, the standard `swift test` invocation works without flags.

let package = Package(
    name: "ouroburn",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ouroburn", targets: ["Ouroburn"])
    ],
    targets: [
        .executableTarget(
            name: "Ouroburn",
            path: "Sources/Ouroburn"
        ),
        .testTarget(
            name: "OuroburnTests",
            dependencies: ["Ouroburn"],
            path: "Tests/OuroburnTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
