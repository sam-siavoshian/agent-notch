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

    private static let clickableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuButton", "AXLink",
        "AXRadioButton", "AXCheckBox", "AXTab", "AXTabGroup",
        "AXPopUpButton", "AXComboBox", "AXTextField", "AXTextArea",
        "AXSearchField", "AXSlider", "AXStepper"
    ]

    /// Build the L2 snapshot synchronously (from the caller's perspective). The
    /// `overallDeadline` parameter is informational — the actual ceiling comes
    /// from the per-component deadlines below.
    ///
    /// Returns the CL2Snapshot (text payload), the JPEG bytes of the screenshot
    /// (already center-cropped + scaled to WXGA 1280x800 so the harness can
    /// attach it to message[0] without re-encoding), and the CoordTransform the
    /// harness needs to invert click coordinates back to logical-point space.
    ///
    /// The JPEG is kept OUT of CL2Snapshot to avoid bloating the Mercury 2
    /// (text-only) selector prompt by hundreds of KB. OCR runs on the FULL-RES
    /// raw image internally so small UI text stays legible.
    ///
    /// There is no per-long-press vision call — the continuous GeminiObserver
    /// is the only vision path; its accumulated SurfaceMemoryStore feeds
    /// Mercury via the `learned_surfaces` payload field.
    public static func snapshot(overallDeadline: TimeInterval = 0.4) async -> (l2: CL2Snapshot, screenshotJPEG: Data?, transform: ScreenCapture.CoordTransform?) {
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
        let transform = capture.transform

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
        return (l2: l2, screenshotJPEG: screenshotJPEG, transform: transform)
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

    /// Bundle returned from `captureScreenshotAndOCR`: the OCR text plus the
    /// JPEG bytes of the same capture pre-sized to the computer-use harness's
    /// `agentDisplaySize` (1280x800 WXGA). The `transform` describes the
    /// crop+scale applied so the harness can invert future click coordinates
    /// back to logical-point space.
    private struct CaptureResult: Sendable {
        let ocrLines: [String]
        let jpegData: Data?
        let transform: ScreenCapture.CoordTransform?
    }

    /// WXGA target the harness pins for the model's coordinate space.
    /// Kept here so L2 ships a JPEG that exactly matches what
    /// `ToolDispatcher.computer.screenshot` will emit on subsequent turns —
    /// turn-1 clicks then land on-target without any extra round-trip.
    private static let harnessTargetSize = CGSize(width: 1280, height: 800)

    /// Race the real screenshot+OCR pipeline against a wall-clock deadline.
    /// Whichever finishes first wins; the other task is cancelled.
    private static func captureScreenshotAndOCR(deadline: TimeInterval) async -> CaptureResult {
        return await withTaskGroup(of: CaptureResult.self) { group in
            group.addTask {
                return await Self.invokeCaptureAndOCR()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return CaptureResult(ocrLines: [], jpegData: nil, transform: nil)
            }
            let result = await group.next() ?? CaptureResult(ocrLines: [], jpegData: nil, transform: nil)
            group.cancelAll()
            return result
        }
    }

    /// Bridge to the existing ScreenCapture + ContextOCRService stack.
    /// One screenshot serves two purposes:
    ///   - full-res raw image for OCR (small UI text stays legible)
    ///   - 1280x800 WXGA JPEG for the harness's first user-message image
    /// Anthropic's computer-use models peak in click accuracy at WXGA, so we
    /// pre-size on capture; subsequent screenshots from ToolDispatcher use
    /// the same target.
    private static func invokeCaptureAndOCR() async -> CaptureResult {
        do {
            let snapshot = try await ScreenCapture.shared.targetSnapshot(
                target: harnessTargetSize
            )
            guard let raw = snapshot.rawImage else {
                return CaptureResult(
                    ocrLines: [],
                    jpegData: snapshot.jpegData,
                    transform: snapshot.transform
                )
            }
            let recognized = await ContextOCRService.shared.recognizeText(in: raw, maxResults: 80)
            return CaptureResult(
                ocrLines: recognized.map(\.text),
                jpegData: snapshot.jpegData,
                transform: snapshot.transform
            )
        } catch {
            return CaptureResult(ocrLines: [], jpegData: nil, transform: nil)
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

        // Prioritize clickable elements; drop unlabeled passive ones; cap at 50.
        let withLabel = collected.filter { ($0.label?.isEmpty == false) || $0.focused }
        let clickable = withLabel.filter { Self.clickableRoles.contains($0.role) }
        let passive = withLabel.filter { !Self.clickableRoles.contains($0.role) }
        // Take clickables first, fill the rest with passives.
        let combined = (clickable + passive).prefix(50)
        return Array(combined)
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
