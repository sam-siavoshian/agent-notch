//
//  ToolDispatcher.swift
//
//  Maps Anthropic computer-use tool calls + custom fast-path tools to CGEvent /
//  AXUIElement / NSWorkspace / AppleScript actions. `computer` coordinates use
//  top-left pixels, matching CGEvent on a single primary display.
//

import Foundation
import AppKit
import Carbon.HIToolbox

private let log = Log(category: "dispatcher")

public struct DispatchedToolResult: Sendable {
    public let toolUseId: String
    public let content: [ContentBlock]
    public let isError: Bool
}

public actor ToolDispatcher {
    /// What the MODEL sees: screenshot dimensions + the display_width/height_px
    /// we advertise. Capped at ~1280 long-edge per Anthropic's accuracy guidance.
    public let agentDisplaySize: CGSize
    /// macOS logical-point space (NSEvent.mouseLocation / CGEvent). Model
    /// coordinates are scaled from agentDisplaySize → this before posting.
    public let logicalDisplaySize: CGSize
    /// Long-edge cap for `computer.screenshot`, matched to agentDisplaySize so
    /// the image and the click coordinate space stay 1:1.
    public let screenshotLongEdge: Int
    private let capture: ScreenCapture

    public init(
        agentDisplaySize: CGSize,
        logicalDisplaySize: CGSize,
        screenshotLongEdge: Int,
        capture: ScreenCapture = .shared
    ) {
        self.agentDisplaySize = agentDisplaySize
        self.logicalDisplaySize = logicalDisplaySize
        self.screenshotLongEdge = screenshotLongEdge
        self.capture = capture
    }

    public func dispatch(toolUseId: String, name: String, input: JSON) async -> DispatchedToolResult {
        log.info("dispatcher.dispatch tool=\(name)")
        do {
            switch name {
            case "computer":      return try await dispatchComputer(toolUseId: toolUseId, input: input)
            case "open_url":      return try await dispatchOpenURL(toolUseId: toolUseId, input: input)
            case "open_app":      return try await dispatchOpenApp(toolUseId: toolUseId, input: input)
            case "applescript":   return try await dispatchAppleScript(toolUseId: toolUseId, input: input)
            case "run_shortcut":  return try await dispatchShortcut(toolUseId: toolUseId, input: input)
            case "ax_query":      return try await dispatchAXQuery(toolUseId: toolUseId, input: input)
            case "ax_press":      return try await dispatchAXPress(toolUseId: toolUseId, input: input)
            case "ax_set_value":  return try await dispatchAXSetValue(toolUseId: toolUseId, input: input)
            case "menu_shortcut": return try await dispatchMenuShortcut(toolUseId: toolUseId, input: input)
            default:
                log.error("dispatcher.unsupported_tool tool=\(name)")
                return errorResult(toolUseId, "Unsupported tool: \(name)")
            }
        } catch let e as DispatchError {
            log.error("dispatcher.dispatch_error tool=\(name) message=\(e.message)")
            return errorResult(toolUseId, e.message)
        } catch {
            log.error("dispatcher.unexpected_error tool=\(name) error=\(error)")
            return errorResult(toolUseId, "Dispatch failed: \(error)")
        }
    }

    // MARK: - computer tool

    private func dispatchComputer(toolUseId: String, input: JSON) async throws -> DispatchedToolResult {
        guard let action = input.objectValue?["action"]?.stringValue else {
            throw DispatchError("Missing 'action' in computer tool input")
        }
        switch action {
        case "screenshot":
            let snap = try await capture.snapshot(maxLongEdge: screenshotLongEdge)
            let b64 = snap.jpegData.base64EncodedString()
            return DispatchedToolResult(
                toolUseId: toolUseId,
                content: [.image(mediaType: "image/jpeg", base64: b64, cache: false)],
                isError: false
            )

        case "left_click":
            let p = try requireCoordinate(input)
            await AgentCursorDriver.shared.click(at: p, button: .left, count: 1)
            return ok(toolUseId, "clicked at \(Int(p.x)),\(Int(p.y))")

        case "right_click":
            let p = try requireCoordinate(input)
            await AgentCursorDriver.shared.click(at: p, button: .right, count: 1)
            return ok(toolUseId, "right-clicked at \(Int(p.x)),\(Int(p.y))")

        case "middle_click":
            let p = try requireCoordinate(input)
            await AgentCursorDriver.shared.click(at: p, button: .center, count: 1)
            return ok(toolUseId, "middle-clicked at \(Int(p.x)),\(Int(p.y))")

        case "double_click":
            let p = try requireCoordinate(input)
            await AgentCursorDriver.shared.click(at: p, button: .left, count: 2)
            return ok(toolUseId, "double-clicked at \(Int(p.x)),\(Int(p.y))")

        case "triple_click":
            let p = try requireCoordinate(input)
            await AgentCursorDriver.shared.click(at: p, button: .left, count: 3)
            return ok(toolUseId, "triple-clicked at \(Int(p.x)),\(Int(p.y))")

        case "left_click_drag":
            let from = NSEvent.mouseLocationFlipped(displayHeight: logicalDisplaySize.height)
            let to = try requireCoordinate(input)
            await AgentCursorDriver.shared.drag(from: from, to: to)
            return ok(toolUseId, "dragged to \(Int(to.x)),\(Int(to.y))")

        case "mouse_move":
            let p = try requireCoordinate(input)
            await AgentCursorDriver.shared.move(to: p)
            return ok(toolUseId, "moved to \(Int(p.x)),\(Int(p.y))")

        case "cursor_position":
            let loc = NSEvent.mouseLocationFlipped(displayHeight: logicalDisplaySize.height)
            return ok(toolUseId, "X=\(Int(loc.x)) Y=\(Int(loc.y))")

        case "type":
            guard let text = input.objectValue?["text"]?.stringValue else {
                throw DispatchError("Missing 'text' for type action")
            }
            let viaPaste = input.objectValue?["via_paste"]?.boolValue
            await postType(text, viaPaste: viaPaste)
            return ok(toolUseId, "typed \(text.count) chars")

        case "key":
            guard let combo = input.objectValue?["text"]?.stringValue else {
                throw DispatchError("Missing 'text' for key action")
            }
            try await postKeyCombo(combo)
            return ok(toolUseId, "pressed \(combo)")

        case "scroll":
            let p = try requireCoordinate(input)
            let requested = input.objectValue?["scroll_amount"]?.intValue ?? 3
            let directionStr = input.objectValue?["scroll_direction"]?.stringValue ?? "down"
            let clicks = max(1, requested)
            let direction: AXScrollDirection = {
                switch directionStr {
                case "up": return .up
                case "left": return .left
                case "right": return .right
                default: return .down
                }
            }()
            await AgentCursorDriver.shared.scroll(at: p, direction: direction, clicks: clicks)
            let pixels = clicks * Self.pixelsPerScrollClick
            return ok(toolUseId, "scrolled \(directionStr) \(clicks) click(s) ≈ \(pixels)px. If you need to move further, use scroll_amount=5+ (each click ≈ 100px).")

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
            throw DispatchError("Unsupported computer action: \(action)")
        }
    }

    // MARK: - Fast-path tools

    private func dispatchOpenURL(toolUseId: String, input: JSON) async throws -> DispatchedToolResult {
        guard let urlString = input.objectValue?["url"]?.stringValue,
              let url = URL(string: urlString) else {
            throw DispatchError("Missing or invalid 'url'")
        }
        let opened = NSWorkspace.shared.open(url)
        if !opened { throw DispatchError("NSWorkspace.open returned false for \(urlString)") }
        return ok(toolUseId, "opened \(urlString)")
    }

    /// Launch a desktop app by name via exact-path resolution. Pins to
    /// `/Applications/<Name>.app`, bypassing Launch Services' scheme handler
    /// which can resolve `discord://` to Discord Canary on machines with both.
    private func dispatchOpenApp(toolUseId: String, input: JSON) async throws -> DispatchedToolResult {
        guard let name = input.objectValue?["name"]?.stringValue, !name.isEmpty else {
            throw DispatchError("Missing 'name'")
        }
        let candidates = [
            "/Applications/\(name).app",
            "/System/Applications/\(name).app",
            "/System/Applications/Utilities/\(name).app",
            "\(NSHomeDirectory())/Applications/\(name).app"
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw DispatchError("No app named '\(name).app' found in /Applications, /System/Applications, /System/Applications/Utilities, or ~/Applications")
        }
        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw DispatchError("Failed to open \(name): \(error.localizedDescription)")
        }
        return ok(toolUseId, "opened \(path)")
    }

    private func dispatchAppleScript(toolUseId: String, input: JSON) async throws -> DispatchedToolResult {
        guard let script = input.objectValue?["script"]?.stringValue, !script.isEmpty else {
            throw DispatchError("Missing 'script'")
        }
        let result = try await AppleScriptBridge.run(script)
        return ok(toolUseId, result.isEmpty ? "applescript ok" : result)
    }

    private func dispatchShortcut(toolUseId: String, input: JSON) async throws -> DispatchedToolResult {
        guard let shortcutName = input.objectValue?["name"]?.stringValue, !shortcutName.isEmpty else {
            throw DispatchError("Missing 'name'")
        }
        let inputText = input.objectValue?["input"]?.stringValue
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        var args = ["run", shortcutName]
        if inputText != nil { args.append(contentsOf: ["-i", "-"]) }
        process.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let inputText {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(inputText.data(using: .utf8) ?? Data())
            try? stdin.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DispatchError("shortcuts run failed: \(err.isEmpty ? "exit \(process.terminationStatus)" : err)")
        }
        return ok(toolUseId, out.isEmpty ? "shortcut '\(shortcutName)' ok" : out)
    }

    private func dispatchAXQuery(toolUseId: String, input: JSON) async throws -> DispatchedToolResult {
        let role = input.objectValue?["role"]?.stringValue
        let label = input.objectValue?["label_contains"]?.stringValue
        let value = input.objectValue?["value_contains"]?.stringValue
        let limit = input.objectValue?["limit"]?.intValue ?? 8
        let matches = try await AXFastPath.shared.query(
            role: role,
            labelContains: label,
            valueContains: value,
            limit: limit
        )
        let json = matches.map { m -> String in
            let frame = m.frame.map { "[\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))]" } ?? ""
            return "id=\(m.id) role=\(m.role ?? "?") title=\(m.title ?? "") desc=\(m.description ?? "") enabled=\(m.enabled) \(frame)"
        }.joined(separator: "\n")
        return ok(toolUseId, matches.isEmpty ? "no matches" : json)
    }

    private func dispatchAXPress(toolUseId: String, input: JSON) async throws -> DispatchedToolResult {
        guard let id = input.objectValue?["id"]?.stringValue else {
            throw DispatchError("Missing 'id'")
        }
        try await AXFastPath.shared.press(id: id)
        return ok(toolUseId, "ax_pressed \(id)")
    }

    private func dispatchAXSetValue(toolUseId: String, input: JSON) async throws -> DispatchedToolResult {
        guard let id = input.objectValue?["id"]?.stringValue,
              let value = input.objectValue?["value"]?.stringValue else {
            throw DispatchError("Missing 'id' or 'value'")
        }
        try await AXFastPath.shared.setValue(id: id, value: value)
        return ok(toolUseId, "ax_set_value \(id)")
    }

    private func dispatchMenuShortcut(toolUseId: String, input: JSON) async throws -> DispatchedToolResult {
        guard let title = input.objectValue?["title"]?.stringValue else {
            throw DispatchError("Missing 'title'")
        }
        guard let combo = try await AXFastPath.shared.menuBarShortcut(forTitle: title) else {
            throw DispatchError("No menu item matched '\(title)' or no shortcut registered")
        }
        await postKeyCode(combo.keyCode, flags: combo.flags)
        return ok(toolUseId, "menu shortcut '\(title)' sent")
    }

    // MARK: - Helpers

    private struct DispatchError: Swift.Error { let message: String; init(_ m: String) { self.message = m } }

    /// Decode the model-emitted `coordinate` (agentDisplaySize space) and
    /// scale into macOS logical points for CGEvent posting. Without scaling,
    /// Retina mismatches double every click offset.
    private func requireCoordinate(_ input: JSON) throws -> CGPoint {
        guard let coord = input.objectValue?["coordinate"]?.arrayValue,
              coord.count >= 2,
              let x = coord[0].intValue,
              let y = coord[1].intValue else {
            throw DispatchError("Missing or invalid 'coordinate'")
        }
        let sx = logicalDisplaySize.width / max(1, agentDisplaySize.width)
        let sy = logicalDisplaySize.height / max(1, agentDisplaySize.height)
        return CGPoint(x: CGFloat(x) * sx, y: CGFloat(y) * sy)
    }

    private func ok(_ id: String, _ text: String) -> DispatchedToolResult {
        DispatchedToolResult(toolUseId: id, content: [.text(text)], isError: false)
    }

    private func errorResult(_ id: String, _ text: String) -> DispatchedToolResult {
        DispatchedToolResult(toolUseId: id, content: [.text(text)], isError: true)
    }

    // MARK: - CGEvent posting (driver-routed)

    // Kept for the scroll status string; the actual scroll dispatch now flows
    // through AgentCursorDriver (AX scroll → CGEvent wheel via postToPid).
    private static let pixelsPerScrollClick: Int = 100

    /// Type text. For strings > 4 chars with only ASCII OR `viaPaste == true`,
    /// use the pasteboard (one Cmd+V event total) instead of posting one
    /// keyDown/keyUp pair per character. Pasteboard contents are preserved.
    private func postType(_ text: String, viaPaste: Bool? = nil) async {
        let shouldPaste: Bool = {
            if let viaPaste { return viaPaste }
            if text.count <= 4 { return false }
            return text.allSatisfy { $0.isASCII }
        }()
        if shouldPaste {
            await pasteText(text)
        } else {
            for scalar in text.unicodeScalars {
                await postUnicode(scalar)
            }
        }
    }

    /// Save pasteboard, write `text`, post Cmd+V, restore. Restore is delayed
    /// so the receiving app has time to read our string before it's clobbered.
    private func pasteText(_ text: String) async {
        let pb = NSPasteboard.general
        let snapshot = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        do { try await postKeyCombo("cmd+v") } catch { NSLog("[ToolDispatcher] paste cmd+v failed: \(error)") }
        try? await Task.sleep(for: .milliseconds(200))
        if let snapshot {
            pb.clearContents()
            pb.writeObjects(snapshot)
        }
    }

    private func postUnicode(_ scalar: Unicode.Scalar) async {
        await AgentCursorDriver.shared.typeUnicode(scalar)
    }

    private func postKeyCombo(_ combo: String) async throws {
        let parts = combo.split(separator: "+").map { String($0).lowercased().trimmingCharacters(in: .whitespaces) }
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode?
        for raw in parts {
            switch raw {
            case "cmd", "command", "super": flags.insert(.maskCommand)
            case "shift":                   flags.insert(.maskShift)
            case "alt", "option", "opt":    flags.insert(.maskAlternate)
            case "ctrl", "control":         flags.insert(.maskControl)
            case "fn":                      flags.insert(.maskSecondaryFn)
            case let part:
                guard let kc = keyCodeForName(part) else { throw DispatchError("Unknown key: \(part)") }
                keyCode = kc
            }
        }
        guard let kc = keyCode else {
            throw DispatchError("No key code in combo: \(combo)")
        }
        await postKeyCode(kc, flags: flags)
    }

    private func postKeyCode(_ kc: CGKeyCode, flags: CGEventFlags) async {
        await AgentCursorDriver.shared.key(keyCode: kc, flags: flags)
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
        await AgentCursorDriver.shared.holdKey(keyCode: kc, flags: flags, durationMs: durationMs)
    }

    private func keyCodeForName(_ name: String) -> CGKeyCode? {
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
        case "f1":  return CGKeyCode(kVK_F1)
        case "f2":  return CGKeyCode(kVK_F2)
        case "f3":  return CGKeyCode(kVK_F3)
        case "f4":  return CGKeyCode(kVK_F4)
        case "f5":  return CGKeyCode(kVK_F5)
        case "f6":  return CGKeyCode(kVK_F6)
        case "f7":  return CGKeyCode(kVK_F7)
        case "f8":  return CGKeyCode(kVK_F8)
        case "f9":  return CGKeyCode(kVK_F9)
        case "f10": return CGKeyCode(kVK_F10)
        case "f11": return CGKeyCode(kVK_F11)
        case "f12": return CGKeyCode(kVK_F12)
        case "home":      return CGKeyCode(kVK_Home)
        case "end":       return CGKeyCode(kVK_End)
        case "pageup":    return CGKeyCode(kVK_PageUp)
        case "pagedown":  return CGKeyCode(kVK_PageDown)
        case "forwarddelete", "del": return CGKeyCode(kVK_ForwardDelete)
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
