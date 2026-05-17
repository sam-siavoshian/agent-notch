//
//  ContextSnapshotStore.swift
//  Agent in the Notch
//
//  Small rolling in-memory buffer for recent screen context.
//

import Foundation

public actor ContextSnapshotStore {
    private let maxSnapshots: Int
    private var snapshots: [ContextSnapshot] = []
    private var signatures: [UUID: ContextDirtySignature] = [:]

    public init(maxSnapshots: Int = 20) {
        self.maxSnapshots = maxSnapshots
    }

    public func record(_ snapshot: ContextSnapshot, signature: ContextDirtySignature? = nil) {
        snapshots.append(snapshot)
        if let signature {
            signatures[snapshot.id] = signature
        }
        if snapshots.count > maxSnapshots {
            let trimCount = snapshots.count - maxSnapshots
            for snap in snapshots.prefix(trimCount) {
                signatures.removeValue(forKey: snap.id)
            }
            snapshots.removeFirst(trimCount)
        }
    }

    public func recentSnapshots() -> [ContextSnapshot] {
        snapshots
    }

    public func lastSnapshot() -> ContextSnapshot? {
        snapshots.last
    }

    public func lastSignature() -> ContextDirtySignature? {
        guard let last = snapshots.last else { return nil }
        return signatures[last.id]
    }
}
