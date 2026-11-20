import Foundation
import Testing
@testable import CheContainerMCPCore

@Suite struct PreflightTests {
    func expectNoStart(_ h: Harness) {
        #expect(!h.runner.argvs.contains { $0.first == "run" })
        #expect(!h.runner.argvs.contains { $0.starts(with: ["image", "pull"]) })
    }

    func runError(_ h: Harness, _ request: RunRequest = RunRequest(image: "swift:6.0.3-noble", command: ["true"])) async -> ContainerMCPError? {
        await #expect(throws: ContainerMCPError.self) { _ = try await h.manager.run(request) }
    }

    @Test func `Malformed config is config_invalid`() async throws {
        let h = try Harness()
        try Data("{bad".utf8).write(to: h.paths.configFile)
        #expect(await runError(h)?.kind == .configInvalid)
        expectNoStart(h)
    }

    @Test func `Missing executable is runtime_unavailable`() async throws {
        let h = try Harness()
        try h.writeConfig(["container_path": "/nonexistent/container"])
        let error = await runError(h)
        #expect(error?.kind == .runtimeUnavailable)
        #expect(error?.message.contains("not found") == true)
        expectNoStart(h)
    }

    @Test func `Stopped service is runtime_unavailable naming the service`() async throws {
        let h = try Harness()
        h.serviceRunning(false)
        let error = await runError(h)
        #expect(error?.kind == .runtimeUnavailable)
        #expect(error?.message.contains("service is not running") == true)
        expectNoStart(h)
    }

    @Test func `Missing kernel is kernel_missing`() async throws {
        let h = try Harness(kernel: false)
        #expect(await runError(h)?.kind == .kernelMissing)
        expectNoStart(h)
    }

    @Test func `Absent image is image_not_found and is not pulled`() async throws {
        let h = try Harness()
        let error = await runError(h, RunRequest(image: "alpine", command: ["true"]))
        #expect(error?.kind == .imageNotFound)
        #expect(error?.message.contains("container_image_ensure") == true)
        expectNoStart(h)
    }

    @Test func `Bad mount is invalid_mount`() async throws {
        let h = try Harness()
        #expect(await runError(h, RunRequest(image: "swift:6.0.3-noble", command: ["true"], mounts: MountRequest(sourceDir: "/")))?.kind == .invalidMount)
        expectNoStart(h)
    }

    @Test func `Empty command is invalid_argument`() async throws {
        let h = try Harness()
        #expect(await runError(h, RunRequest(image: "swift:6.0.3-noble", command: []))?.kind == .invalidArgument)
        expectNoStart(h)
    }
}

@Suite struct RunToolTests {
    @Test func `Successful run returns immediately with the job fields and holds the assertion`() async throws {
        let h = try Harness()
        let source = try h.dir.dir("src")
        let result = try await h.manager.run(RunRequest(image: "swift:6.0.3-noble", command: ["swift", "test"],
                                                         mounts: MountRequest(sourceDir: source)))
        let id = try #require(result["job_id"] as? String)
        #expect(JobId.isValid(id))
        #expect(result["container_name"] as? String == id)
        #expect(result["runtime"] as? String == "container")
        #expect(result["state"] as? String == "running")
        #expect((result["mounts"] as? [[String: Any]])?.first?["readonly"] as? Bool == true)
        let run = try #require(h.runner.argvs.first { $0.first == "run" })
        #expect(!run.contains("--rm"))
        #expect(run.firstRange(of: ["--progress", "none"]) != nil)
        #expect(run.firstRange(of: ["-c", "8", "-m", "16G"]) != nil)
        #expect(run.contains { $0.hasSuffix("target=/.che-job") })
        #expect(try h.store.load(id).state == .running)
        #expect(h.power.isHeld)
    }

    @Test func `Failed start records failed_to_start and returns cli_failed with the job id`() async throws {
        let h = try Harness()
        h.runner.on(["run"], status: 1, stderr: "Error: exec format error")
        let error = await #expect(throws: ContainerMCPError.self) { try await h.startJob() }
        #expect(error?.kind == .cliFailed)
        let id = try #require(h.store.loadAll().first?.jobId)
        #expect(error?.message.contains(id) == true)
        let record = try h.store.load(id)
        #expect(record.state == .failedToStart)
        #expect(record.startError?.contains("exec format error") == true)
        #expect(!h.power.isHeld)
    }
}

