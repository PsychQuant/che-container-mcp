import Darwin
import Foundation
import Testing
@testable import CheContainerMCPCore

/// Resumes a suspended fake CLI call when the test says so.
actor Latch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reached = false
    func wait() async {
        reached = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}

@Suite struct StartRaceTests {
    @Test func `A reconcile while run -d is still starting does not mark the job lost`() async throws {
        let h = try Harness()
        let latch = Latch()
        h.runner.gatePrefix = ["run"]
        h.runner.gate = { await latch.wait() }
        h.containers([])                       // the container is not listed yet
        let start = Task { try await h.startJob() }
        while !(await latch.reached) { await Task.yield() }
        await h.manager.reconcileRunning()    // the 15-second monitor fires mid-start
        let midway = try #require(h.store.loadAll().first)
        #expect(midway.state == .running)
        #expect(midway.launched != true)
        await latch.open()
        let id = try await start.value
        let record = try h.store.load(id)
        #expect(record.state == .running && record.launched == true && !record.containerDeleted)
    }

    @Test func `An unlaunched record older than the start timeout is lost`() async throws {
        let h = try Harness()
        var record = sampleRecord(id: "cj-20261121000000-0000aa", started: h.time.now)
        record.launched = nil
        try h.store.save(record)
        h.containers([])
        h.time.advance(JobManager.startTimeout + 1)
        await h.manager.reconcileRunning()
        #expect(try h.store.load(record.jobId).state == .lost)
    }

    @Test func `A sleep event saved during a reconcile is not overwritten`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "stopped")])
        let latch = Latch()
        h.runner.gatePrefix = ["logs"]
        h.runner.gate = { await latch.wait() }
        let reconcile = Task { await h.manager.reconcileRunning() }
        while !(await latch.reached) { await Task.yield() }
        await h.manager.recordSleepEvent(.sleep, at: h.time.now)
        await latch.open()
        await reconcile.value
        #expect(try h.store.load(id).sleepEvents.count == 1)
    }
}

@Suite struct HardeningTests {
    @Test func `A mount that contains the state root is rejected`() throws {
        let dir = try TempDir()
        let parent = try dir.dir("Library")
        let state = URL(fileURLWithPath: try dir.dir("Library/Application Support/che-container-mcp"))
        let error = #expect(throws: ContainerMCPError.self) {
            try MountPlanner.plan(MountRequest(outputDir: parent), config: .builtIn, stateRoot: state, home: try dir.dir("home"))
        }
        #expect(error?.kind == .invalidMount)
        #expect(error?.message.contains("contains the server's state directory") == true)
    }

    @Test func `A symlinked exit_code is ignored`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        let target = h.dir.path + "/secret"
        try "7\n".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: h.store.exitCodeURL(id).path, withDestinationPath: target)
        h.containers([ContainerEntry(id: id, state: "running")])
        _ = try await h.manager.status(jobId: id)
        #expect(try h.store.load(id).state == .running)
    }

    @Test func `A FIFO exit_code does not block`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        #expect(mkfifo(h.store.exitCodeURL(id).path, 0o644) == 0)
        h.containers([ContainerEntry(id: id, state: "running")])
        _ = try await h.manager.status(jobId: id)   // returns instead of hanging
        #expect(try h.store.load(id).state == .running)
    }

    @Test func `An oversized exit_code is ignored`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        try String(repeating: "1", count: 100).write(to: h.store.exitCodeURL(id), atomically: true, encoding: .utf8)
        h.containers([ContainerEntry(id: id, state: "running")])
        _ = try await h.manager.status(jobId: id)
        #expect(try h.store.load(id).state == .running)
    }
}
