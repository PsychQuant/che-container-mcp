import Foundation
import Testing
@testable import CheContainerMCPCore

@Suite struct ServiceStatusTests {
    @Test func `Running service`() async throws {
        let h = try Harness()
        let status = try await h.manager.serviceStatus(start: false)
        #expect(status["status"] as? String == "running")
        #expect(status["started_now"] as? Bool == false)
        #expect(status["client_version"] as? String == "1.7.1")
        #expect(status["kernel_installed"] as? Bool == true)
        #expect(status["runtime"] as? String == "container")
    }

    @Test func `Stopped service is reported and not started without start`() async throws {
        let h = try Harness()
        h.serviceRunning(false)
        let status = try await h.manager.serviceStatus(start: false)
        #expect(status["status"] as? String == "stopped")
        #expect(!h.runner.argvs.contains { $0.starts(with: ["system", "start"]) })
    }

    @Test func `start: true starts a stopped service with kernel install`() async throws {
        let h = try Harness()
        h.serviceRunning(false)
        h.runner.on(["system", "start"], stdout: "")
        let before = h.runner.argvs.count
        // The second status call (after start) answers running.
        let task = Task { try await h.manager.serviceStatus(start: true) }
        while !h.runner.argvs.dropFirst(before).contains(where: { $0.starts(with: ["system", "start"]) }) { await Task.yield() }
        let result = try await task.value
        let start = try #require(h.runner.argvs.first { $0.starts(with: ["system", "start"]) })
        #expect(start == ["system", "start", "--enable-kernel-install", "--timeout", "60"])
        _ = result
    }

    @Test func `Missing CLI reports unavailable instead of failing`() async throws {
        let h = try Harness()
        try h.writeConfig(["container_path": "/nonexistent/container"])
        let status = try await h.manager.serviceStatus(start: false)
        #expect(status["status"] as? String == "unavailable")
    }

    @Test(arguments: [(true, "installed"), (false, "missing")])
    func `Kernel state from appRoot`(present: Bool, expected: String) throws {
        let h = try Harness(kernel: present)
        let state = ContainerClient.kernelState(appRoot: h.appRoot)
        #expect("\(state)" == expected)
        #expect(ContainerClient.kernelState(appRoot: nil) == .unknown)
        #expect(ContainerClient.kernelState(appRoot: "/nonexistent") == .unknown)
    }
}
