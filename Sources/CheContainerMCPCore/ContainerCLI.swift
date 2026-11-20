import Foundation

/// One CLI call, split so the guard can check only the part this server writes: the
/// subcommand and its options. `positional` holds the image and the job's own command, whose
/// tokens (`swift test -t`) are the user's and must not be rejected.
public struct Invocation: Sendable, Equatable {
    public var subcommand: [String]
    public var options: [String]
    public var positional: [String]

    public init(_ subcommand: [String], options: [String] = [], positional: [String] = []) {
        self.subcommand = subcommand
        self.options = options
        self.positional = positional
    }

    public var argv: [String] { subcommand + options + positional }

    /// Flags that would attach a TTY, keep stdin open or stream forever — any of them could block
    /// the MCP stdio loop (spec: Invoke the container CLI by absolute path with argv).
    public static let forbiddenOptions: Set<String> = ["-i", "-t", "-it", "-ti", "--tty", "--interactive", "--follow"]

    public func validate() throws {
        if let bad = (subcommand + options).first(where: Self.forbiddenOptions.contains) {
            throw ContainerMCPError(.invalidArgument, "refusing to pass \(bad) to the CLI")
        }
        if subcommand == ["logs"], options.contains("-f") {
            throw ContainerMCPError(.invalidArgument, "refusing to follow logs")
        }
        if subcommand == ["stats"], !options.contains("--no-stream") {
            throw ContainerMCPError(.invalidArgument, "stats requires --no-stream")
        }
    }
}

/// Per-subcommand timeouts in seconds (design: CLI 呼叫逾時).
public enum CLITimeouts {
    public static let standard: TimeInterval = 30
    public static let systemStart: TimeInterval = 120
    public static let logs: TimeInterval = 120
    public static let imagePull: TimeInterval = 1_800
}

/// Whether the default kernel is installed.
public enum KernelState: Sendable, Equatable {
    case installed, missing, unknown

    public var jsonValue: Any {
        switch self {
        case .installed: return true
        case .missing: return false
        case .unknown: return "unknown"
        }
    }
}

/// Wraps the installed `container` CLI (design: 以 argv 包裝 container CLI，不連 Swift 套件).
public struct ContainerClient: Sendable {
    public static let defaultPath = "/usr/local/bin/container"

    public let path: String
    public let runner: CommandRunner

    public init(path: String, runner: CommandRunner) {
        self.path = path
        self.runner = runner
    }

    public init(config: ServerConfig, runner: CommandRunner) {
        self.init(path: config.containerPath ?? Self.defaultPath, runner: runner)
    }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: path) }

    /// Runs one invocation; non-zero exit becomes `cli_failed` unless `allowFailure`.
    @discardableResult
    public func call(_ invocation: Invocation, timeout: TimeInterval = CLITimeouts.standard,
                     allowFailure: Bool = false) async throws -> CommandOutput {
        try invocation.validate()
        guard isInstalled else {
            throw ContainerMCPError(.runtimeUnavailable, "the container CLI was not found at \(path)")
        }
        let output = try await runner.run(path, invocation.argv, timeout: timeout)
        if output.status != 0 && !allowFailure {
            throw ContainerMCPError.cliFailed("container " + invocation.subcommand.joined(separator: " "),
                                              status: output.status, stderr: output.stderrString)
        }
        return output
    }

    // MARK: - Version and service

    /// `container --version` → `1.7.1`.
    public func version() async throws -> String {
        let output = try await call(Invocation(["--version"]))
        return Self.parseVersion(output.stdoutString) ?? output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseVersion(_ text: String) -> String? {
        // "container CLI version 1.7.1 (build: release, commit: a15b460)"
        guard let range = text.range(of: #"version\s+([0-9][0-9A-Za-z.\-]*)"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: " ").last.map(String.init)
    }

    /// The service status. A non-zero exit means the API server cannot be reached: `stopped`.
    public func systemStatus(cliVersion: String) async throws -> SystemStatus {
        let output = try await call(Invocation(["system", "status"], options: ["--format", "json"]), allowFailure: true)
        guard output.status == 0 else {
            return SystemStatus(status: "stopped", clientVersion: cliVersion, serverVersion: nil, appRoot: nil)
        }
        return try CLIJSON.systemStatus(output.stdout, cliVersion: cliVersion)
    }

    public func systemStart() async throws {
        try await call(Invocation(["system", "start"], options: ["--enable-kernel-install", "--timeout", "60"]),
                       timeout: CLITimeouts.systemStart)
    }

    /// `<appRoot>/kernels/default.kernel-<arch>` resolving to an existing file means installed;
    /// a `kernels` directory without it means missing; anything unreadable is unknown.
    public static func kernelState(appRoot: String?, architecture: String = CLIJSON.hostArchitecture,
                                   fileManager: FileManager = .default) -> KernelState {
        guard let appRoot else { return .unknown }
        let kernels = URL(fileURLWithPath: appRoot).appendingPathComponent("kernels", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: kernels.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unknown
        }
        let link = kernels.appendingPathComponent("default.kernel-\(architecture)")
        guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil
                || fileManager.fileExists(atPath: link.path) else {
            return .missing
        }
        return fileManager.fileExists(atPath: link.resolvingSymlinksInPath().path) ? .installed : .missing
    }

    // MARK: - Images

    public func images(cliVersion: String) async throws -> [ImageSummary] {
        let output = try await call(Invocation(["image", "list"], options: ["--format", "json"]))
        return try CLIJSON.images(output.stdout, cliVersion: cliVersion)
    }

    public static func pullInvocation(reference: String, platform: String?) -> Invocation {
        var options = ["--progress", "none"]
        if let platform { options += ["--platform", platform] }
        return Invocation(["image", "pull"], options: options, positional: [reference])
    }

    // MARK: - Containers

    public func containers(cliVersion: String) async throws -> [ContainerSummary] {
        let output = try await call(Invocation(["list"], options: ["--all", "--format", "json"]))
        return try CLIJSON.containers(output.stdout, cliVersion: cliVersion)
    }

    public static func logsInvocation(name: String, tail: Int?) -> Invocation {
        Invocation(["logs"], options: tail.map { ["-n", String($0)] } ?? [], positional: [name])
    }

    public static func stopInvocation(name: String, graceSeconds: Int) -> Invocation {
        Invocation(["stop"], options: ["--time", String(graceSeconds)], positional: [name])
    }

    public static func deleteInvocation(name: String) -> Invocation {
        Invocation(["delete"], options: ["--force"], positional: [name])
    }
}
