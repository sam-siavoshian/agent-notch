import Foundation
import EvalHarness
import OpenRouterAPI

@main
struct EvalRunnerCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"

        do {
            switch command {
            case "mock":
                try await RunnerCommands.mock()
            case "live":
                try await RunnerCommands.live()
            case "list":
                try RunnerCommands.list()
            case "help", "--help", "-h":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n".utf8))
                printUsage()
                exit(64)
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        Usage: eval-runner <command>

        Commands:
          mock       Run all selector fixtures through MockLLMClient (no network)
          live       Run all selector fixtures through LiveMercuryClient (OpenRouter)
          list       List discovered fixtures
        """)
    }
}
