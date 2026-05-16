//
//  ContextCoordinator.swift
//  Agent in the Notch
//
//  Native context feature entry point. Owns click-triggered captures and
//  exposes a compact text packet to AgentSession through AgentInterfaces.
//

import Foundation
import CoreGraphics

public final class ContextCoordinator: RecentActivityContext {
    public static let shared = ContextCoordinator()

    private let store = ContextSnapshotStore(maxSnapshots: 20)
    private let capture: ScreenCapture
    private let clickMonitor: ContextClickMonitor

    private var isStarted = false

    private init(capture: ScreenCapture = .shared) {
        self.capture = capture
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
        await store.recentActivityContext()
    }

    public func recentSnapshots() async -> [ContextSnapshot] {
        await store.recentSnapshots()
    }

    public func capture(trigger: ContextCaptureTrigger, cursorLocation: CGPoint?) async {
        let metadata = await MainActor.run {
            ContextWindowMetadataReader.current()
        }

        do {
            let snapshot = try await capture.snapshot(quality: 0.55)
            await store.record(ContextSnapshot(
                capturedAt: snapshot.capturedAt,
                trigger: trigger,
                appName: metadata.appName,
                windowTitle: metadata.windowTitle,
                cursorLocation: cursorLocation,
                jpegData: snapshot.jpegData,
                width: snapshot.width,
                height: snapshot.height
            ))
            NSLog("[ContextCoordinator] Captured \(trigger.rawValue) context for \(metadata.appName)")
        } catch {
            NSLog("[ContextCoordinator] Capture failed: \(error)")
        }
    }
}
