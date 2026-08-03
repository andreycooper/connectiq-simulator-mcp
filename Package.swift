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
        .testTarget(
            name: "SimulatorMCPCoreTests",
            dependencies: [
                "SimulatorMCPCore",
                .product(name: "MCP", package: "swift-sdk")
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
