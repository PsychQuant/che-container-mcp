import Foundation
import Testing
@testable import CheContainerMCPCore

func sampleRecord(id: String = "cj-20261121000000-abc123", state: JobState = .running,
                  started: Date = Date(timeIntervalSince1970: 1_795_000_000)) -> JobRecord {
    JobRecord(jobId: id, containerName: id, runtime: .container, image: "docker.io/library/swift:6.0.3-noble",
              command: ["swift", "test"], mounts: [MountSpec(hostPath: "/p", containerPath: "/src", readonly: true)],
              cpus: 8, memory: "16G", workdir: "/src", envKeys: ["CI"], state: state, startedAt: started,
              lastMonitoredAt: started)
}

struct JobIdTests {
    @Test func `Format is cj-UTC timestamp-6 hex`() {
        let id = JobId.make(now: Date(timeIntervalSince1970: 1_795_198_451), random: { 0xABCDEF })
        #expect(id == "cj-20261120181411-abcdef")
        #expect(JobId.isValid(id))
        #expect(!JobId.isValid("cj-2026-abc"))
        #expect(!JobId.isValid("../etc"))
    }

    @Test func `Labels are job id and schema 1`() {
        let labels = JobId.labels(for: "cj-1")
        #expect(labels.map(\.0) == ["che-container-mcp.job", "che-container-mcp.schema"])
        #expect(labels.map(\.1) == ["cj-1", "1"])
    }

    @Test func `Container run argv names the container after the job and labels it`() {
        let spec = RunSpec(name: "cj-20261121000000-abcdef", image: "img", mounts: [], cpus: 2, memory: "1G",
                           workdir: "/", env: [:], command: ["true"])
        let argv = ContainerJobRuntime.runInvocation(spec).argv
        #expect(argv.firstRange(of: ["--name", "cj-20261121000000-abcdef"]) != nil)
        #expect(argv.firstRange(of: ["--label", "che-container-mcp.job=cj-20261121000000-abcdef"]) != nil)
        #expect(argv.firstRange(of: ["--label", "che-container-mcp.schema=1"]) != nil)
    }
}

struct JobStoreTests {
    @Test func `Round trip keeps every field and times carry an offset`() throws {
        let dir = try TempDir()
        let store = JobStore(paths: StatePaths(root: dir.url))
        var record = sampleRecord()
        record.endedAt = record.startedAt.addingTimeInterval(61)
        record.endedAtSource = .exitCodeFile
        record.exitCode = 3
        record.exitCodeSource = .file
        record.sleepEvents = [SleepEvent(kind: .sleep, at: record.startedAt.addingTimeInterval(5))]
        try store.save(record)
        #expect(try store.load(record.jobId) == record)
        let text = try String(contentsOf: store.recordURL(record.jobId), encoding: .utf8)
        #expect(text.range(of: #""started_at" : "\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d([+-]\d\d:\d\d|Z)""#, options: .regularExpression) != nil)
        #expect(text.contains("\"env_keys\""))
        #expect(!FileManager.default.fileExists(atPath: store.recordURL(record.jobId).path + ".tmp"))
    }

    @Test func `Unknown state fails to decode`() throws {
        let dir = try TempDir()
        let store = JobStore(paths: StatePaths(root: dir.url))
        let record = sampleRecord()
        try store.save(record)
        let url = store.recordURL(record.jobId)
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\"running\"", with: "\"zombie\"")
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ContainerMCPError.self) { try store.load(record.jobId) }
    }

    @Test func `Unknown or malformed id is job_not_found`() throws {
        let dir = try TempDir()
        let store = JobStore(paths: StatePaths(root: dir.url))
        #expect(throws: ContainerMCPError(.jobNotFound, "no job with id ../x")) { try store.load("../x") }
        #expect(store.loadAll().isEmpty)
    }

    @Test func `loadAll returns saved records in id order`() throws {
        let dir = try TempDir()
        let store = JobStore(paths: StatePaths(root: dir.url))
        try store.save(sampleRecord(id: "cj-20261121000001-000002"))
        try store.save(sampleRecord(id: "cj-20261121000000-000001"))
        #expect(store.loadAll().map(\.jobId) == ["cj-20261121000000-000001", "cj-20261121000001-000002"])
    }

    @Test(arguments: [
        ([SleepEvent](), false, "false"),
        ([SleepEvent(kind: .sleep, at: Date())], false, "true"),
        ([SleepEvent](), true, "unknown"),
    ])
    func `host_slept_during_job table`(events: [SleepEvent], gap: Bool, expected: String) {
        var record = sampleRecord()
        record.sleepEvents = events
        record.monitoringGap = gap
        #expect("\(record.hostSleptDuringJob)" == expected)
    }
}

