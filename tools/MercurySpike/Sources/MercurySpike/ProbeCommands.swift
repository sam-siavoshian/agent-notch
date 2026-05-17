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
