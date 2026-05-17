import Foundation
import OpenRouterAPI

@main
struct MercurySpikeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"

        guard let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !apiKey.isEmpty else {
            FileHandle.standardError.write(Data("ERROR: OPENROUTER_API_KEY not set\n".utf8))
            exit(2)
        }
        let client = OpenRouterClient(apiKey: apiKey)

        do {
            switch command {
            case "ping":
                try await ProbeCommands.ping(client: client, model: args.dropFirst().first ?? "inception/mercury-2")
            case "jsonMode":
                try await ProbeCommands.jsonMode(client: client, model: args.dropFirst().first ?? "inception/mercury-2")
            case "latency":
                try await ProbeCommands.latency(client: client, model: args.dropFirst().first ?? "inception/mercury-2")
            case "all":
                let model = args.dropFirst().first ?? "inception/mercury-2"
                try await ProbeCommands.ping(client: client, model: model)
                print()
                try await ProbeCommands.jsonMode(client: client, model: model)
                print()
                try await ProbeCommands.latency(client: client, model: model)
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
        Usage: mercury-spike <command> [args]

        Commands:
          ping [model]       Send a tiny round-trip; default model: inception/mercury-2
          jsonMode [model]   Validate response_format=json_object behavior
          latency [model]    Measure p50/p95 at representative payload sizes (10 runs)
          all                Run ping, jsonMode, latency in sequence
        """)
    }
}
