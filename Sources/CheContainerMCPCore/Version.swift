import Foundation

/// Version and identity. `mcpServerName` must equal `mcpb/manifest.json` `name`.
public enum AppVersion {
    public static let current = "0.1.0"
    public static let name = "CheContainerMCP"
    public static let mcpServerName = "che-container-mcp"
    public static let displayName = "Apple container MCP Server"

    /// The `container` CLI version the server was tested against.
    public static let testedContainerVersion = "1.7.1"

    public static var versionString: String { "\(name) \(current)" }

    public static var helpMessage: String {
        """
        \(displayName)

        Usage: \(name) [options]
               \(name) --cli <tool> [--key value ...]
               \(name) --cli <tool> '{"key": value}'

        Options:
          --version, -v    Show version information
          --help, -h       Show this help message
          --cli            Run one tool call and print its JSON result

        Runs jobs through Apple's `container` CLI (tested with \(testedContainerVersion)).
        State and config live in ~/Library/Application Support/che-container-mcp/
        (override with CHE_CONTAINER_MCP_HOME).
        """
    }
}
