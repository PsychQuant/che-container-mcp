import Foundation
import Testing
@testable import CheContainerMCPCore

struct CLIInvocationTests {
    @Test(arguments: ["-i", "-t", "--tty", "--interactive", "--follow", "-it"])
    func `Forbidden options are refused`(flag: String) {
        #expect(throws: ContainerMCPError.self) { try Invocation(["run"], options: [flag]).validate() }
    }

    @Test func `User command tokens after the image are not checked`() throws {
        try Invocation(["run"], options: ["-d"], positional: ["img", "swift", "test", "-t", "--follow"]).validate()
    }

    @Test func `stats without --no-stream is refused`() throws {
        #expect(throws: ContainerMCPError.self) { try Invocation(["stats"], options: ["--format", "json"]).validate() }
        try Invocation(["stats"], options: ["--no-stream"]).validate()
    }

    @Test func `logs -f is refused`() {
        #expect(throws: ContainerMCPError.self) { try Invocation(["logs"], options: ["-f"], positional: ["x"]).validate() }
    }

    @Test func `Missing executable is runtime_unavailable and starts nothing`() async throws {
        let runner = FakeCommandRunner()
        let client = ContainerClient(path: "/nonexistent/container", runner: runner)
        let error = await #expect(throws: ContainerMCPError.self) {
            try await client.call(Invocation(["list"]))
        }
        #expect(error?.kind == .runtimeUnavailable)
        #expect(error?.message.contains("/nonexistent/container") == true)
        #expect(runner.calls.isEmpty)
    }

    @Test func `Path comes from config or the default`() {
        var config = ServerConfig.builtIn
        #expect(ContainerClient(config: config, runner: FakeCommandRunner()).path == "/usr/local/bin/container")
        config.containerPath = "/opt/container"
        #expect(ContainerClient(config: config, runner: FakeCommandRunner()).path == "/opt/container")
    }

    @Test func `Timeout terminates the child and throws cli_timeout`() async throws {
        let dir = try TempDir()
        let stub = try dir.executable("slow", script: "sleep 30")
        let start = Date()
        let error = await #expect(throws: ContainerMCPError.self) {
            try await ProcessCommandRunner().run(stub, [], timeout: 1)
        }
        #expect(error?.kind == .cliTimeout)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func `Non-zero exit becomes cli_failed with stderr`() async throws {
        let dir = try TempDir()
        let stub = try dir.executable("container", script: "echo 'boom happened' >&2; exit 2")
        let client = ContainerClient(path: stub, runner: ProcessCommandRunner())
        let error = await #expect(throws: ContainerMCPError.self) { try await client.call(Invocation(["list"])) }
        #expect(error?.kind == .cliFailed)
        #expect(error?.message.contains("boom happened") == true)
        #expect(error?.message.contains("status 2") == true)
    }

    @Test func `Arguments reach the child unsplit and without a shell`() async throws {
        let dir = try TempDir()
        let stub = try dir.executable("echoargs", script: #"for a in "$@"; do printf '[%s]\n' "$a"; done"#)
        let output = try await ProcessCommandRunner().run(stub, ["a b", "$HOME", ";ls"], timeout: 5)
        #expect(output.stdoutString == "[a b]\n[$HOME]\n[;ls]\n")
    }

    @Test func `Large output does not deadlock`() async throws {
        let dir = try TempDir()
        let stub = try dir.executable("big", script: "i=0; while [ $i -lt 20000 ]; do echo 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done")
        let output = try await ProcessCommandRunner().run(stub, [], timeout: 30)
        #expect(output.stdout.count > 1_000_000)
    }

    @Test func `Version is parsed from the CLI banner`() throws {
        #expect(ContainerClient.parseVersion(try Fixture.text("container-version.txt")) == "1.7.1")
    }
}
