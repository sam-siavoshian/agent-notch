import Foundation
import AppKit

/// Polls NSPasteboard for changes and emits `copy_paste` CEvents when content appears
/// to flow from one app to another.
/// If a copy comes from a never-log app, the resulting paste in any other app is suppressed —
/// the secret follows the clipboard.
public final class ClipboardWatcher {

    public static let shared = ClipboardWatcher()

    private var lastChangeCount: Int
    private var pollTimer: Timer?
    private var lastCopySource: CopySource?

    private struct CopySource {
        let app: String
        let bundleID: String
        let preview: String?
        let isFromNeverLogApp: Bool
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

    // MARK: - Poll

    private func poll() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        let prevChangeCount = lastChangeCount
        lastChangeCount = current

        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName ?? "<unknown>"
        let bundleID = frontmost?.bundleIdentifier ?? "<unknown>"

        let preview = readPasteboardPreview(pb)

        // Heuristic: if the change happened in a different app than the last `lastCopySource`,
        // treat this as a paste-target. Otherwise it's a new copy.
        if let src = lastCopySource, src.bundleID != bundleID,
           current == prevChangeCount + 1 || current == prevChangeCount {
            if src.isFromNeverLogApp { return }
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

        // New copy — remember its source.
        lastCopySource = CopySource(
            app: appName,
            bundleID: bundleID,
            preview: preview,
            isFromNeverLogApp: PrivacyGate.shared.neverLogApps.contains(bundleID)
        )
    }

    private func readPasteboardPreview(_ pb: NSPasteboard) -> String? {
        if let s = pb.string(forType: .string) {
            return String(s.prefix(200))
        }
        if let image = NSImage(pasteboard: pb) {
            let s = image.size
            return "<image:\(Int(s.width))x\(Int(s.height))>"
        }
        return nil
    }
}
