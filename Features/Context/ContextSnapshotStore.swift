//
//  ContextSnapshotStore.swift
//  Agent in the Notch
//
//  Small rolling in-memory buffer for recent screen context. This is the
//  native app counterpart to the ArshanTesting memory artifact, deliberately
//  simple for hackathon iteration.
//

import Foundation

public actor ContextSnapshotStore {
    private let maxSnapshots: Int
    private var snapshots: [ContextSnapshot] = []

    public init(maxSnapshots: Int = 20) {
        self.maxSnapshots = maxSnapshots
    }

    public func record(_ snapshot: ContextSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }
    }

    public func recentSnapshots() -> [ContextSnapshot] {
        snapshots
    }

    public func recentActivityContext(now: Date = Date()) -> String {
        guard !snapshots.isEmpty else {
            return "No recent screen context has been captured yet."
        }

        let latest = snapshots[snapshots.count - 1]
        let window = latest.windowTitle.isEmpty ? "Untitled window" : latest.windowTitle
        let span = Int(now.timeIntervalSince(snapshots[0].capturedAt))
        let lines = snapshots.suffix(8).map { snapshot in
            let age = max(0, Int(now.timeIntervalSince(snapshot.capturedAt)))
            let title = snapshot.windowTitle.isEmpty ? "Untitled window" : snapshot.windowTitle
            let cursor = snapshot.cursorLocation.map { " cursor=(\(Int($0.x)),\(Int($0.y)))" } ?? ""
            return "- \(age)s ago: \(snapshot.trigger.rawValue) in \(snapshot.appName), \(title).\(cursor)"
        }

        return """
        Recent screen context:
        Captured \(snapshots.count) screenshots over the last \(span)s.
        Current/latest app: \(latest.appName)
        Current/latest window: \(window)
        Recent captures:
        \(lines.joined(separator: "\n"))
        """
    }
}
