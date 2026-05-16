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
    private let capture: ScreenCapture
    private let clickMonitor: ContextClickMonitor

    private var isStarted = false

    private init(
        capture: ScreenCapture = .shared,
        memoryStore: ContextMemoryStore = .shared,
        ocrService: ContextOCRService = .shared,
        geminiObservationService: ContextGeminiObservationService = .shared
    ) {
        self.capture = capture
        self.memoryStore = memoryStore
        self.ocrService = ocrService
        self.geminiObservationService = geminiObservationService
        self.clickMonitor = ContextClickMonitor { location in
            Task {
                await ContextCoordinator.shared.capture(trigger: .click, cursorLocation: location)
            }
        }
    }

    @MainActor
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        AgentInterfaces.context = self
        clickMonitor.start()

        Task {
            await capture(trigger: .startup, cursorLocation: nil)
        }
    }

    @MainActor
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        clickMonitor.stop()
        if AgentInterfaces.context === self {
            AgentInterfaces.context = nil
        }
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

    public func captureCurrentScreenForDebug() async {
        let cursorLocation = await MainActor.run {
            NSEvent.mouseLocation
        }
        await capture(trigger: .manual, cursorLocation: cursorLocation)
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
                hasLearnedMemory: false
            )
        }

        let learnedMemory = await memoryStore.activationMemory(appName: latest.appName)
        return ContextDiagnostics(
            snapshotCount: snapshots.count,
            latestAppName: latest.appName,
            latestWindowTitle: latest.windowTitle,
            latestTrigger: latest.trigger,
            latestRecognizedTextCount: latest.recognizedText.count,
            hasLearnedMemory: !learnedMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    public func capture(trigger: ContextCaptureTrigger, cursorLocation: CGPoint?) async {
        let metadata = await MainActor.run {
            ContextWindowMetadataReader.current()
        }

        do {
            let snapshot = try await capture.snapshot(quality: 0.55)
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
            scheduleGeminiObservation(for: contextSnapshot)
            NSLog("[ContextCoordinator] Captured \(trigger.rawValue) context for \(metadata.appName) with \(recognizedText.count) OCR text items")
        } catch {
            NSLog("[ContextCoordinator] Capture failed: \(error)")
        }
    }

    private func scheduleGeminiObservation(for snapshot: ContextSnapshot) {
        guard snapshot.trigger != .activation else { return }
        guard ContextGeminiObservationService.isAPIKeyConfigured else { return }

        let geminiObservationService = geminiObservationService
        let memoryStore = memoryStore
        Task(priority: .utility) { [snapshot] in
            let startedAt = Date()
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

            guard let observation else { return }

            await memoryStore.record(
                observation,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                capturedAt: snapshot.capturedAt
            )
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            NSLog("[ContextCoordinator] Gemini learned \(observation.appLabel) / \(observation.surfaceLabel) in \(elapsedMilliseconds)ms, confidence \(observation.confidence)")
        }
    }

    private static func textPreview(from snapshot: ContextSnapshot) -> String {
        ContextTextSignalFilter.usefulText(from: snapshot.recognizedText, maxCount: 8)
            .joined(separator: " | ")
    }
}