@Suite struct ReconcileTests {
    func reconciled(_ h: Harness, _ id: String) async throws -> JobRecord {
        _ = try await h.manager.status(jobId: id)
        return try h.store.load(id)
    }

    @Test func `Exit code file wins and gives ended_at from its mtime`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        let ended = h.time.now.addingTimeInterval(30)
        h.time.advance(40)
        try h.writeExitCode(id, 0, modified: ended)
        h.containers([ContainerEntry(id: id, state: "running")])
        let record = try await reconciled(h, id)
        #expect(record.state == .exited && record.exitCode == 0 && record.exitCodeSource == .file)
        #expect(record.endedAtSource == .exitCodeFile)
        #expect(abs(record.endedAt!.timeIntervalSince(ended)) < 1)
    }

    @Test func `Running container stays running and takes startedDate`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "running", started: "2026-11-20T18:00:00Z")])
        let record = try await reconciled(h, id)
        #expect(record.state == .running)
        #expect(record.startedAt == ISO8601.parse("2026-11-20T18:00:00Z"))
    }

    @Test func `Stopped with marker is exited from the log`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "stopped")])
        h.logs("x\n__CHE_JOB_EXIT__ \(id) 1\n")
        let record = try await reconciled(h, id)
        #expect(record.state == .exited && record.exitCode == 1 && record.exitCodeSource == .logMarker)
        #expect(record.endedAtSource == .observed)
        #expect(record.logPath != nil)
    }

    @Test func `Stopped without file or marker is exited_unknown`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "stopped")])
        h.logs("/bin/sh: not found\n")
        let record = try await reconciled(h, id)
        #expect(record.state == .exitedUnknown && record.exitCode == nil)
    }

    @Test func `Missing container and no file is lost`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([])
        let record = try await reconciled(h, id)
        #expect(record.state == .lost)
    }

    @Test func `Unlabelled containers are never reported or touched`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, labelled: false, state: "running")])
        #expect(try await reconciled(h, id).state == .lost)
        #expect(!h.runner.argvs.contains { ["stop", "delete", "logs"].contains($0.first ?? "") && $0.contains(id) })
    }

    @Test func `A new manager instance reads jobs started by the previous one`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        try h.writeExitCode(id, 5)
        let fresh = JobManager(paths: h.paths, runner: h.runner, clock: h.time.clock, power: FakePower())
        let status = try await fresh.status(jobId: id)
        #expect(status["state"] as? String == "exited")
        h.logs("out\n")
        h.containers([ContainerEntry(id: id, state: "stopped")])
        let result = try await fresh.result(jobId: id, tailLines: 50, keepContainer: true)
        #expect(result["exit_code"] as? Int == 5)
    }
}

@Suite struct LogCaptureTests {
    @Test func `Logs are copied before the container is deleted`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        try h.writeExitCode(id, 0)
        h.containers([ContainerEntry(id: id, state: "stopped")])
        h.logs("line1\nline2\n")
        let result = try await h.manager.result(jobId: id, tailLines: 50, keepContainer: false)
        let subs = h.subcommands()
        let logsIndex = try #require(subs.firstIndex(of: "logs"))
        let deleteIndex = try #require(subs.firstIndex(of: "delete"))
        #expect(logsIndex < deleteIndex)
        #expect(result["container_deleted"] as? Bool == true)
        let path = try #require(result["log_path"] as? String)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "line1\nline2\n")
        // A second result reads the host copy.
        h.containers([])
        let again = try await h.manager.result(jobId: id, tailLines: 50, keepContainer: false)
        #expect(again["tail"] as? [String] == ["line1", "line2"])
    }

    @Test func `Container is kept when the log cannot be copied`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        try h.writeExitCode(id, 0)
        h.containers([ContainerEntry(id: id, state: "stopped")])
        h.runner.fail(["logs"], with: ContainerMCPError(.cliTimeout, "slow"))
        let result = try await h.manager.result(jobId: id, tailLines: 50, keepContainer: false)
        #expect(result["container_deleted"] as? Bool == false)
        #expect(result["cleanup_error"] != nil)
        #expect(!h.subcommands().contains("delete"))
    }
}

