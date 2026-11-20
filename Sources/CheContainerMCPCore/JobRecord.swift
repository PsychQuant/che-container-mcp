import Darwin
import Foundation

public enum RuntimeKind: String, Codable, Sendable {
    case container, docker
}

/// The closed set of job states (spec: Job state persisted on disk).
public enum JobState: String, Codable, Sendable, CaseIterable {
    case running
    case exited
    case exitedUnknown = "exited_unknown"
    case cancelled
    case lost
    case failedToStart = "failed_to_start"

    public var isFinished: Bool { self != .running }
}

public enum ExitCodeSource: String, Codable, Sendable {
    case file
    case logMarker = "log_marker"
    case none
}

public enum EndedAtSource: String, Codable, Sendable {
    case exitCodeFile = "exit_code_file"
    case observed
}

public struct SleepEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case sleep, wake }
    public var kind: Kind
    public var at: Date
}

/// One job's `job.json`.
public struct JobRecord: Codable, Equatable, Sendable {
    public var schema: Int = 1
    public var jobId: String
    public var containerName: String
    public var runtime: RuntimeKind
    public var image: String
    public var command: [String]
    public var mounts: [MountSpec]
    public var cpus: Int
    public var memory: String
    public var workdir: String
    public var envKeys: [String]
    public var state: JobState
    public var startedAt: Date
    public var endedAt: Date?
    public var endedAtSource: EndedAtSource?
    public var exitCode: Int?
    public var exitCodeSource: ExitCodeSource?
    public var logPath: String?
    public var startError: String?
    public var sleepEvents: [SleepEvent] = []
    public var lastMonitoredAt: Date
    public var monitoringGap: Bool = false
    public var containerDeleted: Bool = false
    /// Set once `run -d` returned 0. Until then a container that is not listed yet is still
    /// starting, not lost (the start can take up to `JobManager.startTimeout`).
    public var launched: Bool?

    enum CodingKeys: String, CodingKey {
        case schema
        case jobId = "job_id"
        case containerName = "container_name"
        case runtime, image, command, mounts, cpus, memory, workdir
        case envKeys = "env_keys"
        case state
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case endedAtSource = "ended_at_source"
        case exitCode = "exit_code"
        case exitCodeSource = "exit_code_source"
        case logPath = "log_path"
        case startError = "start_error"
        case sleepEvents = "sleep_events"
        case lastMonitoredAt = "last_monitored_at"
        case monitoringGap = "monitoring_gap"
        case containerDeleted = "container_deleted"
        case launched
    }

    /// `host_slept_during_job` (spec: Report host sleep during a job).
    public var hostSleptDuringJob: Any {
        if sleepEvents.contains(where: { $0.kind == .sleep }) { return true }
        return monitoringGap ? "unknown" : false
    }

    public func elapsedSeconds(now: Date) -> Int {
        max(0, Int(((endedAt ?? now).timeIntervalSince(startedAt)).rounded()))
    }
}

/// Job ids: `cj-<UTC yyyyMMddHHmmss>-<6 lowercase hex>` (design: job id、容器名稱與 label).
public enum JobId {
    public static let labelKey = "che-container-mcp.job"
    public static let schemaLabelKey = "che-container-mcp.schema"
    public static let pattern = #"^cj-[0-9]{14}-[0-9a-f]{6}$"#

    public static func make(now: Date, random: () -> UInt32 = { arc4random() }) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let suffix = String(format: "%06x", random() & 0xFFFFFF)
        return "cj-\(formatter.string(from: now))-\(suffix)"
    }

    public static func isValid(_ id: String) -> Bool {
        id.range(of: pattern, options: .regularExpression) != nil
    }

    public static func labels(for id: String) -> [(String, String)] {
        [(labelKey, id), (schemaLabelKey, "1")]
    }
}

/// `<root>/jobs/<job_id>/` with `job.json`, `state/` and `output.log` (design: job 狀態以每 job
/// 一個 JSON 檔落盤). Writes go through a temporary file and `rename(2)`.
public struct JobStore: Sendable {
    public let paths: StatePaths

    public init(paths: StatePaths) { self.paths = paths }

    public func directory(_ id: String) -> URL { paths.jobsDirectory.appendingPathComponent(id, isDirectory: true) }
    public func recordURL(_ id: String) -> URL { directory(id).appendingPathComponent("job.json") }
    public func stateDirectory(_ id: String) -> URL { directory(id).appendingPathComponent("state", isDirectory: true) }
    public func exitCodeURL(_ id: String) -> URL { stateDirectory(id).appendingPathComponent("exit_code") }
    public func logURL(_ id: String) -> URL { directory(id).appendingPathComponent("output.log") }

    public func prepare(_ id: String) throws {
        try FileManager.default.createDirectory(at: stateDirectory(id), withIntermediateDirectories: true)
    }

    public func save(_ record: JobRecord) throws {
        try FileManager.default.createDirectory(at: directory(record.jobId), withIntermediateDirectories: true)
        try Self.atomicWrite(try Self.encoder.encode(record), to: recordURL(record.jobId))
    }

    public func load(_ id: String) throws -> JobRecord {
        guard JobId.isValid(id), let data = try? Data(contentsOf: recordURL(id)) else {
            throw ContainerMCPError(.jobNotFound, "no job with id \(id)")
        }
        do {
            return try Self.decoder.decode(JobRecord.self, from: data)
        } catch {
            throw ContainerMCPError(.jobNotFound, "the record of job \(id) cannot be read")
        }
    }

    /// Every readable record, oldest first. Unreadable directories are skipped.
    public func loadAll() -> [JobRecord] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: paths.jobsDirectory.path)) ?? []
        return ids.filter(JobId.isValid).sorted().compactMap { try? load($0) }
    }

    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ContainerMCPError(.cliFailed, "could not replace \(url.lastPathComponent)")
        }
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, coder in
            var container = coder.singleValueContainer()
            try container.encode(ISO8601.format(date))
        }
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { coder in
            let container = try coder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISO8601.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad date \(text)")
            }
            return date
        }
        return decoder
    }()
}

/// The shell wrapper that records the exit code (design: job 指令包一層 shell 寫出 exit code).
public enum Wrapper {
    public static let markerPrefix = "__CHE_JOB_EXIT__"

    /// `$0` is `che-job`; the job's command is `"$@"`. The script never re-splits arguments.
    ///
    /// The command runs in the foreground. A non-interactive shell would make a background
    /// command ignore SIGINT and SIGQUIT, and that is inherited by everything the job starts
    /// (bash cannot even trap a signal ignored on entry). Cancellation therefore signals the
    /// job's processes directly with `kill -TERM -1` through `exec` (see `JobRuntime.signalJob`).
    public static func script(jobId: String, stateDir: String = MountPlanner.jobStateMount) -> String {
        """
        "$@"
        rc=$?
        printf '%s\\n' "$rc" > '\(stateDir)/exit_code.tmp' && mv '\(stateDir)/exit_code.tmp' '\(stateDir)/exit_code'
        printf '%s %s %s\\n' '\(markerPrefix)' '\(jobId)' "$rc"
        exit "$rc"
        """
    }

    /// The exit code from the last marker line for `jobId`, if any.
    public static func exitCode(fromLog log: String, jobId: String) -> Int? {
        for line in log.split(whereSeparator: \.isNewline).reversed() {
            let parts = line.split(separator: " ")
            if parts.count == 3, parts[0] == markerPrefix, parts[1] == jobId, let code = Int(parts[2]) {
                return code
            }
        }
        return nil
    }
}
