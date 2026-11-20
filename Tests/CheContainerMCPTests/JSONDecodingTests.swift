import Foundation
import Testing
@testable import CheContainerMCPCore

struct JSONDecodingTests {
    @Test func `System status parses`() throws {
        let status = try CLIJSON.systemStatus(try Fixture.data("system-status.json"), cliVersion: "1.7.1")
        #expect(status.status == "running")
        #expect(status.clientVersion == "1.7.1")
        #expect(status.serverVersion == "1.7.1")
        #expect(status.appRoot?.hasSuffix("com.apple.container/") == true)
    }

    @Test func `Missing status field is cli_output_unexpected with the version`() throws {
        let data = try Fixture.data("system-status-missing-status.json")
        let error = #expect(throws: ContainerMCPError.self) { try CLIJSON.systemStatus(data, cliVersion: "1.7.1") }
        #expect(error?.kind == .cliOutputUnexpected)
        #expect(error?.message.contains("1.7.1") == true)
    }

    @Test func `Unknown fields are ignored`() throws {
        let json = #"[{"configuration":{"id":"a","labels":{},"brandNew":42},"status":{"state":"running","extra":[1]},"surprise":true}]"#
        let list = try CLIJSON.containers(Data(json.utf8), cliVersion: "9.9")
        #expect(list == [ContainerSummary(id: "a", labels: [:], state: "running", startedDate: nil)])
    }

    @Test func `Image list gives reference, digest and the host variant size`() throws {
        let images = try CLIJSON.images(try Fixture.data("image-list.json"), cliVersion: "1.7.1", architecture: "arm64")
        let swift = try #require(images.first)
        #expect(swift.reference == "docker.io/library/swift:6.0.3-noble")
        #expect(swift.digest.hasPrefix("sha256:e6aab687"))
        #expect(swift.sizeBytes == 963_058_048)
    }

    @Test func `Container list keeps labels, state and start time`() throws {
        let list = try CLIJSON.containers(try Fixture.data("container-list.json"), cliVersion: "1.7.1")
        let job = try #require(list.first { $0.id == "cj-20261121000000-abc123" })
        #expect(job.labels["che-container-mcp.job"] == "cj-20261121000000-abc123")
        #expect(job.state == "stopped")
        #expect(job.startedDate != nil)
        let other = try #require(list.first { $0.id != job.id })
        #expect(other.labels.isEmpty)
        #expect(other.isRunning)
    }

    @Test func `Job log fixture ends with the exit marker`() throws {
        #expect(try Fixture.text("job-logs.txt").contains("__CHE_JOB_EXIT__ cj-20261121000000-abc123 0"))
    }
}
