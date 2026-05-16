//
//  CursorTracker.swift
//  Agent in the Notch
//
//  120Hz polling of NSEvent.mouseLocation. Repositions the companion window.
//  Polling beats CGEventTap on mouseMoved here — no Accessibility cost for
//  this layer alone, and 120Hz on a single timer is cheap.
//

import AppKit
import Foundation

@MainActor
final class CursorTracker {
    private let window: CursorCompanionWindow
    private var timer: DispatchSourceTimer?
    private let interval: DispatchTimeInterval = .milliseconds(8) // ~120Hz

    init(window: CursorCompanionWindow) {
        self.window = window
    }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let location = NSEvent.mouseLocation
        window.reposition(toCursorTip: location)
    }
}
