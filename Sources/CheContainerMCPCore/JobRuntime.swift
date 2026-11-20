import Foundation

/// Everything needed to start one job's container.
public struct RunSpec: Sendable, Equatable {
    public var name: String
    public var image: String
    public var mounts: [MountSpec]
    public var cpus: Int
    public var memory: String
    public var workdir: String
    public var env: [String: String]
    public var command: [String]

    public var labels: [(String, String)] { JobId.labels(for: name) }

    public static func == (lhs: RunSpec, rhs: RunSpec) -> Bool {
        lhs.name == rhs.name && lhs.image == rhs.image && lhs.mounts == rhs.mounts && lhs.cpus == rhs.cpus
            && lhs.memory == rhs.memory && lhs.workdir == rhs.workdir && lhs.env == rhs.env && lhs.command == rhs.command
    }

    /// `--mount` value for one bind mount.
    static func mountValue(_ mount: MountSpec) -> String {
        "type=bind,source=\(mount.hostPath),target=\(mount.containerPath)" + (mount.readonly ? ",readonly" : "")
    }

    /// Positional part shared by both runtimes: image, then `/bin/sh -c <wrapper> che-job <command…>`.
    var positional: [String] {
        [image, "-c", Wrapper.script(jobId: name), "che-job"] + command
    }
}

/// A container that carries the job label.
public struct JobContainer: Sendable, Equatable {
    public var jobId: String
    public var running: Bool
    public var startedAt: Date?
}

/// The operations the job manager needs from a runtime. Only containers carrying the
/// `che-container-mcp.job` label are ever returned or touched.
public protocol JobRuntime: Sendable {
    var kind: RuntimeKind { get }
    /// Starts the container detached. Returns the CLI output; a non-zero status is the caller's
    /// to turn into `failed_to_start`.
    func start(_ spec: RunSpec) async throws -> CommandOutput
    func jobContainers() async throws -> [JobContainer]
    func logs(_ name: String, tail: Int?) async throws -> Data
    func stop(_ name: String, graceSeconds: Int) async throws
    func delete(_ name: String) async throws
    /// Sends TERM to every process of the job except the wrapper (PID 1), which then records the
    /// exit code and exits.
    func signalJob(_ name: String) async throws
}

extension JobRuntime {
    static var signalArguments: [String] { ["/bin/sh", "-c", "kill -TERM -1"] }
}

public struct ContainerJobRuntime: JobRuntime {
    public let client: ContainerClient
    public let cliVersion: String
    public var kind: RuntimeKind { .container }

    public init(client: ContainerClient, cliVersion: String) {
        self.client = client
        self.cliVersion = cliVersion
    }

    public static func runInvocation(_ spec: RunSpec) -> Invocation {
        var options = ["-d", "--progress", "none", "--name", spec.name]
        for (key, value) in spec.labels { options += ["--label", "\(key)=\(value)"] }
        for mount in spec.mounts { options += ["--mount", RunSpec.mountValue(mount)] }
        options += ["-w", spec.workdir]
        for key in spec.env.keys.sorted() { options += ["-e", "\(key)=\(spec.env[key]!)"] }
        options += ["-c", String(spec.cpus), "-m", spec.memory, "--entrypoint", "/bin/sh"]
        return Invocation(["run"], options: options, positional: spec.positional)
    }

    public func start(_ spec: RunSpec) async throws -> CommandOutput {
        try await client.call(Self.runInvocation(spec), timeout: 120, allowFailure: true)
    }

    public func jobContainers() async throws -> [JobContainer] {
        try await client.containers(cliVersion: cliVersion).compactMap { summary in
            guard let id = summary.labels[JobId.labelKey], id == summary.id else { return nil }
            return JobContainer(jobId: id, running: summary.isRunning, startedAt: summary.startedDate)
        }
    }

    public func logs(_ name: String, tail: Int?) async throws -> Data {
        try await client.call(ContainerClient.logsInvocation(name: name, tail: tail), timeout: CLITimeouts.logs).stdout
    }

    public func stop(_ name: String, graceSeconds: Int) async throws {
        try await client.call(ContainerClient.stopInvocation(name: name, graceSeconds: graceSeconds),
                              timeout: TimeInterval(graceSeconds) + CLITimeouts.standard)
    }

