import Foundation
import Testing
@testable import CheContainerMCPCore

struct MountPlanTests {
    let dir: TempDir
    let state: URL
    init() throws {
        dir = try TempDir()
        state = URL(fileURLWithPath: try dir.dir("state-root"))
    }

    @Test func `Source is read-only at /src unless writable is requested`() throws {
        let src = try dir.dir("proj")
        let mounts = try MountPlanner.plan(MountRequest(sourceDir: src), config: .builtIn, stateRoot: state)
        #expect(mounts == [MountSpec(hostPath: src, containerPath: "/src", readonly: true)])
        let writable = try MountPlanner.plan(MountRequest(sourceDir: src, sourceWritable: true), config: .builtIn, stateRoot: state)
        #expect(writable.first?.readonly == false)
    }

    @Test func `Output is writable at /out`() throws {
        let out = try dir.dir("results")
        let mounts = try MountPlanner.plan(MountRequest(outputDir: out), config: .builtIn, stateRoot: state)
        #expect(mounts == [MountSpec(hostPath: out, containerPath: "/out", readonly: false)])
    }

    @Test func `Config defaults fill missing directories and mount paths`() throws {
        var config = ServerConfig.builtIn
        config.sourceDir = try dir.dir("a")
        config.outputDir = try dir.dir("b")
        config.sourceMount = "/code"
        config.outputMount = "/res"
        let mounts = try MountPlanner.plan(MountRequest(), config: config, stateRoot: state)
        #expect(mounts.map(\.containerPath) == ["/code", "/res"])
        #expect(mounts.map(\.readonly) == [true, false])
    }

    @Test func `Nothing given means nothing mounted`() throws {
        #expect(try MountPlanner.plan(MountRequest(), config: .builtIn, stateRoot: state).isEmpty)
    }
}

struct MountValidationTests {
    let dir: TempDir
    let state: URL
    let home: String
    init() throws {
        dir = try TempDir()
        state = URL(fileURLWithPath: try dir.dir("state-root"))
        home = try dir.dir("home")
    }

    func plan(_ source: String?, _ output: String? = nil) throws -> [MountSpec] {
        try MountPlanner.plan(MountRequest(sourceDir: source, outputDir: output), config: .builtIn, stateRoot: state, home: home)
    }

    func rejects(_ source: String?, _ output: String? = nil, mentioning text: String) {
        let error = #expect(throws: ContainerMCPError.self) { try plan(source, output) }
        #expect(error?.kind == .invalidMount)
        #expect(error?.message.contains(text) == true, "\(error?.message ?? "") should mention \(text)")
    }

    @Test func `Spec validation table`() throws {
        let proj = try dir.dir("home/proj")
        rejects("proj", mentioning: "not an absolute path")
        rejects(home + "/missing", mentioning: "does not exist")
        rejects("/", mentioning: "root directory")
        rejects(home, mentioning: "home directory itself")
        rejects(proj, try dir.dir("home/proj/out"), mentioning: "inside source_dir")
        rejects(try dir.dir("home/proj/sub"), proj, mentioning: "inside output_dir")
        let sibling = try dir.dir("home/proj-out")
        #expect(try plan(proj, sibling).count == 2)
    }

    @Test func `A file is not a directory`() throws {
        let file = dir.path + "/home/file.txt"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        rejects(file, mentioning: "not a directory")
    }

    @Test func `Same directory twice is rejected`() throws {
        let proj = try dir.dir("home/same")
        rejects(proj, proj, mentioning: "same directory")
    }

    @Test func `Symlink into the source nests after realpath`() throws {
        let proj = try dir.dir("home/proj2")
        let inner = try dir.dir("home/proj2/build")
        let link = dir.path + "/home/link-out"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: inner)
        rejects(proj, link, mentioning: "inside source_dir")
    }

    @Test func `Directories inside the state root are rejected`() throws {
        rejects(try dir.dir("state-root/jobs"), mentioning: "state directory")
    }

    @Test func `Paths with a comma are rejected`() throws {
        rejects(try dir.dir("home/a,b"), mentioning: "comma")
    }

    @Test func `Container paths under /.che-job are rejected`() throws {
        var config = ServerConfig.builtIn
        config.outputMount = "/.che-job/out"
        let error = #expect(throws: ContainerMCPError.self) {
            try MountPlanner.plan(MountRequest(outputDir: try dir.dir("home/o")), config: config, stateRoot: state, home: home)
        }
        #expect(error?.kind == .invalidMount)
    }
}

struct EnvTests {
    @Test func `Keys are sorted and values kept`() throws {
        let pairs = try EnvironmentPolicy.validate(["CI": "1", "A": "x=y"])
        #expect(pairs.map(\.key) == ["A", "CI"])
        #expect(pairs.map(\.value) == ["x=y", "1"])
    }

    @Test(arguments: ["", "A=B"])
    func `Empty or = keys are invalid_argument`(key: String) {
        let error = #expect(throws: ContainerMCPError.self) { try EnvironmentPolicy.validate([key: "v"]) }
        #expect(error?.kind == .invalidArgument)
    }

    @Test func `Run argv passes -e KEY=VALUE and nothing that inherits host env`() {
        let spec = RunSpec(name: "cj-20261121000000-abcdef", image: "img", mounts: [], cpus: 8, memory: "16G",
                           workdir: "/src", env: ["CI": "1"], command: ["true"])
        let argv = ContainerJobRuntime.runInvocation(spec).argv
        #expect(argv.contains("CI=1"))
        #expect(!argv.contains("--env-file") && !argv.contains("--secret") && !argv.contains("--ssh"))
    }
}

struct ImageReferenceTests {
    @Test(arguments: [
        ("alpine", "docker.io/library/alpine:latest"),
        ("swift:6.0.3-noble", "docker.io/library/swift:6.0.3-noble"),
        ("ghcr.io/org/tool:1.2", "ghcr.io/org/tool:1.2"),
        ("org/tool", "docker.io/org/tool:latest"),
        ("localhost:5000/x", "localhost:5000/x:latest"),
    ])
    func `Normalization table`(input: String, expected: String) throws {
        #expect(try ImageReference.normalize(input) == expected)
    }

    @Test func `Empty reference is invalid_argument`() {
        #expect(throws: ContainerMCPError.self) { try ImageReference.normalize(" ") }
    }
}
