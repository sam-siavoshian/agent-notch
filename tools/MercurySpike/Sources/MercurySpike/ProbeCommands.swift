import Foundation
import OpenRouterAPI

enum ProbeCommands {

    static func ping(client: OpenRouterClient, model: String) async throws {
        print("→ ping model=\(model)")
        let start = Date()
        let resp = try await client.chatCompletion(request: .init(
            model: model,
            messages: [.init(role: "user", content: "Reply with exactly the word OK and nothing else.")],
            maxTokens: 10
        ))
        let elapsed = Date().timeIntervalSince(start)
        let content = resp.choices.first?.message.content ?? "<none>"
        print("  latency: \(String(format: "%.2f", elapsed))s")
        print("  content: \(content.prefix(120))")
        if let usage = resp.usage {
            print("  tokens:  prompt=\(usage.promptTokens) completion=\(usage.completionTokens)")
        }
    }
}

extension ProbeCommands {
    static func jsonMode(client: OpenRouterClient, model: String, runs: Int = 5) async throws {
        print("→ jsonMode model=\(model) runs=\(runs)")
        let systemPrompt = """
        Return strictly one JSON object with this shape:
        {"intent": {"verb": string, "target": string}, "brief": string}
        No prose outside the JSON.
        """
        let userPrompt = "Transcript: \"open the latest PR\"\nReturn the JSON object only."

        var validCount = 0
        var totalLatency: TimeInterval = 0
        for i in 1...runs {
            let start = Date()
            let resp = try await client.chatCompletion(request: .init(
                model: model,
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: userPrompt)
                ],
                responseFormat: .jsonObject,
                maxTokens: 300
            ))
            let elapsed = Date().timeIntervalSince(start)
            totalLatency += elapsed
            let content = resp.choices.first?.message.content ?? ""
            let isValid = isStrictJSON(content)
            validCount += isValid ? 1 : 0
            let status = isValid ? "✓" : "✗"
            print("  run \(i): \(String(format: "%.2f", elapsed))s \(status)")
            if !isValid {
                print("    raw: \(content.prefix(200))")
            }
        }
        let avg = totalLatency / Double(runs)
        let rate = Double(validCount) / Double(runs) * 100
        print("  json valid: \(validCount)/\(runs) (\(String(format: "%.0f", rate))%)")
        print("  avg latency: \(String(format: "%.2f", avg))s")
    }

    private static func isStrictJSON(_ s: String) -> Bool {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return obj["intent"] != nil && obj["brief"] != nil
    }
}

extension ProbeCommands {
    static func latency(client: OpenRouterClient, model: String, runs: Int = 10) async throws {
        print("→ latency model=\(model) runs=\(runs) (~5K input target)")
        let fillerJSON = String(repeating: "{\"t\":\"2026-05-16T19:42:11Z\",\"kind\":\"input\",\"app\":\"Slack\",\"text\":\"like this?\"},", count: 60)
        let userPrompt = """
        Recent events from the user:
        [\(fillerJSON.dropLast())]

        Transcript: "send maya the latest draft"

        Return JSON: {"intent": {"verb": string, "target": string, "confidence": number}, "brief": string}
        """

        var latencies: [TimeInterval] = []
        var promptTokens = 0
        var completionTokens = 0
        for i in 1...runs {
            let start = Date()
            let resp = try await client.chatCompletion(request: .init(
                model: model,
                messages: [.init(role: "user", content: userPrompt)],
                responseFormat: .jsonObject,
                maxTokens: 600
            ))
            let elapsed = Date().timeIntervalSince(start)
            latencies.append(elapsed)
            if let u = resp.usage {
                promptTokens = u.promptTokens
                completionTokens = u.completionTokens
            }
            print("  run \(i): \(String(format: "%.2f", elapsed))s")
        }
        latencies.sort()
        let p50 = latencies[latencies.count / 2]
        let p95 = latencies[min(Int(Double(latencies.count) * 0.95), latencies.count - 1)]
        print("  prompt tokens (last run): \(promptTokens)")
        print("  completion tokens (last run): \(completionTokens)")
        print("  p50: \(String(format: "%.2f", p50))s")
        print("  p95: \(String(format: "%.2f", p95))s")
        print("  spec target: p50 ≤ 1.5s, p95 ≤ 2.5s (selector budget)")
    }
}
