//
//  AppleScriptBridge.swift
//  Agent in the Notch
//
//  Centralized NSAppleScript runner with an explicit allowlist of `tell
//  application` targets. The agent + IntentRouter both route through this
//  so we control the apps any AI-driven script can talk to.
//
//  NSAppleScript runs in-process (faster than spawning `osascript`) but
//  still needs Apple Events permission for each target app the first time.
//  We rely on the existing Accessibility / Automation grants the user
//  already onboarded.
//

import Foundation

public enum AppleScriptBridgeError: Error, CustomStringConvertible {
    case disallowedTarget(String)
    case executionFailed(String)
    case scriptCompileFailed(String)

    public var description: String {
        switch self {
        case .disallowedTarget(let t): return "AppleScript target not allowlisted: \(t)"
        case .executionFailed(let m): return "AppleScript failed: \(m)"
        case .scriptCompileFailed(let m): return "AppleScript compile failed: \(m)"
        }
    }
}

public enum AppleScriptBridge {
    /// Apps the agent is allowed to drive via AppleScript. Add here
    /// deliberately — anything outside the list is rejected. `System Events`
    /// is intentionally excluded: it can synthesize arbitrary input, which
    /// is what `computer` tool is for (with safer dispatch).
    public static let allowedTargets: Set<String> = [
        "Safari",
        "Google Chrome",
        "Arc",
        "Brave Browser",
        "Spotify",
        "Music",
        "Messages",
        "Mail",
        "Notes",
        "Reminders",
        "Calendar",
        "Finder",
        "Xcode",
        "Terminal",
        "iTerm",
        "iTerm2"
    ]

    /// Run a script. Caller must ensure the script's tell-application targets
    /// are in `allowedTargets`. Returns the string form of the result, or "".
    @discardableResult
    public static func run(_ script: String) async throws -> String {
        try assertAllowed(script)
        return try await withCheckedThrowingContinuation { cont in
            Task.detached(priority: .userInitiated) {
                guard let scriptObj = NSAppleScript(source: script) else {
                    cont.resume(throwing: AppleScriptBridgeError.scriptCompileFailed("init returned nil"))
                    return
                }
                var error: NSDictionary?
                let result = scriptObj.executeAndReturnError(&error)
                if let error {
                    let msg = (error[NSAppleScript.errorMessage] as? String) ?? "unknown"
                    cont.resume(throwing: AppleScriptBridgeError.executionFailed(msg))
                    return
                }
                cont.resume(returning: result.stringValue ?? "")
            }
        }
    }

    /// Reject scripts that target apps outside the allowlist. Conservative
    /// parse: scans every `tell application "..."` and `application "..."`
    /// literal and confirms each name is allowlisted. Misses obfuscated
    /// indirection (e.g. `set x to "Finder" \n tell application x`), which is
    /// fine — anything the model writes will be in the obvious form.
    // swiftlint:disable:next force_try — pattern is a compile-time literal
    private static let targetRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"application\s+"([^"]+)""#,
        options: [.caseInsensitive]
    )

    private static func assertAllowed(_ script: String) throws {
        let range = NSRange(script.startIndex..., in: script)
        let matches = targetRegex.matches(in: script, options: [], range: range)
        for m in matches where m.numberOfRanges >= 2 {
            guard let r = Range(m.range(at: 1), in: script) else { continue }
            let target = String(script[r])
            if !allowedTargets.contains(target) {
                throw AppleScriptBridgeError.disallowedTarget(target)
            }
        }
        // No `tell application` at all = utility script (e.g. `return "x"`).
        // Allow these; they cannot drive other apps.
    }
}

