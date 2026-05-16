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

    private static func cleaned(_ value: String, y: Double) -> String? {
        let text = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count >= 3 else { return nil }
        guard y < 0.965 else { return nil }

        let lower = text.lowercased()
        if menuOrStatusText.contains(lower) { return nil }
        if lower.hasPrefix("sat ") || lower.hasPrefix("sun ") || lower.hasPrefix("mon ") ||
            lower.hasPrefix("tue ") || lower.hasPrefix("wed ") || lower.hasPrefix("thu ") ||
            lower.hasPrefix("fri ") {
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
        if mostlyNonLetters(text) {
            return nil
        }

        return text
    }

    private static func mostlyNonLetters(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count
        let numbers = text.filter(\.isNumber).count
        return letters < 2 && numbers > 0
    }

    private static func looksLikeClockText(_ lower: String) -> Bool {
        guard lower.contains(":") else { return false }
        return lower.hasSuffix("am") || lower.hasSuffix("pm") || lower.contains(" am") || lower.contains(" pm")
    }

    private static let menuOrStatusText: Set<String> = [
        "file",
        "edit",
        "view",
        "window",
        "help",
        "cpu"
    ]
}
