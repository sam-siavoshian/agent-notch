import Foundation
import AppKit

/// Single ingest point for all monitors. Fills the envelope (seq, sourceMonitor, frontmost-app),
/// runs PrivacyGate, and forwards survivors to EventLog.
public final class EventIngester {

    public static let shared = EventIngester()

    private init() {}

    /// Ingest a payload from a monitor.
    /// - Parameters:
    ///   - explicitApp: when set, overrides the frontmost-app autofill (e.g. for app_switch events)
    @discardableResult
    public func ingest(
        kind: CEvent.Kind,
        sourceMonitor: String,
        payload: CEvent.Payload,
        explicitApp: AppContext? = nil
    ) -> CEvent? {
        let app = explicitApp ?? Self.frontmostAppContext()
        let event = CEvent(
            t: Date(),
            seq: EventLog.shared.nextSeq(),
            kind: kind,
            sourceMonitor: sourceMonitor,
            app: app?.name,
            bundleID: app?.bundleID,
            pid: app?.pid,
            windowTitle: app?.windowTitle,
            windowID: app?.windowID,
            displayID: app?.displayID,
            payload: payload
        )

        guard let gated = PrivacyGate.shared.process(event) else { return nil }
        EventLog.shared.append(gated)
        return gated
    }

    // MARK: - Frontmost app autofill

    public struct AppContext {
        public let name: String?
        public let bundleID: String?
        public let pid: Int?
        public let windowTitle: String?
        public let windowID: Int?
        public let displayID: Int?
        public init(name: String? = nil, bundleID: String? = nil, pid: Int? = nil,
                    windowTitle: String? = nil, windowID: Int? = nil, displayID: Int? = nil) {
            self.name = name; self.bundleID = bundleID; self.pid = pid
            self.windowTitle = windowTitle; self.windowID = windowID; self.displayID = displayID
        }
    }

    private static func frontmostAppContext() -> AppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppContext(
            name: app.localizedName,
            bundleID: app.bundleIdentifier,
            pid: Int(app.processIdentifier)
        )
    }
}
