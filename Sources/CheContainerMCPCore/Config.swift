import Foundation

/// Where state and config live (design: 設定檔提供預設值).
public struct StatePaths: Sendable, Equatable {
    public var root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    /// `CHE_CONTAINER_MCP_HOME`, otherwise `~/Library/Application Support/che-container-mcp/`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> StatePaths {
        if let override = environment["CHE_CONTAINER_MCP_HOME"], !override.isEmpty {
            return StatePaths(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/che-container-mcp", isDirectory: true)
        return StatePaths(root: support)
    }

    public var configFile: URL { root.appendingPathComponent("config.json") }
    public var jobsDirectory: URL { root.appendingPathComponent("jobs", isDirectory: true) }
    public var pullsDirectory: URL { root.appendingPathComponent("pulls", isDirectory: true) }
}

/// The optional config file. Every field is optional; built-in defaults fill the rest.
public struct ServerConfig: Sendable, Equatable {
    public var containerPath: String?
    public var dockerPath: String?
    public var sourceDir: String?
    public var outputDir: String?
    public var cpus: Int
    public var memory: String
    public var sourceMount: String
    public var outputMount: String
    public var workdir: String?

    public static let builtIn = ServerConfig(
        containerPath: nil, dockerPath: nil, sourceDir: nil, outputDir: nil,
        cpus: 8, memory: "16G", sourceMount: "/src", outputMount: "/out", workdir: nil)

    /// The working directory when neither the call nor the config gives one.
    public var effectiveWorkdir: String { workdir ?? sourceMount }

    /// Reads `paths.configFile`. A missing file means built-in defaults; anything else that is
    /// not a valid config throws `config_invalid` (never a silent fallback).
    public static func load(from paths: StatePaths) throws -> ServerConfig {
        let url = paths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else { return .builtIn }
        guard let data = try? Data(contentsOf: url) else {
            throw invalid("cannot read \(url.lastPathComponent)")
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> ServerConfig {
        guard let value = try? JSONSerialization.jsonObject(with: data), let root = value as? [String: Any] else {
            throw invalid("config.json is not a JSON object")
        }
        var config = ServerConfig.builtIn
        config.containerPath = try optionalString(root, "container_path")
        config.dockerPath = try optionalString(root, "docker_path")
        if let raw = root["defaults"] {
            guard let defaults = raw as? [String: Any] else { throw invalid("`defaults` must be an object") }
            config.sourceDir = try optionalString(defaults, "source_dir", prefix: "defaults.")
            config.outputDir = try optionalString(defaults, "output_dir", prefix: "defaults.")
            if let cpus = defaults["cpus"] {
                guard let number = cpus as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.intValue), number.intValue > 0 else {
                    throw invalid("`defaults.cpus` must be a positive integer")
                }
                config.cpus = number.intValue
            }
            if let memory = try optionalString(defaults, "memory", prefix: "defaults.") { config.memory = memory }
            if let mount = try optionalString(defaults, "source_mount", prefix: "defaults.") { config.sourceMount = mount }
            if let mount = try optionalString(defaults, "output_mount", prefix: "defaults.") { config.outputMount = mount }
            config.workdir = try optionalString(defaults, "workdir", prefix: "defaults.")
        }
        return config
    }

    private static func optionalString(_ object: [String: Any], _ key: String, prefix: String = "") throws -> String? {
        guard let value = object[key] else { return nil }
        guard let text = value as? String, !text.isEmpty else { throw invalid("`\(prefix)\(key)` must be a non-empty string") }
        return text
    }

    private static func invalid(_ detail: String) -> ContainerMCPError {
        ContainerMCPError(.configInvalid, detail)
    }
}
