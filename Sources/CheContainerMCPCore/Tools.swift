import CheMCPKit
import Foundation
import MCP

/// The seven tools and their schemas (design: Implementation Contract → 工具介面).
public enum ToolCatalog {
    public static let names = [
        "container_status", "container_image_ensure", "container_run",
        "container_job_status", "container_job_wait", "container_job_result", "container_job_cancel",
    ]

    static func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": .bool(false),
        ])
    }

    public static let tools: [Tool] = [
        Tool(name: "container_status",
             description: "Report whether Apple's `container` service is running, the CLI and server versions, and whether the default kernel is installed. With start: true and the service stopped, runs `container system start --enable-kernel-install`.",
             inputSchema: schema(["start": prop("boolean", "Start the service if it is not running. Default false.")]),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "container_image_ensure",
             description: "Make sure an image is local. Pulls it when absent and waits up to 600 seconds; if the pull is still running then, returns state \"pulling\" (call again to keep waiting on the same pull).",
             inputSchema: schema(["image": prop("string", "Image reference, e.g. swift:6.0.3-noble or ghcr.io/org/tool:1.2."),
                                  "platform": prop("string", "Optional os/arch[/variant], e.g. linux/arm64.")],
                                 required: ["image"]),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)),
        Tool(name: "container_run",
             description: "Start a one-off container job and return its job_id at once, without waiting. The image must contain /bin/sh, which wraps `command` to record its exit code. The source directory is mounted read-only at /src unless source_writable is true; the output directory is mounted writable at /out. The container is kept until container_job_result or container_job_cancel removes it. Uses Docker only when allow_docker is true AND `container` is unavailable.",
             inputSchema: schema([
                "image": prop("string", "Image reference; must already be local (see container_image_ensure)."),
                "command": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                    "description": .string("The command as an argument array, e.g. [\"swift\", \"test\"]. For shell syntax pass [\"sh\", \"-c\", \"...\"].")]),
                "source_dir": prop("string", "Absolute host directory mounted read-only at /src (config default if omitted)."),
                "source_writable": prop("boolean", "Mount the source directory writable. Default false."),
                "output_dir": prop("string", "Absolute host directory mounted writable at /out (config default if omitted)."),
                "cpus": prop("integer", "CPUs for the container. Default from config (8)."),
                "memory": prop("string", "Memory, e.g. 16G. Default from config (16G)."),
                "workdir": prop("string", "Working directory inside the container. Default /src."),
                "env": .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string")]),
                                "description": .string("Explicit environment values {\"KEY\": \"value\"}. Host variables are never inherited.")]),
                "allow_docker": prop("boolean", "Authorize Docker for this one call, used only if `container` is unavailable. Default false."),
             ], required: ["image", "command"]),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)),
        Tool(name: "container_job_status",
             description: "State of one job (job_id) or of every job. Running jobs include the last 20 log lines.",
             inputSchema: schema(["job_id": prop("string", "Job id from container_run; omit to list all jobs.")]),
             annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "container_job_wait",
             description: "Wait for a job to finish, at most timeout_seconds (default 120, max 600). On timeout returns timed_out: true with state running — not an error.",
             inputSchema: schema(["job_id": prop("string", "Job id."),
                                  "timeout_seconds": prop("integer", "1 to 600, default 120.")], required: ["job_id"]),
             annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "container_job_result",
             description: "Exit code, elapsed time, the last tail_lines of output, the full log path, and whether the host slept during the job. After the log is copied to the host, deletes the job's container unless keep_container is true. Fails with job_not_finished while the job runs.",
             inputSchema: schema(["job_id": prop("string", "Job id."),
                                  "tail_lines": prop("integer", "1 to 1000, default 50."),
                                  "keep_container": prop("boolean", "Keep the container. Default false.")], required: ["job_id"]),
             annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)),
        Tool(name: "container_job_cancel",
             description: "Stop a running job (TERM, then KILL after grace_seconds), copy its log, and delete its container. On a finished job, only deletes the container. Touches only the container labelled with this job id.",
             inputSchema: schema(["job_id": prop("string", "Job id."),
                                  "grace_seconds": prop("integer", "0 to 300, default 10.")], required: ["job_id"]),
             annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)),
    ]
}

/// Typed access to tool arguments; a wrong type or an unknown key is `invalid_argument`.
struct ToolArguments {
    let values: [String: Value]

