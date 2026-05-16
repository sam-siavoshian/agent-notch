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

public final class ContextCoordinator: RecentActivityContext {
    public static let shared = ContextCoordinator()

    private let store = ContextSnapshotStore(maxSnapshots: 20)
    private let memoryStore: ContextMemoryStore
    private let ocrService: ContextOCRService
    private let geminiObservationService: ContextGeminiObservationService
    private let aiObservationLog: ContextAIObservationLog
    private let geminiGate: ContextGeminiObservationGate
    private let debugArtifactStore: ContextDebugArtifactStore
    private let capture: ScreenCapture
    private let clickMonitor: ContextClickMonitor
    private let appSwitchMonitor: ContextAppSwitchMonitor

    @MainActor private var isStarted = false
    @MainActor private var isGatheringPaused = false

    private init(
        capture: ScreenCapture = .shared,
        memoryStore: ContextMemoryStore = .shared,
        ocrService: ContextOCRService = .shared,
        geminiObservationService: ContextGeminiObservationService = .shared,
        aiObservationLog: ContextAIObservationLog = .shared,
        geminiGate: ContextGeminiObservationGate = ContextGeminiObservationGate(),
        debugArtifactStore: ContextDebugArtifactStore = .shared
    ) {
        self.capture = capture
        self.memoryStore = memoryStore
        self.ocrService = ocrService
        self.geminiObservationService = geminiObservationService
        self.aiObservationLog = aiObservationLog
        self.geminiGate = geminiGate
        self.debugArtifactStore = debugArtifactStore
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

        NSLog("[ContextCoordinator] Context gathering \(paused ? "paused" : "resumed").")
        return isGatheringPaused
    }

    public func getRecentActivityContext() async -> String {
        let cursorLocation = await MainActor.run {
            NSEvent.mouseLocation
        }
        await capture(trigger: .activation, cursorLocation: cursorLocation)
        let snapshots = await store.recentSnapshots()
        let appName = snapshots.last?.appName ?? ""
        let learnedMemory = await memoryStore.activationMemory(appName: appName)
        return await store.recentActivityContext(learnedUIMemory: learnedMemory)
    }

    public func recentSnapshots() async -> [ContextSnapshot] {
        await store.recentSnapshots()
    }

    public func currentActivationPreview() async -> String {
        let snapshots = await store.recentSnapshots()
        let appName = snapshots.last?.appName ?? ""
        let learnedMemory = await memoryStore.activationMemory(appName: appName)
        return await store.recentActivityContext(learnedUIMemory: learnedMemory)
    }

    public func debugSnapshots(limit: Int = 10) async -> [ContextDebugSnapshot] {
        let snapshots = await store.recentSnapshots()
        return snapshots
            .suffix(max(0, limit))
            .reversed()
            .map { snapshot in
                ContextDebugSnapshot(
                    id: snapshot.id,
                    capturedAt: snapshot.capturedAt,
                    trigger: snapshot.trigger,
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    jpegData: snapshot.jpegData,
                    recognizedTextCount: snapshot.recognizedText.count,
                    textPreview: Self.textPreview(from: snapshot)
                )
            }
    }

    public func aiObservationEvents(limit: Int = 20) async -> [ContextAIObservationEvent] {
        await aiObservationLog.recentEvents(limit: limit)
    }

    public func aiObservationSummary() async -> ContextAIObservationSummary {
        await aiObservationLog.summary()
    }

    public func captureCurrentScreenForDebug() async {
        let cursorLocation = await MainActor.run {
            NSEvent.mouseLocation
        }
        await capture(trigger: .manual, cursorLocation: cursorLocation, bypassPause: true)
    }

