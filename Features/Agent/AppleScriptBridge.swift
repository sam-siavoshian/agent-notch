//
//  AppleScriptBridge.swift
//
//  In-process NSAppleScript runner with an allowlist of `tell application`
//  targets. `System Events` is excluded on purpose: arbitrary-input synthesis
//  belongs in the `computer` tool path with safer dispatch.
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
    public static let allowedTargets: Set<String> = [
        "Safari", "Google Chrome", "Arc", "Brave Browser",
        "Spotify", "Music", "Messages", "Mail", "Notes",
        "Reminders", "Calendar", "Finder", "Xcode",
        "Terminal", "iTerm", "iTerm2"
    ]

    /// Run a script. Throws if any `tell application "X"` target isn't in
    /// `allowedTargets`. Returns the result's string form (or "").
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

    // swiftlint:disable:next force_try — pattern is a compile-time literal
    private static let targetRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"application\s+"([^"]+)""#,
        options: [.caseInsensitive]
    )

    /// Conservative parse: any literal `application "X"` must be in the
    /// allowlist. Misses obfuscated indirection — model output never uses it.
    private static func assertAllowed(_ script: String) throws {
        let range = NSRange(script.startIndex..., in: script)
        for m in targetRegex.matches(in: script, options: [], range: range) where m.numberOfRanges >= 2 {
            guard let r = Range(m.range(at: 1), in: script) else { continue }
            let target = String(script[r])
            if !allowedTargets.contains(target) { throw AppleScriptBridgeError.disallowedTarget(target) }
        }
    }
}
