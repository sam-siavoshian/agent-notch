//
//  L2Snapshotter.swift
//  Agent in the Notch
//
//  Phase 4 (P4-3). Synchronous "current screen" snapshot built from the existing
//  services. Consumed by the Selector at long-press time.
//
//  Each subcomponent has its own short deadline so the worst case stays under
//  ~400 ms. Components run in parallel where they don't depend on each other:
//    - Window metadata    (NSWorkspace.frontmost + window title via AX)
//    - Display identity   (NSScreen of the frontmost window, best-effort)
//    - Screenshot + OCR   (ScreenCapture + ContextOCRService, ≤250 ms)
//    - AX element dump    (top-10 children of front window + focused flag, ≤150 ms)
//    - Selection          (AXObserverManager.shared.focusedElementDescriptor)
//    - Clipboard          (NSPasteboard.general; source-app taint not yet exposed)
//    - App-specific blob  (AdapterRegistry.shared.snapshot, 200 ms internal deadline)
//

import Foundation
import AppKit
import ApplicationServices

public enum L2Snapshotter {

    /// Build the L2 snapshot synchronously (from the caller's perspective). The
    /// `overallDeadline` parameter is informational — the actual ceiling comes
    /// from the per-component deadlines below.
    public static func snapshot(overallDeadline: TimeInterval = 0.4) async -> CL2Snapshot {
        _ = overallDeadline // reserved for future use (e.g. Dev Tools timing assertions)

        // Frontmost app
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "<unknown>"
        let bundleID = app?.bundleIdentifier ?? "<unknown>"
        let pid = Int(app?.processIdentifier ?? 0)
        let windowTitle = readWindowTitle(pid: pid)
        let (windowID, displayID, displayBounds) = readWindowAndDisplay(pid: pid)

        // Parallel: screenshot+OCR, AX dump, app_specific adapter.
        async let ocrLinesTask = captureAndOCR(deadline: 0.25)
        async let axElementsTask = dumpAXElements(pid: pid, deadline: 0.15)
        async let appSpecificTask = AdapterRegistry.shared.snapshot(bundleID: bundleID, timeout: 0.2)

        let ocrLines = await ocrLinesTask
        let axElements = await axElementsTask
        let appSpecific = await appSpecificTask

        // Sync: selection + clipboard + cursor (cheap).
        let selection = AXObserverManager.shared.focusedElementDescriptor
        let clipboard = readClipboard()
        let cursor = readCursor()

        return CL2Snapshot(
            app: appName,
            bundleID: bundleID,
            pid: pid,
            windowTitle: windowTitle,
            windowID: windowID,
            displayID: displayID,
            displayBounds: displayBounds,
            capturedAt: Date(),
            ocrLines: ocrLines,
            axElements: axElements,
            cursor: cursor,
            selection: selection,
            clipboard: clipboard,
            appSpecific: appSpecific
        )
    }

    // MARK: - Window + display

