import CheMCPKit
import Foundation
import Testing
@testable import CheContainerMCPCore

struct ErrorCodeTests {
    @Test func `The error code set is exactly the twelve closed values`() {
        let expected: Set<String> = [
            "runtime_unavailable", "kernel_missing", "image_not_found", "invalid_mount", "invalid_argument",
            "config_invalid", "job_not_found", "job_not_finished", "cli_timeout", "cli_failed",
            "cli_output_unexpected", "docker_unavailable",
        ]
        #expect(Set(ErrorCode.allCases.map(\.rawValue)) == expected)
    }

    @Test func `Envelope carries the code and the message`() throws {
        let error = ContainerMCPError(.imageNotFound, "image docker.io/library/x:latest is not local")
        let envelope = ErrorEnvelope.make(for: error, sanitizedCode: "unused")
        let inner = try #require(envelope["error"] as? [String: Any])
        #expect(inner["code"] as? String == "image_not_found")
        #expect((inner["message"] as? String)?.contains("not local") == true)
    }

    @Test func `cli_failed keeps at most 2000 characters of stderr`() {
        let error = ContainerMCPError.cliFailed("container run", status: 1, stderr: String(repeating: "#", count: 5_000))
        #expect(error.kind == .cliFailed)
        #expect(error.message.filter { $0 == "#" }.count == 2_000)
    }
}
