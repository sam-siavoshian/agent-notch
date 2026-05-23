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
    }

    public static var anthropicAPIKey: String? {
        resolve(env: "ANTHROPIC_API_KEY", account: Account.anthropic)
    }

    public static var openAIAPIKey: String? {
        resolve(env: "OPENAI_API_KEY", account: Account.openai)
    }

    public static func setOpenAIAPIKey(_ key: String) {
        Keychain.set(key, account: Account.openai)
    }

    public static func setAnthropicAPIKey(_ key: String) {
        Keychain.set(key, account: Account.anthropic)
    }

    private static func resolve(env: String, account: String) -> String? {
        if let v = Env.value(env), !v.isEmpty { return v }
        if let v = Keychain.get(account), !v.isEmpty { return v }
        return nil
    }
}
