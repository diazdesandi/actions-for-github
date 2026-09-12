// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ActionsForGitHub",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "ActionsForGitHub", type: .dynamic, targets: ["ActionsForGitHub"])
    ],
    dependencies: [
        // Local SDK checkout. Swap for the tagged URL before publishing:
        //     .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.5.0")
        .package(path: "../droppykit")
    ],
    targets: [
        .target(
            name: "ActionsForGitHub",
            dependencies: [.product(name: "DroppyKit", package: "DroppyKit")]
        ),
        .executableTarget(
            name: "ActionsForGitHubHarness",
            dependencies: [
                "ActionsForGitHub",
                .product(name: "DroppyKitHarness", package: "DroppyKit")
            ]
        )
    ]
)
