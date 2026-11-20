import Foundation
@testable import CheContainerMCPCore

final class FakePower: PowerAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private(set) var history: [Bool] = []
    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
    func setHeld(_ wanted: Bool) { lock.lock(); held = wanted; history.append(wanted); lock.unlock() }
}

/// A clock whose `sleep` advances `now` instantly.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_795_000_000)) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
    /// Runs after every `sleep` advanced the time, on the sleeping task.
    var onSleep: ((Date) throws -> Void)?
    var clock: Clock { Clock(now: { self.now }, sleep: { self.advance($0); try self.onSleep?(self.now) }) }
}

struct ContainerEntry {
    var id: String
    var labelled = true
    var state = "running"
    var started: String? = "2026-11-20T18:00:00Z"
}

/// A state root, stub executables and a scripted runner for JobManager tests.
final class Harness {
    let dir: TempDir
    let runner = FakeCommandRunner()
    let power = FakePower()
    let time = TestClock()
    let paths: StatePaths
    let containerPath: String
    let dockerPath: String
    let appRoot: String
    var dockerFound = true
    lazy var manager = JobManager(paths: paths, runner: runner, clock: time.clock, power: power,
                                  dockerLocator: { [unowned self] _ in self.dockerFound ? self.dockerPath : nil })

    init(kernel: Bool = true) throws {
        dir = try TempDir()
        paths = StatePaths(root: URL(fileURLWithPath: try dir.dir("state")))
        containerPath = try dir.executable("container", script: "exit 0")
        dockerPath = try dir.executable("docker", script: "exit 0")
        appRoot = try dir.dir("appRoot")
        let kernels = try dir.dir("appRoot/kernels")
        if kernel {
            let file = kernels + "/vmlinux"
            try Data("k".utf8).write(to: URL(fileURLWithPath: file))
            try FileManager.default.createSymbolicLink(atPath: kernels + "/default.kernel-\(CLIJSON.hostArchitecture)",
                                                       withDestinationPath: file)
        }
        try writeConfig(["container_path": containerPath])
        runner.on(["--version"], stdout: "container CLI version 1.7.1 (build: release, commit: a15b460)\n")
        serviceRunning(true)
        runner.on(["image", "list"], stdout: try Fixture.text("image-list.json"))
        runner.on(["list"], stdout: "[]")
        runner.on(["run"], stdout: "")
    }

    func writeConfig(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: paths.configFile)
    }

    func serviceRunning(_ running: Bool) {
        if running {
            runner.on(["system", "status"], stdout: #"{"status":"running","client":{"version":"1.7.1"},"server":{"version":"1.7.1"},"paths":{"appRoot":"\#(appRoot)"}}"#)
        } else {
            runner.on(["system", "status"], status: 1, stderr: "XPC connection error")
        }
    }

    func containers(_ entries: [ContainerEntry]) {
        let items: [[String: Any]] = entries.map { entry in
            var status: [String: Any] = ["state": entry.state]
            if let started = entry.started { status["startedDate"] = started }
            return ["configuration": ["id": entry.id, "labels": entry.labelled ? ["che-container-mcp.job": entry.id] : [:]],
                    "status": status]
        }
        runner.on(["list"], stdout: String(decoding: try! JSONSerialization.data(withJSONObject: items), as: UTF8.self))
    }

    func logs(_ text: String) { runner.on(["logs"], stdout: text) }

    var store: JobStore { JobStore(paths: paths) }

    /// Starts a job through the manager and returns its id.
    func startJob(_ command: [String] = ["true"]) async throws -> String {
        let result = try await manager.run(RunRequest(image: "swift:6.0.3-noble", command: command))
        return result["job_id"] as! String
    }

    func writeExitCode(_ id: String, _ code: Int, modified: Date? = nil) throws {
        let url = store.exitCodeURL(id)
        try "\(code)\n".write(to: url, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    func subcommands() -> [String] {
        runner.argvs.compactMap(\.first)
    }
}
