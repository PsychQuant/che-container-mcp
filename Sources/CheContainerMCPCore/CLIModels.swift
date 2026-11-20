import Foundation

/// `container system status --format json`.
public struct SystemStatus: Sendable, Equatable {
    public var status: String
    public var clientVersion: String
    public var serverVersion: String?
    public var appRoot: String?
}

/// One local image from `container image list --format json`.
public struct ImageSummary: Sendable, Equatable {
    /// Fully qualified reference, e.g. `docker.io/library/swift:6.0.3-noble`.
    public var reference: String
    public var digest: String
    /// Size of the linux variant for `architecture` (the host's), or the largest linux variant.
    public var sizeBytes: Int64?
}

/// One container from `container list --all --format json`.
public struct ContainerSummary: Sendable, Equatable {
    public var id: String
    public var labels: [String: String]
    public var state: String
    public var startedDate: Date?

    public var isRunning: Bool { state == "running" }
}

/// Tolerant JSON parsing (spec: Tolerant parsing of CLI JSON output). Unknown fields are
/// ignored; a missing or mistyped required field throws `cli_output_unexpected` naming the
/// field and the CLI version.
public enum CLIJSON {
    public static func systemStatus(_ data: Data, cliVersion: String) throws -> SystemStatus {
        let root = try object(data, what: "system status", cliVersion: cliVersion)
        let status = try string(root["status"], field: "status", cliVersion: cliVersion)
        let client = (root["client"] as? [String: Any]).flatMap { $0["version"] as? String }
        let server = (root["server"] as? [String: Any]).flatMap { $0["version"] as? String }
        let appRoot = (root["paths"] as? [String: Any]).flatMap { $0["appRoot"] as? String }
        return SystemStatus(status: status, clientVersion: client ?? cliVersion, serverVersion: server, appRoot: appRoot)
    }

    public static func images(_ data: Data, cliVersion: String, architecture: String = hostArchitecture) throws -> [ImageSummary] {
        let items = try array(data, what: "image list", cliVersion: cliVersion)
        return try items.map { item in
            let configuration = try dict(item["configuration"], field: "configuration", cliVersion: cliVersion)
            let name = try string(configuration["name"], field: "configuration.name", cliVersion: cliVersion)
            let descriptor = try dict(configuration["descriptor"], field: "configuration.descriptor", cliVersion: cliVersion)
            let digest = try string(descriptor["digest"], field: "configuration.descriptor.digest", cliVersion: cliVersion)
            let variants = (item["variants"] as? [[String: Any]]) ?? []
            let linux = variants.filter { (($0["platform"] as? [String: Any])?["os"] as? String) == "linux" }
            let matching = linux.first { (($0["platform"] as? [String: Any])?["architecture"] as? String) == architecture }
            let size = (matching ?? linux.max { int64($0["size"]) < int64($1["size"]) }).map { int64($0["size"]) }
            return ImageSummary(reference: name, digest: digest, sizeBytes: size)
        }
    }

    public static func containers(_ data: Data, cliVersion: String) throws -> [ContainerSummary] {
        let items = try array(data, what: "container list", cliVersion: cliVersion)
        return try items.map { item in
            let configuration = try dict(item["configuration"], field: "configuration", cliVersion: cliVersion)
            let id = try string(configuration["id"], field: "configuration.id", cliVersion: cliVersion)
            let labels = (configuration["labels"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            let status = try dict(item["status"], field: "status", cliVersion: cliVersion)
            let state = try string(status["state"], field: "status.state", cliVersion: cliVersion)
            let started = (status["startedDate"] as? String).flatMap(ISO8601.parse)
            return ContainerSummary(id: id, labels: labels, state: state, startedDate: started)
        }
    }

    // MARK: - helpers

    public static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    private static func object(_ data: Data, what: String, cliVersion: String) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data), let root = value as? [String: Any] else {
            throw unexpected("\(what) output is not a JSON object", cliVersion)
        }
        return root
    }

    private static func array(_ data: Data, what: String, cliVersion: String) throws -> [[String: Any]] {
        guard let value = try? JSONSerialization.jsonObject(with: data), let items = value as? [[String: Any]] else {
            throw unexpected("\(what) output is not a JSON array of objects", cliVersion)
        }
        return items
    }

    private static func string(_ value: Any?, field: String, cliVersion: String) throws -> String {
        guard let text = value as? String else { throw unexpected("missing or non-string field `\(field)`", cliVersion) }
        return text
    }

    private static func dict(_ value: Any?, field: String, cliVersion: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw unexpected("missing or non-object field `\(field)`", cliVersion) }
        return object
    }

    private static func int64(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }

    private static func unexpected(_ detail: String, _ cliVersion: String) -> ContainerMCPError {
        ContainerMCPError(.cliOutputUnexpected, "container CLI \(cliVersion): \(detail)")
    }
}

/// ISO 8601 with an explicit offset (the job record's time format).
public enum ISO8601 {
    public static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Formats in the host's time zone with its offset, e.g. `2026-11-21T02:14:11+08:00`.
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
