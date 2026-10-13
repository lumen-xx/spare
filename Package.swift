// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Spare",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Spare", targets: ["Spare"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "SpareCore"),
        .executableTarget(name: "Spare", dependencies: ["SpareCore", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Resources"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "SpareChecks", dependencies: ["SpareCore"], path: "Tests/SpareCoreTests")
    ]
)
