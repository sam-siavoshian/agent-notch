//
//  AXFastPath.swift
//  Agent in the Notch
//
//  Minimal AXUIElement wrapper for the agent. Lets the model name a button,
//  link, or text field by role + label/title substring and act on it without
//  taking a screenshot or moving the mouse.
//
//  Why this exists: vision + click is the slow path. AX press is ~10ms,
//  doesn't steal focus, doesn't depend on coordinate accuracy, and survives
//  scaled displays. We use it preferentially and keep CGEvent click as the
//  universal fallback.
//
//  We deliberately do NOT pull in AXorcist (SPM) — small surface, easy to
//  reason about, no dependency cost. Patterns borrowed from steipete/AXorcist
//  and Geisterhand-io/macos.
//

import Foundation
import AppKit
import ApplicationServices

public struct AXMatch: Sendable {
    public let id: String
    public let role: String?
    public let title: String?
    public let description: String?
    public let value: String?
    public let enabled: Bool
    public let frame: CGRect?
}

public enum AXFastPathError: Error, CustomStringConvertible {
    case permissionDenied
    case noFrontmostApp
    case axError(AXError)
    case elementNotFound(String)

    public var description: String {
        switch self {
        case .permissionDenied: return "Accessibility permission not granted to AgentNotch."
        case .noFrontmostApp: return "No frontmost application."
        case .axError(let e): return "AX error: \(e.rawValue)"
        case .elementNotFound(let id): return "AX element not found for id: \(id)"
        }
    }
}