@Suite struct JobStatusTests {
    @Test func `Unknown job is job_not_found`() async throws {
        let h = try Harness()
        let error = await #expect(throws: ContainerMCPError.self) { try await h.manager.status(jobId: "cj-20261121000000-000000") }
        #expect(error?.kind == .jobNotFound)
    }

    @Test func `Running job includes the last 20 lines`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "running")])
        h.logs("a\nb\n")
        let status = try await h.manager.status(jobId: id)
        #expect(status["tail"] as? [String] == ["a", "b"])
        #expect(h.runner.argvs.contains { $0.starts(with: ["logs", "-n", "20"]) })
    }

    @Test func `All jobs are listed`() async throws {
        let h = try Harness()
        let a = try await h.startJob()
        h.time.advance(1)
        let b = try await h.startJob()
        h.containers([ContainerEntry(id: a), ContainerEntry(id: b)])
        let all = try await h.manager.status(jobId: nil)
        #expect((all["jobs"] as? [[String: Any]])?.count == 2)
    }
}

@Suite struct JobWaitTests {
    @Test func `Timeout returns timed_out without an error`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "running")])
        let result = try await h.manager.wait(jobId: id, timeoutSeconds: 5)
        #expect(result["timed_out"] as? Bool == true)
        #expect(result["state"] as? String == "running")
        #expect(result["waited_seconds"] as? Int == 5)
    }

    @Test func `Finishing during the wait returns early`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "running")])
        let start = h.time.now
        h.time.onSleep = { now in
            if now.timeIntervalSince(start) >= 3 { try h.writeExitCode(id, 0) }
        }
        let result = try await h.manager.wait(jobId: id, timeoutSeconds: 60)
        #expect(result["timed_out"] as? Bool == false)
        #expect((result["waited_seconds"] as? Int ?? 99) <= 6)
    }

    @Test(arguments: [0, 601])
    func `Out of range timeout is invalid_argument`(seconds: Int) async throws {
        let h = try Harness()
        let id = try await h.startJob()
        let error = await #expect(throws: ContainerMCPError.self) { try await h.manager.wait(jobId: id, timeoutSeconds: seconds) }
        #expect(error?.kind == .invalidArgument)
    }
}

@Suite struct JobResultTests {
    @Test func `Running job is job_not_finished`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "running")])
        let error = await #expect(throws: ContainerMCPError.self) { try await h.manager.result(jobId: id, tailLines: 50, keepContainer: false) }
        #expect(error?.kind == .jobNotFinished)
    }

    @Test func `keep_container leaves the container`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        try h.writeExitCode(id, 2)
        h.containers([ContainerEntry(id: id, state: "stopped")])
        h.logs("x\n")
        let result = try await h.manager.result(jobId: id, tailLines: 50, keepContainer: true)
        #expect(result["container_deleted"] as? Bool == false)
        #expect(result["exit_code"] as? Int == 2)
        #expect(result["exit_code_source"] as? String == "file")
        #expect(!h.subcommands().contains("delete"))
    }

    @Test func `Unknown exit code reports source none`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "stopped")])
        h.logs("nothing\n")
        let result = try await h.manager.result(jobId: id, tailLines: 50, keepContainer: true)
        #expect(result["exit_code_source"] as? String == "none")
        #expect(result["exit_code"] is NSNull)
    }

    @Test func `tail_lines is bounded`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        await #expect(throws: ContainerMCPError.self) { try await h.manager.result(jobId: id, tailLines: 1001, keepContainer: false) }
    }
}

