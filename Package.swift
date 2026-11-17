// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Injectosh",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Injectosh", targets: ["Injectosh"])],
    targets: [
        .executableTarget(
            name: "Injectosh",
            resources: [.copy("Resources/InjectoshInjector.exe")]
        )
    ]
)
