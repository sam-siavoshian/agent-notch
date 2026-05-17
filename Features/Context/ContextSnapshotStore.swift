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
    private var observationsBySurface: [String: ContextGeminiObservation] = [:]
    private var cachedLastReducerObservation: ContextGeminiObservation?

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
            let dropped = snapshots.prefix(trimCount).map(\.id)
            snapshots.removeFirst(trimCount)
            for id in dropped {
                signatures.removeValue(forKey: id)
            }
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

    public func signature(for snapshotID: UUID) -> ContextDirtySignature? {
        signatures[snapshotID]
    }

    /// Persist the most recent reducer observation so the dirty-region
    /// short-circuit and the `.update` lane can compare against it.
    public func recordReducerObservation(
        _ observation: ContextGeminiObservation,
        surfaceKey: String
    ) {
        cachedLastReducerObservation = observation
        observationsBySurface[surfaceKey] = observation
    }

    public func lastReducerObservation() -> ContextGeminiObservation? {
        cachedLastReducerObservation
    }

    public func reducerObservation(forSurfaceKey key: String) -> ContextGeminiObservation? {
        observationsBySurface[key]
    }

    public func recentActivityContext(now: Date = Date(), learnedUIMemory: String = "") -> String {
        ContextActivationBuilder.build(
            from: snapshots,
            learnedUIMemory: learnedUIMemory,
            now: now
        ).promptText
    }
}