@Suite struct JobCancelTests {
    @Test func `Running job is stopped, logged, then deleted`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "running")])
        h.logs("partial\n")
        let result = try await h.manager.cancel(jobId: id, graceSeconds: 7)
        #expect(result["state"] as? String == "cancelled")
        #expect(result["container_deleted"] as? Bool == true)
        let calls = h.runner.argvs.filter { ["stop", "logs", "delete"].contains($0.first ?? "") }
        #expect(calls.map { $0[0] } == ["stop", "logs", "delete"])
        #expect(calls[0] == ["stop", "--time", "7", id])
        #expect(!h.power.isHeld)
    }

    @Test func `Finished job keeps its state and only loses the container`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        try h.writeExitCode(id, 0)
        h.containers([ContainerEntry(id: id, state: "stopped")])
        let result = try await h.manager.cancel(jobId: id, graceSeconds: 10)
        #expect(result["state"] as? String == "exited")
        #expect(!h.subcommands().contains("stop"))
        #expect(h.subcommands().contains("delete"))
    }
}

@Suite struct SleepReportTests {
    @Test func `Sleep events go to running jobs only`() async throws {
        let h = try Harness()
        let running = try await h.startJob()
        h.time.advance(1)
        let done = try await h.startJob()
        try h.writeExitCode(done, 0)
        h.containers([ContainerEntry(id: running), ContainerEntry(id: done, state: "stopped")])
        await h.manager.reconcileRunning()
        await h.manager.recordSleepEvent(.sleep, at: h.time.now)
        #expect(try h.store.load(running).sleepEvents.count == 1)
        #expect(try h.store.load(done).sleepEvents.isEmpty)
    }

    @Test(arguments: [(59.0, false), (61.0, true)])
    func `Monitoring gap threshold is 60 seconds`(gap: Double, expected: Bool) async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "running")])
        h.time.advance(gap)
        await h.manager.reconcileRunning()
        #expect(try h.store.load(id).monitoringGap == expected)
    }

    @Test func `Gap stays set once recorded`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "running")])
        h.time.advance(300)
        await h.manager.reconcileRunning()
        h.time.advance(5)
        await h.manager.reconcileRunning()
        try h.writeExitCode(id, 0, modified: h.time.now)
        let result = try await h.manager.result(jobId: id, tailLines: 5, keepContainer: true)
        #expect(result["host_slept_during_job"] as? String == "unknown")
    }

    @Test func `Assertion is released once no job runs`() async throws {
        let h = try Harness()
        let id = try await h.startJob()
        h.containers([ContainerEntry(id: id, state: "running")])
        #expect(h.power.isHeld)
        try h.writeExitCode(id, 0)
        await h.manager.reconcileRunning()
        #expect(!h.power.isHeld)
    }
}

@Suite struct DockerAuthorizationTests {
    @Test func `Without authorization an unavailable container never touches Docker`() async throws {
        let h = try Harness()
        h.serviceRunning(false)
        await #expect(throws: ContainerMCPError.self) { try await h.startJob() }
        #expect(!h.runner.calls.contains { $0.executable == h.dockerPath })
    }

    @Test func `Authorized call while container is unavailable runs under Docker`() async throws {
        let h = try Harness()
        h.serviceRunning(false)
        let result = try await h.manager.run(RunRequest(image: "swift:6.0.3-noble", command: ["true"], allowDocker: true))
        #expect(result["runtime"] as? String == "docker")
        let dockerRun = try #require(h.runner.calls.first { $0.executable == h.dockerPath && $0.arguments.first == "run" })
        #expect(dockerRun.arguments.firstRange(of: ["--cpus", "8", "--memory", "16G"]) != nil)
        let id = try #require(result["job_id"] as? String)
        #expect(try h.store.load(id).runtime == .docker)
        #expect(!(try String(contentsOf: h.paths.configFile, encoding: .utf8)).contains("docker"))
        // Later calls for that job use Docker without a new authorization.
        h.runner.on(["ps"], stdout: #"{"Names":"\#(id)","State":"running","Labels":"che-container-mcp.job=\#(id),che-container-mcp.schema=1"}"#)
        let status = try await h.manager.status(jobId: id)
        #expect(status["state"] as? String == "running")
        #expect(status["runtime"] as? String == "docker")
    }

    @Test func `Authorization does not carry over`() async throws {
        let h = try Harness()
        h.serviceRunning(false)
        _ = try await h.manager.run(RunRequest(image: "swift:6.0.3-noble", command: ["true"], allowDocker: true))
        let error = await #expect(throws: ContainerMCPError.self) { try await h.startJob() }
        #expect(error?.kind == .runtimeUnavailable)
    }

    @Test func `Authorization changes nothing when container is available`() async throws {
        let h = try Harness()
        let result = try await h.manager.run(RunRequest(image: "swift:6.0.3-noble", command: ["true"], allowDocker: true))
        #expect(result["runtime"] as? String == "container")
        #expect(!h.runner.calls.contains { $0.executable == h.dockerPath })
    }

    @Test func `Authorized but Docker missing is docker_unavailable`() async throws {
        let h = try Harness()
        h.serviceRunning(false)
        h.dockerFound = false
        let error = await #expect(throws: ContainerMCPError.self) {
            try await h.manager.run(RunRequest(image: "swift:6.0.3-noble", command: ["true"], allowDocker: true))
        }
        #expect(error?.kind == .dockerUnavailable)
    }
}

