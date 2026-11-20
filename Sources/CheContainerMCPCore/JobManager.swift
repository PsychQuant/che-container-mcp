import Darwin
import Foundation

/// What `container_run` was asked for, after argument parsing.
public struct RunRequest: Sendable, Equatable {
    public var image: String
    public var command: [String]
    public var mounts: MountRequest
    public var cpus: Int?
    public var memory: String?
    public var workdir: String?
    public var env: [String: String]
    public var allowDocker: Bool

    public init(image: String, command: [String], mounts: MountRequest = MountRequest(), cpus: Int? = nil,
                memory: String? = nil, workdir: String? = nil, env: [String: String] = [:], allowDocker: Bool = false) {
        self.image = image
        self.command = command
        self.mounts = mounts
        self.cpus = cpus
        self.memory = memory
        self.workdir = workdir
        self.env = env
        self.allowDocker = allowDocker
    }
}

/// Injected time so waits and the 60-second gap rule are testable.
public struct Clock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = Clock(now: { Date() }, sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
}

/// Owns job state: start, reconcile, status, wait, result, cancel (spec: container-jobs).
public actor JobManager {
    public static let gapThreshold: TimeInterval = 60
    public static let waitPollInterval: TimeInterval = 2
    public static let runningTailLines = 20
    /// How long a record may stay unlaunched before an unlisted container counts as lost:
    /// `run -d`'s own timeout plus a margin.
    public static let startTimeout: TimeInterval = 150

    public let paths: StatePaths
    public let store: JobStore
    let runner: CommandRunner
    let clock: Clock
    let power: PowerAssertion
    /// Overridable so tests can point Docker at a stub.
    let dockerLocator: @Sendable (ServerConfig) -> String?
    private var cachedVersion: (path: String, version: String)?

    public init(paths: StatePaths, runner: CommandRunner, clock: Clock = .system, power: PowerAssertion,
                dockerLocator: @escaping @Sendable (ServerConfig) -> String? = { DockerJobRuntime.locate(config: $0) }) {
        self.paths = paths
        self.store = JobStore(paths: paths)
        self.runner = runner
        self.clock = clock
        self.power = power
        self.dockerLocator = dockerLocator
    }

    // MARK: - Runtime access

    func config() throws -> ServerConfig { try ServerConfig.load(from: paths) }

    func client(_ config: ServerConfig) -> ContainerClient { ContainerClient(config: config, runner: runner) }

    func cliVersion(_ client: ContainerClient) async throws -> String {
        if let cached = cachedVersion, cached.path == client.path { return cached.version }
        let version = try await client.version()
        cachedVersion = (client.path, version)
        return version
    }

    /// Why the `container` runtime cannot be used, or nil with its status when it can.
    func containerAvailability(_ client: ContainerClient) async throws -> (status: SystemStatus?, version: String?, reason: String?) {
        guard client.isInstalled else {
            return (nil, nil, "the container CLI was not found at \(client.path)")
        }
        let version = try await cliVersion(client)
        let status = try await client.systemStatus(cliVersion: version)
        guard status.status == "running" else {
            return (status, version, "the container service is not running (status: \(status.status)); call container_status with start: true")
        }
        return (status, version, nil)
    }

    func runtime(for record: JobRecord, config: ServerConfig) async throws -> JobRuntime {
        switch record.runtime {
        case .container:
            let client = client(config)
            guard client.isInstalled else {
                throw ContainerMCPError(.runtimeUnavailable, "the container CLI was not found at \(client.path)")
            }
            return ContainerJobRuntime(client: client, cliVersion: try await cliVersion(client))
        case .docker:
            guard let path = dockerLocator(config) else {
                throw ContainerMCPError(.dockerUnavailable, "this job ran under Docker but the docker CLI was not found")
            }
            return DockerJobRuntime(path: path, runner: runner)
        }
    }

    // MARK: - container_run

    public func run(_ request: RunRequest) async throws -> [String: Any] {
        // Preflight order (spec): config, executable, service, kernel, image, mounts.
        let config = try config()
        let image = try ImageReference.normalize(request.image)
        guard !request.command.isEmpty else { throw ContainerMCPError(.invalidArgument, "command must have at least one element") }
        let cpus = request.cpus ?? config.cpus
        guard cpus > 0 else { throw ContainerMCPError(.invalidArgument, "cpus must be a positive integer") }
        let memory = request.memory ?? config.memory
        guard memory.range(of: #"^[0-9]+[KMGTPkmgtp]?$"#, options: .regularExpression) != nil else {
            throw ContainerMCPError(.invalidArgument, "memory must look like 16G, 512M or 1073741824")
        }
        let workdir = request.workdir ?? config.effectiveWorkdir
        guard workdir.hasPrefix("/") else { throw ContainerMCPError(.invalidArgument, "workdir must be an absolute container path") }
        let env = Dictionary(uniqueKeysWithValues: try EnvironmentPolicy.validate(request.env).map { ($0.key, $0.value) })

        let containerClient = client(config)
        let availability = try await containerAvailability(containerClient)
        let runtime: JobRuntime
        if let reason = availability.reason {
            guard request.allowDocker else { throw ContainerMCPError(.runtimeUnavailable, reason) }
            guard let dockerPath = dockerLocator(config) else {
                throw ContainerMCPError(.dockerUnavailable, "\(reason); Docker was authorized but the docker CLI was not found")
            }
            let docker = DockerJobRuntime(path: dockerPath, runner: runner)
            guard await docker.isAvailable() else {
                throw ContainerMCPError(.dockerUnavailable, "\(reason); Docker was authorized but its daemon does not answer")
            }
            let inspect = try await runner.run(dockerPath, ["image", "inspect", image], timeout: CLITimeouts.standard)
            guard inspect.status == 0 else {
                throw ContainerMCPError(.imageNotFound, "image \(image) is not in Docker's local images; pull it with docker first")
            }
            runtime = docker
        } else {
            let version = availability.version ?? ""
            if ContainerClient.kernelState(appRoot: availability.status?.appRoot) == .missing {
                throw ContainerMCPError(.kernelMissing, "the default kernel is not installed; call container_status with start: true")
            }
            let images = try await containerClient.images(cliVersion: version)
            guard images.contains(where: { $0.reference == image }) else {
                throw ContainerMCPError(.imageNotFound, "image \(image) is not local; call container_image_ensure first")
            }
            runtime = ContainerJobRuntime(client: containerClient, cliVersion: version)
        }
        let mounts = try MountPlanner.plan(request.mounts, config: config, stateRoot: paths.root)

        let now = clock.now()
        let id = JobId.make(now: now)
        try store.prepare(id)
        let stateDir = MountPlanner.resolve(store.stateDirectory(id).path) ?? store.stateDirectory(id).path
        guard !stateDir.contains(",") else {
            throw ContainerMCPError(.invalidMount, "the state directory \(stateDir) contains a comma; set CHE_CONTAINER_MCP_HOME")
        }
        let allMounts = mounts + [MountSpec(hostPath: stateDir, containerPath: MountPlanner.jobStateMount, readonly: false)]
        var record = JobRecord(jobId: id, containerName: id, runtime: runtime.kind, image: image, command: request.command,
                               mounts: mounts, cpus: cpus, memory: memory, workdir: workdir, envKeys: env.keys.sorted(),
                               state: .running, startedAt: now, lastMonitoredAt: now)
        try store.save(record)

        let spec = RunSpec(name: id, image: image, mounts: allMounts, cpus: cpus, memory: memory, workdir: workdir,
                           env: env, command: request.command)
        let output: CommandOutput
        do {
            output = try await runtime.start(spec)
        } catch {
            try markFailedToStart(&record, detail: (error as? ContainerMCPError)?.message ?? "\(error)")
            throw ContainerMCPError(.cliFailed, "job \(id) failed to start: \((error as? ContainerMCPError)?.message ?? "start error")")
        }
        guard output.status == 0 else {
            // 1.7.1 leaves no container behind on a failed start; delete by name in case a
            // later version does, so container_deleted stays true to its word.
            try? await runtime.delete(id)
            try markFailedToStart(&record, detail: output.stderrString)
            throw ContainerMCPError.cliFailed("job \(id) failed to start; \(runtime.kind.rawValue) run",
                                              status: output.status, stderr: output.stderrString)
        }
        // Reload: a reconcile or a sleep event may have saved this record while `run -d` ran.
        record = (try? store.load(id)) ?? record
        record.launched = true
        try store.save(record)
        power.setHeld(true)
        return [
            "job_id": id,
            "container_name": id,
            "runtime": runtime.kind.rawValue,
            "state": JobState.running.rawValue,
            "started_at": ISO8601.format(record.startedAt),
            "mounts": mounts.map(\.jsonObject),
        ]
    }

    private func markFailedToStart(_ record: inout JobRecord, detail: String) throws {
        record = (try? store.load(record.jobId)) ?? record
        record.state = .failedToStart
        record.startError = String(detail.prefix(2_000))
        record.endedAt = clock.now()
        record.endedAtSource = .observed
        record.containerDeleted = true
        try store.save(record)
    }

    // MARK: - Reconciliation

    /// Brings one record up to date (spec: Reconcile jobs on startup and on every query).
    /// `containers` is nil when the runtime could not be listed; only the exit-code file is
    /// consulted then.
    func reconcile(_ input: JobRecord, containers: [JobContainer]?, runtime: JobRuntime?) async -> JobRecord {
        var record = input
        let now = clock.now()
        if record.state == .running {
            if let (code, modified) = readExitCode(record.jobId) {
                noteGap(&record, until: min(modified, now))
                record.state = .exited
                record.exitCode = code
                record.exitCodeSource = .file
                record.endedAt = modified
                record.endedAtSource = .exitCodeFile
            } else if let containers {
                if let container = containers.first(where: { $0.jobId == record.jobId }) {
                    if let started = container.startedAt { record.startedAt = started }
                    noteGap(&record, until: now)
                    if container.running {
                        record.lastMonitoredAt = now
                    } else {
                        record.endedAt = now
                        record.endedAtSource = .observed
                        if let runtime { await captureLog(&record, runtime: runtime) }
                        if let code = markerExitCode(record) {
                            record.state = .exited
                            record.exitCode = code
                            record.exitCodeSource = .logMarker
                        } else {
                            record.state = .exitedUnknown
                            record.exitCodeSource = ExitCodeSource.none
                        }
                    }
                } else if record.launched != true, now.timeIntervalSince(record.startedAt) < Self.startTimeout {
                    // `run -d` has not returned yet: starting, not lost.
                    noteGap(&record, until: now)
                    record.lastMonitoredAt = now
                } else {
                    noteGap(&record, until: now)
                    record.state = .lost
                    record.exitCodeSource = ExitCodeSource.none
                    record.endedAt = now
                    record.endedAtSource = .observed
                    record.containerDeleted = true
                }
            } else {
                // The runtime cannot be listed right now; this server is still watching.
                noteGap(&record, until: now)
                record.lastMonitoredAt = now
            }
        }
        if record.state.isFinished, record.logPath == nil, !record.containerDeleted, let runtime, containers != nil {
            if containers?.contains(where: { $0.jobId == record.jobId }) == true {
                await captureLog(&record, runtime: runtime)
            }
        }
        return record
    }

    private func noteGap(_ record: inout JobRecord, until end: Date) {
        if end.timeIntervalSince(record.lastMonitoredAt) > Self.gapThreshold { record.monitoringGap = true }
    }

    /// The container controls this file, so it is read only when it is a regular file of at most
    /// 32 bytes, opened with O_NOFOLLOW | O_NONBLOCK (a symlink or FIFO is ignored).
    private func readExitCode(_ id: String) -> (Int, Date)? {
        let path = store.exitCodeURL(id).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 32 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = read(fd, &buffer, 32)
        guard count > 0,
              let code = Int(String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return (code, modified)
    }

    private func markerExitCode(_ record: JobRecord) -> Int? {
        guard let path = record.logPath, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Wrapper.exitCode(fromLog: text, jobId: record.jobId)
    }

    /// Copies the full log to `output.log` once (spec: Log copied to the host when a job finishes).
    private func captureLog(_ record: inout JobRecord, runtime: JobRuntime) async {
        guard record.logPath == nil, !record.containerDeleted else { return }
        guard let data = try? await runtime.logs(record.containerName, tail: nil) else { return }
        let url = store.logURL(record.jobId)
        guard (try? JobStore.atomicWrite(data, to: url)) != nil else { return }
        record.logPath = url.path
    }

    /// Reconciles the given records, listing each runtime once, and saves what changed.
    func refresh(_ records: [JobRecord]) async -> [JobRecord] {
        guard let config = try? config() else { return records }
        var listings: [RuntimeKind: (runtime: JobRuntime?, containers: [JobContainer]?)] = [:]
        var updated: [JobRecord] = []
        for record in records {
            if listings[record.runtime] == nil {
                let runtime = try? await runtime(for: record, config: config)
                let containers = try? await runtime?.jobContainers()
                listings[record.runtime] = (runtime, containers)
            }
            let listing = listings[record.runtime]!
            var fresh = await reconcile(record, containers: listing.containers, runtime: listing.runtime)
            // A sleep event or the launch flag may have been saved while this reconcile awaited.
            if let stored = try? store.load(record.jobId) {
                if stored.sleepEvents.count > fresh.sleepEvents.count { fresh.sleepEvents = stored.sleepEvents }
                if stored.launched == true { fresh.launched = true }
                if stored.state.isFinished && !fresh.state.isFinished { fresh = stored }
            }
            if fresh != record { try? store.save(fresh) }
            updated.append(fresh)
        }
        updatePower()
        return updated
    }

    /// Holds the assertion exactly while some job is running.
    func updatePower() {
        power.setHeld(store.loadAll().contains { $0.state == .running })
    }

    /// Startup and the 15-second monitor (spec: Hold an idle-sleep assertion while jobs run).
    public func reconcileRunning() async {
        _ = await refresh(store.loadAll().filter { $0.state == .running })
    }

    public func recordSleepEvent(_ kind: SleepEvent.Kind, at date: Date) {
        for var record in store.loadAll() where record.state == .running {
            record.sleepEvents.append(SleepEvent(kind: kind, at: date))
            try? store.save(record)
        }
    }

    // MARK: - Status, wait, result, cancel

    func loadFresh(_ id: String) async throws -> JobRecord {
        let record = try store.load(id)
        return await refresh([record])[0]
    }

    func summary(_ record: JobRecord) -> [String: Any] {
        var fields: [String: Any] = [
            "job_id": record.jobId,
            "state": record.state.rawValue,
            "runtime": record.runtime.rawValue,
            "image": record.image,
            "started_at": ISO8601.format(record.startedAt),
            "ended_at": record.endedAt.map { ISO8601.format($0) as Any } ?? NSNull(),
            "elapsed_seconds": record.elapsedSeconds(now: clock.now()),
        ]
        if record.state == .failedToStart { fields["start_error"] = record.startError ?? "" }
        return fields
    }

    public func status(jobId: String?) async throws -> [String: Any] {
        let records: [JobRecord]
        if let jobId {
            records = [try await loadFresh(jobId)]
        } else {
            records = await refresh(store.loadAll())
        }
        var jobs: [[String: Any]] = []
        for record in records {
            var fields = summary(record)
            if record.state == .running { fields["tail"] = await runningTail(record) }
            jobs.append(fields)
        }
        if jobId != nil { return jobs[0] }
        return ["jobs": jobs, "runtime": "container"]
    }

    private func runningTail(_ record: JobRecord) async -> [String] {
        guard let config = try? config(), let runtime = try? await runtime(for: record, config: config),
              let data = try? await runtime.logs(record.containerName, tail: Self.runningTailLines) else { return [] }
        return Self.lastLines(String(decoding: data, as: UTF8.self), Self.runningTailLines)
    }

    public func wait(jobId: String, timeoutSeconds: Int) async throws -> [String: Any] {
        guard (1...600).contains(timeoutSeconds) else {
            throw ContainerMCPError(.invalidArgument, "timeout_seconds must be between 1 and 600")
        }
        let start = clock.now()
        var record = try await loadFresh(jobId)
        while record.state == .running {
            let waited = clock.now().timeIntervalSince(start)
            if waited >= Double(timeoutSeconds) { break }
            try await clock.sleep(min(Self.waitPollInterval, Double(timeoutSeconds) - waited))
            record = try await loadFresh(jobId)
        }
        var fields = summary(record)
        fields["timed_out"] = record.state == .running
        fields["waited_seconds"] = Int(clock.now().timeIntervalSince(start).rounded())
        return fields
    }

    public func result(jobId: String, tailLines: Int, keepContainer: Bool) async throws -> [String: Any] {
        guard (1...1_000).contains(tailLines) else {
            throw ContainerMCPError(.invalidArgument, "tail_lines must be between 1 and 1000")
        }
        var record = try await loadFresh(jobId)
        guard record.state != .running else {
            throw ContainerMCPError(.jobNotFinished, "job \(jobId) is still running; use container_job_wait")
        }
        var cleanupError: String?
        if !keepContainer, !record.containerDeleted {
            // Never delete before the log is on the host.
            if record.logPath != nil {
                do {
                    let config = try config()
                    try await runtime(for: record, config: config).delete(record.containerName)
                    record.containerDeleted = true
                    try store.save(record)
                } catch {
                    cleanupError = (error as? ContainerMCPError)?.message ?? "delete failed"
                }
            } else {
                cleanupError = "the log could not be copied yet, so the container was kept"
            }
        }
        var fields = summary(record)
        fields["exit_code"] = record.exitCode.map { $0 as Any } ?? NSNull()
        fields["exit_code_source"] = (record.exitCodeSource ?? ExitCodeSource.none).rawValue
        fields["ended_at_source"] = record.endedAtSource.map { $0.rawValue as Any } ?? NSNull()
        fields["log_path"] = record.logPath.map { $0 as Any } ?? NSNull()
        fields["tail"] = logTail(record, lines: tailLines)
        fields["host_slept_during_job"] = record.hostSleptDuringJob
        fields["sleep_events"] = record.sleepEvents.map { ["kind": $0.kind.rawValue, "at": ISO8601.format($0.at)] }
        fields["container_deleted"] = record.containerDeleted
        if let cleanupError { fields["cleanup_error"] = cleanupError }
        return fields
    }

    func logTail(_ record: JobRecord, lines: Int) -> [String] {
        guard let path = record.logPath, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Self.lastLines(text, lines)
    }

    static func lastLines(_ text: String, _ count: Int) -> [String] {
        Array(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .reversed().drop(while: \.isEmpty).prefix(count).reversed())
    }

    public func cancel(jobId: String, graceSeconds: Int) async throws -> [String: Any] {
        guard (0...300).contains(graceSeconds) else {
            throw ContainerMCPError(.invalidArgument, "grace_seconds must be between 0 and 300")
        }
        var record = try await loadFresh(jobId)
        if !record.containerDeleted {
            let config = try config()
            let runtime = try await runtime(for: record, config: config)
            if record.state == .running {
                try await runtime.stop(record.containerName, graceSeconds: graceSeconds)
                record.state = .cancelled
                record.endedAt = clock.now()
                record.endedAtSource = .observed
                if let (code, _) = readExitCode(record.jobId) {
                    record.exitCode = code
                    record.exitCodeSource = .file
                }
            }
            await captureLog(&record, runtime: runtime)
            if record.logPath != nil {
                try await runtime.delete(record.containerName)
                record.containerDeleted = true
            }
            try store.save(record)
        }
        updatePower()
        var fields: [String: Any] = [
            "job_id": record.jobId,
            "state": record.state.rawValue,
            "runtime": record.runtime.rawValue,
            "container_deleted": record.containerDeleted,
            "log_path": record.logPath.map { $0 as Any } ?? NSNull(),
        ]
        if !record.containerDeleted {
            fields["cleanup_error"] = "the log could not be copied, so the container was kept; cancel again to retry"
        }
        return fields
    }
}