struct WrapperScriptTests {
    /// Runs the wrapper on the host's /bin/sh with a scratch state directory.
    func runWrapper(_ command: [String], stateDir: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Wrapper.script(jobId: "cj-20261121000000-abcdef", stateDir: stateDir), "che-job"] + command
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test func `Exit code is written to the file and the marker`() throws {
        let dir = try TempDir()
        let state = try dir.dir("state")
        let result = try runWrapper(["sh", "-c", "exit 3"], stateDir: state)
        #expect(result.status == 3)
        #expect(try String(contentsOfFile: state + "/exit_code", encoding: .utf8) == "3\n")
        #expect(!FileManager.default.fileExists(atPath: state + "/exit_code.tmp"))
        #expect(Wrapper.exitCode(fromLog: result.output, jobId: "cj-20261121000000-abcdef") == 3)
    }

    @Test func `Arguments with spaces are not re-split`() throws {
        let dir = try TempDir()
        let result = try runWrapper(["printf", "%s\\n", "a b"], stateDir: try dir.dir("state"))
        #expect(result.output.hasPrefix("a b\n"))
        #expect(result.status == 0)
    }

    @Test func `The command does not inherit an ignored SIGINT`() throws {
        // A non-interactive shell ignores SIGINT and SIGQUIT in background jobs, and bash cannot
        // trap a signal ignored on entry: a CI suite's SIGINT termination test failed 3/3 under
        // the first (backgrounding) wrapper.
        let dir = try TempDir()
        let result = try runWrapper(["sh", "-c", "kill -INT $$; echo survived"], stateDir: try dir.dir("state"))
        #expect(!result.output.contains("survived"))
        #expect(result.status == 130)
    }

    @Test func `Marker for another job is ignored`() {
        #expect(Wrapper.exitCode(fromLog: "__CHE_JOB_EXIT__ cj-other 1\n", jobId: "cj-me") == nil)
        #expect(Wrapper.exitCode(fromLog: "x\n__CHE_JOB_EXIT__ cj-me 0\n__CHE_JOB_EXIT__ cj-me 7\n", jobId: "cj-me") == 7)
    }

    @Test func `Run argv uses /bin/sh entrypoint, no --rm, progress none`() {
        let spec = RunSpec(name: "cj-20261121000000-abcdef", image: "img",
                           mounts: [MountSpec(hostPath: "/h/src", containerPath: "/src", readonly: true)],
                           cpus: 8, memory: "16G", workdir: "/src", env: [:], command: ["swift", "test", "-t"])
        let invocation = ContainerJobRuntime.runInvocation(spec)
        #expect(!invocation.argv.contains("--rm"))
        #expect(invocation.options.firstRange(of: ["--progress", "none"]) != nil)
        #expect(invocation.options.firstRange(of: ["--entrypoint", "/bin/sh"]) != nil)
        #expect(invocation.options.firstRange(of: ["--mount", "type=bind,source=/h/src,target=/src,readonly"]) != nil)
        #expect(invocation.options.firstRange(of: ["-c", "8", "-m", "16G"]) != nil)
        #expect(Array(invocation.positional.prefix(2)) == ["img", "-c"])
        #expect(Array(invocation.positional.suffix(4)) == ["che-job", "swift", "test", "-t"])
        #expect(throws: Never.self) { try invocation.validate() }
    }
}
