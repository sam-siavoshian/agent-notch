import Foundation
import AppKit

/// Polls NSPasteboard for changes and emits `copy_paste` CEvents when content appears
/// to flow from one app to another.
///
/// Self-paste suppression: the agent's own `computer.type` tool mutates the pasteboard.
/// ToolDispatcher (Phase 4+) calls `registerSelfPaste(changeCount:)` to tell us those
/// writes are not user-initiated and should not appear in the event log.
///
/// Cross-app paste suppression: if a copy comes from a never-log app, the resulting paste
/// in any other app is suppressed too — the secret follows the clipboard.
public final class ClipboardWatcher {

    public static let shared = ClipboardWatcher()

    private var lastChangeCount: Int
    private var pollTimer: Timer?
    private var lastCopySource: CopySource?
    private var selfPasteChangeCounts: Set<Int> = []

    public struct CopySource {
        public let app: String
        public let bundleID: String
        public let preview: String?
        public let kind: String           // "text" | "image" | "file"
        public let bytes: Int
        public let isFromNeverLogApp: Bool
        public let changeCount: Int
        public let timestamp: Date
    }

    private init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    public func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// ToolDispatcher (Phase 4) calls this immediately after a self-initiated pasteboard write.
    public func registerSelfPaste(changeCount: Int) {
        selfPasteChangeCounts.insert(changeCount)
        // Garbage-collect old entries to avoid leak.
        if selfPasteChangeCounts.count > 64 {
            let toRemove = selfPasteChangeCounts.sorted().prefix(selfPasteChangeCounts.count - 32)
            for x in toRemove { selfPasteChangeCounts.remove(x) }
        }
    }

    // MARK: - Poll

    private func poll() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        let prevChangeCount = lastChangeCount
        lastChangeCount = current

        // Skip self-paste writes by the agent itself.
        if selfPasteChangeCounts.contains(current) {
            selfPasteChangeCounts.remove(current)
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName ?? "<unknown>"
        let bundleID = frontmost?.bundleIdentifier ?? "<unknown>"

        // Read kind + preview
        let (kind, preview, bytes) = readPasteboard(pb)

        // Heuristic: if the change happened in a different app than the last `lastCopySource`,
        // treat this as a paste-target. Otherwise it's a new copy.
        if let src = lastCopySource, src.bundleID != bundleID,
           current == prevChangeCount + 1 || current == prevChangeCount {
            // Looks like the same payload showed up in a new app — that's a paste.
            // Suppress if source app is never-log.
            if src.isFromNeverLogApp {
                return
            }
            let from = CEvent.Payload.CopyEndpoint(app: src.app, element: nil, selection: src.preview)
            let to = CEvent.Payload.CopyEndpoint(app: appName, element: nil, selection: nil)
            DispatchQueue.main.async {
                _ = EventIngester.shared.ingest(
                    kind: .copyPaste,
                    sourceMonitor: "ClipboardWatcher",
                    payload: .copyPaste(from: from, to: to, changeCount: current)
                )
            }
            lastCopySource = nil
            return
        }

        // Otherwise this is a new copy — remember its source.
        let neverLog = PrivacyGate.shared.neverLogApps.contains(bundleID)
        lastCopySource = CopySource(
            app: appName,
            bundleID: bundleID,
            preview: preview,
            kind: kind,
            bytes: bytes,
            isFromNeverLogApp: neverLog,
            changeCount: current,
            timestamp: Date()
        )
    }

    private func readPasteboard(_ pb: NSPasteboard) -> (kind: String, preview: String?, bytes: Int) {
        if let s = pb.string(forType: .string) {
            return ("text", String(s.prefix(200)), s.utf8.count)
        }
        if let image = NSImage(pasteboard: pb) {
            let s = image.size
            return ("image", "<image:\(Int(s.width))x\(Int(s.height))>", 0)
        }
        return ("unknown", nil, 0)
    }
}
