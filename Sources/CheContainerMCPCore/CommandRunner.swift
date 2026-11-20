import Darwin
import Foundation

/// What a finished child process produced.
public struct CommandOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs executables by absolute path with an argument array — never through a shell.
public protocol CommandRunner: Sendable {
    /// Runs to completion or until `timeout` seconds pass. On timeout the child is
    /// terminated (then killed) and `cli_timeout` is thrown.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput

    /// Starts a child that outlives this call (used for `image pull`). Output goes to `logFile`.
    /// Returns the child's pid.
    func spawnDetached(_ executable: String, _ arguments: [String], logFile: URL) throws -> Int32

    /// Whether `pid` is still a live process.
    func isAlive(pid: Int32) -> Bool
}

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ContainerMCPError(.runtimeUnavailable, "executable not found: \(executable)")
        }
        // Output goes to temporary files, not pipes: `container logs` of a long CI run is far
        // larger than a pipe buffer, and draining a pipe only after exit would deadlock.
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("che-container-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("che-container-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        let timedOut = TimeoutFlag()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: ContainerMCPError(.cliFailed, "could not start \(executable)"))
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        try? outHandle.close()
        try? errHandle.close()
        if timedOut.value {
            let name = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.prefix(2)).joined(separator: " ")
            throw ContainerMCPError(.cliTimeout, "\(name) did not finish within \(Int(timeout)) seconds and was terminated")
        }
        return CommandOutput(status: status,
                             stdout: (try? Data(contentsOf: outURL)) ?? Data(),
                             stderr: (try? Data(contentsOf: errURL)) ?? Data())
    }

    public func spawnDetached(_ executable: String, _ arguments: [String], logFile: URL) throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ContainerMCPError(.runtimeUnavailable, "executable not found: \(executable)")
        }
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        // Keep the Process so Foundation reaps the child when it exits; a zombie would still
        // answer kill(pid, 0) and look alive forever.
        DetachedChildren.shared.add(process)
        return process.processIdentifier
    }

    public func isAlive(pid: Int32) -> Bool {
        if let owned = DetachedChildren.shared.process(pid) { return owned.isRunning }
        return pid > 0 && kill(pid, 0) == 0   // started by another server process
    }
}

/// Children started with `spawnDetached` by this process.
final class DetachedChildren: @unchecked Sendable {
    static let shared = DetachedChildren()
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]

    func add(_ process: Process) {
        lock.lock(); processes[process.processIdentifier] = process; lock.unlock()
    }

    func process(_ pid: Int32) -> Process? {
        lock.lock(); defer { lock.unlock() }; return processes[pid]
    }
}

/// Set once from the timeout timer, read after the child exits.
final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
