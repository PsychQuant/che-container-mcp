import CheContainerMCPCore
import CheMCPKit
import Foundation

let arguments = CommandLine.arguments

if arguments.contains("--version") || arguments.contains("-v") {
    print(AppVersion.versionString)
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(AppVersion.helpMessage)
    exit(0)
}

let manager = JobManager(paths: StatePaths.resolve(), runner: ProcessCommandRunner(), power: IOKitPowerAssertion())
let dispatcher = ToolDispatcher(manager: manager)

if arguments.contains("--cli") {
    await CLIRunner.run(executor: dispatcher, tools: ToolCatalog.tools, usageName: AppVersion.name, args: arguments)
    exit(0)
}

let server = await ContainerMCPServer(dispatcher: dispatcher)
try await server.run()
