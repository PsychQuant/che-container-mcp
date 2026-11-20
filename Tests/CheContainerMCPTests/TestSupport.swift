import Foundation
@testable import CheContainerMCPCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    static func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }
}

import Testing

/// Records every call and answers from a script keyed by the argv's leading words.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    struct Call: Equatable { var executable: String; var arguments: [String] }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var responses: [(prefix: [String], output: CommandOutput)] = []
    private var errors: [(prefix: [String], error: Error)] = []
    var alivePids: Set<Int32> = []
    var nextPid: Int32 = 4242
    /// Called inside `spawnDetached`; when set, the spawned pid starts out finished.
    var onSpawn: (() -> Void)?
    /// Awaited before answering a call whose argv starts with `gatePrefix` (simulates a slow CLI).
    var gatePrefix: [String]?
    var gate: (() async -> Void)?

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var argvs: [[String]] { calls.map(\.arguments) }

    /// Later registrations win over earlier ones for the same prefix.
    func on(_ prefix: [String], status: Int32 = 0, stdout: String = "", stderr: String = "") {
        on(prefix, CommandOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)))
    }
    func on(_ prefix: [String], _ output: CommandOutput) {
        lock.lock(); responses.insert((prefix, output), at: 0); lock.unlock()
    }
    func fail(_ prefix: [String], with error: Error) {
        lock.lock(); errors.insert((prefix, error), at: 0); lock.unlock()
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        lock.lock()
        _calls.append(Call(executable: executable, arguments: arguments))
        let error = errors.first { arguments.starts(with: $0.prefix) }?.error
        let response = responses.first { arguments.starts(with: $0.prefix) }?.output
        let gate = gatePrefix.map { arguments.starts(with: $0) } == true ? self.gate : nil
        lock.unlock()
        if let gate { await gate() }
        if let error { throw error }
        return response ?? CommandOutput(status: 0)
    }

    func spawnDetached(_ executable: String, _ arguments: [String], logFile: URL) throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        _calls.append(Call(executable: executable, arguments: arguments))
        let pid = nextPid
        nextPid += 1
        if let onSpawn {
            lock.unlock()
            onSpawn()
            lock.lock()
        } else {
            alivePids.insert(pid)
        }
        return pid
    }

    func isAlive(pid: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return alivePids.contains(pid) }
    func finish(pid: Int32) { lock.lock(); alivePids.remove(pid); lock.unlock() }
}

/// A scratch directory removed when the owner is deinitialized.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("che-container-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // realpath so comparisons with resolved paths hold (/var → /private/var).
        _ = url
    }
    var path: String { MountPlanner.resolve(url.path) ?? url.path }
    func dir(_ name: String) throws -> String {
        let sub = URL(fileURLWithPath: path).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub.path
    }
    func executable(_ name: String, script: String) throws -> String {
        let file = URL(fileURLWithPath: path).appendingPathComponent(name)
        try ("#!/bin/sh\n" + script + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
