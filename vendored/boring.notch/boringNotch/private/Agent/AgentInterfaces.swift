//
//  AgentInterfaces.swift
//  Agent in the Notch
//
//  Cross-feature contract stubs (PRD §9). Keep these stable — they're the only
//  surface Sam and Ashan touch.
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
