//
//  ContextCoordinator.swift
//  Agent in the Notch
//
//  Native context feature entry point. Owns click-triggered captures and
//  exposes a compact text packet to AgentSession through AgentInterfaces.
//

import Foundation
import CoreGraphics
import AppKit

private let log = Log(category: "context")

public final class ContextCoordinator: RecentActivityContext {
    public static let shared = ContextCoordinator()

    private let store = ContextSnapshotStore(maxSnapshots: 20)
    private let ocrService: ContextOCRService
    private let capture: ScreenCapture
    private let clickMonitor: ContextClickMonitor
    private let appSwitchMonitor: ContextAppSwitchMonitor
    private let dirtyThresholdsTracker = DirtyThresholdsTracker()
    private let dirtyRing = ContextDirtyRingBuffer(capacity: 30)

    public struct DirtyComparisonRecord: Sendable {
        public let snapshotID: UUID
        public let classification: ContextDirtyClassification
        public let hamming: Int
        public let changedArea: Double
        public let dirtyBoundingRect: CGRect?
        public let capturedAt: Date
        public let appName: String
        public let windowTitle: String
        public let jpegData: Data
    }

    public func recentDirtyComparisons(limit: Int = 30) async -> [DirtyComparisonRecord] {
        await dirtyRing.recent(limit: limit)
    }

    public func dirtyThresholdsSnapshot() async -> ContextDirtyThresholds {
        await dirtyThresholdsTracker.currentThresholds()
    }

    @MainActor private var isStarted = false
    @MainActor private var isGatheringPaused = false

    private init(
        capture: ScreenCapture = .shared,
        ocrService: ContextOCRService = .shared
    ) {
        self.capture = capture
        self.ocrService = ocrService
        self.clickMonitor = ContextClickMonitor { location in
            Task {
                await ContextCoordinator.shared.capture(trigger: .click, cursorLocation: location)
            }
        }
        self.appSwitchMonitor = ContextAppSwitchMonitor { _ in
            Task {
                await ContextCoordinator.shared.capture(trigger: .appSwitch, cursorLocation: nil)
            }
        }
    }

    @MainActor
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        AgentInterfaces.context = self
        if !isGatheringPaused {
            clickMonitor.start()
            appSwitchMonitor.start()
        }

