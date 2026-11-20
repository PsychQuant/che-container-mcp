import Darwin
import Foundation

/// One bind mount as it is recorded and reported.
public struct MountSpec: Codable, Equatable, Sendable {
    public var hostPath: String
    public var containerPath: String
    public var readonly: Bool

    public init(hostPath: String, containerPath: String, readonly: Bool) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.readonly = readonly
    }

    enum CodingKeys: String, CodingKey {
        case hostPath = "host_path"
        case containerPath = "container_path"
        case readonly
    }

    public var jsonObject: [String: Any] {
        ["host_path": hostPath, "container_path": containerPath, "readonly": readonly]
    }
}

/// The mount part of a `container_run` call.
public struct MountRequest: Sendable, Equatable {
    public var sourceDir: String?
    public var sourceWritable: Bool
    public var outputDir: String?

    public init(sourceDir: String? = nil, sourceWritable: Bool = false, outputDir: String? = nil) {
        self.sourceDir = sourceDir
        self.sourceWritable = sourceWritable
        self.outputDir = outputDir
    }
}

/// Plans and validates mounts (spec: Per-call source and output directories, Mount validation
/// before start). The job state mount (`/.che-job`) is added by the job manager, not here.
public enum MountPlanner {
    public static let jobStateMount = "/.che-job"

    public static func plan(_ request: MountRequest, config: ServerConfig, stateRoot: URL,
                            home: String = NSHomeDirectory()) throws -> [MountSpec] {
        let source = request.sourceDir ?? config.sourceDir
        let output = request.outputDir ?? config.outputDir
        let sourceMount = config.sourceMount
        let outputMount = config.outputMount

        for target in [sourceMount, outputMount] {
            guard target.hasPrefix("/") else { throw invalid("container path \(target) is not absolute") }
            let normalized = (target as NSString).standardizingPath
            if normalized == jobStateMount || normalized.hasPrefix(jobStateMount + "/") {
                throw invalid("container path \(target) is reserved for job state")
            }
        }
        if source != nil, output != nil,
           (sourceMount as NSString).standardizingPath == (outputMount as NSString).standardizingPath {
            throw invalid("source and output mount at the same container path \(sourceMount)")
        }

        let homeResolved = resolve(home) ?? home
        let stateResolved = resolve(stateRoot.path) ?? stateRoot.standardizedFileURL.path
        let resolvedSource = try source.map { try validated($0, role: "source_dir", home: homeResolved, stateRoot: stateResolved) }
        let resolvedOutput = try output.map { try validated($0, role: "output_dir", home: homeResolved, stateRoot: stateResolved) }

        if let s = resolvedSource, let o = resolvedOutput {
            if s == o { throw invalid("source_dir and output_dir are the same directory (\(s))") }
            if isInside(o, s) { throw invalid("output_dir \(o) is inside source_dir \(s)") }
            if isInside(s, o) { throw invalid("source_dir \(s) is inside output_dir \(o)") }
        }

        var mounts: [MountSpec] = []
        if let s = resolvedSource {
            mounts.append(MountSpec(hostPath: s, containerPath: sourceMount, readonly: !request.sourceWritable))
        }
        if let o = resolvedOutput {
            mounts.append(MountSpec(hostPath: o, containerPath: outputMount, readonly: false))
        }
        return mounts
    }

    private static func validated(_ path: String, role: String, home: String, stateRoot: String) throws -> String {
        guard path.hasPrefix("/") else { throw invalid("\(role) \(path) is not an absolute path") }
        guard let resolved = resolve(path) else { throw invalid("\(role) \(path) does not exist") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw invalid("\(role) \(path) is not a directory")
        }
        if resolved == "/" { throw invalid("\(role) is the root directory") }
        if resolved == home { throw invalid("\(role) is the home directory itself") }
        if resolved == stateRoot || isInside(resolved, stateRoot) {
            throw invalid("\(role) \(resolved) is inside the server's state directory")
        }
        // `--mount` separates its fields with commas, so a comma in the path would be misread.
        if resolved.contains(",") { throw invalid("\(role) \(resolved) contains a comma") }
        return resolved
    }

    /// `realpath(3)`; nil when the path does not exist.
    static func resolve(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Whether `child` is strictly below `parent` (both resolved).
    static func isInside(_ child: String, _ parent: String) -> Bool {
        let base = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(base)
    }

    private static func invalid(_ message: String) -> ContainerMCPError {
        ContainerMCPError(.invalidMount, message)
    }
}

/// Explicit `KEY=VALUE` pairs only (spec: Explicit environment values only).
public enum EnvironmentPolicy {
    public static func validate(_ env: [String: String]) throws -> [(key: String, value: String)] {
        try env.keys.sorted().map { key in
            guard !key.isEmpty, !key.contains("=") else {
                throw ContainerMCPError(.invalidArgument, "environment key \"\(key)\" must be non-empty and contain no '='")
            }
            return (key, env[key]!)
        }
    }
}

/// Image reference normalization (spec: Ensure an image is present locally).
public enum ImageReference {
    public static func normalize(_ raw: String) throws -> String {
        let reference = raw.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty, !reference.contains(" ") else {
            throw ContainerMCPError(.invalidArgument, "image reference \"\(raw)\" is empty or contains spaces")
        }
        var components = reference.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let first = components[0]
        let hasRegistry = components.count > 1 && (first.contains(".") || first.contains(":") || first == "localhost")
        if !hasRegistry {
            if components.count == 1 { components.insert("library", at: 0) }
            components.insert("docker.io", at: 0)
        }
        var last = components.removeLast()
        if !last.contains(":") && !last.contains("@") { last += ":latest" }
        components.append(last)
        return components.joined(separator: "/")
    }
}
