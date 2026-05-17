import Foundation
import OpenRouterAPI

public struct LiveMercuryClient: LLMClientProtocol {
    public let openRouter: OpenRouterClient
    public let model: String
    public let selectorSystemPrompt: String

    public init(openRouter: OpenRouterClient, model: String, selectorSystemPrompt: String) {
        self.openRouter = openRouter
        self.model = model
        self.selectorSystemPrompt = selectorSystemPrompt
    }

    public func complete(rawInput: Data) async throws -> String {
        let userContent = String(data: rawInput, encoding: .utf8) ?? "<non-utf8>"
        let request = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: selectorSystemPrompt),
                .init(role: "user", content: userContent)
            ],
            responseFormat: .jsonObject,
            maxTokens: 1200
        )
        let response = try await openRouter.chatCompletion(request: request)
        return response.choices.first?.message.content ?? ""
    }
}
