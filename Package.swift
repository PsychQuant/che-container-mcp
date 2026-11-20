// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheContainerMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CheContainerMCPCore", targets: ["CheContainerMCPCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.0")),
        .package(url: "https://github.com/PsychQuant/che-mcp-kit-swift.git", .upToNextMinor(from: "0.2.0"))
    ],
    targets: [
        // Everything testable lives here: CLI invocation, job store, mounts, tools.
        .target(
            name: "CheContainerMCPCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "CheMCPKit", package: "che-mcp-kit-swift")
            ],
            path: "Sources/CheContainerMCPCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Thin entry point: --version / --help / --cli / MCP stdio.
        .executableTarget(
            name: "CheContainerMCP",
            dependencies: [
                "CheContainerMCPCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "CheMCPKit", package: "che-mcp-kit-swift")
            ],
            path: "Sources/CheContainerMCP"
        ),
        .testTarget(
            name: "CheContainerMCPTests",
            dependencies: ["CheContainerMCPCore"],
            path: "Tests/CheContainerMCPTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
