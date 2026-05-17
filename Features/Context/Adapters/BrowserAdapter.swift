import Foundation

/// AppContextAdapter for the four supported web browsers (Arc, Chrome, Safari, Brave).
///
/// Uses AppleScript via `NSAppleScript`. Chromium-derived browsers (Chrome,
/// Brave, Arc) share the same `active tab of window 1` shape; Safari uses
/// `current tab of window 1`.
///
/// **URL emission rules** (enforced before any URL leaves this adapter):
///   - Strip `user:pass@` userinfo
///   - Strip query params matching
///     (token|key|secret|password|auth|api_key|access_token|sig|signature)
public final class BrowserAdapter: AppContextAdapter {

    public static let bundleIDs: [String] = [
        "company.thebrowser.Browser",   // Arc
        "com.google.Chrome",
        "com.apple.Safari",
        "com.brave.Browser"
    ]

    public init() {}

    public func snapshot(bundleID: String) async throws -> [String: AnyCodable] {
        let script: String
        switch bundleID {
        case "com.apple.Safari":
            script = """
            tell application "Safari"
                try
                    set out to {}
                    repeat with t in (tabs of window 1)
                        set end of out to {(name of t as string), (URL of t as string)}
                    end repeat
                    set activeURL to URL of current tab of window 1 as string
                    set activeTitle to name of current tab of window 1 as string
                    return {activeURL, activeTitle, out}
                on error
                    return {"", "", {}}
                end try
            end tell
            """
        case "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser":
            // App name in AppleScript: "Google Chrome" | "Brave Browser" | "Arc"
            let appName: String = {
                switch bundleID {
                case "com.google.Chrome":            return "Google Chrome"
                case "com.brave.Browser":             return "Brave Browser"
                case "company.thebrowser.Browser":    return "Arc"
                default:                              return "Google Chrome"
                }
            }()
            script = """
            tell application "\(appName)"
                try
                    set out to {}
                    repeat with t in (tabs of window 1)
                        set end of out to {(title of t as string), (URL of t as string)}
                    end repeat
                    set activeURL to URL of active tab of window 1 as string
                    set activeTitle to title of active tab of window 1 as string
                    return {activeURL, activeTitle, out}
                on error
                    return {"", "", {}}
                end try
            end tell
            """
        default:
            throw AdapterError.unsupportedBundle(bundleID)
        }

        let result = try await runScript(script, bundleID: bundleID)
        let (activeURL, activeTitle, tabs) = parseBrowserResult(result)
        let cleanedActiveURL = Self.cleanURL(activeURL)
        let cleanedTabs: [[String: Any]] = tabs.map { tab in
            let cleanedURL = Self.cleanURL(tab.url)
            return [
                "title": tab.title,
                "url": cleanedURL,
                "active": cleanedURL == cleanedActiveURL
            ]
        }
        return [
            "active_url": AnyCodable(cleanedActiveURL),
            "active_title": AnyCodable(activeTitle),
            "tabs": AnyCodable(cleanedTabs)
        ]
    }

    // MARK: - AppleScript invocation

    private func runScript(_ source: String, bundleID: String) async throws -> NSAppleEventDescriptor {
        // NSAppleScript is not Sendable; run in a detached task and pass the
        // descriptor back as a value.
        try await Task.detached(priority: .userInitiated) { () throws -> NSAppleEventDescriptor in
            guard let script = NSAppleScript(source: source) else {
                throw AdapterError.malformedResponse("could not parse AppleScript for \(bundleID)")
            }
            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            if let error {
                throw AdapterError.appUnreachable("\(bundleID): \(error)")
            }
            return descriptor
        }.value
    }

    private func parseBrowserResult(_ descriptor: NSAppleEventDescriptor) -> (activeURL: String, activeTitle: String, tabs: [(title: String, url: String)]) {
        // Descriptor is a 3-element list: {activeURL, activeTitle, {{title, url}, ...}}
        let activeURL = descriptor.atIndex(1)?.stringValue ?? ""
        let activeTitle = descriptor.atIndex(2)?.stringValue ?? ""
        var tabs: [(String, String)] = []
        if let tabsList = descriptor.atIndex(3) {
            let count = tabsList.numberOfItems
            if count > 0 {
                for i in 1...count {
                    guard let tab = tabsList.atIndex(i) else { continue }
                    if tab.numberOfItems >= 2 {
                        let title = tab.atIndex(1)?.stringValue ?? ""
                        let url = tab.atIndex(2)?.stringValue ?? ""
                        tabs.append((title, url))
                    }
                }
            }
        }
        return (activeURL, activeTitle, tabs)
    }

    // MARK: - URL sanitation

    private static let blockedQueryParams: Set<String> = [
        "token", "key", "secret", "password", "auth",
        "api_key", "access_token", "sig", "signature"
    ]

    /// Strip user:pass@ userinfo and credential-bearing query params before any
    /// URL leaves the adapter.
    private static func cleanURL(_ raw: String) -> String {
        guard !raw.isEmpty, var comps = URLComponents(string: raw) else { return raw }
        comps.user = nil
        comps.password = nil
        if let items = comps.queryItems {
            comps.queryItems = items.filter { !Self.blockedQueryParams.contains($0.name.lowercased()) }
            if comps.queryItems?.isEmpty ?? false { comps.queryItems = nil }
        }
        return comps.string ?? raw
    }
}
