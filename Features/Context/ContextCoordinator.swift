//
//  ContextCoordinator.swift
//  Agent in the Notch
//
//  Native context feature entry point. Owns click-triggered captures and
//  exposes a compact text packet to AgentSession through AgentInterfaces.
//

import CryptoKit
import Foundation
import CoreGraphics
import AppKit

private let log = Log(category: "context")

public final class ContextCoordinator: RecentActivityContext {
    public static let shared = ContextCoordinator()

    private let store = ContextSnapshotStore(maxSnapshots: 20)
    private let memoryStore: ContextMemoryStore
    private let ocrService: ContextOCRService
    private let geminiObservationService: ContextGeminiObservationService
    private let aiObservationLog: ContextAIObservationLog
    private let geminiGate: ContextGeminiObservationGate
    private let capture: ScreenCapture
    private let clickMonitor: ContextClickMonitor
    private let appSwitchMonitor: ContextAppSwitchMonitor
    private let dirtyThresholdsTracker = DirtyThresholdsTracker()

    @MainActor private var isStarted = false
    @MainActor private var isGatheringPaused = false

    private init(
        capture: ScreenCapture = .shared,
        memoryStore: ContextMemoryStore = .shared,
        ocrService: ContextOCRService = .shared,
        geminiObservationService: ContextGeminiObservationService = .shared,
        aiObservationLog: ContextAIObservationLog = .shared,
        geminiGate: ContextGeminiObservationGate = ContextGeminiObservationGate()
    ) {
        self.capture = capture
        self.memoryStore = memoryStore
        self.ocrService = ocrService
        self.geminiObservationService = geminiObservationService
        self.aiObservationLog = aiObservationLog
        self.geminiGate = geminiGate
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
        return await buildActivityContext()
    }

    public func getRecentActivityContext(hint: ActivationContextHint?) async -> String {
        let cursorLocation = await MainActor.run { NSEvent.mouseLocation }
        await capture(trigger: .activation, cursorLocation: cursorLocation)

        if hint == nil {
            return await buildActivityContext()
        }

        let snapshots = await store.recentSnapshots()
        let appName = snapshots.last?.appName ?? ""
        let mainMemory = await memoryStore.appMemory(appName: appName)
        let knownApps = await memoryStore.allKnownAppNames()
        let lowerKnown = Dictionary(uniqueKeysWithValues: knownApps.map { ($0.lowercased(), $0) })
        let mentioned = hint?.mentionedApps ?? []
        var crossAppMemories: [ContextAppMemory] = []
        for name in mentioned {
            let lower = name.lowercased()
            guard let canonical = lowerKnown[lower],
                  canonical.caseInsensitiveCompare(appName) != .orderedSame else { continue }
            if let mem = await memoryStore.appMemory(appName: canonical) {
                crossAppMemories.append(mem)
            }
        }

        let tailored = ContextMemoryRenderer.tailoredActivationSnippet(
            for: mainMemory,
            hint: hint,
            otherApps: crossAppMemories
        )
        return await store.recentActivityContext(learnedUIMemory: tailored)
    }

    public func diagnosticsSummary() async -> String {
        await diagnostics().summary
    }

    public func recentSnapshots() async -> [ContextSnapshot] {
        await store.recentSnapshots()
    }

    public func currentActivationPreview() async -> String {
        await buildActivityContext()
    }

