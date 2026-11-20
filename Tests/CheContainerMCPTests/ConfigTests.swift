import Foundation
import Testing
@testable import CheContainerMCPCore

struct ConfigTests {
    @Test func `No file means built-in defaults`() throws {
        let dir = try TempDir()
        let config = try ServerConfig.load(from: StatePaths(root: dir.url))
        #expect(config == .builtIn)
        #expect(config.cpus == 8 && config.memory == "16G")
        #expect(config.sourceMount == "/src" && config.outputMount == "/out" && config.effectiveWorkdir == "/src")
    }

    @Test func `Valid file overrides defaults`() throws {
        let json = #"{"container_path":"/x/container","docker_path":"/x/docker","defaults":{"source_dir":"/a","output_dir":"/b","cpus":4,"memory":"8G","source_mount":"/code","output_mount":"/results","workdir":"/code/sub"}}"#
        let config = try ServerConfig.parse(Data(json.utf8))
        #expect(config.containerPath == "/x/container" && config.dockerPath == "/x/docker")
        #expect(config.sourceDir == "/a" && config.outputDir == "/b")
        #expect(config.cpus == 4 && config.memory == "8G")
        #expect(config.sourceMount == "/code" && config.outputMount == "/results" && config.effectiveWorkdir == "/code/sub")
    }

    @Test(arguments: ["{not json", #"{"defaults":{"cpus":"8"}}"#, #"{"defaults":{"cpus":true}}"#, #"{"defaults":[]}"#, #"{"container_path":3}"#, "[]"])
    func `Malformed config is config_invalid`(text: String) {
        let error = #expect(throws: ContainerMCPError.self) { try ServerConfig.parse(Data(text.utf8)) }
        #expect(error?.kind == .configInvalid)
    }

    @Test func `Bad file on disk is config_invalid, not a fallback`() throws {
        let dir = try TempDir()
        try Data("{oops".utf8).write(to: StatePaths(root: dir.url).configFile)
        #expect(throws: ContainerMCPError(.configInvalid, "config.json is not a JSON object")) {
            try ServerConfig.load(from: StatePaths(root: dir.url))
        }
    }

    @Test func `State root honours CHE_CONTAINER_MCP_HOME`() {
        #expect(StatePaths.resolve(environment: ["CHE_CONTAINER_MCP_HOME": "/tmp/x"]).root.path == "/tmp/x")
        #expect(StatePaths.resolve(environment: [:]).root.path.hasSuffix("Library/Application Support/che-container-mcp"))
    }
}
