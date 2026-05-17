//
//  Secrets.swift
//  Agent in the Notch
//
//  API key resolution. Order: env var > Keychain > nil.
//  Keys are stored per-account under the Keychain service "com.agentnotch.app".
//

import Foundation

public enum Secrets {
    public enum Account {
        public static let anthropic = "ANTHROPIC_API_KEY"
        public static let openai = "OPENAI_API_KEY"
        public static let openRouter = "OPENROUTER_API_KEY"
        // Phase 5b: Account.gemini removed alongside the Gemini observation pipeline.
    }

    public static var anthropicAPIKey: String? {
        resolve(env: "ANTHROPIC_API_KEY", account: Account.anthropic)
    }

    public static var openAIAPIKey: String? {
        resolve(env: "OPENAI_API_KEY", account: Account.openai)
    }

    // Phase 5b: geminiAPIKey removed alongside the Gemini observation pipeline.

    // Mercury 2 (via OpenRouter) — context-layer LLM
    public static var openRouterAPIKey: String? {
        resolve(env: "OPENROUTER_API_KEY", account: Account.openRouter)
    }

    public static func setOpenAIAPIKey(_ key: String) {
        Keychain.set(key, account: Account.openai)
    }

    public static func setAnthropicAPIKey(_ key: String) {
        Keychain.set(key, account: Account.anthropic)
    }

    // Phase 5b: setGeminiAPIKey removed alongside the Gemini observation pipeline.

    public static func setOpenRouterAPIKey(_ key: String) {
        Keychain.set(key, account: Account.openRouter)
    }

    /// One-shot seed: stores a default OpenAI key only if Keychain has none.
    /// Used during hackathon bring-up so a fresh machine works without manual setup.
    public static func bootstrapOpenAIKey(_ key: String) {
        guard Keychain.get(Account.openai) == nil else { return }
        Keychain.set(key, account: Account.openai)
    }

    private static func resolve(env: String, account: String) -> String? {
        if let v = Env.value(env) { return v }
        if let v = Keychain.get(account), !v.isEmpty { return v }
        return nil
    }
}