    private func buildActivityContext() async -> String {
        let snapshots = await store.recentSnapshots()
        let appName = snapshots.last?.appName ?? ""
        let learnedMemory = await memoryStore.activationMemory(appName: appName)
        return await store.recentActivityContext(learnedUIMemory: learnedMemory)
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
                hasLearnedMemory: false,
                isGatheringPaused: await MainActor.run { isGatheringPaused }
            )
        }

        let learnedMemory = await memoryStore.activationMemory(appName: latest.appName)
        return ContextDiagnostics(
            snapshotCount: snapshots.count,
            latestAppName: latest.appName,
            latestWindowTitle: latest.windowTitle,
            latestTrigger: latest.trigger,
            latestRecognizedTextCount: latest.recognizedText.count,
            hasLearnedMemory: !learnedMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
        guard !Self.shouldIgnoreCapture(metadata) else {
            log.debug("ignored \(trigger.rawValue) capture for AgentNotch UI")
            return
        }

        do {
            let snapshot = try await capture.snapshot(quality: 0.35)
            let recognizedText = await ocrService.recognizeText(in: snapshot.pngData)
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

            // Dirty-region classification. The PNG is the canonical pixel source
            // (lossless, matches what Gemini gets). Compute a signature now so
            // future captures can diff against it even if we skip Gemini today.
            let signature = ContextDirtyDetector.signature(
                from: snapshot.pngData,
                screenWidth: snapshot.width,
                screenHeight: snapshot.height
            )
            await store.record(contextSnapshot, signature: signature)
            await memoryStore.record(contextSnapshot)
            let classification = await classifyDirtyChange(
                trigger: trigger,
                currentSignature: signature,
                previousSignature: previousSignature,
                currentSnapshot: contextSnapshot,
                previousSnapshot: previousSnapshot
            )

            switch classification.classification {
            case .unchanged:
                await recordUnchangedEvent(
                    snapshot: contextSnapshot,
                    comparison: classification.comparison
                )
                log.info("captured \(trigger.rawValue) for \(metadata.appName) — UNCHANGED, skipping Gemini fan-out")
            case .minorChange:
                if let previousObservation = await store.lastReducerObservation() {
                    scheduleGeminiUpdate(
                        for: contextSnapshot,
                        imageData: snapshot.pngData,
                        mimeType: "image/png",
                        previousSnapshot: previousSnapshot,
                        previousObservation: previousObservation,
                        comparison: classification.comparison
                    )
                    log.info("captured \(trigger.rawValue) for \(metadata.appName) — MINOR_CHANGE, dispatching update lane only")
                } else {
                    scheduleGeminiObservation(
                        for: contextSnapshot,
                        imageData: snapshot.pngData,
                        mimeType: "image/png",
                        previousSnapshot: previousSnapshot,
                        comparison: classification.comparison
                    )
                    log.info("captured \(trigger.rawValue) for \(metadata.appName) — minor change without baseline, full fan-out")
                }
            case .majorChange:
                scheduleGeminiObservation(
                    for: contextSnapshot,
                    imageData: snapshot.pngData,
                    mimeType: "image/png",
                    previousSnapshot: previousSnapshot,
                    comparison: classification.comparison
                )
                log.info("captured \(trigger.rawValue) for \(metadata.appName) — MAJOR_CHANGE, full fan-out")
            }

            await dirtyThresholdsTracker.observe(classification.classification)
        } catch {
            log.error("capture failed: \(error)")
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

    private func recordUnchangedEvent(
        snapshot: ContextSnapshot,
        comparison: ContextDirtyComparison?
    ) async {
        let hamming = comparison?.hammingDistance ?? 0
        let area = comparison?.changedAreaFraction ?? 0
        let reason = "stable screen — hamming=\(hamming), changedArea=\(String(format: "%.3f", area)); skipped all Gemini lanes"
        await aiObservationLog.record(ContextAIObservationEvent(
            status: .skipped,
            trigger: snapshot.trigger,
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            reason: reason,
            laneName: "dirty-detector",
            summary: reason
        ))
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

    private func scheduleGeminiObservation(
        for snapshot: ContextSnapshot,
        imageData: Data,
        mimeType: String,
        previousSnapshot: ContextSnapshot?,
        comparison: ContextDirtyComparison? = nil
    ) {
        let geminiObservationService = geminiObservationService
        let memoryStore = memoryStore
        let aiObservationLog = aiObservationLog
        let geminiGate = geminiGate
        let mediaResolution = ContextGeminiObservationService.configuredMediaResolution
        let thinkingLevel = ContextGeminiObservationService.configuredThinkingLevel
        let attemptID = UUID()
        let lanes = Self.geminiLanes(for: snapshot, previousSnapshot: previousSnapshot)
        let input = ContextGeminiObservationInput(
            imageData: imageData,
            mimeType: mimeType,
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            width: snapshot.width,
            height: snapshot.height,
            recognizedText: snapshot.recognizedText,
            metadata: Self.geminiMetadata(for: snapshot, previousSnapshot: previousSnapshot)
        )

        let fanoutClassification = comparison?.classification.label
        Task(priority: .utility) { [snapshot, imageData, previousSnapshot, input, lanes, fanoutClassification] in
            let decision = await geminiGate.startDecision(
                trigger: snapshot.trigger,
                isAPIKeyConfigured: ContextGeminiObservationService.isAPIKeyConfigured,
                dirtyClassification: fanoutClassification
            )

            switch decision {
            case .skip(let reason):
                await aiObservationLog.record(ContextAIObservationEvent(
                    status: .skipped,
                    trigger: snapshot.trigger,
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    reason: reason,
                    attemptID: attemptID,
                    laneName: "modular",
                    imageBytes: imageData.count,
                    requestMimeType: mimeType,
                    requestMediaResolution: mediaResolution,
                    requestThinkingLevel: thinkingLevel,
                    ocrCount: snapshot.recognizedText.count
                ))
                return
            case .run:
                break
            }

            let startedAt = Date()
            let classificationLabel = (comparison?.classification ?? .majorChange).label
            await aiObservationLog.record(ContextAIObservationEvent(
                status: .queued,
                trigger: snapshot.trigger,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                reason: "queued modular screen understanding with \(lanes.count) lanes (dirty=\(classificationLabel))",
                attemptID: attemptID,
                laneName: "modular",
                imageBytes: imageData.count,
                requestMimeType: mimeType,
                requestMediaResolution: mediaResolution,
                requestThinkingLevel: thinkingLevel,
                ocrCount: snapshot.recognizedText.count
            ))

            let laneResults = await withTaskGroup(of: ContextGeminiLaneObservation?.self) { group in
                for lane in lanes {
                    group.addTask {
                        await aiObservationLog.record(ContextAIObservationEvent(
                            status: .queued,
                            trigger: snapshot.trigger,
                            appName: snapshot.appName,
                            windowTitle: snapshot.windowTitle,
                            reason: "queued \(lane.label) lane for \(lane.shortGoal)",
                            attemptID: attemptID,
                            laneName: lane.rawValue,
                            imageBytes: imageData.count,
                            requestMimeType: mimeType,
                            requestMediaResolution: mediaResolution,
                            requestThinkingLevel: thinkingLevel,
                            ocrCount: snapshot.recognizedText.count
                        ))

                        let laneStartedAt = Date()
                        let laneObservation = await geminiObservationService.observeLane(
                            lane,
                            input: input,
                            previousSnapshot: previousSnapshot
                        )
                        let laneElapsedMilliseconds = Int(Date().timeIntervalSince(laneStartedAt) * 1000)

                        guard let laneObservation else {
                            await aiObservationLog.record(ContextAIObservationEvent(
                                status: .failed,
                                trigger: snapshot.trigger,
                                appName: snapshot.appName,
                                windowTitle: snapshot.windowTitle,
                                reason: "\(lane.label) lane returned no valid observation",
                                attemptID: attemptID,
                                laneName: lane.rawValue,
                                latencyMilliseconds: laneElapsedMilliseconds,
                                imageBytes: imageData.count,
                                requestMimeType: mimeType,
                                requestMediaResolution: mediaResolution,
                                requestThinkingLevel: thinkingLevel,
                                ocrCount: snapshot.recognizedText.count
                            ))
                            return nil
                        }

                        let controls = Self.controlDescriptions(laneObservation.controls)
                        await aiObservationLog.record(ContextAIObservationEvent(
                            status: .completed,
                            trigger: snapshot.trigger,
                            appName: snapshot.appName,
                            windowTitle: snapshot.windowTitle,
                            reason: "\(lane.label) lane recorded \(laneObservation.controls.count) controls, \(laneObservation.entities.count) entities, \(laneObservation.memoryCards.count) memory cards",
                            attemptID: attemptID,
                            laneName: lane.rawValue,
                            source: laneObservation.source.rawValue,
                            latencyMilliseconds: laneElapsedMilliseconds,
                            confidence: laneObservation.confidence,
                            surfaceLabel: laneObservation.surfaceLabel,
                            summary: laneObservation.summary,
                            screenType: laneObservation.screenType,
                            primaryTask: laneObservation.primaryTask,
                            contentSummary: laneObservation.contentSummary,
                            controls: controls,
                            landmarks: laneObservation.layoutRegions,
                            entities: laneObservation.entities,
                            affordances: controls,
                            stateIndicators: laneObservation.stateIndicators,
                            navigationPaths: laneObservation.navigation,
                            dataRegions: laneObservation.layoutRegions,
                            workflowHints: laneObservation.workflows,
                            negativeCues: laneObservation.negativeCues,
                            memoryCandidates: laneObservation.memoryCards,
                            uncertainty: laneObservation.uncertainty,
                            imageBytes: imageData.count,
                            requestMimeType: mimeType,
                            requestMediaResolution: mediaResolution,
                            requestThinkingLevel: thinkingLevel,
                            ocrCount: snapshot.recognizedText.count,
                            controlsCount: laneObservation.controls.count,
                            affordancesCount: laneObservation.workflows.count,
                            entitiesCount: laneObservation.entities.count
                        ))
                        return laneObservation
                    }
                }

                var observations: [ContextGeminiLaneObservation] = []
                for await laneObservation in group {
                    if let laneObservation {
                        observations.append(laneObservation)
                    }
                }
                return observations
            }

            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            await geminiGate.finish()

            // Try the LLM reducer first; fall back to the static Swift reducer when it
            // fails or times out. Log clearly which path took.
            var reducerObservation: ContextGeminiObservation?
            var reducerPath = "swift-fallback"
            if !laneResults.isEmpty {
                let reducerStartedAt = Date()
                do {
                    reducerObservation = try await geminiObservationService.reduceObservations(
                        laneResults,
                        trigger: snapshot.trigger
                    )
                    reducerPath = "gemini-llm"
                    let reducerElapsedMs = Int(Date().timeIntervalSince(reducerStartedAt) * 1000)
                    log.info("reducer succeeded path=gemini-llm in \(reducerElapsedMs)ms")
                } catch {
                    let reducerElapsedMs = Int(Date().timeIntervalSince(reducerStartedAt) * 1000)
                    log.warning("reducer LLM failed in \(reducerElapsedMs)ms: \(error) — falling back to Swift reducer")
                }
            }
            if reducerObservation == nil {
                reducerObservation = ContextGeminiObservationService.reduceLaneObservations(
                    laneResults,
                    input: input,
                    imageHash: Self.sha256Hex(imageData)
                )
                if reducerObservation != nil {
                    log.info("reducer used swift fallback for \(laneResults.count) lanes")
                }
            }

            guard let observation = reducerObservation else {
                await aiObservationLog.record(ContextAIObservationEvent(
                    status: .failed,
                    trigger: snapshot.trigger,
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    reason: "No modular Gemini lanes returned valid observations (reducerPath=\(reducerPath))",
                    attemptID: attemptID,
                    laneName: ContextGeminiObservationLane.reducer.rawValue,
                    latencyMilliseconds: elapsedMilliseconds,
                    imageBytes: imageData.count,
                    requestMimeType: mimeType,
                    requestMediaResolution: mediaResolution,
                    requestThinkingLevel: thinkingLevel,
                    ocrCount: snapshot.recognizedText.count
                ))
                return
            }
            NSLog("[ContextCoordinator] Reducer path: \(reducerPath) for \(snapshot.appName)")

            // Stash the reducer output so the dirty-region short-circuit and the
            // `.update` lane have a baseline to compare against on the next capture.
            await store.recordReducerObservation(
                observation,
                surfaceKey: Self.surfaceKey(for: snapshot)
            )

            await memoryStore.record(
                observation,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                capturedAt: snapshot.capturedAt
            )
            let controls = Self.controlDescriptions(observation.visibleControls)
            await aiObservationLog.record(ContextAIObservationEvent(
                status: .completed,
                trigger: snapshot.trigger,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                reason: "reduced \(laneResults.count) lanes into activation-ready memory",
                attemptID: attemptID,
                laneName: ContextGeminiObservationLane.reducer.rawValue,
                source: observation.source.rawValue,
                latencyMilliseconds: elapsedMilliseconds,
                confidence: observation.confidence,
                surfaceLabel: observation.surfaceLabel,
                summary: observation.summary,
                screenType: observation.screenType,
                primaryTask: observation.primaryTask,
                layoutSummary: observation.layoutSummary,
                contentSummary: observation.contentSummary,
                controls: controls,
                landmarks: observation.landmarks,
                entities: observation.entities,
                affordances: observation.affordances,
                stateIndicators: observation.stateIndicators,
                navigationPaths: observation.navigationPaths,
                dataRegions: observation.dataRegions,
                workflowHints: observation.workflowHints,
                negativeCues: observation.negativeCues,
                memoryCandidates: observation.memoryCandidates,
                uncertainty: observation.uncertainty,
                imageBytes: imageData.count,
                requestMimeType: mimeType,
                requestMediaResolution: mediaResolution,
                requestThinkingLevel: thinkingLevel,
                ocrCount: snapshot.recognizedText.count,
                controlsCount: observation.visibleControls.count,
                affordancesCount: observation.affordances.count,
                entitiesCount: observation.entities.count
            ))
            log.info("Gemini learned \(observation.appLabel)/\(observation.surfaceLabel) in \(elapsedMilliseconds)ms, confidence \(observation.confidence)")
        }
    }

    private func scheduleGeminiUpdate(
        for snapshot: ContextSnapshot,
        imageData: Data,
        mimeType: String,
        previousSnapshot: ContextSnapshot?,
        previousObservation: ContextGeminiObservation,
        comparison: ContextDirtyComparison?
    ) {
        let geminiObservationService = geminiObservationService
        let memoryStore = memoryStore
        let aiObservationLog = aiObservationLog
        let geminiGate = geminiGate
        let store = store
        let attemptID = UUID()
        let lane = ContextGeminiObservationLane.update
        let mediaResolution = "MEDIA_RESOLUTION_HIGH"
        let thinkingLevel = "minimal"
        let debugPaths = ContextGeminiObservationService.debugPaths(
            for: imageData,
            mimeType: mimeType,
            laneName: lane.rawValue
        )
        let input = ContextGeminiObservationInput(
            imageData: imageData,
            mimeType: mimeType,
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            width: snapshot.width,
            height: snapshot.height,
            recognizedText: snapshot.recognizedText,
            metadata: Self.geminiMetadata(for: snapshot, previousSnapshot: previousSnapshot)
        )
        let classificationLabel = (comparison?.classification ?? .minorChange).label
        let surfaceKey = Self.surfaceKey(for: snapshot)

        Task(priority: .utility) { [snapshot, imageData, input, previousObservation, comparison, classificationLabel] in
            let decision = await geminiGate.startDecision(
                trigger: snapshot.trigger,
                isAPIKeyConfigured: ContextGeminiObservationService.isAPIKeyConfigured,
                dirtyClassification: classificationLabel
            )
            switch decision {
            case .skip(let reason):
                await aiObservationLog.record(ContextAIObservationEvent(
                    status: .skipped,
                    trigger: snapshot.trigger,
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    reason: "\(reason) (update lane)",
                    attemptID: attemptID,
                    laneName: lane.rawValue,
                    imageBytes: imageData.count,
                    requestMimeType: mimeType,
                    requestMediaResolution: mediaResolution,
                    requestThinkingLevel: thinkingLevel,
                    ocrCount: snapshot.recognizedText.count,
                ))
                return
            case .run:
                break
            }

            await aiObservationLog.record(ContextAIObservationEvent(
                status: .queued,
                trigger: snapshot.trigger,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                reason: "queued cheap update lane against previous reducer observation (dirty=\(classificationLabel))",
                attemptID: attemptID,
                laneName: lane.rawValue,
                imageBytes: imageData.count,
                requestMimeType: mimeType,
                requestMediaResolution: mediaResolution,
                requestThinkingLevel: thinkingLevel,
                ocrCount: snapshot.recognizedText.count,
            ))

            let startedAt = Date()

            // Tier 0 — OCR-delta fast path. If the dirty region is small and
            // overlaps a single previously-known OCR text region whose text
            // has changed, synthesize the delta locally and skip Gemini.
            if let ocrDelta = Self.attemptOCRDelta(
                comparison: comparison,
                previousSnapshot: previousSnapshot,
                currentSnapshot: snapshot
            ) {
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                await geminiGate.finish()
                let merged = ContextGeminiObservationService.mergeUpdate(
                    previous: previousObservation,
                    delta: ocrDelta
                )
                await store.recordReducerObservation(merged, surfaceKey: surfaceKey)
                await memoryStore.record(
                    merged,
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    capturedAt: snapshot.capturedAt
                )
                await aiObservationLog.record(ContextAIObservationEvent(
                    status: .completed,
                    trigger: snapshot.trigger,
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    reason: "OCR-delta fast path: \(ocrDelta.summary ?? "text change") in \(elapsedMs)ms (no LLM)",
                    attemptID: attemptID,
                    laneName: lane.rawValue,
                    source: "ocr-delta",
                    latencyMilliseconds: elapsedMs,
                    summary: ocrDelta.summary,
                    imageBytes: imageData.count,
                    requestMimeType: mimeType,
                    requestMediaResolution: "n/a",
                    requestThinkingLevel: "n/a",
                    ocrCount: snapshot.recognizedText.count,
                ))
                NSLog("[ContextCoordinator] OCR-delta fast path applied for \(snapshot.appName) in \(elapsedMs)ms")
                return
            }

            // Tier 1 — build a focused crop + low-res thumbnail when we have a
            // bounding rect. Falls back to the full image when the rect is
            // unavailable or the crop covers most of the screen anyway.
            let (thumbnail, crop) = Self.makeUpdateLaneImages(
                imageData: imageData,
                comparison: comparison
            )
            let delta = await geminiObservationService.observeUpdate(
                previousObservation: previousObservation,
                input: input,
                thumbnailData: thumbnail,
                cropData: crop
            )
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            await geminiGate.finish()

            guard let delta else {
                // Gemini returned no_change, errored, or timed out. Record a
                // skipped/completed event so dev tools shows what happened, but
                // don't disturb the cached observation.
                await aiObservationLog.record(ContextAIObservationEvent(
                    status: .completed,
                    trigger: snapshot.trigger,
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    reason: "update lane reported no_change (or no delta produced) in \(elapsedMs)ms",
                    attemptID: attemptID,
                    laneName: lane.rawValue,
                    source: ContextGeminiObservation.Source.gemini.rawValue,
                    latencyMilliseconds: elapsedMs,
                    summary: "no_change",
                    imageBytes: imageData.count,
                    requestMimeType: mimeType,
                    requestMediaResolution: mediaResolution,
                    requestThinkingLevel: thinkingLevel,
                    ocrCount: snapshot.recognizedText.count,
                ))
                NSLog("[ContextCoordinator] Update lane reported no_change for \(snapshot.appName)")
                return
            }

            let merged = ContextGeminiObservationService.mergeUpdate(
                previous: previousObservation,
                delta: delta
            )
            await store.recordReducerObservation(merged, surfaceKey: surfaceKey)
            await memoryStore.record(
                merged,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                capturedAt: snapshot.capturedAt
            )

            let controls = merged.visibleControls.map { control -> String in
                if let actionHint = control.actionHint, !actionHint.isEmpty {
                    return "\(control.label) (\(control.role), \(control.region)): \(actionHint)"
                }
                return "\(control.label) (\(control.role), \(control.region))"
            }

            await aiObservationLog.record(ContextAIObservationEvent(
                status: .completed,
                trigger: snapshot.trigger,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                reason: "update lane merged delta into baseline observation in \(elapsedMs)ms",
                attemptID: attemptID,
                laneName: lane.rawValue,
                source: delta.source.rawValue,
                latencyMilliseconds: elapsedMs,
                confidence: merged.confidence,
                surfaceLabel: merged.surfaceLabel,
                summary: merged.summary,
                screenType: merged.screenType,
                primaryTask: merged.primaryTask,
                layoutSummary: merged.layoutSummary,
                contentSummary: merged.contentSummary,
                controls: controls,
                landmarks: merged.landmarks,
                entities: merged.entities,
                affordances: merged.affordances,
                stateIndicators: merged.stateIndicators,
                navigationPaths: merged.navigationPaths,
                dataRegions: merged.dataRegions,
                workflowHints: merged.workflowHints,
                negativeCues: merged.negativeCues,
                memoryCandidates: merged.memoryCandidates,
                uncertainty: merged.uncertainty,
                imageBytes: imageData.count,
                requestMimeType: mimeType,
                requestMediaResolution: mediaResolution,
                requestThinkingLevel: thinkingLevel,
                ocrCount: snapshot.recognizedText.count,
                controlsCount: merged.visibleControls.count,
                affordancesCount: merged.affordances.count,
                entitiesCount: merged.entities.count,
            ))
            NSLog("[ContextCoordinator] Update lane merged delta for \(snapshot.appName) in \(elapsedMs)ms")
        }
    }

    private static func surfaceKey(for snapshot: ContextSnapshot) -> String {
        let app = snapshot.appName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let window = snapshot.windowTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(app)::\(window)"
    }

    // MARK: - Dirty-rect crop + thumbnail helpers (Tier 1)

    /// Returns (thumbnail, crop) PNG data for the update lane when the dirty
    /// rect is meaningful AND localized. Returns (nil, nil) when there's no
    /// rect or the dirty region covers most of the screen — in that case the
    /// service falls back to sending the full image.
    private static func makeUpdateLaneImages(
        imageData: Data,
        comparison: ContextDirtyComparison?
    ) -> (Data?, Data?) {
        guard let comparison,
              let bbox = comparison.dirtyBoundingRect else { return (nil, nil) }

        // If the dirty rect already covers >= 60% of either dimension, a crop
        // wouldn't focus anything — skip the split and use the full image.
        if bbox.width >= 0.6 || bbox.height >= 0.6 { return (nil, nil) }

        guard let crop = ContextDirtyDetector.croppedPNG(from: imageData, normalizedBBox: bbox),
              let thumbnail = ContextDirtyDetector.thumbnailPNG(from: imageData) else {
            return (nil, nil)
        }
        return (thumbnail, crop)
    }

    // MARK: - OCR-delta fast path (Tier 0)

    /// Attempt to synthesize a `ContextGeminiLaneObservation` delta from just
    /// the OCR text inside the dirty bbox — no Gemini call. Conservative: only
    /// fires when the dirty rect is small AND the OCR set inside that rect has
    /// the same number of items in both snapshots (same layout) but at least
    /// one text value differs (purely text-content change like a counter
    /// updating, a value editing in place, a "saved 2s ago" timestamp).
    static func attemptOCRDelta(
        comparison: ContextDirtyComparison?,
        previousSnapshot: ContextSnapshot?,
        currentSnapshot: ContextSnapshot
    ) -> ContextGeminiLaneObservation? {
        guard let comparison, comparison.changedAreaFraction < 0.03,
              let bbox = comparison.dirtyBoundingRect,
              let previousSnapshot else { return nil }

        let previousInside = ocrItems(insideNormalized: bbox, snapshot: previousSnapshot)
        let currentInside = ocrItems(insideNormalized: bbox, snapshot: currentSnapshot)

        // Both must have at least one item and the layout (count + sorted
        // bbox positions) must match. Otherwise this is a layout change, not
        // a text-only change — fall through to Gemini.
        guard !previousInside.isEmpty,
              previousInside.count == currentInside.count else { return nil }

        let sortedPrev = previousInside.sorted { ocrSortKey($0) < ocrSortKey($1) }
        let sortedCurr = currentInside.sorted { ocrSortKey($0) < ocrSortKey($1) }

        var changes: [(String, String)] = []
        for (prev, curr) in zip(sortedPrev, sortedCurr) {
            // Require positions to match within ~1% of screen — anything more
            // is a layout change.
            if abs(prev.x - curr.x) > 0.01 || abs(prev.y - curr.y) > 0.01 {
                return nil
            }
            if prev.text != curr.text {
                changes.append((prev.text, curr.text))
            }
        }
        guard !changes.isEmpty else { return nil }

        let summaryText = changes
            .prefix(3)
            .map { "\"\($0.0)\" → \"\($0.1)\"" }
            .joined(separator: "; ")
        let stateIndicators = changes
            .prefix(5)
            .map { "Updated value: \($0.1)" }

        return ContextGeminiLaneObservation(
            id: UUID().uuidString,
            observedAt: Date(),
            source: .gemini,
            model: "ocr-delta",
            promptVersion: "tier0",
            imageHash: "",
            lane: .update,
            appLabel: currentSnapshot.appName,
            windowTitle: currentSnapshot.windowTitle,
            surfaceID: "",
            surfaceLabel: "",
            screenType: "",
            summary: "Local text update inside known region: \(summaryText)",
            primaryTask: "",
            contentSummary: "",
            layoutRegions: [],
            controls: [],
            entities: [],
            stateIndicators: stateIndicators,
            workflows: [],
            navigation: [],
            negativeCues: [],
            memoryCards: [],
            uncertainty: ["Inferred from OCR diff inside dirty bbox; no LLM verification."],
            confidence: 0.65
        )
    }

    private static func ocrItems(insideNormalized bbox: CGRect, snapshot: ContextSnapshot) -> [ContextRecognizedText] {
        snapshot.recognizedText.filter { item in
            // Vision OCR origin is top-left, normalized 0...1.
            let itemRect = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
            return bbox.intersects(itemRect)
        }
    }

    private static func ocrSortKey(_ item: ContextRecognizedText) -> Double {
        // Sort top-to-bottom then left-to-right so zip(prev, curr) lines up.
        item.y * 1000 + item.x
    }

    private static func geminiLanes(
        for snapshot: ContextSnapshot,
        previousSnapshot: ContextSnapshot?
    ) -> [ContextGeminiObservationLane] {
        var lanes: [ContextGeminiObservationLane] = [.activity, .uiMap, .entityContent]
        if previousSnapshot != nil, snapshot.trigger == .click || snapshot.trigger == .appSwitch || snapshot.trigger == .manual {
            lanes.append(.interaction)
        }
        return lanes
    }

    private static func geminiMetadata(
        for snapshot: ContextSnapshot,
        previousSnapshot: ContextSnapshot?
    ) -> [String: String] {
        var metadata = [
            "captureTrigger": snapshot.trigger.rawValue
        ]
        if let cursorLocation = snapshot.cursorLocation {
            metadata["cursor"] = "x=\(Int(cursorLocation.x)), y=\(Int(cursorLocation.y))"
        }
        if let previousSnapshot {
            metadata["previousApp"] = previousSnapshot.appName
            metadata["previousWindow"] = previousSnapshot.windowTitle
            metadata["previousTrigger"] = previousSnapshot.trigger.rawValue
        }
        return metadata
    }

    private static func controlDescriptions(_ controls: [ContextGeminiObservation.VisibleControl]) -> [String] {
        controls.map { control -> String in
            if let actionHint = control.actionHint, !actionHint.isEmpty {
                return "\(control.label) (\(control.role), \(control.region)): \(actionHint)"
            }
            return "\(control.label) (\(control.role), \(control.region))"
        }
    }

    private static func textPreview(from snapshot: ContextSnapshot) -> String {
        ContextTextSignalFilter.usefulText(from: snapshot.recognizedText, maxCount: 8)
            .joined(separator: " | ")
    }

    private static func shouldIgnoreCapture(_ metadata: ContextWindowMetadata) -> Bool {
        let appName = metadata.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let windowTitle = metadata.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return appName == "agentnotch"
            || appName == "agent in the notch"
            || windowTitle.contains("agentnotch dev tools")
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
