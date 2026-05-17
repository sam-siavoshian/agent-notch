//
//  AXFastPath.swift
//
//  Minimal AXUIElement wrapper. Lets the model address a button/link/field by
//  role + label substring and act on it without screenshot or mouse movement.
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

    private func frontmostPID() throws -> pid_t {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AXFastPathError.noFrontmostApp
        }
        return app.processIdentifier
    }

    // MARK: - Public API

    /// Find elements in the frontmost app matching role / label substrings.
    public func query(
        role: String? = nil,
        labelContains: String? = nil,
        valueContains: String? = nil,
        limit: Int = 8
    ) throws -> [AXMatch] {
        guard AXIsProcessTrusted() else { throw AXFastPathError.permissionDenied }
        let app = AXUIElementCreateApplication(try frontmostPID())

        var results: [AXMatch] = []
        var visited = 0
        let labelNeedle = labelContains?.lowercased()
        let valueNeedle = valueContains?.lowercased()
        walk(app, depth: 0, visited: &visited) { element in
            guard let match = matchIfRelevant(
                element: element,
                role: role,
                labelContains: labelNeedle,
                valueContains: valueNeedle
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

    // MARK: - Coordinate-based AX fast path (used by AgentCursorDriver)

    /// Resolve the AX element under `point` (top-left CGEvent coords) and
    /// attempt AXPress on it. Returns true on success — caller treats false
    /// as "fall through to CGEvent click". Never throws: the agent driver
    /// uses this as a best-effort optimization, not a hard requirement.
    public func tryPressAtPoint(_ point: CGPoint, pid: pid_t) -> Bool {
        guard Self.isTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        var elementRef: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &elementRef)
        guard err == .success, let element = elementRef else { return false }

        // Require that the element actually advertises Press as an action
        // before we attempt it. Some elements return .success on a synthesis
        // call but do nothing visible; gating on action names cuts that.
        var actionsRef: CFArray?
        let actionErr = AXUIElementCopyActionNames(element, &actionsRef)
        guard actionErr == .success,
              let actions = actionsRef as? [String],
              actions.contains(kAXPressAction as String) else { return false }

        let pressErr = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return pressErr == .success
    }

    /// Resolve the nearest AX scroll-area ancestor at `point` and adjust its
    /// scroll position by `clicks` notches in `direction`. Returns true on
    /// success. Best-effort: many apps do not expose AXScrollArea or do not
    /// honor SetAttributeValue on kAXValueAttribute for scrolling, in which
    /// case the caller falls through to CGEvent scroll wheel.
    public func tryScrollAtPoint(
        _ point: CGPoint,
        pid: pid_t,
        direction: AXScrollDirection,
        clicks: Int
    ) -> Bool {
        guard Self.isTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        var elementRef: AXUIElement?
        let hitErr = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &elementRef)
        guard hitErr == .success, var element = elementRef else { return false }

        // Walk up to find an AXScrollArea ancestor.
        var depth = 0
        while depth < 10, stringAttr(element, kAXRoleAttribute) != "AXScrollArea" {
            var parentRef: CFTypeRef?
            let pErr = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef)
            guard pErr == .success, let parent = parentRef as! AXUIElement? else { return false }
            element = parent
            depth += 1
        }
        guard stringAttr(element, kAXRoleAttribute) == "AXScrollArea" else { return false }

        // AXScrollArea exposes a kAXValueAttribute that is a CGPoint(0..1, 0..1)
        // representing scroll position. Read, mutate, write.
        var valueRef: CFTypeRef?
        let getErr = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard getErr == .success, let v = valueRef, CFGetTypeID(v) == AXValueGetTypeID() else { return false }
        var current = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &current) else { return false }

        // ~5% of the viewport per click in AX scroll-position space.
        let step: CGFloat = CGFloat(max(1, clicks)) * 0.05
        var next = current
        switch direction {
        case .up:    next.y = max(0, current.y - step)
        case .down:  next.y = min(1, current.y + step)
        case .left:  next.x = max(0, current.x - step)
        case .right: next.x = min(1, current.x + step)
        }
        guard let axValue = AXValueCreate(.cgPoint, &next) else { return false }
        let setErr = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, axValue)
        return setErr == .success
    }

    /// Walk the menu bar of the frontmost app; return the keystroke for the
    /// first menu item whose title contains `title` (case-insensitive).
    public func menuBarShortcut(forTitle title: String) throws -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        guard AXIsProcessTrusted() else { throw AXFastPathError.permissionDenied }
        let app = AXUIElementCreateApplication(try frontmostPID())

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
            if !label.lowercased().contains(labelContains) { return nil }
        }
        if let valueContains, !valueContains.isEmpty {
            if !(value?.lowercased().contains(valueContains) ?? false) { return nil }
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
