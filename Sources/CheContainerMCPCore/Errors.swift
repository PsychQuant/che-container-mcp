import CheMCPKit
import Foundation

/// The closed set of error codes this server returns (design: 錯誤碼). Adding a value is a
/// spec change: `ErrorCodeTests` pins the set.
public enum ErrorCode: String, CaseIterable, Sendable {
    case runtimeUnavailable = "runtime_unavailable"
    case kernelMissing = "kernel_missing"
    case imageNotFound = "image_not_found"
    case invalidMount = "invalid_mount"
    case invalidArgument = "invalid_argument"
    case configInvalid = "config_invalid"
    case jobNotFound = "job_not_found"
    case jobNotFinished = "job_not_finished"
    case cliTimeout = "cli_timeout"
    case cliFailed = "cli_failed"
    case cliOutputUnexpected = "cli_output_unexpected"
    case dockerUnavailable = "docker_unavailable"
}

/// Every error a tool returns. The kit's `ErrorEnvelope` reads `code` (via `CodedError`) and
/// sanitizes the message before it reaches the client, so CLI stderr embedded in `message`
/// cannot inject control characters.
public struct ContainerMCPError: Error, LocalizedError, CodedError, Equatable, Sendable {
    public let kind: ErrorCode
    public let message: String

    public init(_ kind: ErrorCode, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var code: String { kind.rawValue }
    public var errorDescription: String? { message }
}

extension ContainerMCPError {
    /// At most the first 2,000 characters of a CLI's stderr (spec: CLI exits non-zero).
    public static func cliFailed(_ command: String, status: Int32, stderr: String) -> ContainerMCPError {
        let trimmed = String(stderr.prefix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        return ContainerMCPError(.cliFailed, "\(command) exited with status \(status): \(trimmed)")
    }
}