    private static func readWindowTitle(pid: Int) -> String? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement], let first = windows.first else { return nil }
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(first, kAXTitleAttribute as CFString, &titleValue)
        return titleValue as? String
    }

    /// Returns (windowID, displayID, displayBounds). Best-effort — falls back to
    /// the main screen. windowID requires CGWindowListCopyWindowInfo; left nil
    /// for Phase 4 to stay under the time budget.
    private static func readWindowAndDisplay(pid: Int) -> (Int?, Int, [Double]) {
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let displayID = (mainScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 1
        let bounds = mainScreen?.frame ?? .zero
        let displayBounds: [Double] = [
            Double(bounds.origin.x),
            Double(bounds.origin.y),
            Double(bounds.width),
            Double(bounds.height)
        ]
        return (nil, displayID, displayBounds)
    }

    // MARK: - Screenshot + OCR

    /// Race the real screenshot+OCR pipeline against a wall-clock deadline.
    /// Whichever finishes first wins; the other task is cancelled.
    private static func captureAndOCR(deadline: TimeInterval) async -> [String] {
        return await withTaskGroup(of: [String].self) { group in
            group.addTask {
                return await Self.invokeExistingOCR()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    /// Bridge to the existing ScreenCapture + ContextOCRService stack.
    /// Both are actors with async APIs that already handle their own errors.
    /// On any failure we return [] — the Selector still works without OCR lines.
    private static func invokeExistingOCR() async -> [String] {
        do {
            // Skip downsampling here — OCR wants the full-res CGImage so small
            // UI text (menu bars, terminals) stays legible. The JPEG returned
            // by ScreenCapture is downsampled, but `rawImage` is full res.
            let snapshot = try await ScreenCapture.shared.snapshot(
                displayId: nil,
                quality: 0.7,
                maxLongEdge: nil
            )
            guard let raw = snapshot.rawImage else {
                // Shouldn't happen with the SCKit path, but be defensive.
                return []
            }
            let recognized = await ContextOCRService.shared.recognizeText(in: raw, maxResults: 80)
            return recognized.map(\.text)
        } catch {
            return []
        }
    }

    // MARK: - AX element dump

    private static func dumpAXElements(pid: Int, deadline: TimeInterval) async -> [CL2Snapshot.AXElement] {
        return await withTaskGroup(of: [CL2Snapshot.AXElement].self) { group in
            group.addTask { Self.dumpAXSync(pid: pid) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    /// Synchronous AX dump of the frontmost window's children (one level deep,
    /// top 10). Records (role, label, ax_path, bbox, focused). Best-effort —
    /// returns [] on permission error or when AX times out.
    private static func dumpAXSync(pid: Int) -> [CL2Snapshot.AXElement] {
        guard pid > 0 else { return [] }
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement], let window = windows.first else { return [] }

        // Focused element via the app's focused-element attribute.
        var focusedAny: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedAny)
        let focusedElement: AXUIElement? = {
            guard let v = focusedAny, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }()

        // Walk children one level deep.
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return [] }

        var out: [CL2Snapshot.AXElement] = []
        for child in children.prefix(10) {
            let isFocused: Bool = {
                guard let focusedElement else { return false }
                return CFEqual(child, focusedElement)
            }()
            if let el = describe(child, parent: "AXWindow", isFocused: isFocused) {
                out.append(el)
            }
        }
        return out
    }

    private static func describe(_ element: AXUIElement, parent: String, isFocused: Bool) -> CL2Snapshot.AXElement? {
        let role = copyStringAttr(element, kAXRoleAttribute) ?? "AXUnknown"
        let label = copyStringAttr(element, kAXTitleAttribute)
            ?? copyStringAttr(element, kAXDescriptionAttribute)
            ?? copyStringAttr(element, kAXValueAttribute)
        let path = "\(parent)/\(role)\(label.map { "[\($0)]" } ?? "")"

        var posValue: AnyObject?
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        var bbox: [Int]? = nil
        if let posValue, let sizeValue,
           CFGetTypeID(posValue) == AXValueGetTypeID(),
           CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            var origin = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            bbox = [Int(origin.x), Int(origin.y), Int(size.width), Int(size.height)]
        }
        return CL2Snapshot.AXElement(
            role: role,
            label: label,
            axPath: path,
            bbox: bbox,
            focused: isFocused
        )
    }

    private static func copyStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Cursor + clipboard

    /// Cursor location in top-left-origin screen coordinates (matches AX/CG conventions).
    /// NSEvent.mouseLocation returns bottom-left, so we flip Y against the main screen.
    private static func readCursor() -> [Int]? {
        let p = NSEvent.mouseLocation
        if let screen = NSScreen.main {
            let y = Int(screen.frame.height - p.y)
            return [Int(p.x), y]
        }
        return [Int(p.x), Int(p.y)]
    }

    /// Read the current clipboard contents synchronously. ClipboardWatcher's
    /// internal CopySource (which carries source-app taint) is private; until
    /// it's exposed we set sourceApp/sourceBundleID to nil. Selector + Mercury
    /// can still benefit from preview + bytes.
    private static func readClipboard() -> CL2Snapshot.ClipboardSnapshot? {
        let pb = NSPasteboard.general
        guard let s = pb.string(forType: .string), !s.isEmpty else { return nil }
        return CL2Snapshot.ClipboardSnapshot(
            kind: "text",
            preview: String(s.prefix(200)),
            bytes: s.utf8.count,
            ageS: 0,
            sourceApp: nil,
            sourceBundleID: nil
        )
    }
}
