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
        ContextActivationBuilder.build(from: snapshots, now: now).promptText
    }
}
