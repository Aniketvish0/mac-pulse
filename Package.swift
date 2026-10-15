// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "macpulse", targets: ["MacPulse"])],
    targets: [
        .executableTarget(
            name: "MacPulse",
            resources: [.copy("Resources/dashboard.html")],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)
