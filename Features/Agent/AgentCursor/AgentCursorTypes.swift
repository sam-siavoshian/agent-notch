//
//  AgentCursorTypes.swift
//  Agent in the Notch
//
//  Shared enums used by AgentCursorDriver and AXFastPath. Free-standing here
//  so AXFastPath does not need to reference AgentCursorDriver (would create a
//  module-internal cyclic visibility issue and bloat AX surface).
//

import Foundation

public enum AXScrollDirection: Sendable {
    case up, down, left, right
}