    public func delete(_ name: String) async throws {
        try await client.call(ContainerClient.deleteInvocation(name: name))
    }

    public func signalJob(_ name: String) async throws {
        try await client.call(Invocation(["exec"], positional: [name] + Self.signalArguments))
    }
}

/// Docker, used only for a job that a single `container_run` call authorized (design: Docker 只在
/// 單次授權且 container 不可用時使用).
public struct DockerJobRuntime: JobRuntime {
    public static let candidatePaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]

    public let path: String
    public let runner: CommandRunner
    public var kind: RuntimeKind { .docker }

    public init(path: String, runner: CommandRunner) {
        self.path = path
        self.runner = runner
    }

    /// `docker_path` from the config, else the first existing candidate.
    public static func locate(config: ServerConfig, fileManager: FileManager = .default) -> String? {
        if let configured = config.dockerPath { return fileManager.isExecutableFile(atPath: configured) ? configured : nil }
        return candidatePaths.first(where: fileManager.isExecutableFile(atPath:))
    }

    /// Whether the daemon answers.
    public func isAvailable() async -> Bool {
        guard let output = try? await runner.run(path, ["info", "--format", "{{.ServerVersion}}"], timeout: CLITimeouts.standard) else {
            return false
        }
        return output.status == 0
    }

    public static func runInvocation(_ spec: RunSpec) -> Invocation {
        var options = ["-d", "--name", spec.name]
        for (key, value) in spec.labels { options += ["--label", "\(key)=\(value)"] }
        for mount in spec.mounts { options += ["--mount", RunSpec.mountValue(mount)] }
        options += ["-w", spec.workdir]
        for key in spec.env.keys.sorted() { options += ["-e", "\(key)=\(spec.env[key]!)"] }
        options += ["--cpus", String(spec.cpus), "--memory", spec.memory, "--entrypoint", "/bin/sh"]
        return Invocation(["run"], options: options, positional: spec.positional)
    }

    @discardableResult
    private func call(_ invocation: Invocation, timeout: TimeInterval = CLITimeouts.standard,
                      allowFailure: Bool = false) async throws -> CommandOutput {
        try invocation.validate()
        let output = try await runner.run(path, invocation.argv, timeout: timeout)
        if output.status != 0 && !allowFailure {
            throw ContainerMCPError.cliFailed("docker " + invocation.subcommand.joined(separator: " "),
                                              status: output.status, stderr: output.stderrString)
        }
        return output
    }

    public func start(_ spec: RunSpec) async throws -> CommandOutput {
        try await call(Self.runInvocation(spec), timeout: 120, allowFailure: true)
    }

    public func jobContainers() async throws -> [JobContainer] {
        let output = try await call(Invocation(["ps"], options: ["--all", "--no-trunc", "--filter", "label=\(JobId.labelKey)",
                                                                 "--format", "{{json .}}"]))
        return Self.parsePS(output.stdoutString)
    }

    /// `docker ps --format '{{json .}}'` prints one JSON object per line.
    static func parsePS(_ text: String) -> [JobContainer] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let names = object["Names"] as? String else { return nil }
            let labels = (object["Labels"] as? String ?? "").split(separator: ",").reduce(into: [String: String]()) { result, pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { result[parts[0]] = parts[1] }
            }
            guard let id = labels[JobId.labelKey], id == names else { return nil }
            return JobContainer(jobId: id, running: (object["State"] as? String) == "running", startedAt: nil)
        }
    }

    public func logs(_ name: String, tail: Int?) async throws -> Data {
        // `docker logs` replays the container's stderr on its own stderr: keep both.
        let options = tail.map { ["--tail", String($0)] } ?? []
        let output = try await call(Invocation(["logs"], options: options, positional: [name]), timeout: CLITimeouts.logs)
        return output.stdout + output.stderr
    }

    public func stop(_ name: String, graceSeconds: Int) async throws {
        try await call(Invocation(["stop"], options: ["--time", String(graceSeconds)], positional: [name]),
                       timeout: TimeInterval(graceSeconds) + CLITimeouts.standard)
    }

    public func delete(_ name: String) async throws {
        try await call(Invocation(["rm"], options: ["--force"], positional: [name]))
    }

    public func signalJob(_ name: String) async throws {
        try await call(Invocation(["exec"], positional: [name] + Self.signalArguments))
    }
}