@Suite struct ImageEnsureTests {
    @Test func `Present image is not pulled`() async throws {
        let h = try Harness()
        let result = try await h.manager.ensureImage("swift:6.0.3-noble", platform: nil)
        #expect(result["state"] as? String == "present")
        #expect(result["size_bytes"] as? Int64 == 963_058_048 || result["size_bytes"] as? Int == 963_058_048)
        #expect(!h.runner.argvs.contains { $0.starts(with: ["image", "pull"]) })
    }

    @Test func `Absent image is pulled in the background and reported pulled`() async throws {
        let h = try Harness()
        // The pull "finishes" as it is spawned; afterwards the image list includes alpine.
        h.runner.onSpawn = {
            h.runner.on(["image", "list"], stdout: #"[{"configuration":{"name":"docker.io/library/alpine:latest","descriptor":{"digest":"sha256:aa"}},"variants":[]}]"#)
        }
        let result = try await h.manager.ensureImage("alpine", platform: nil)
        let pull = try #require(h.runner.argvs.first { $0.starts(with: ["image", "pull"]) })
        #expect(pull == ["image", "pull", "--progress", "none", "docker.io/library/alpine:latest"])
        #expect(result["state"] as? String == "pulled")
        #expect(result["digest"] as? String == "sha256:aa")
    }

    @Test func `Long pull returns pulling and a second call reuses it`() async throws {
        let h = try Harness()
        let first = try await h.manager.ensureImage("alpine", platform: nil)
        #expect(first["state"] as? String == "pulling")
        let second = try await h.manager.ensureImage("alpine", platform: nil)
        #expect(second["state"] as? String == "pulling")
        #expect(h.runner.argvs.filter { $0.starts(with: ["image", "pull"]) }.count == 1)
    }
}

@Suite struct ToolCatalogTests {
    @Test func `tools/list has exactly the seven tools`() {
        #expect(ToolCatalog.tools.map(\.name) == ToolCatalog.names)
        #expect(ToolCatalog.names.count == 7)
    }

    @Test func `Unknown or mistyped arguments are invalid_argument`() async throws {
        let h = try Harness()
        let dispatcher = ToolDispatcher(manager: h.manager)
        await #expect(throws: ContainerMCPError(.invalidArgument, "unknown argument rm")) {
            try await dispatcher.executeToolCall(name: "container_status", arguments: ["rm": .bool(true)])
        }
        let error = await #expect(throws: ContainerMCPError.self) {
            try await dispatcher.executeToolCall(name: "container_run", arguments: ["image": .string("x"), "command": .string("ls")])
        }
        #expect(error?.message == "command must be an array of strings")
    }

    @Test func `Errors come back as an isError envelope`() async throws {
        let h = try Harness()
        let dispatcher = ToolDispatcher(manager: h.manager)
        let result = await dispatcher.callTool(name: "container_job_status", arguments: ["job_id": .string("cj-nope")])
        #expect(result.isError == true)
        guard case .text(let text, _, _) = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("job_not_found"))
    }
}
