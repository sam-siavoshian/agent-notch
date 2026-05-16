//
//  CursorColor.swift
//  Agent in the Notch
//
//  Wyatt — settings primitive shared with Sam's cursor module.
//

import SwiftUI

public enum CursorColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case red
    case green
    case blue
    case yellow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        }
    }

    public var swatch: Color {
        switch self {
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        case .yellow: return .yellow
        }
    }

    public var assetName: String {
        "cursor_\(rawValue)"
    }
}
