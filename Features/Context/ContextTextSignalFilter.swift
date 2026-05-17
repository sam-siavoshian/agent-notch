//
//  ContextTextSignalFilter.swift
//  Agent in the Notch
//
//  Keeps screenshot OCR useful for agent context by dropping menu-bar/status
//  chrome and tiny fragments that do not teach UI structure.
//

import Foundation

enum ContextTextSignalFilter {
    static func usefulText(from recognizedText: [ContextRecognizedText], maxCount: Int) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for item in recognizedText {
            guard let text = cleaned(item.text, y: item.y) else { continue }
            let key = text.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(text)
            if output.count >= maxCount {
                break
            }
        }

        return output
    }

    static func memoryText(_ value: String, maxLength: Int = 220) -> String? {
        let text = normalized(value)
        guard text.count >= 3 else { return nil }
        guard !isLowSignalMemory(text) else { return nil }

        let redacted = redacted(text)
        guard !redacted.isEmpty else { return nil }
        if redacted.count > maxLength {
            return String(redacted.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return redacted
    }

    static func redacted(_ value: String) -> String {
        var text = value
        for (pattern, replacement, options) in redactionReplacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: options)
        }
        return normalized(text)
    }

    private static let redactionReplacements: [(String, String, String.CompareOptions)] = [
        (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[email]", [.regularExpression, .caseInsensitive]),
        (#"AIza[0-9A-Za-z_-]{20,}"#, "[gemini-api-key]", [.regularExpression]),
        (#"sk-ant-[0-9A-Za-z_-]{20,}"#, "[anthropic-api-key]", [.regularExpression]),
        (#"sk-[A-Za-z0-9_-]{20,}"#, "[api-key]", [.regularExpression]),
        (#"\.{3}[A-Za-z0-9_-]{4,}"#, "[masked-secret]", [.regularExpression]),
        (#"[A-Za-z0-9._%+-]{6,}\.{3}"#, "[redacted-fragment]", [.regularExpression])
    ]

    static func looksTransientState(_ value: String) -> Bool {
        let lower = normalized(value).lowercased()
        guard !lower.isEmpty else { return true }

        let transientMarkers = [
            "currently",
            "current ",
            "visible ",
            "cursor",
            "hover",
            "usage remaining",
            "weekly limit",
            "pro account",
            "subscription active",
            "thinking/loading",
            "loading indicator",
            "notification active",
            "system notification",
            "request timed out",
            "nsurlerrordomain",
            "kcferrordomaincfnetwork",
            "code -1001",
            "file system error",
            "log output",
            "chat discusses",
            "chat content",
            "the screen shows",
            "screen shows",
            "viewing and managing",
            "user is viewing",
            "user is interacting",
            "user is engaged",
            "the user is",
            "selected",
            "active"
        ]

        if transientMarkers.contains(where: { lower.contains($0) }) {
            return true
        }
        if lower.contains("%") || lower.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func cleaned(_ value: String, y: Double) -> String? {
        let text = normalized(value)

        guard text.count >= 3 else { return nil }
        guard y < 0.965 else { return nil }
        guard !isLowSignalMemory(text) else { return nil }

        let lower = text.lowercased()
        if menuOrStatusText.contains(lower) { return nil }
        if dayPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return nil
        }
        if looksLikeClockText(lower) || lower.contains("cpu") {
            return nil
        }
        if lower.contains("file") && lower.contains("edit") && lower.contains("view") {
            return nil
        }
        if lower.contains("%") && text.count <= 8 {
            return nil
        }
        if y > 0.84 && looksLikeTopChromeFragment(text) {
            return nil
        }
        if mostlyNonLetters(text) {
            return nil
        }

        return redacted(text)
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLowSignalMemory(_ text: String) -> Bool {
        let lower = normalized(text).lowercased()
        if lower.isEmpty { return true }
        if lower == "draggable" || lower == "content summary" {
            return true
        }
        if lower == "time sensitive" || lower == "make it happen" || lower == "make it happen." {
            return true
        }
        if lower.contains(" file | edit ") || lower.contains(" edit view | window ") {
            return true
        }
        if lower.contains("codex file | edit") || lower.contains("brave | file | edit") {
            return true
        }
        return false
    }

    private static func looksLikeTopChromeFragment(_ text: String) -> Bool {
        let lower = text.lowercased()
        if text.contains(" | ") {
            return true
        }
        if lower.hasPrefix("< ") || lower.hasPrefix("@") {
            return true
        }
        if lower.count < 42 && (lower.contains(" - ") || lower.contains(" i ")) {
            return true
        }
        return false
    }

    private static func mostlyNonLetters(_ text: String) -> Bool {
        var letters = 0
        var numbers = 0
        for ch in text {
            if ch.isLetter { letters += 1 }
            else if ch.isNumber { numbers += 1 }
        }
        return letters < 2 && numbers > 0
    }

    private static func looksLikeClockText(_ lower: String) -> Bool {
        guard lower.contains(":") else { return false }
        return lower.hasSuffix("am") || lower.hasSuffix("pm") || lower.contains(" am") || lower.contains(" pm")
    }

    private static let dayPrefixes: [String] = [
        "sat ", "sun ", "mon ", "tue ", "wed ", "thu ", "fri "
    ]

    private static let menuOrStatusText: Set<String> = [
        "file",
        "edit",
        "view",
        "window",
        "help",
        "cpu"
    ]
}