/// Actor-isolated registry of AXUIElement references handed out to the model
/// as opaque string ids. Cleared per agent run (call `reset()`).
public actor AXFastPath {
    public static let shared = AXFastPath()

    private var registry: [String: AXUIElement] = [:]
    /// Soft cap on recursion when walking a window subtree. Some apps
    /// (Electron, JetBrains) expose enormous AX trees; a bounded walk keeps
    /// query latency under control.
    private let maxNodes: Int = 1500
    private let maxDepth: Int = 25

    public init() {}

    public func reset() {
        registry.removeAll(keepingCapacity: true)
    }

    public static func isTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    // MARK: - Public API

    public func frontmostApp() throws -> (pid: pid_t, bundleID: String?, name: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AXFastPathError.noFrontmostApp
        }
        return (app.processIdentifier, app.bundleIdentifier, app.localizedName)
    }

    /// Find elements in the frontmost app matching role / label substrings.
    /// Returns up to `limit` matches.
    public func query(
        role: String? = nil,
        labelContains: String? = nil,
        valueContains: String? = nil,
        limit: Int = 8
    ) throws -> [AXMatch] {
        guard Self.isTrusted() else { throw AXFastPathError.permissionDenied }
        let (pid, _, _) = try frontmostApp()
        let app = AXUIElementCreateApplication(pid)

        var results: [AXMatch] = []
        var visited = 0
        walk(app, depth: 0, visited: &visited) { element in
            guard let match = matchIfRelevant(
                element: element,
                role: role,
                labelContains: labelContains,
                valueContains: valueContains
            ) else { return }
            results.append(match)
        }
        return Array(results.prefix(limit))
    }

    public func press(id: String) throws {
        guard let element = registry[id] else {
            throw AXFastPathError.elementNotFound(id)
        }
        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if err != .success { throw AXFastPathError.axError(err) }
    }

    public func setValue(id: String, value: String) throws {
        guard let element = registry[id] else {
            throw AXFastPathError.elementNotFound(id)
        }
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        if err != .success { throw AXFastPathError.axError(err) }
    }

    /// Walk the menu bar of the frontmost app and return the keyboard
    /// shortcut for a menu item whose title contains `title` (case-insensitive
    /// substring). Returns (CGKeyCode, CGEventFlags) when found.
    public func menuBarShortcut(forTitle title: String) throws -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        guard Self.isTrusted() else { throw AXFastPathError.permissionDenied }
        let (pid, _, _) = try frontmostApp()
        let app = AXUIElementCreateApplication(pid)

        var menuBarRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef)
        if err != .success { return nil }
        guard let menuBar = menuBarRef as! AXUIElement? else { return nil }

        let needle = title.lowercased()
        var found: (CGKeyCode, CGEventFlags)?
        var visited = 0
        walk(menuBar, depth: 0, visited: &visited) { element in
            if found != nil { return }
            guard role(of: element) == "AXMenuItem" else { return }
            let itemTitle = (stringAttr(element, kAXTitleAttribute) ?? "").lowercased()
            guard !itemTitle.isEmpty, itemTitle.contains(needle) else { return }
            // kAXMenuItemCmdCharAttribute = single character key
            guard let ch = stringAttr(element, "AXMenuItemCmdChar"), let scalar = ch.unicodeScalars.first else { return }
            let keyCode = keyCodeFor(unicode: scalar)
            guard let keyCode else { return }
            let mods = intAttr(element, "AXMenuItemCmdModifiers") ?? 0
            // AXMenuItemCmdModifiers bitfield (Apple-defined): bit 0 = Shift,
            // bit 1 = Option, bit 2 = Control, bit 3 = (NO command),
            // i.e. command is IMPLIED unless bit 3 set.
            var flags: CGEventFlags = []
            if (mods & 0b0001) != 0 { flags.insert(.maskShift) }
            if (mods & 0b0010) != 0 { flags.insert(.maskAlternate) }
            if (mods & 0b0100) != 0 { flags.insert(.maskControl) }
            if (mods & 0b1000) == 0 { flags.insert(.maskCommand) }
            found = (keyCode, flags)
        }
        return found
    }

    // MARK: - Internal

    private func matchIfRelevant(
        element: AXUIElement,
        role: String?,
        labelContains: String?,
        valueContains: String?
    ) -> AXMatch? {
        let r = stringAttr(element, kAXRoleAttribute)
        if let role, let r {
            if !r.caseInsensitiveContains(role) { return nil }
        }
        let title = stringAttr(element, kAXTitleAttribute)
        let desc = stringAttr(element, kAXDescriptionAttribute)
        let value = stringAttr(element, kAXValueAttribute)
        let label = [title, desc, stringAttr(element, "AXHelp")]
            .compactMap { $0 }
            .joined(separator: " ")
        if let labelContains, !labelContains.isEmpty {
            if !label.lowercased().contains(labelContains.lowercased()) { return nil }
        }
        if let valueContains, !valueContains.isEmpty {
            if !(value?.lowercased().contains(valueContains.lowercased()) ?? false) { return nil }
        }
        if labelContains == nil && valueContains == nil && role == nil { return nil }
        let id = UUID().uuidString.prefix(8).description
        registry[id] = element
        return AXMatch(
            id: id,
            role: r,
            title: title,
            description: desc,
            value: value,
            enabled: (boolAttr(element, kAXEnabledAttribute)) ?? true,
            frame: frame(of: element)
        )
    }

    private func walk(_ element: AXUIElement, depth: Int, visited: inout Int, visit: (AXUIElement) -> Void) {
        if visited >= maxNodes || depth > maxDepth { return }
        visited += 1
        visit(element)
        var childrenRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if err == .success, let children = childrenRef as? [AXUIElement] {
            for child in children {
                if visited >= maxNodes { return }
                walk(child, depth: depth + 1, visited: &visited, visit: visit)
            }
        }
    }

    private func role(of element: AXUIElement) -> String? {
        stringAttr(element, kAXRoleAttribute)
    }

    private func stringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }

    private func boolAttr(_ element: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard err == .success else { return nil }
        return (ref as? Bool)
    }

    private func intAttr(_ element: AXUIElement, _ attr: String) -> Int? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard err == .success, let num = ref as? NSNumber else { return nil }
        return num.intValue
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let e1 = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        let e2 = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        guard e1 == .success, e2 == .success else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        if let pos = posRef, CFGetTypeID(pos) == AXValueGetTypeID() {
            AXValueGetValue(pos as! AXValue, .cgPoint, &position)
        }
        if let sz = sizeRef, CFGetTypeID(sz) == AXValueGetTypeID() {
            AXValueGetValue(sz as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }

    /// Map a printable ASCII character to its US-layout virtual keycode.
    /// Sufficient for menu shortcuts which the model would otherwise click.
    private func keyCodeFor(unicode: Unicode.Scalar) -> CGKeyCode? {
        let lower = Character(unicode).lowercased()
        guard let ch = lower.first else { return nil }
        switch ch {
        case "a": return 0x00
        case "s": return 0x01
        case "d": return 0x02
        case "f": return 0x03
        case "h": return 0x04
        case "g": return 0x05
        case "z": return 0x06
        case "x": return 0x07
        case "c": return 0x08
        case "v": return 0x09
        case "b": return 0x0B
        case "q": return 0x0C
        case "w": return 0x0D
        case "e": return 0x0E
        case "r": return 0x0F
        case "y": return 0x10
        case "t": return 0x11
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "6": return 0x16
        case "5": return 0x17
        case "9": return 0x19
        case "7": return 0x1A
        case "8": return 0x1C
        case "0": return 0x1D
        case "o": return 0x1F
        case "u": return 0x20
        case "i": return 0x22
        case "p": return 0x23
        case "l": return 0x25
        case "j": return 0x26
        case "k": return 0x28
        case "n": return 0x2D
        case "m": return 0x2E
        case ",": return 0x2B
        case ".": return 0x2F
        case "/": return 0x2C
        case ";": return 0x29
        case "'": return 0x27
        case "[": return 0x21
        case "]": return 0x1E
        case "\\": return 0x2A
        case "-": return 0x1B
        case "=": return 0x18
        case "`": return 0x32
        default: return nil
        }
    }
}

private extension String {
    func caseInsensitiveContains(_ other: String) -> Bool {
        self.range(of: other, options: .caseInsensitive) != nil
    }
}
