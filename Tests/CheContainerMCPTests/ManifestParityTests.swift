import Foundation
import Testing
@testable import CheContainerMCPCore

struct ManifestParityTests {
    func manifest() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("mcpb/manifest.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func `Manifest tools equal tools/list`() throws {
        let tools = try #require(try manifest()["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ToolCatalog.names)
    }

    @Test func `Manifest name and version match the server identity`() throws {
        let m = try manifest()
        #expect(m["name"] as? String == AppVersion.mcpServerName)
        #expect(m["version"] as? String == AppVersion.current)
    }
}
