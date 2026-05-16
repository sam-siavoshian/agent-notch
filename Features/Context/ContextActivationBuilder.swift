//
//  ContextActivationBuilder.swift
//  Agent in the Notch
//
//  Converts the rolling screenshot buffer into a compact prompt packet for
//  the computer-use agent. This packet should teach action-relevant UI facts,
//  not replay raw capture bookkeeping.
//

import Foundation

enum ContextActivationBuilder {
    static func build(
        from snapshots: [ContextSnapshot],
        learnedUIMemory: String = "",
        now: Date = Date()
    ) -> ContextActivationPacket {
        guard let latest = snapshots.last else {
            return ContextActivationPacket(
                generatedAt: now,
                capturedCount: 0,
                elapsedSeconds: 0,
                currentApp: "Unknown app",
                currentWindow: "Unknown window",
                recentTimeline: [],
                observedTransitions: [],
                learnedUIMemory: learnedUIMemory,
                firstActionGuidance: ["- No local screenshot context has been captured yet. Use the computer screenshot tool before acting."]
            )
        }

        let elapsed = max(0, Int(now.timeIntervalSince(snapshots.first?.capturedAt ?? latest.capturedAt)))
        return ContextActivationPacket(
            generatedAt: now,
            capturedCount: snapshots.count,
            elapsedSeconds: elapsed,
            currentApp: latest.appName,
            currentWindow: displayTitle(latest.windowTitle),
            recentTimeline: currentScreenFacts(from: latest),
            observedTransitions: interactionSignals(from: snapshots),
            learnedUIMemory: learnedUIMemory,
            firstActionGuidance: guidance(from: snapshots)
        )
    }

    private static func currentScreenFacts(from snapshot: ContextSnapshot) -> [String] {
        var facts: [String] = []
        let visibleText = ContextTextSignalFilter.usefulText(from: snapshot.recognizedText, maxCount: 10)
        if !visibleText.isEmpty {
            facts.append("- Useful visible text: \(visibleText.joined(separator: " | "))")
        }
        if let cursorLocation = snapshot.cursorLocation {
            facts.append("- Cursor at activation/capture: x=\(Int(cursorLocation.x)), y=\(Int(cursorLocation.y)).")
        }
        if snapshot.trigger == .activation {
            facts.append("- Fresh screenshot was captured for this long-press activation.")
        }
        return facts
    }

    private static func interactionSignals(from snapshots: [ContextSnapshot]) -> [String] {
        guard snapshots.count >= 2 else { return [] }

        var notes: [String] = []
        var sameSurfaceClickSeen = false
        for i in snapshots.indices.dropFirst() {
            let before = snapshots[i - 1]
            let after = snapshots[i]
            guard after.trigger == .click || after.trigger == .activation else { continue }

            if before.appName != after.appName {
                notes.append("- User moved from \(before.appName) to \(after.appName).")
            } else if normalizedTitle(before.windowTitle) != normalizedTitle(after.windowTitle) {
                notes.append("- \(before.appName) changed from \(displayTitle(before.windowTitle)) to \(displayTitle(after.windowTitle)).")
            } else if after.trigger == .click {
                sameSurfaceClickSeen = true
            }
        }

        var compactNotes = Array(unique(notes).suffix(3))
        if sameSurfaceClickSeen {
            compactNotes.append("- Recent clicks stayed on the current app/window, so they likely selected, edited, opened inline controls, or changed state without navigation.")
        }

        return compactNotes
    }

    private static func guidance(from snapshots: [ContextSnapshot]) -> [String] {
        guard snapshots.last != nil else { return ["- Take a screenshot before acting."] }

        let notes: [String] = [
            "- Treat the current screen as ground truth; learned memory is only prior UI knowledge.",
            "- Prefer known surfaces, controls, and affordances from memory before exploratory screenshots."
        ]

        return notes
    }

    private static func displayTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled window" : title
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let key = value.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

