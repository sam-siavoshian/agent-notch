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
        self.appSwitchMonitor = ContextAppSwitchMonitor {
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
    @discardableResult
    public func toggleGatheringPaused() -> Bool {
        isGatheringPaused.toggle()

        if isStarted {
            if isGatheringPaused {
                clickMonitor.stop()
                appSwitchMonitor.stop()
            } else {
                clickMonitor.start()
                appSwitchMonitor.start()
            }
        }

        log.info("context gathering \(isGatheringPaused ? "paused" : "resumed")")
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
        let paused = await MainActor.run { isGatheringPaused }
        guard let latest = snapshots.last else {
            return ContextDiagnostics(
                snapshotCount: 0,
                latestAppName: "Unknown app",
                latestWindowTitle: "Unknown window",
                latestTrigger: nil,
                latestRecognizedTextCount: 0,
                isGatheringPaused: paused
            )
        }

        return ContextDiagnostics(
            snapshotCount: snapshots.count,
            latestAppName: latest.appName,
            latestWindowTitle: latest.windowTitle,
            latestTrigger: latest.trigger,
            latestRecognizedTextCount: latest.recognizedText.count,
            isGatheringPaused: paused
        )
    }

    func capture(trigger: ContextCaptureTrigger, cursorLocation: CGPoint?) async {
        if await MainActor.run(body: { isGatheringPaused }) {
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
            // OCR the raw CGImage when available — the JPEG downsample makes
            // small UI text unreadable.
            let recognizedText: [ContextRecognizedText]
            if let rawImage = snapshot.rawImage {
                recognizedText = await ocrService.recognizeText(in: rawImage)
            } else {
                recognizedText = await ocrService.recognizeText(in: snapshot.jpegData)
            }
            let previousSnapshot = await store.lastSnapshot()
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

            // Record the current window as a generic resource so the Selector
            // can resolve deictic references like "the doc I had open".
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

            log.info("captured \(trigger.rawValue) for \(metadata.appName) — \(classification.classification.label.uppercased())")

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

            // Fan out to Gemini observer on major changes only. Detached so we
            // never block the capture path. Gemini wants PNG for sharper UI
            // text edges than the JPEG-35 we keep for OCR/dirty/Claude.
            if classification.classification == .majorChange, let rawImage = snapshot.rawImage,
               let png = ScreenCapture.shared.pngEncode(rawImage) {
                Task.detached(priority: .utility) {
                    let hint = await MainActor.run {
                        NSWorkspace.shared.frontmostApplication?.localizedName
                    }
                    await GeminiObserver.shared.observe(
                        screenshotPNG: png,
                        frontmostHint: hint,
                        bundleID: bundleID.isEmpty ? nil : bundleID
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
        // First capture or startup: treat as major.
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

        // App / window switch always counts as major regardless of pixels.
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

    private static let ignoredAppNames: Set<String> = ["agentnotch", "agent in the notch"]

    private static func shouldIgnoreCapture(_ metadata: ContextWindowMetadata) -> Bool {
        let appName = metadata.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ignoredAppNames.contains(appName) { return true }
        let windowTitle = metadata.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return windowTitle.contains("agentnotch dev tools")
    }
}
