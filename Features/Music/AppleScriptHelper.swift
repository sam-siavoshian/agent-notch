//
//  AppleScriptHelper.swift
//  Agent in the Notch
//
//  Async NSAppleScript wrapper. Ported from boring.notch (MIT).
//

import Foundation

enum AppleScriptHelper {
    @discardableResult
    static func execute(_ scriptText: String) async throws -> NSAppleEventDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let script = NSAppleScript(source: scriptText)
                var error: NSDictionary?
                if let descriptor = script?.executeAndReturnError(&error) {
                    continuation.resume(returning: descriptor)
                } else if let error {
                    continuation.resume(throwing: NSError(
                        domain: "AppleScriptError",
                        code: 1,
                        userInfo: error as? [String: Any]
                    ))
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AppleScriptError",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown AppleScript error"]
                    ))
                }
            }
        }
    }

    static func executeVoid(_ scriptText: String) async throws {
        _ = try await execute(scriptText)
    }
}
