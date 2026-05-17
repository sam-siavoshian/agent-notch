import Foundation
import GeminiPerceptionEval

@main
struct GeminiPerceptionEvalCLI {

    static func main() async {
        let args = CommandLine.arguments
        var fixturesPath: String?
        var variantNames: [String] = []
        var reportPath: String?

        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--fixtures":
                i += 1
                if i < args.count { fixturesPath = args[i] }
            case "--variants":
                i += 1
                if i < args.count {
                    variantNames = args[i].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                }
            case "--report":
                i += 1
                if i < args.count { reportPath = args[i] }
            case "-h", "--help":
                printUsage()
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown arg: \(a)\n".utf8))
                printUsage()
                exit(2)
            }
            i += 1
        }

        guard let fixturesPath, let reportPath, !variantNames.isEmpty else {
            FileHandle.standardError.write(Data("missing required flags\n".utf8))
            printUsage()
            exit(2)
        }

        // Resolve variants up-front so we fail fast on typos.
        var variants: [GeminiClient.Variant] = []
        for name in variantNames {
            guard let v = GeminiClient.Variant.named(name) else {
                FileHandle.standardError.write(Data("unknown variant: \(name)\n".utf8))
                exit(2)
            }
            variants.append(v)
        }

        let fixturesURL = URL(fileURLWithPath: fixturesPath, isDirectory: true)
        let reportURL = URL(fileURLWithPath: reportPath)

        let env = ProcessInfo.processInfo.environment
        let apiKey = env["GEMINI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        var report = "# Gemini Perception Eval\n\n"
        report += "Generated: \(ISO8601DateFormatter().string(from: Date()))\n\n"
        report += "Fixtures: `\(fixturesURL.path)`  ·  Variants: `\(variants.map { $0.name }.joined(separator: ", "))`\n\n"

        do {
            if apiKey == nil || apiKey?.isEmpty == true {
                print("GEMINI_API_KEY not set — running prompt-only dry mode (no API calls, no scoring)")
                let runner = EvalRunner(fixturesDir: fixturesURL, variants: variants, client: nil)
                var body = ""
                try runner.runDry(out: &body)
                report += "## Mode\n\nDry run (no API key)\n\n"
                report += body
                print(body)
            } else {
                let client = GeminiClient(apiKey: apiKey!)
                let runner = EvalRunner(fixturesDir: fixturesURL, variants: variants, client: client)
                var body = ""
                try await runner.runLive(out: &body)
                report += body
                print(body)
            }

            // Write the report. Create parent dir if missing.
            let parent = reportURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try report.write(to: reportURL, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("Wrote report to \(reportURL.path)\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        let s = """
        usage: gemini-perception-eval --fixtures <dir> --variants <a,b,c> --report <path>

        variants: high-min, ultra-min, high-default, medium-min, ultra-default

        Set GEMINI_API_KEY to run live. Without it, the CLI runs in dry mode,
        printing the prompt and request bodies for inspection.
        """
        print(s)
    }
}
