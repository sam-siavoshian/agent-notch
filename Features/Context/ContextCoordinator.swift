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
            let recognizedText = await ocrService.recognizeText(in: snapshot.jpegData)
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
            scheduleGeminiObservation(for: contextSnapshot, captureArtifact: captureArtifact)
            NSLog("[ContextCoordinator] Captured \(trigger.rawValue) context for \(metadata.appName) with \(recognizedText.count) OCR text items")
        } catch {
            NSLog("[ContextCoordinator] Capture failed: \(error)")
        }
    }

    private func scheduleGeminiObservation(for snapshot: ContextSnapshot, captureArtifact: ContextCaptureDebugArtifact?) {
        let geminiObservationService = geminiObservationService
        let memoryStore = memoryStore
        let aiObservationLog = aiObservationLog
        let geminiGate = geminiGate
        let debugPaths = ContextGeminiObservationService.debugPaths(for: snapshot.jpegData)

        Task(priority: .utility) { [snapshot] in
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
                    imageBytes: snapshot.jpegData.count,
                    ocrCount: snapshot.recognizedText.count,
                    imageHash: debugPaths.imageHash,
                    captureImagePath: captureArtifact?.jpegPath,
                    captureJSONPath: captureArtifact?.jsonPath,
                    promptPath: debugPaths.promptPath,
                    rawResponsePath: debugPaths.rawResponsePath,
                    errorPath: debugPaths.errorPath
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
                reason: "queued for visual UI/UX observation",
                imageBytes: snapshot.jpegData.count,
                ocrCount: snapshot.recognizedText.count,
                imageHash: debugPaths.imageHash,
                captureImagePath: captureArtifact?.jpegPath,
                captureJSONPath: captureArtifact?.jsonPath,
                promptPath: debugPaths.promptPath,
                rawResponsePath: debugPaths.rawResponsePath,
                errorPath: debugPaths.errorPath
            ))
            NSLog("[ContextCoordinator] Gemini observation queued for \(snapshot.appName) / \(snapshot.windowTitle)")
            let observation = await geminiObservationService.observe(
                jpegData: snapshot.jpegData,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                width: snapshot.width,
                height: snapshot.height,
                recognizedText: snapshot.recognizedText,
                metadata: [
                    "captureTrigger": snapshot.trigger.rawValue
                ]
            )
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            await geminiGate.finish()

            guard let observation else {
                await aiObservationLog.record(ContextAIObservationEvent(
                    status: .failed,
                    trigger: snapshot.trigger,
                    appName: snapshot.appName,
                    windowTitle: snapshot.windowTitle,
                    reason: "Gemini returned no valid observation",
                    latencyMilliseconds: elapsedMilliseconds,
                    imageBytes: snapshot.jpegData.count,
                    ocrCount: snapshot.recognizedText.count,
                    imageHash: debugPaths.imageHash,
                    captureImagePath: captureArtifact?.jpegPath,
                    captureJSONPath: captureArtifact?.jsonPath,
                    promptPath: debugPaths.promptPath,
                    rawResponsePath: debugPaths.rawResponsePath,
                    errorPath: debugPaths.errorPath
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
                reason: "recorded \(observation.visibleControls.count) controls, \(observation.affordances.count) affordances, \(observation.entities.count) entities",
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
                imageBytes: snapshot.jpegData.count,
                ocrCount: snapshot.recognizedText.count,
                imageHash: debugPaths.imageHash,
                captureImagePath: captureArtifact?.jpegPath,
                captureJSONPath: captureArtifact?.jsonPath,
                promptPath: debugPaths.promptPath,
                rawResponsePath: debugPaths.rawResponsePath,
                errorPath: debugPaths.errorPath,
                controlsCount: observation.visibleControls.count,
                affordancesCount: observation.affordances.count,
                entitiesCount: observation.entities.count
            ))
            NSLog("[ContextCoordinator] Gemini learned \(observation.appLabel) / \(observation.surfaceLabel) in \(elapsedMilliseconds)ms, confidence \(observation.confidence)")
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
}
