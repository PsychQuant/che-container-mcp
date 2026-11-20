import Foundation
import Testing
@testable import CheContainerMCPCore

/// Runs against the real `container` service. Enabled only with CHE_CONTAINER_LIVE=1, and
/// uses an image that is already local (CHE_CONTAINER_LIVE_IMAGE, default swift:6.0.3-noble).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CHE_CONTAINER_LIVE"] == "1"))
struct LiveTests {
    let dir: TempDir
    let paths: StatePaths
    let image = ProcessInfo.processInfo.environment["CHE_CONTAINER_LIVE_IMAGE"] ?? "swift:6.0.3-noble"

    init() throws {
        dir = try TempDir()
        paths = StatePaths(root: URL(fileURLWithPath: try dir.dir("state")))
    }

    func manager() -> JobManager {
        JobManager(paths: paths, runner: ProcessCommandRunner(), power: FakePower())
    }

    func containerCount() async throws -> Int {
        let client = ContainerClient(path: ContainerClient.defaultPath, runner: ProcessCommandRunner())
        return try await client.containers(cliVersion: "live").count
    }

    @Test func `exit 3 is reported from the exit code file`() async throws {
        let m = manager()
        let run = try await m.run(RunRequest(image: image, command: ["sh", "-c", "echo hi; exit 3"], cpus: 1, memory: "512M", workdir: "/"))
        let id = try #require(run["job_id"] as? String)
        let waited = try await m.wait(jobId: id, timeoutSeconds: 120)
        #expect(waited["state"] as? String == "exited")
        let result = try await m.result(jobId: id, tailLines: 10, keepContainer: false)
        #expect(result["exit_code"] as? Int == 3)
        #expect(result["exit_code_source"] as? String == "file")
        #expect((result["tail"] as? [String])?.first == "hi")
        #expect(result["container_deleted"] as? Bool == true)
    }

    @Test func `A job started before a restart is read by a new instance`() async throws {
        let id = try #require(try await manager().run(RunRequest(image: image, command: ["sh", "-c", "sleep 3; exit 4"],
                                                                 cpus: 1, memory: "512M", workdir: "/")))["job_id"] as? String
        let fresh = manager()
        _ = try await fresh.wait(jobId: try #require(id), timeoutSeconds: 120)
        let result = try await fresh.result(jobId: id!, tailLines: 5, keepContainer: false)
        #expect(result["exit_code"] as? Int == 4)
    }

    @Test func `Cancel removes the container and keeps the log`() async throws {
        let m = manager()
        let id = try #require(try await m.run(RunRequest(image: image, command: ["sh", "-c", "echo started; sleep 300"],
                                                         cpus: 1, memory: "512M", workdir: "/"))["job_id"] as? String)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let cancelled = try await m.cancel(jobId: id, graceSeconds: 5)
        #expect(cancelled["state"] as? String == "cancelled")
        let client = ContainerClient(path: ContainerClient.defaultPath, runner: ProcessCommandRunner())
        #expect(try await client.containers(cliVersion: "live").contains { $0.id == id } == false)
        let log = try #require(cancelled["log_path"] as? String)
        #expect(try String(contentsOfFile: log, encoding: .utf8).contains("started"))
    }

    @Test func `Preflight errors start no container`() async throws {
        let m = manager()
        let before = try await containerCount()
        await #expect(throws: ContainerMCPError.self) {
            try await m.run(RunRequest(image: "docker.io/library/does-not-exist:never", command: ["true"]))
        }
        await #expect(throws: ContainerMCPError.self) {
            try await m.run(RunRequest(image: image, command: ["true"], mounts: MountRequest(sourceDir: "/")))
        }
        try JSONSerialization.data(withJSONObject: ["container_path": "/nonexistent/container"]).write(to: paths.configFile)
        let error = await #expect(throws: ContainerMCPError.self) {
            try await m.run(RunRequest(image: image, command: ["true"]))
        }
        #expect(error?.kind == .runtimeUnavailable)
        #expect(try await containerCount() == before)
    }
}