        Task {
            await capture(trigger: .startup, cursorLocation: nil)
        }
    }

    @MainActor
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        clickMonitor.stop()
        appSwitchMonitor.stop()
        if AgentInterfaces.context === self {
            AgentInterfaces.context = nil
        }
    }

    @MainActor
    @discardableResult
    public func toggleGatheringPaused() -> Bool {
        setGatheringPaused(!isGatheringPaused)
    }

    @MainActor
    @discardableResult
    public func setGatheringPaused(_ paused: Bool) -> Bool {
        isGatheringPaused = paused

        if isStarted {
            if paused {
                clickMonitor.stop()
                appSwitchMonitor.stop()
            } else {
                clickMonitor.start()
                appSwitchMonitor.start()
            }
        }

        log.info("context gathering \(paused ? "paused" : "resumed")")
        return isGatheringPaused
    }

    public func getRecentActivityContext() async -> String {
        let cursorLocation = await MainActor.run { NSEvent.mouseLocation }
        await capture(trigger: .activation, cursorLocation: cursorLocation)
        return await currentActivationPreview()
    }

    public func diagnosticsSummary() async -> String {
        await diagnostics().summary
    }

    public func recentSnapshots() async -> [ContextSnapshot] {
        await store.recentSnapshots()
    }

    /// Returns the brief from the most recent Selector run, or an empty string
    /// if no run has happened yet. The Dev Tools poll this for the live header preview.
    public func currentActivationPreview() async -> String {
        ContextSelector.shared.lastRun?.brief ?? ""
    }

    public func diagnostics() async -> ContextDiagnostics {
        let snapshots = await store.recentSnapshots()
        guard let latest = snapshots.last else {
            return ContextDiagnostics(
                snapshotCount: 0,
                latestAppName: "Unknown app",
                latestWindowTitle: "Unknown window",
                latestTrigger: nil,
                latestRecognizedTextCount: 0,
                isGatheringPaused: await MainActor.run { isGatheringPaused }
            )
        }

        return ContextDiagnostics(
            snapshotCount: snapshots.count,
            latestAppName: latest.appName,
            latestWindowTitle: latest.windowTitle,
            latestTrigger: latest.trigger,
            latestRecognizedTextCount: latest.recognizedText.count,
            isGatheringPaused: await MainActor.run { isGatheringPaused }
        )
    }

    public func capture(trigger: ContextCaptureTrigger, cursorLocation: CGPoint?, bypassPause: Bool = false) async {
        if !bypassPause, await MainActor.run(body: { isGatheringPaused }) {
            log.debug("skipped \(trigger.rawValue) capture — gathering paused")
            return
        }

        let metadata = await MainActor.run {
            ContextWindowMetadataReader.current()
        }
        let bundleID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        }
        guard !Self.shouldIgnoreCapture(metadata) else {
            log.debug("ignored \(trigger.rawValue) capture for AgentNotch UI")
            return
        }

        do {
            let snapshot = try await capture.snapshot(quality: 0.35)
            // OCR on the FULL-RESOLUTION raw CGImage, not the downsampled JPEG.
            // The 1568px downsample + JPEG-35 compression makes small UI text
            // unreadable. Vision .accurate + the raw image gives clean OCR.
            // Falls back to the JPEG path only if rawImage is nil.
            let recognizedText: [ContextRecognizedText]
            if let rawImage = snapshot.rawImage {
                recognizedText = await ocrService.recognizeText(in: rawImage)
            } else {
                recognizedText = await ocrService.recognizeText(in: snapshot.jpegData)
            }
            let previousSnapshot = await store.recentSnapshots().last
            let previousSignature = await store.lastSignature()
            let contextSnapshot = ContextSnapshot(
                capturedAt: snapshot.capturedAt,
                trigger: trigger,
                appName: metadata.appName,
                windowTitle: metadata.windowTitle,
                cursorLocation: cursorLocation,
                jpegData: snapshot.jpegData,
                width: snapshot.width,
                height: snapshot.height,
                recognizedText: recognizedText
            )

            // Record the current window as a generic resource so the long-press
            // Selector can resolve deictic references like "the doc I had open"
            // even after the user has switched apps. No adapter required.
            // ResourceIndex dedups by URI and refreshes lastSeen on repeats.
            let trimmedTitle = metadata.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                let resource = CResourceRef(
                    kind: "window",
                    uri: "\(bundleID)//\(trimmedTitle)",
                    label: trimmedTitle,
                    app: metadata.appName,
                    lastSeen: contextSnapshot.capturedAt
                )
                ResourceIndex.shared.record(resource)
            }

            // Dirty-region classification drives memory hygiene and the
            // Dev Tools dirty pane; classification is a pure local signal.
            let signature = ContextDirtyDetector.signature(
                from: snapshot.jpegData,
                screenWidth: snapshot.width,
                screenHeight: snapshot.height
            )
            await store.record(contextSnapshot, signature: signature)
            let classification = await classifyDirtyChange(
                trigger: trigger,
                currentSignature: signature,
                previousSignature: previousSignature,
                currentSnapshot: contextSnapshot,
                previousSnapshot: previousSnapshot
            )

            switch classification.classification {
            case .unchanged:
                log.info("captured \(trigger.rawValue) for \(metadata.appName) — UNCHANGED")
            case .minorChange:
                log.info("captured \(trigger.rawValue) for \(metadata.appName) — MINOR_CHANGE")
            case .majorChange:
                log.info("captured \(trigger.rawValue) for \(metadata.appName) — MAJOR_CHANGE")
            }

            await dirtyThresholdsTracker.observe(classification.classification)
            await dirtyRing.append(DirtyComparisonRecord(
                snapshotID: contextSnapshot.id,
                classification: classification.classification,
                hamming: classification.comparison?.hammingDistance ?? 0,
                changedArea: classification.comparison?.changedAreaFraction ?? 0,
                dirtyBoundingRect: classification.comparison?.dirtyBoundingRect,
                capturedAt: contextSnapshot.capturedAt,
                appName: contextSnapshot.appName,
                windowTitle: contextSnapshot.windowTitle,
                jpegData: snapshot.jpegData
            ))

            // Phase 6+: continuous vision-based UI/UX learning.
            // Only fires when the screen has genuinely changed (DirtyDetector
            // said major), and is throttled internally to >=8s between calls.
            // Detached so we never block the capture path.
            //
            // Gemini observer wants PNG (sharper UI text edges than the JPEG-35
            // we keep for OCR/dirty/Claude). Re-encode from the raw CGImage
            // when available; skip the observer for this turn if PNG encode
            // fails or the raw image is missing.
            if classification.classification == .majorChange, let rawImage = snapshot.rawImage,
               let png = ScreenCapture.shared.pngEncode(rawImage) {
                Task.detached(priority: .utility) {
                    let hint = await MainActor.run {
                        NSWorkspace.shared.frontmostApplication?.localizedName
                    }
                    await GeminiObserver.shared.observe(
                        screenshotPNG: png,
                        frontmostHint: hint
                    )
                }
            }
        } catch {
            log.error("capture failed: \(error)")
        }
    }

    actor ContextDirtyRingBuffer {
        private var records: [DirtyComparisonRecord] = []
        let capacity: Int

        init(capacity: Int) { self.capacity = capacity }

        func append(_ record: DirtyComparisonRecord) {
            records.append(record)
            if records.count > capacity {
                records.removeFirst(records.count - capacity)
            }
        }

        func recent(limit: Int) -> [DirtyComparisonRecord] {
            let slice = records.suffix(min(limit, records.count))
            return Array(slice.reversed())
        }
    }

    private func classifyDirtyChange(
        trigger: ContextCaptureTrigger,
        currentSignature: ContextDirtySignature?,
        previousSignature: ContextDirtySignature?,
        currentSnapshot: ContextSnapshot,
        previousSnapshot: ContextSnapshot?
    ) async -> DirtyClassificationResult {
        // First capture in a session, or any startup capture: treat as major.
        guard trigger != .startup, let previousSnapshot, let previousSignature, let currentSignature else {
            return DirtyClassificationResult(classification: .majorChange, comparison: nil)
        }

        let appChanged = previousSnapshot.appName.caseInsensitiveCompare(currentSnapshot.appName) != .orderedSame
        let windowChanged = previousSnapshot.windowTitle.caseInsensitiveCompare(currentSnapshot.windowTitle) != .orderedSame

        let thresholds = await dirtyThresholdsTracker.currentThresholds()
        let comparison = ContextDirtyDetector.compare(
            current: currentSignature,
            previous: previousSignature,
            thresholds: thresholds
        )

        // App or window switch always counts as a major change even if the
        // pixels happen to look similar.
        if appChanged || windowChanged {
            return DirtyClassificationResult(
                classification: .majorChange,
                comparison: comparison
            )
        }

        return DirtyClassificationResult(
            classification: comparison.classification,
            comparison: comparison
        )
    }

    private struct DirtyClassificationResult: Sendable {
        let classification: ContextDirtyClassification
        let comparison: ContextDirtyComparison?
    }

    /// In-memory tracker for adaptive dirty thresholds. Lives for the session
    /// only — nothing persists.
    private actor DirtyThresholdsTracker {
        private var thresholds = ContextDirtyThresholds.default
        private var consecutiveMinor = 0
        private var consecutiveUnchanged = 0
        private var recentMajorBursts = 0

        func currentThresholds() -> ContextDirtyThresholds {
            thresholds
        }

        func observe(_ classification: ContextDirtyClassification) {
            switch classification {
            case .minorChange:
                consecutiveMinor += 1
                consecutiveUnchanged = 0
                if consecutiveMinor > 20 {
                    // Noisy environment — nudge unchanged hamming up by 1.
                    thresholds.unchangedHamming = min(8, thresholds.unchangedHamming + 1)
                    NSLog("[ContextCoordinator] Adaptive dirty thresholds: bumped unchangedHamming to \(thresholds.unchangedHamming) after \(consecutiveMinor) consecutive minor captures.")
                    consecutiveMinor = 0
                }
            case .unchanged:
                consecutiveUnchanged += 1
                consecutiveMinor = 0
                if consecutiveUnchanged > 50 && recentMajorBursts > 2 {
                    NSLog("[ContextCoordinator] Adaptive dirty thresholds suggestion: \(consecutiveUnchanged) consecutive unchanged with \(recentMajorBursts) recent major bursts — consider tightening minor band.")
                    recentMajorBursts = 0
                }
            case .majorChange:
                if consecutiveUnchanged > 5 {
                    recentMajorBursts += 1
                }
                consecutiveMinor = 0
                consecutiveUnchanged = 0
            }
        }
    }

    private static func shouldIgnoreCapture(_ metadata: ContextWindowMetadata) -> Bool {
        let appName = metadata.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let windowTitle = metadata.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return appName == "agentnotch"
            || appName == "agent in the notch"
            || windowTitle.contains("agentnotch dev tools")
    }
}
