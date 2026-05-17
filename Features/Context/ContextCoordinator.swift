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
            scheduleGeminiObservation(
                for: contextSnapshot,
                imageData: snapshot.pngData,
                mimeType: "image/png",
                previousSnapshot: previousSnapshot
            )
            log.info("captured \(trigger.rawValue) for \(metadata.appName) with \(recognizedText.count) OCR items")
        } catch {
            log.error("capture failed: \(error)")
        }
    }

    private func scheduleGeminiObservation(
        for snapshot: ContextSnapshot,
        imageData: Data,
        mimeType: String,
        previousSnapshot: ContextSnapshot?
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
                    ocrCount: snapshot.recognizedText.count
                ))
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

            guard let observation = ContextGeminiObservationService.reduceLaneObservations(
                laneResults,
                input: input,
                imageHash: Self.sha256Hex(imageData)
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
                    ocrCount: snapshot.recognizedText.count
                ))
                return
            }

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
