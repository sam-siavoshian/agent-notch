//
//  L2Snapshotter.swift
//  Agent in the Notch
//
//  Synchronous "current screen" snapshot consumed by the Selector at
//  long-press time. Independent components run in parallel; per-component
//  deadlines keep the worst case under ~400ms.
//

import Foundation
import AppKit
import ApplicationServices

public enum L2Snapshotter {

    private static let clickableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuButton", "AXLink",
        "AXRadioButton", "AXCheckBox", "AXTab", "AXTabGroup",
        "AXPopUpButton", "AXComboBox", "AXTextField", "AXTextArea",
        "AXSearchField", "AXSlider", "AXStepper"
    ]

    /// Build the L2 snapshot. Returns both the text payload AND the raw JPEG
    /// from the same capture — the JPEG is kept OUT of the payload to avoid
    /// bloating the text-only Mercury prompt. Callers wanting the image
    /// (AgentSession passing the initiation screenshot to Claude) read it
    /// from the tuple.
    ///
    /// `overallDeadline` is informational; the actual ceiling comes from the
    /// per-component deadlines below.
    public static func snapshot(overallDeadline: TimeInterval = 0.4) async -> (l2: CL2Snapshot, screenshotJPEG: Data?) {
        _ = overallDeadline // reserved for future use (e.g. Dev Tools timing assertions)

        // Frontmost app
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "<unknown>"
        let bundleID = app?.bundleIdentifier ?? "<unknown>"
        let pid = Int(app?.processIdentifier ?? 0)
        let windowTitle = readWindowTitle(pid: pid)
        let (windowID, displayID, displayBounds) = readWindowAndDisplay(pid: pid)

        // Parallel: screenshot+OCR, AX dump, app_specific adapter.
        async let captureTask = captureScreenshotAndOCR(deadline: 0.25)
        async let axElementsTask = dumpAXElements(pid: pid, deadline: 0.15)
        async let appSpecificTask = AdapterRegistry.shared.snapshot(bundleID: bundleID, timeout: 0.2)

        let capture = await captureTask
        let ocrLines = capture.ocrLines
        let screenshotJPEG = capture.jpegData

        let axElements = await axElementsTask
        let appSpecific = await appSpecificTask

        // Sync: selection + clipboard + cursor (cheap).
        let selection = AXObserverManager.shared.focusedElementDescriptor
        let clipboard = readClipboard()
        let cursor = readCursor()

        let l2 = CL2Snapshot(
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
        return (l2: l2, screenshotJPEG: screenshotJPEG)
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
    /// to stay under the time budget.
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

    /// OCR text + downsampled (≤1568 long-edge) JPEG from one capture.
    /// 1568 matches Anthropic's auto-downsample, so the full-res upload
    /// would be wasted bytes.
    private struct CaptureResult: Sendable {
        let ocrLines: [String]
        let jpegData: Data?
    }

    /// Race the screenshot+OCR pipeline against a wall-clock deadline.
    private static func captureScreenshotAndOCR(deadline: TimeInterval) async -> CaptureResult {
        return await withTaskGroup(of: CaptureResult.self) { group in
            group.addTask {
                return await Self.invokeCaptureAndOCR()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return CaptureResult(ocrLines: [], jpegData: nil)
            }
            let result = await group.next() ?? CaptureResult(ocrLines: [], jpegData: nil)
            group.cancelAll()
            return result
        }
    }

    /// One screenshot, two outputs: full-res rawImage for OCR (small UI text
    /// stays legible) + downsampled jpegData for the multimodal model.
    private static func invokeCaptureAndOCR() async -> CaptureResult {
        do {
            let snapshot = try await ScreenCapture.shared.snapshot(
                displayId: nil,
                quality: 0.7,
                maxLongEdge: 1568
            )
            guard let raw = snapshot.rawImage else {
                return CaptureResult(ocrLines: [], jpegData: snapshot.jpegData)
            }
            let recognized = await ContextOCRService.shared.recognizeText(in: raw, maxResults: 80)
            return CaptureResult(ocrLines: recognized.map(\.text), jpegData: snapshot.jpegData)
        } catch {
            return CaptureResult(ocrLines: [], jpegData: nil)
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

    /// Synchronous AX dump of the frontmost window, walking 3 levels deep and
    /// capturing up to 50 elements. Prioritizes clickable controls (buttons,
    /// menu items, links, text fields, etc.) so the most actionable surface
    /// reaches the selector even when the window is deeply nested.
    /// Best-effort — returns [] on permission error or when AX times out.
    private static func dumpAXSync(pid: Int) -> [CL2Snapshot.AXElement] {
        guard pid > 0 else { return [] }
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement], let window = windows.first else { return [] }

        var focusedAny: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedAny)
        let focused: AXUIElement? = {
            guard let v = focusedAny, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }()

        var collected: [CL2Snapshot.AXElement] = []
        walk(element: window, parentPath: "AXWindow", depth: 0, maxDepth: 3, focused: focused, collected: &collected)

        // Drop unlabeled passive elements; partition clickables ahead of the rest; cap at 50.
        var clickable: [CL2Snapshot.AXElement] = []
        var passive: [CL2Snapshot.AXElement] = []
        for el in collected where (el.label?.isEmpty == false) || el.focused {
            if Self.clickableRoles.contains(el.role) {
                clickable.append(el)
            } else {
                passive.append(el)
            }
        }
        return Array((clickable + passive).prefix(50))
    }

    private static func walk(
        element: AXUIElement,
        parentPath: String,
        depth: Int,
        maxDepth: Int,
        focused: AXUIElement?,
        collected: inout [CL2Snapshot.AXElement]
    ) {
        guard collected.count < 80 else { return }   // hard cap before sort/filter
        guard depth <= maxDepth else { return }

        if let el = describe(element, parent: parentPath, isFocused: focused.map { CFEqual(element, $0) } ?? false) {
            collected.append(el)
        }

        // Recurse into children
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }

        // For deep windows, cap children per level so the recursion stays bounded
        let perLevelCap = depth == 0 ? 30 : (depth == 1 ? 20 : 10)
        let role = (collected.last?.role ?? "?")
        let pathPrefix = "\(parentPath)/\(role)"

        for child in children.prefix(perLevelCap) {
            walk(element: child, parentPath: pathPrefix, depth: depth + 1, maxDepth: maxDepth, focused: focused, collected: &collected)
        }
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

    /// Read the current clipboard. Source-app taint (from ClipboardWatcher)
    /// isn't exposed yet, so sourceApp/sourceBundleID are nil.
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
