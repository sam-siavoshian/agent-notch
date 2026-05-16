//
//  LongPressEvents.swift
//  Agent in the Notch
//
//  Cross-feature signal. Sam's long-press detector emits these; Ashan's voice
//  module subscribes and starts/stops Whisper.
//

import Foundation

public extension Notification.Name {
    static let longPressBegan = Notification.Name("AgentNotch.longPressBegan")
    static let longPressEnded = Notification.Name("AgentNotch.longPressEnded")
    static let transcriptReady = Notification.Name("AgentNotch.transcriptReady")
}
