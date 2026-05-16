//
//  CursorCompanionViewModel.swift
//  Agent in the Notch
//
//  Drives the sprite: color + listening state. Owned by CursorCompanion.
//

import Foundation
import Combine

@MainActor
public final class CursorCompanionViewModel: ObservableObject {
    @Published public var color: CursorColor
    @Published public var isListening: Bool = false
    @Published public var isThinking: Bool = false

    public init(color: CursorColor) {
        self.color = color
    }
}
