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

public protocol RecentActivityContext: AnyObject {
    func getRecentActivityContext() async -> String
}

@MainActor
public enum AgentInterfaces {
    public static var cursor: CursorAppearanceSetting?
    public static var context: RecentActivityContext?
}
