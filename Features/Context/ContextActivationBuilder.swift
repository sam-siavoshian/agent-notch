//
//  ContextActivationBuilder.swift
//  Agent in the Notch
//
//  Converts the rolling screenshot buffer into a compact prompt packet for
//  the computer-use agent. This is deliberately text-only for the hot path;
//  VLM summaries can feed this same packet later.
//

import Foundation

enum ContextActivationBuilder {
    static func build(from snapshots: [ContextSnapshot], now: Date = Date()) -> ContextActivationPacket {
        guard let latest = snapshots.last else {
            return ContextActivationPacket(
                generatedAt: now,
                capturedCount: 0,
                elapsedSeconds: 0,
                currentApp: "Unknown app",
                currentWindow: "Unknown window",
                recentTimeline: [],
                observedTransitions: [],
                firstActionGuidance: ["- No screen context has been captured yet. Take a screenshot before acting."]
            )
        }

        let elapsed = max(0, Int(now.timeIntervalSince(snapshots.first?.capturedAt ?? latest.capturedAt)))
        return ContextActivationPacket(
            generatedAt: now,
            capturedCount: snapshots.count,
            elapsedSeconds: elapsed,
            currentApp: latest.appName,
            currentWindow: displayTitle(latest.windowTitle),
            recentTimeline: timeline(from: snapshots, now: now),
            observedTransitions: transitions(from: snapshots),
            firstActionGuidance: guidance(from: snapshots)
        )
    }

    private static func timeline(from snapshots: [ContextSnapshot], now: Date) -> [String] {
        snapshots.suffix(8).map { snapshot in
            let age = max(0, Int(now.timeIntervalSince(snapshot.capturedAt)))
            let cursor = snapshot.cursorLocation.map { " cursor=(\(Int($0.x)),\(Int($0.y)))" } ?? ""
            return "- \(age)s ago: \(snapshot.trigger.rawValue) capture in \(snapshot.appName), \(displayTitle(snapshot.windowTitle)).\(cursor)"
        }
    }

    private static func transitions(from snapshots: [ContextSnapshot]) -> [String] {
        guard snapshots.count >= 2 else { return [] }

        var notes: [String] = []
        for pair in snapshots.adjacentPairs() {
            let before = pair.0
            let after = pair.1
            guard after.trigger == .click || after.trigger == .activation else { continue }

            if before.appName != after.appName {
                notes.append("- \(after.trigger.rawValue): moved from \(before.appName) to \(after.appName).")
            } else if normalizedTitle(before.windowTitle) != normalizedTitle(after.windowTitle) {
                notes.append("- \(after.trigger.rawValue): \(before.appName) window changed from \(displayTitle(before.windowTitle)) to \(displayTitle(after.windowTitle)).")
            } else if after.trigger == .click {
                notes.append("- click: stayed in \(after.appName), \(displayTitle(after.windowTitle)); no app/window transition detected.")
            }
        }

        return Array(notes.suffix(6))
    }

    private static func guidance(from snapshots: [ContextSnapshot]) -> [String] {
        guard let latest = snapshots.last else {
            return ["- Take a screenshot before acting."]
        }

        var notes: [String] = [
            "- Start from the current app/window above; it is the freshest local context captured at activation.",
            "- Use recent transition hints as soft memory, not as guaranteed UI coordinates."
        ]

        if snapshots.contains(where: { $0.trigger == .click }) {
            notes.append("- Recent clicks indicate what the user was actively interacting with before long-press.")
        }

        if latest.trigger == .activation {
            notes.append("- The latest capture was taken specifically for this long-press activation.")
        }

        return notes
    }

    private static func displayTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled window" : title
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array {
    func adjacentPairs() -> [(Element, Element)] {
        guard count >= 2 else { return [] }
        return zip(dropLast(), dropFirst()).map { ($0, $1) }
    }
}