    public func compareLatestScreenshotForDebug() async {
        guard ContextGeminiObservationService.isAPIKeyConfigured else {
            await aiObservationLog.record(ContextAIObservationEvent(
                status: .skipped,
                trigger: .manual,
                appName: "Gemini comparison",
                windowTitle: "",
                reason: "GEMINI_API_KEY is not configured",
                laneName: "compare"
            ))
            return
        }

        guard let snapshot = await store.recentSnapshots().last else {
            await aiObservationLog.record(ContextAIObservationEvent(
                status: .skipped,
                trigger: .manual,
                appName: "Gemini comparison",
                windowTitle: "",
                reason: "No recent screenshot available to compare",
                laneName: "compare"
            ))
            return
        }

        let attemptID = UUID()
        let variants = Self.comparisonVariants
        let input = ContextGeminiObservationInput(
            imageData: snapshot.jpegData,
            mimeType: "image/jpeg",
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            width: snapshot.width,
            height: snapshot.height,
            recognizedText: snapshot.recognizedText,
            metadata: [
                "captureTrigger": "compare",
                "comparisonLane": ContextGeminiObservationLane.uiMap.rawValue,
                "comparisonPurpose": "same screenshot UI-map quality and latency comparison"
            ]
        )

        await withTaskGroup(of: Void.self) { group in
            for variant in variants {
                group.addTask {
                    let laneName = "compare-\(variant.id)"
                    let debugPaths = ContextGeminiObservationService.debugPaths(
                        for: snapshot.jpegData,
                        mimeType: "image/jpeg",
                        laneName: laneName
                    )
                    await self.aiObservationLog.record(ContextAIObservationEvent(
                        status: .queued,
                        model: variant.model,
                        trigger: .manual,
                        appName: snapshot.appName,
                        windowTitle: snapshot.windowTitle,
                        reason: "queued same-screenshot UI Map comparison for \(variant.label)",
                        attemptID: attemptID,
                        laneName: laneName,
                        imageBytes: snapshot.jpegData.count,
                        requestMimeType: "image/jpeg",
                        requestMediaResolution: variant.mediaResolution,
                        requestThinkingLevel: variant.thinkingLevel,
                        ocrCount: snapshot.recognizedText.count,
                        imageHash: debugPaths.imageHash,
                        requestImagePath: debugPaths.requestImagePath,
                        requestMetadataPath: debugPaths.requestMetadataPath,
                        promptPath: debugPaths.promptPath,
                        rawResponsePath: debugPaths.rawResponsePath,
                        errorPath: debugPaths.errorPath
                    ))

                    let service = ContextGeminiObservationService(
                        model: variant.model,
                        mediaResolutionOverride: variant.mediaResolution,
                        thinkingLevelOverride: variant.thinkingLevel
                    )
                    let startedAt = Date()
                    let observation = await service.observeLane(
                        .uiMap,
                        input: input,
                        previousSnapshot: nil,
                        debugLaneName: laneName
                    )
                    let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)

                    guard let observation else {
                        await self.aiObservationLog.record(ContextAIObservationEvent(
                            status: .failed,
                            model: variant.model,
                            trigger: .manual,
                            appName: snapshot.appName,
                            windowTitle: snapshot.windowTitle,
                            reason: "\(variant.label) returned no valid UI Map comparison output",
                            attemptID: attemptID,
                            laneName: laneName,
                            latencyMilliseconds: elapsedMilliseconds,
                            imageBytes: snapshot.jpegData.count,
                            requestMimeType: "image/jpeg",
                            requestMediaResolution: variant.mediaResolution,
                            requestThinkingLevel: variant.thinkingLevel,
                            ocrCount: snapshot.recognizedText.count,
                            imageHash: debugPaths.imageHash,
                            requestImagePath: debugPaths.requestImagePath,
                            requestMetadataPath: debugPaths.requestMetadataPath,
                            promptPath: debugPaths.promptPath,
                            rawResponsePath: debugPaths.rawResponsePath,
                            errorPath: debugPaths.errorPath
                        ))
                        return
                    }

                    await self.aiObservationLog.record(ContextAIObservationEvent(
                        status: .completed,
                        model: variant.model,
                        trigger: .manual,
                        appName: snapshot.appName,
                        windowTitle: snapshot.windowTitle,
                        reason: "\(variant.label) comparison produced \(observation.controls.count) controls, \(observation.workflows.count) workflows, \(observation.memoryCards.count) memory cards",
                        attemptID: attemptID,
                        laneName: laneName,
                        source: observation.source.rawValue,
                        latencyMilliseconds: elapsedMilliseconds,
                        confidence: observation.confidence,
                        surfaceLabel: observation.surfaceLabel,
                        summary: observation.summary,
                        screenType: observation.screenType,
                        primaryTask: observation.primaryTask,
                        contentSummary: observation.contentSummary,
                        controls: Self.controlDescriptions(observation.controls),
                        landmarks: observation.layoutRegions,
                        entities: observation.entities,
                        affordances: Self.controlDescriptions(observation.controls),
                        stateIndicators: observation.stateIndicators,
                        navigationPaths: observation.navigation,
                        dataRegions: observation.layoutRegions,
                        workflowHints: observation.workflows,
                        negativeCues: observation.negativeCues,
                        memoryCandidates: observation.memoryCards,
                        uncertainty: observation.uncertainty,
                        imageBytes: snapshot.jpegData.count,
                        requestMimeType: "image/jpeg",
                        requestMediaResolution: variant.mediaResolution,
                        requestThinkingLevel: variant.thinkingLevel,
                        ocrCount: snapshot.recognizedText.count,
                        imageHash: debugPaths.imageHash,
                        requestImagePath: debugPaths.requestImagePath,
                        requestMetadataPath: debugPaths.requestMetadataPath,
                        promptPath: debugPaths.promptPath,
                        rawResponsePath: debugPaths.rawResponsePath,
                        errorPath: debugPaths.errorPath,
                        controlsCount: observation.controls.count,
                        affordancesCount: observation.workflows.count,
                        entitiesCount: observation.entities.count
                    ))
                }
            }
        }
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
            NSLog("[ContextCoordinator] Skipped \(trigger.rawValue) capture because context gathering is paused.")
            return
        }

        let metadata = await MainActor.run {
            ContextWindowMetadataReader.current()
        }
        guard !Self.shouldIgnoreCapture(metadata) else {
            NSLog("[ContextCoordinator] Ignored \(trigger.rawValue) capture for AgentNotch UI.")
            return
        }

        do {
            let snapshot = try await capture.snapshot(quality: 0.35)
            let recognizedText = await ocrService.recognizeText(in: snapshot.pngData)
            let previousSnapshot = await store.recentSnapshots().last
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
            await store.record(contextSnapshot)
            await memoryStore.record(contextSnapshot)
            let captureArtifact = await debugArtifactStore.recordCapture(contextSnapshot)
            scheduleGeminiObservation(
                for: contextSnapshot,
                imageData: snapshot.pngData,
                mimeType: "image/png",
                captureArtifact: captureArtifact,
                previousSnapshot: previousSnapshot
            )
            NSLog("[ContextCoordinator] Captured \(trigger.rawValue) context for \(metadata.appName) with \(recognizedText.count) OCR text items")
        } catch {
            NSLog("[ContextCoordinator] Capture failed: \(error)")
        }
    }

    private func scheduleGeminiObservation(
        for snapshot: ContextSnapshot,
        imageData: Data,
        mimeType: String,
        captureArtifact: ContextCaptureDebugArtifact?,
        previousSnapshot: ContextSnapshot?
    ) {
        let geminiObservationService = geminiObservationService
        let memoryStore = memoryStore
        let aiObservationLog = aiObservationLog
        let geminiGate = geminiGate
        let aggregateDebugPaths = ContextGeminiObservationService.debugPaths(for: imageData, mimeType: mimeType)
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

        Task(priority: .utility) { [snapshot, imageData, previousSnapshot, input, lanes] in
            let decision = await geminiGate.startDecision(
                trigger: snapshot.trigger,
                isAPIKeyConfigured: ContextGeminiObservationService.isAPIKeyConfigured
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
                    ocrCount: snapshot.recognizedText.count,
                    imageHash: aggregateDebugPaths.imageHash,
                    requestImagePath: aggregateDebugPaths.requestImagePath,
                    requestMetadataPath: aggregateDebugPaths.requestMetadataPath,
                    captureImagePath: captureArtifact?.jpegPath,
                    captureJSONPath: captureArtifact?.jsonPath,
                    promptPath: aggregateDebugPaths.promptPath,
                    rawResponsePath: aggregateDebugPaths.rawResponsePath,
                    errorPath: aggregateDebugPaths.errorPath
                ))
                NSLog("[ContextCoordinator] Gemini skipped for \(snapshot.appName) / \(snapshot.windowTitle): \(reason)")
                return
            case .run:
                break
            }

            let startedAt = Date()
            await aiObservationLog.record(ContextAIObservationEvent(
                status: .queued,
                trigger: snapshot.trigger,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                reason: "queued modular screen understanding with \(lanes.count) lanes",
                attemptID: attemptID,
                laneName: "modular",
                imageBytes: imageData.count,
                requestMimeType: mimeType,
                requestMediaResolution: mediaResolution,
                requestThinkingLevel: thinkingLevel,
                ocrCount: snapshot.recognizedText.count,
                imageHash: aggregateDebugPaths.imageHash,
                requestImagePath: aggregateDebugPaths.requestImagePath,
                requestMetadataPath: aggregateDebugPaths.requestMetadataPath,
                captureImagePath: captureArtifact?.jpegPath,
                captureJSONPath: captureArtifact?.jsonPath,
                promptPath: aggregateDebugPaths.promptPath,
                rawResponsePath: aggregateDebugPaths.rawResponsePath,
                errorPath: aggregateDebugPaths.errorPath
            ))
            NSLog("[ContextCoordinator] Gemini modular observation queued for \(snapshot.appName) / \(snapshot.windowTitle)")

            let laneResults = await withTaskGroup(of: ContextGeminiLaneObservation?.self) { group in
                for lane in lanes {
                    group.addTask {
                        let laneDebugPaths = ContextGeminiObservationService.debugPaths(
                            for: imageData,
                            mimeType: mimeType,
                            laneName: lane.rawValue
                        )
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
                            ocrCount: snapshot.recognizedText.count,
                            imageHash: laneDebugPaths.imageHash,
                            requestImagePath: laneDebugPaths.requestImagePath,
                            requestMetadataPath: laneDebugPaths.requestMetadataPath,
                            captureImagePath: captureArtifact?.jpegPath,
                            captureJSONPath: captureArtifact?.jsonPath,
                            promptPath: laneDebugPaths.promptPath,
                            rawResponsePath: laneDebugPaths.rawResponsePath,
                            errorPath: laneDebugPaths.errorPath
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
                                ocrCount: snapshot.recognizedText.count,
                                imageHash: laneDebugPaths.imageHash,
                                requestImagePath: laneDebugPaths.requestImagePath,
                                requestMetadataPath: laneDebugPaths.requestMetadataPath,
                                captureImagePath: captureArtifact?.jpegPath,
                                captureJSONPath: captureArtifact?.jsonPath,
                                promptPath: laneDebugPaths.promptPath,
                                rawResponsePath: laneDebugPaths.rawResponsePath,
                                errorPath: laneDebugPaths.errorPath
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
                            imageHash: laneDebugPaths.imageHash,
                            requestImagePath: laneDebugPaths.requestImagePath,
                            requestMetadataPath: laneDebugPaths.requestMetadataPath,
                            captureImagePath: captureArtifact?.jpegPath,
                            captureJSONPath: captureArtifact?.jsonPath,
                            promptPath: laneDebugPaths.promptPath,
                            rawResponsePath: laneDebugPaths.rawResponsePath,
                            errorPath: laneDebugPaths.errorPath,
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

            guard let observation = ContextGeminiObservationService.reduceLaneObservations(
                laneResults,
                input: input,
                imageHash: aggregateDebugPaths.imageHash
            ) else {
                await aiObservationLog.record(ContextAIObservationEvent(
                    status: .failed,
                    trigger: snapshot.trigger,
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    reason: "No modular Gemini lanes returned valid observations",
                    attemptID: attemptID,
                    laneName: ContextGeminiObservationLane.reducer.rawValue,
                    latencyMilliseconds: elapsedMilliseconds,
                    imageBytes: imageData.count,
                    requestMimeType: mimeType,
                    requestMediaResolution: mediaResolution,
                    requestThinkingLevel: thinkingLevel,
                    ocrCount: snapshot.recognizedText.count,
                    imageHash: aggregateDebugPaths.imageHash,
                    requestImagePath: aggregateDebugPaths.requestImagePath,
                    requestMetadataPath: aggregateDebugPaths.requestMetadataPath,
                    captureImagePath: captureArtifact?.jpegPath,
                    captureJSONPath: captureArtifact?.jsonPath,
                    promptPath: aggregateDebugPaths.promptPath,
                    rawResponsePath: aggregateDebugPaths.rawResponsePath,
                    errorPath: aggregateDebugPaths.errorPath
                ))
                return
            }

            await memoryStore.record(
                observation,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                capturedAt: snapshot.capturedAt
            )
            let controls = observation.visibleControls.map { control -> String in
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
                imageHash: aggregateDebugPaths.imageHash,
                requestImagePath: aggregateDebugPaths.requestImagePath,
                requestMetadataPath: aggregateDebugPaths.requestMetadataPath,
                captureImagePath: captureArtifact?.jpegPath,
                captureJSONPath: captureArtifact?.jsonPath,
                promptPath: aggregateDebugPaths.promptPath,
                rawResponsePath: aggregateDebugPaths.rawResponsePath,
                errorPath: aggregateDebugPaths.errorPath,
                controlsCount: observation.visibleControls.count,
                affordancesCount: observation.affordances.count,
                entitiesCount: observation.entities.count
            ))
            NSLog("[ContextCoordinator] Gemini modular lanes learned \(observation.appLabel) / \(observation.surfaceLabel) in \(elapsedMilliseconds)ms, confidence \(observation.confidence)")
        }
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

    private struct GeminiComparisonVariant: Sendable {
        let id: String
        let label: String
        let model: String
        let mediaResolution: String
        let thinkingLevel: String
    }

    private static let comparisonVariants: [GeminiComparisonVariant] = [
        GeminiComparisonVariant(
            id: "31-lite-min",
            label: "Gemini 3.1 Flash-Lite minimal",
            model: "gemini-3.1-flash-lite",
            mediaResolution: "MEDIA_RESOLUTION_HIGH",
            thinkingLevel: "minimal"
        ),
        GeminiComparisonVariant(
            id: "31-lite-low",
            label: "Gemini 3.1 Flash-Lite low",
            model: "gemini-3.1-flash-lite",
            mediaResolution: "MEDIA_RESOLUTION_HIGH",
            thinkingLevel: "low"
        ),
        GeminiComparisonVariant(
            id: "3-flash-min",
            label: "Gemini 3 Flash minimal",
            model: "gemini-3-flash",
            mediaResolution: "MEDIA_RESOLUTION_HIGH",
            thinkingLevel: "minimal"
        ),
        GeminiComparisonVariant(
            id: "3-flash-low",
            label: "Gemini 3 Flash low",
            model: "gemini-3-flash",
            mediaResolution: "MEDIA_RESOLUTION_HIGH",
            thinkingLevel: "low"
        )
    ]

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
}
