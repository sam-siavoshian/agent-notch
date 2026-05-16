//
//  Secrets.swift
//  Agent in the Notch
//
//  API key resolution. Order: env var > settings > nil. For hackathon, set
//  ANTHROPIC_API_KEY in Xcode scheme env or shell before launching.
//

import Foundation

public enum Secrets {
    public static var anthropicAPIKey: String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        return nil
    }
}
