//
//  CursorCompanion.swift
//  Agent in the Notch
//
//  Top-level coordinator for Sam's cursor module. Owns window + tracker +
//  long-press detector. Registers itself as AgentInterfaces.cursor so Wyatt's
//  settings panel can flip the color via setCursorColor.
//

import AppKit
import Combine

@MainActor
public final class CursorCompanion: CursorAppearanceSetting {
    public static let shared = CursorCompanion()

    private let viewModel: CursorCompanionViewModel
    private let window: CursorCompanionWindow
    private let tracker: CursorTracker
    private let longPress: LongPressDetector

    private var listeningObserver: NSObjectProtocol?
    private var endedObserver: NSObjectProtocol?
    private var settingsCancellable: AnyCancellable?

    private init() {
        let initialColor = AgentSettingsStore.shared.cursorColor
        let vm = CursorCompanionViewModel(color: initialColor)
        self.viewModel = vm
        self.window = CursorCompanionWindow(viewModel: vm)
        self.tracker = CursorTracker(window: window)
        self.longPress = LongPressDetector()
    }

    public func start() {
        window.show()
        tracker.start()
        longPress.start()
        wireNotifications()
        wireSettings()
        AgentInterfaces.cursor = self
    }

    public func stop() {
        tracker.stop()
        longPress.stop()
        window.hide()
        let center = NotificationCenter.default
        if let listeningObserver { center.removeObserver(listeningObserver) }
        if let endedObserver { center.removeObserver(endedObserver) }
        listeningObserver = nil
        endedObserver = nil
        settingsCancellable = nil
        AgentInterfaces.cursor = nil
    }

    // MARK: - CursorAppearanceSetting

    public func setCursorColor(_ color: CursorColor) {
        viewModel.color = color
        AgentSettingsStore.shared.cursorColor = color
    }

    public func setThinking(_ thinking: Bool) {
        viewModel.isThinking = thinking
    }

    // MARK: - Agent-driven (detached) mode

    /// Pause the 120Hz follow-user loop and park the sprite at
    /// `initialTarget` (AppKit screen space, bottom-left origin). The agent
    /// driver becomes the sole owner of sprite position until `reattach()`.
    /// Idempotent — calling while already detached just re-parks the sprite.
    public func detach(initialTarget: NSPoint) {
        tracker.pause()
        window.setSpriteCenter(initialTarget)
    }

    /// Resume tracking the real cursor. Idempotent.
    public func reattach() {
        tracker.resume()
    }

    /// Set the sprite center in AppKit screen space. Only meaningful while
    /// detached; if the tracker is live it will overwrite the position on
    /// the next tick. Used by `CursorAnimator` at 120Hz.
    public func setSpriteOriginAbsolute(_ point: NSPoint) {
        window.setSpriteCenter(point)
    }

    // MARK: - Wiring

    private func wireNotifications() {
        let center = NotificationCenter.default
        listeningObserver = center.addObserver(
            forName: .longPressBegan,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.viewModel.isListening = true
            AgentState.shared.set(.listening)
        }

        endedObserver = center.addObserver(
            forName: .longPressEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.viewModel.isListening = false
        }
    }

    private func wireSettings() {
        settingsCancellable = AgentSettingsStore.shared.$settings
            .map(\.cursorColor)
            .removeDuplicates()
            .sink { [weak self] color in
                self?.viewModel.color = color
            }
    }
}
