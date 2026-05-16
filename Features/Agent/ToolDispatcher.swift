//
//  ToolDispatcher.swift
//  Agent in the Notch
//
//  Maps Anthropic computer-use tool calls to CGEvent / ScreenCapture actions.
//
//  Coordinate system: Anthropic computer-use uses top-left origin in display
//  pixels. AppKit also uses top-left in CGEvent calls (CGWarpMouseCursor,
//  CGEventCreateMouseEvent), so coordinates map 1:1 for the primary display.
//  Multi-monitor / scaled displays are deliberately out of scope for v1.
//
//  Reference: https://docs.anthropic.com/en/docs/agents-and-tools/computer-use
//

import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox

public struct DispatchedToolResult: Sendable {
    public let toolUseId: String
    public let content: [ContentBlock]
    public let isError: Bool
}

public actor ToolDispatcher {
    public let displaySize: CGSize
    private let capture: ScreenCapture

    public init(displaySize: CGSize, capture: ScreenCapture = .shared) {
        self.displaySize = displaySize
        self.capture = capture
    }

    public func dispatch(toolUseId: String, name: String, input: JSON) async -> DispatchedToolResult {
        guard name == "computer" else {
            return errorResult(toolUseId, "Unsupported tool: \(name)")
        }
        guard let action = input.objectValue?["action"]?.stringValue else {
            return errorResult(toolUseId, "Missing 'action' in tool input")
        }

        do {
            switch action {
            case "screenshot":
                let snap = try await capture.snapshot()
                let b64 = snap.jpegData.base64EncodedString()
                return DispatchedToolResult(
                    toolUseId: toolUseId,
                    content: [.image(mediaType: "image/jpeg", base64: b64)],
                    isError: false
                )

            case "left_click":
                let p = try requireCoordinate(input)
                postMouseClick(at: p, button: .left)
                return ok(toolUseId, "clicked at \(Int(p.x)),\(Int(p.y))")

            case "right_click":
                let p = try requireCoordinate(input)
                postMouseClick(at: p, button: .right)
                return ok(toolUseId, "right-clicked at \(Int(p.x)),\(Int(p.y))")

            case "middle_click":
                let p = try requireCoordinate(input)
                postMouseClick(at: p, button: .center)
                return ok(toolUseId, "middle-clicked at \(Int(p.x)),\(Int(p.y))")

            case "double_click":
                let p = try requireCoordinate(input)
                postMouseClick(at: p, button: .left, clickCount: 2)
                return ok(toolUseId, "double-clicked at \(Int(p.x)),\(Int(p.y))")

            case "left_click_drag":
                let from = NSEvent.mouseLocationFlipped(displayHeight: displaySize.height)
                let to = try requireCoordinate(input)
                postDrag(from: from, to: to)
                return ok(toolUseId, "dragged to \(Int(to.x)),\(Int(to.y))")

            case "mouse_move":
                let p = try requireCoordinate(input)
                CGWarpMouseCursorPosition(p)
                CGAssociateMouseAndMouseCursorPosition(1)
                return ok(toolUseId, "moved to \(Int(p.x)),\(Int(p.y))")

            case "cursor_position":
                let loc = NSEvent.mouseLocationFlipped(displayHeight: displaySize.height)
                return ok(toolUseId, "X=\(Int(loc.x)) Y=\(Int(loc.y))")

            case "type":
                guard let text = input.objectValue?["text"]?.stringValue else {
                    throw DispatchError("Missing 'text' for type action")
                }
                postType(text)
                return ok(toolUseId, "typed \(text.count) chars")

            case "key":
                guard let combo = input.objectValue?["text"]?.stringValue else {
                    throw DispatchError("Missing 'text' for key action")
                }
                try postKeyCombo(combo)
                return ok(toolUseId, "pressed \(combo)")

            case "scroll":
                let p = try requireCoordinate(input)
                let dy = input.objectValue?["scroll_amount"]?.intValue ?? 3
                let direction = input.objectValue?["scroll_direction"]?.stringValue ?? "down"
                postScroll(at: p, direction: direction, amount: dy)
                return ok(toolUseId, "scrolled \(direction) by \(dy)")

            case "wait":
                let ms = input.objectValue?["duration"]?.intValue ?? 250
                try await Task.sleep(for: .milliseconds(ms))
                return ok(toolUseId, "waited \(ms)ms")

            case "hold_key":
                guard let combo = input.objectValue?["text"]?.stringValue else {
                    throw DispatchError("Missing 'text' for hold_key action")
                }
                let dur = input.objectValue?["duration"]?.intValue ?? 100
                try await postHoldKey(combo, durationMs: dur)
                return ok(toolUseId, "held \(combo) for \(dur)ms")

            default:
                return errorResult(toolUseId, "Unsupported action: \(action)")
            }
        } catch let e as DispatchError {
            return errorResult(toolUseId, e.message)
        } catch {
            return errorResult(toolUseId, "Dispatch failed: \(error)")
        }
    }

    // MARK: - Helpers

    private struct DispatchError: Swift.Error { let message: String; init(_ m: String) { self.message = m } }

    private func requireCoordinate(_ input: JSON) throws -> CGPoint {
        guard let coord = input.objectValue?["coordinate"]?.arrayValue,
              coord.count >= 2,
              let x = coord[0].intValue,
              let y = coord[1].intValue else {
            throw DispatchError("Missing or invalid 'coordinate'")
        }
        return CGPoint(x: x, y: y)
    }

    private func ok(_ id: String, _ text: String) -> DispatchedToolResult {
        DispatchedToolResult(toolUseId: id, content: [.text(text)], isError: false)
    }

    private func errorResult(_ id: String, _ text: String) -> DispatchedToolResult {
        DispatchedToolResult(toolUseId: id, content: [.text(text)], isError: true)
    }

    // MARK: - CGEvent posting

    private func postMouseClick(at p: CGPoint, button: CGMouseButton, clickCount: Int = 1) {
        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case .left:   downType = .leftMouseDown;  upType = .leftMouseUp
        case .right:  downType = .rightMouseDown; upType = .rightMouseUp
        default:      downType = .otherMouseDown; upType = .otherMouseUp
        }

        for n in 1...clickCount {
            let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: p, mouseButton: button)
            let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: p, mouseButton: button)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func postDrag(from: CGPoint, to: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: to, mouseButton: .left)
        drag?.post(tap: .cghidEventTap)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
    }

    private func postScroll(at p: CGPoint, direction: String, amount: Int) {
        CGWarpMouseCursorPosition(p)
        let sign: Int32
        switch direction {
        case "up":    sign = 1
        case "down":  sign = -1
        case "left":  sign = 1
        case "right": sign = -1
        default:      sign = -1
        }
        let isVertical = (direction == "up" || direction == "down")
        let yWheel = isVertical ? sign * Int32(amount) * 3 : 0
        let xWheel = isVertical ? 0 : sign * Int32(amount) * 3
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: yWheel, wheel2: xWheel, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func postType(_ text: String) {
        for scalar in text.unicodeScalars {
            postUnicode(scalar)
        }
    }

    private func postUnicode(_ scalar: Unicode.Scalar) {
        let chars: [UniChar] = [UniChar(scalar.value & 0xFFFF)]
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
            chars.withUnsafeBufferPointer { ptr in
                down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
            }
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            chars.withUnsafeBufferPointer { ptr in
                up.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
            }
            up.post(tap: .cghidEventTap)
        }
    }

    private func postKeyCombo(_ combo: String) throws {
        let parts = combo.split(separator: "+").map { String($0).lowercased().trimmingCharacters(in: .whitespaces) }
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode?
        for part in parts {
            switch part {
            case "cmd", "command", "super": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt":    flags.insert(.maskAlternate)
            case "ctrl", "control":         flags.insert(.maskControl)
            case "fn":                      flags.insert(.maskSecondaryFn)
            default:
                guard let kc = keyCodeForName(part) else {
                    throw DispatchError("Unknown key: \(part)")
                }
                keyCode = kc
            }
        }
        guard let kc = keyCode else {
            throw DispatchError("No key code in combo: \(combo)")
        }
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    private func postHoldKey(_ combo: String, durationMs: Int) async throws {
        let parts = combo.split(separator: "+").map { String($0).lowercased() }
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode?
        for part in parts {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift":          flags.insert(.maskShift)
            case "alt", "option":  flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                guard let kc = keyCodeForName(part) else {
                    throw DispatchError("Unknown key: \(part)")
                }
                keyCode = kc
            }
        }
        guard let kc = keyCode else { throw DispatchError("No key in hold combo: \(combo)") }
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .milliseconds(durationMs))
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    private func keyCodeForName(_ name: String) -> CGKeyCode? {
        // Subset that's actually useful for computer-use. Extend as needed.
        switch name {
        case "return", "enter":   return CGKeyCode(kVK_Return)
        case "tab":               return CGKeyCode(kVK_Tab)
        case "space":             return CGKeyCode(kVK_Space)
        case "delete", "backspace": return CGKeyCode(kVK_Delete)
        case "escape", "esc":     return CGKeyCode(kVK_Escape)
        case "left":              return CGKeyCode(kVK_LeftArrow)
        case "right":             return CGKeyCode(kVK_RightArrow)
        case "up":                return CGKeyCode(kVK_UpArrow)
        case "down":              return CGKeyCode(kVK_DownArrow)
        case "a": return CGKeyCode(kVK_ANSI_A)
        case "b": return CGKeyCode(kVK_ANSI_B)
        case "c": return CGKeyCode(kVK_ANSI_C)
        case "d": return CGKeyCode(kVK_ANSI_D)
        case "e": return CGKeyCode(kVK_ANSI_E)
        case "f": return CGKeyCode(kVK_ANSI_F)
        case "g": return CGKeyCode(kVK_ANSI_G)
        case "h": return CGKeyCode(kVK_ANSI_H)
        case "i": return CGKeyCode(kVK_ANSI_I)
        case "j": return CGKeyCode(kVK_ANSI_J)
        case "k": return CGKeyCode(kVK_ANSI_K)
        case "l": return CGKeyCode(kVK_ANSI_L)
        case "m": return CGKeyCode(kVK_ANSI_M)
        case "n": return CGKeyCode(kVK_ANSI_N)
        case "o": return CGKeyCode(kVK_ANSI_O)
        case "p": return CGKeyCode(kVK_ANSI_P)
        case "q": return CGKeyCode(kVK_ANSI_Q)
        case "r": return CGKeyCode(kVK_ANSI_R)
        case "s": return CGKeyCode(kVK_ANSI_S)
        case "t": return CGKeyCode(kVK_ANSI_T)
        case "u": return CGKeyCode(kVK_ANSI_U)
        case "v": return CGKeyCode(kVK_ANSI_V)
        case "w": return CGKeyCode(kVK_ANSI_W)
        case "x": return CGKeyCode(kVK_ANSI_X)
        case "y": return CGKeyCode(kVK_ANSI_Y)
        case "z": return CGKeyCode(kVK_ANSI_Z)
        case "0": return CGKeyCode(kVK_ANSI_0)
        case "1": return CGKeyCode(kVK_ANSI_1)
        case "2": return CGKeyCode(kVK_ANSI_2)
        case "3": return CGKeyCode(kVK_ANSI_3)
        case "4": return CGKeyCode(kVK_ANSI_4)
        case "5": return CGKeyCode(kVK_ANSI_5)
        case "6": return CGKeyCode(kVK_ANSI_6)
        case "7": return CGKeyCode(kVK_ANSI_7)
        case "8": return CGKeyCode(kVK_ANSI_8)
        case "9": return CGKeyCode(kVK_ANSI_9)
        default: return nil
        }
    }
}

extension NSEvent {
    /// Cursor location in TOP-LEFT origin pixels for the primary display.
    static func mouseLocationFlipped(displayHeight: CGFloat) -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: displayHeight - p.y)
    }
}