    init(_ values: [String: Value], allowed: Set<String>) throws {
        let present = values.filter { if case .null = $0.value { return false }; return true }
        if let unknown = present.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ContainerMCPError(.invalidArgument, "unknown argument \(unknown)")
        }
        self.values = present
    }

    func string(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let text) = value else { throw wrong(key, "a string") }
        return text
    }

    func requiredString(_ key: String) throws -> String {
        guard let text = try string(key), !text.isEmpty else {
            throw ContainerMCPError(.invalidArgument, "\(key) is required")
        }
        return text
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard case .bool(let flag) = value else { throw wrong(key, "a boolean") }
        return flag
    }

    func int(_ key: String) throws -> Int? {
        guard let value = values[key] else { return nil }
        switch value {
        case .int(let number): return number
        case .double(let number) where number == number.rounded(): return Int(number)
        default: throw wrong(key, "an integer")
        }
    }

    func stringArray(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        guard case .array(let items) = value else { throw wrong(key, "an array of strings") }
        return try items.map { item in
            guard case .string(let text) = item else { throw wrong(key, "an array of strings") }
            return text
        }
    }

    func stringMap(_ key: String) throws -> [String: String]? {
        guard let value = values[key] else { return nil }
        guard case .object(let object) = value else { throw wrong(key, "an object of strings") }
        return try object.mapValues { item in
            guard case .string(let text) = item else { throw wrong(key, "an object of strings") }
            return text
        }
    }

    private func wrong(_ key: String, _ kind: String) -> ContainerMCPError {
        ContainerMCPError(.invalidArgument, "\(key) must be \(kind)")
    }
}

/// Dispatches tool calls for both the MCP server and `--cli`.
public final class ToolDispatcher: CLIToolExecutor, Sendable {
    public let manager: JobManager

    public init(manager: JobManager) { self.manager = manager }

    private static func allowed(_ name: String) -> Set<String> {
        guard let tool = ToolCatalog.tools.first(where: { $0.name == name }),
              case .object(let schema) = tool.inputSchema,
              case .object(let properties)? = schema["properties"] else { return [] }
        return Set(properties.keys)
    }

    public func executeToolCall(name: String, arguments: [String: Value]) async throws -> String {
        guard ToolCatalog.names.contains(name) else {
            throw ContainerMCPError(.invalidArgument, "unknown tool \(name)")
        }
        let args = try ToolArguments(arguments, allowed: Self.allowed(name))
        let result: [String: Any]
        switch name {
        case "container_status":
            result = try await manager.serviceStatus(start: try args.bool("start") ?? false)
        case "container_image_ensure":
            result = try await manager.ensureImage(try args.requiredString("image"), platform: try args.string("platform"))
        case "container_run":
            guard let command = try args.stringArray("command") else {
                throw ContainerMCPError(.invalidArgument, "command is required")
            }
            let request = RunRequest(
                image: try args.requiredString("image"), command: command,
                mounts: MountRequest(sourceDir: try args.string("source_dir"),
                                     sourceWritable: try args.bool("source_writable") ?? false,
                                     outputDir: try args.string("output_dir")),
                cpus: try args.int("cpus"), memory: try args.string("memory"), workdir: try args.string("workdir"),
                env: try args.stringMap("env") ?? [:], allowDocker: try args.bool("allow_docker") ?? false)
            result = try await manager.run(request)
        case "container_job_status":
            result = try await manager.status(jobId: try args.string("job_id"))
        case "container_job_wait":
            result = try await manager.wait(jobId: try args.requiredString("job_id"),
                                            timeoutSeconds: try args.int("timeout_seconds") ?? 120)
        case "container_job_result":
            result = try await manager.result(jobId: try args.requiredString("job_id"),
                                              tailLines: try args.int("tail_lines") ?? 50,
                                              keepContainer: try args.bool("keep_container") ?? false)
        default: // container_job_cancel
            result = try await manager.cancel(jobId: try args.requiredString("job_id"),
                                              graceSeconds: try args.int("grace_seconds") ?? 10)
        }
        return try formatJSON(result)
    }

    /// The MCP `CallTool` answer: the JSON result, or the error envelope with `isError`.
    public func callTool(name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            return CallTool.Result(content: [.text(text: try await executeToolCall(name: name, arguments: arguments), annotations: nil, _meta: nil)])
        } catch {
            let sanitized = ErrorSanitizer.writeFailureLog(handler: "callTool", identifier: name, error: error)
            let envelope = ErrorEnvelope.make(for: error, sanitizedCode: sanitized)
            let text = (try? formatJSON(envelope)) ?? #"{"error":{"code":"internal_error","message":"internal_error"}}"#
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: true)
        }
    }
}

/// The stdio MCP server, with the startup reconcile, the 15-second monitor and the sleep observer.
public final class ContainerMCPServer: @unchecked Sendable {
    public static let monitorInterval: UInt64 = 15

    public let dispatcher: ToolDispatcher
    private let server: Server
    private var observer: SleepObserver?

    public init(dispatcher: ToolDispatcher) async {
        self.dispatcher = dispatcher
        server = Server(name: AppVersion.mcpServerName, version: AppVersion.current, capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: ToolCatalog.tools) }
        await server.withMethodHandler(CallTool.self) { [dispatcher] params in
            await dispatcher.callTool(name: params.name, arguments: params.arguments ?? [:])
        }
    }

    public func run() async throws {
        let manager = dispatcher.manager
        await manager.reconcileRunning()
        let observer = SleepObserver { kind, date in
            Task { await manager.recordSleepEvent(kind, at: date) }
        }
        observer.start()
        self.observer = observer
        let monitor = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.monitorInterval * 1_000_000_000)
                await manager.reconcileRunning()
            }
        }
        defer { monitor.cancel() }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
