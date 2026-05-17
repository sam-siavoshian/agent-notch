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

    /// Returns the most recent N snapshots reduced to (app, surface, ocr lines)
    /// tuples — the shape ActiveTaskUpdater needs to enrich the Mercury
    /// active_task prompt. Caller does dedup/truncation; this helper just
    /// strips the heavy fields (jpegData, geometry) so downstream code doesn't
    /// touch internal snapshot structure.
    public func recentForOCR(limit: Int) -> [(app: String, surface: String, ocr: [String])] {
        let tail = snapshots.suffix(max(0, limit))
        return tail.map { snap in
            let lines = snap.recognizedText.compactMap { item -> String? in
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return (app: snap.appName, surface: snap.windowTitle, ocr: lines)
        }
    }

    public func lastSnapshot() -> ContextSnapshot? {
        snapshots.last
    }

    public func lastSignature() -> ContextDirtySignature? {
        guard let last = snapshots.last else { return nil }
        return signatures[last.id]
    }

    public func signature(for snapshotID: UUID) -> ContextDirtySignature? {
        signatures[snapshotID]
    }

}
