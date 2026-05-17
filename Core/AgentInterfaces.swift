//
//  AgentInterfaces.swift
//  Agent in the Notch
//
//  Cross-feature contract stubs (PRD §9). Keep stable — the only surface
//  Sam (Cursor) and Ashan (Context/Agent) touch from outside their features.
//

import Foundation

public protocol CursorAppearanceSetting: AnyObject {
    func setCursorColor(_ color: CursorColor)
}

public struct ActivationContextHint: Sendable {
    public let verb: String?
    public let target: String?
    public let inferredGoal: String?
    public let mentionedApps: [String]
    public let mentionedEntityLabels: [String]
    public let keywords: [String]
    public let confidence: Double

    public init(
        verb: String?,
        target: String?,
        inferredGoal: String?,
        mentionedApps: [String],
        mentionedEntityLabels: [String],
        keywords: [String],
        confidence: Double
    ) {
        self.verb = verb
        self.target = target
        self.inferredGoal = inferredGoal
        self.mentionedApps = mentionedApps
        self.mentionedEntityLabels = mentionedEntityLabels
        self.keywords = keywords
        self.confidence = confidence
    }
}

public protocol RecentActivityContext: AnyObject {
    func getRecentActivityContext() async -> String
    func getRecentActivityContext(hint: ActivationContextHint?) async -> String
    @MainActor func presentDevTools()
    func diagnosticsSummary() async -> String
}

public extension RecentActivityContext {
    func getRecentActivityContext(hint: ActivationContextHint?) async -> String {
        await getRecentActivityContext()
    }
}

@MainActor
public enum AgentInterfaces {
    public static var cursor: CursorAppearanceSetting?
    public static var context: RecentActivityContext?
}
