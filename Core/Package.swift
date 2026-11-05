// swift-tools-version: 6.2
import PackageDescription

// DayCore holds the model, the Google client, sync and every rule that turns events into
// text, with Foundation only, so the iPhone app, the widget, the Mac app and day-cli all
// draw from one implementation and the rules can be tested without a simulator.
let package = Package(
    name: "DayCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DayCore", targets: ["DayCore"]),
        .executable(name: "day-cli", targets: ["day-cli"]),
    ],
    targets: [
        .target(name: "DayCore"),
        .executableTarget(name: "day-cli", dependencies: ["DayCore"]),
        // Fixtures/ is copied whole, so recorded Google responses added next to
        // invented-week.json are found through Bundle.module with no change here.
        .testTarget(
            name: "DayCoreTests",
            dependencies: ["DayCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
