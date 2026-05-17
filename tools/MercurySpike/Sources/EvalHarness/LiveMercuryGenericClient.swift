import Foundation
import OpenRouterAPI

/// A `LiveMercuryClient` variant whose system prompt is injected at construction
/// time. Used by Phase-3 prompt categories (active_task_updater, recipe_naming)
/// that share the same OpenRouter transport but use different system prompts.
///
/// `LiveMercuryClient` (selector-specific) is kept as-is so Phase 1 behavior
/// is unchanged.
public struct LiveMercuryGenericClient: LLMClientProtocol {
    public let openRouter: OpenRouterClient
    public let model: String
    public let systemPrompt: String
    public let maxTokens: Int

    public init(openRouter: OpenRouterClient, model: String, systemPrompt: String, maxTokens: Int = 1200) {
        self.openRouter = openRouter
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
    }

    public func complete(rawInput: Data) async throws -> String {
        let userContent = String(data: rawInput, encoding: .utf8) ?? "<non-utf8>"
        let request = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userContent)
            ],
            responseFormat: .jsonObject,
            maxTokens: maxTokens
        )
        let response = try await openRouter.chatCompletion(request: request)
        return response.choices.first?.message.content ?? ""
    }
}
