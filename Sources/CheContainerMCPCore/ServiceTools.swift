import CryptoKit
import Darwin
import Foundation

/// A background `image pull` in progress, recorded so a later call waits on it instead of
/// starting another (spec: Ensure an image is present locally).
struct PullRecord: Codable {
    var pid: Int32
    var reference: String
    var startedAt: Date

    enum CodingKeys: String, CodingKey {
        case pid, reference
        case startedAt = "started_at"
    }
}

extension JobManager {
    public static let ensureWaitLimit: TimeInterval = 600

    // MARK: - container_status

    public func serviceStatus(start: Bool) async throws -> [String: Any] {
        let config = try config()
        let client = client(config)
        guard client.isInstalled else {
            return [
                "cli_path": client.path, "client_version": NSNull(), "server_version": NSNull(),
                "status": "unavailable", "kernel_installed": KernelState.unknown.jsonValue,
                "started_now": false, "runtime": "container",
            ]
        }
        let version = try await cliVersion(client)
        var status = try await client.systemStatus(cliVersion: version)
        var startedNow = false
        if start, status.status != "running" {
            try await client.systemStart()
            status = try await client.systemStatus(cliVersion: version)
            startedNow = status.status == "running"
        }
        return [
            "cli_path": client.path,
            "client_version": status.clientVersion,
            "server_version": status.serverVersion.map { $0 as Any } ?? NSNull(),
            "status": status.status == "running" ? "running" : "stopped",
            "kernel_installed": ContainerClient.kernelState(appRoot: status.appRoot).jsonValue,
            "started_now": startedNow,
            "runtime": "container",
        ]
    }

    // MARK: - container_image_ensure

    public func ensureImage(_ raw: String, platform: String?) async throws -> [String: Any] {
        let config = try config()
        let reference = try ImageReference.normalize(raw)
        let client = client(config)
        let availability = try await containerAvailability(client)
        if let reason = availability.reason { throw ContainerMCPError(.runtimeUnavailable, reason) }
        let version = availability.version ?? ""

        if let image = try await client.images(cliVersion: version).first(where: { $0.reference == reference }) {
            return imageFields(reference, state: "present", image: image)
        }

        let recordURL = pullRecordURL(reference)
        let logURL = recordURL.deletingPathExtension().appendingPathExtension("log")
        var pull = loadPull(recordURL)
        if let existing = pull, runner.isAlive(pid: existing.pid),
           clock.now().timeIntervalSince(existing.startedAt) > CLITimeouts.imagePull {
            kill(existing.pid, SIGTERM)
            try? FileManager.default.removeItem(at: recordURL)
            throw ContainerMCPError(.cliTimeout, "pull of \(reference) ran longer than \(Int(CLITimeouts.imagePull)) seconds and was terminated")
        }
        if pull == nil || !runner.isAlive(pid: pull!.pid) {
            let invocation = ContainerClient.pullInvocation(reference: reference, platform: platform)
            try invocation.validate()
            try FileManager.default.createDirectory(at: paths.pullsDirectory, withIntermediateDirectories: true)
            let pid = try runner.spawnDetached(client.path, invocation.argv, logFile: logURL)
            pull = PullRecord(pid: pid, reference: reference, startedAt: clock.now())
            try JobStore.atomicWrite(try JobStore.encoder.encode(pull!), to: recordURL)
        }

        let waitStart = clock.now()
        while runner.isAlive(pid: pull!.pid) {
            if clock.now().timeIntervalSince(waitStart) >= Self.ensureWaitLimit {
                return ["image": reference, "state": "pulling", "digest": NSNull(), "size_bytes": NSNull(), "runtime": "container"]
            }
            try await clock.sleep(Self.waitPollInterval)
        }
        try? FileManager.default.removeItem(at: recordURL)
        if let image = try await client.images(cliVersion: version).first(where: { $0.reference == reference }) {
            return imageFields(reference, state: "pulled", image: image)
        }
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        throw ContainerMCPError(.cliFailed, "pull of \(reference) finished but the image is not local: "
                                    + String(Self.lastLines(log, 5).joined(separator: " | ").prefix(2_000)))
    }

    private func imageFields(_ reference: String, state: String, image: ImageSummary) -> [String: Any] {
        ["image": reference, "state": state, "digest": image.digest,
         "size_bytes": image.sizeBytes.map { $0 as Any } ?? NSNull(), "runtime": "container"]
    }

    func pullRecordURL(_ reference: String) -> URL {
        let digest = SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }.joined()
        return paths.pullsDirectory.appendingPathComponent("\(digest).json")
    }

    private func loadPull(_ url: URL) -> PullRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JobStore.decoder.decode(PullRecord.self, from: data)
    }
}
