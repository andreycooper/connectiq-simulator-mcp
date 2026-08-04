// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "simulator-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "simulator-mcp", targets: ["SimulatorMCP"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        )
    ],
    targets: [
        .target(
            name: "SimulatorMCPCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "SimulatorMCP",
            dependencies: [
                "SimulatorMCPCore",
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        // Test-only fixture. Deliberately not a package product, and placed
        // outside Sources/ so it stays clear of the architecture boundary.
        .executableTarget(
            name: "MemoryHoldFixture",
            path: "Tests/fixtures/MemoryHoldFixture"
        ),
        .testTarget(
            name: "SimulatorMCPCoreTests",
            dependencies: [
                "SimulatorMCPCore",
                "MemoryHoldFixture",
                .product(name: "MCP", package: "swift-sdk")
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
