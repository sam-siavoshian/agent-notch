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

// Private CoreGraphics SPI — public CGCursorIsVisible was retired.
// Resolved dynamically via dlsym so the binary still links cleanly if Apple
// renames or drops the symbol on a future macOS. Falls back to "visible"
// in that case (no false hides).
private let _CGSDefaultConnectionFn: (@convention(c) () -> Int32)? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
}()
private let _CGSCursorIsVisibleFn: (@convention(c) (Int32) -> Bool)? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCursorIsVisible") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Int32) -> Bool).self)
}()

// Connection is stable per-process — resolve once instead of 120Hz.
private let _cgsConnection: Int32? = _CGSDefaultConnectionFn?()

private func systemCursorVisible() -> Bool {
    guard let conn = _cgsConnection,
          let isVisible = _CGSCursorIsVisibleFn else { return true }
    return isVisible(conn)
}

@MainActor
final class CursorTracker {
    private let window: CursorCompanionWindow
    private var timer: DispatchSourceTimer?
    private static let interval: DispatchTimeInterval = .milliseconds(8) // ~120Hz
    private var lastVisible: Bool = true

    init(window: CursorCompanionWindow) {
        self.window = window
    }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(1))
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

    /// Idempotent. Pauses the 120Hz follow-user loop so the agent driver can
    /// own sprite position. Counterpart to `resume()`.
    func pause() {
        stop()
    }

    /// Resume tracking the real cursor. Safe to call multiple times — `start`
    /// already cancels any in-flight timer first.
    func resume() {
        start()
    }

    private func tick() {
        let visible = systemCursorVisible()
        if visible != lastVisible {
            lastVisible = visible
            if visible { window.show() } else { window.hide() }
        }
        guard visible else { return }
        let location = NSEvent.mouseLocation
        window.reposition(toCursorTip: location)
    }
}
