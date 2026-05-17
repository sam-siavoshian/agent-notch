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
            case "mock-active-task":
                try await PromptCategoryCommands.mockActiveTask()
            case "live-active-task":
                try await PromptCategoryCommands.liveActiveTask()
            case "mock-recipe-naming":
                try await PromptCategoryCommands.mockRecipeNaming()
            case "live-recipe-naming":
                try await PromptCategoryCommands.liveRecipeNaming()
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
          mock                    Run selector fixtures through MockLLMClient (no network)
          live                    Run selector fixtures through LiveMercuryClient (OpenRouter)
          list                    List discovered selector fixtures
          mock-active-task        Run active_task_updater fixtures through MockLLMClient
          live-active-task        Run active_task_updater fixtures through OpenRouter
          mock-recipe-naming      Run recipe_naming fixtures through MockLLMClient
          live-recipe-naming      Run recipe_naming fixtures through OpenRouter
        """)
    }
}
