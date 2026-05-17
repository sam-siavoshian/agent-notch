//
//  LongPressDetector.swift
//  Agent in the Notch
//
//  Long-press detector with drag rejection.
//
//  Fires .longPressBegan when the user holds the left mouse button down for
//  at least `holdThreshold` seconds AND the cursor has moved less than
//  `movementThreshold` points since mouseDown. Any larger movement during
//  the hold cancels the gesture — that's how we distinguish "I want to talk"
//  from drag-select, text selection, or window drag.
//
//  Why not hardware Force Touch:
//    - NSEvent .pressure events are only delivered to the focused app's first
//      responder. Global monitors do NOT receive them.
//    - CGEvent's `kCGMouseEventPressure` field is unreliable across hardware:
//      regular USB mice report constant 1.0 on every drag, non-FT trackpads
//      report ~0.166. We can't threshold reliably without device detection.
//    - Doing real global force-click detection requires private
//      MultitouchSupport.framework. Out of scope for hackathon.
//
//  Tradeoff (unchanged from earlier time-based version): the initial
//  mouseDown is passed through immediately so every click does not pay
//  latency. mouseUp is swallowed only when we have already fired
//  longPressBegan, so the underlying app does not see a phantom click.
//

import ApplicationServices
import Foundation
import CoreGraphics
import os.lock

private let log = Log(category: "longpress")

final class LongPressDetector {
    private enum State {
        case idle
        case pressing(timer: DispatchSourceTimer, startLocation: CGPoint)
        case cancelled  // moved too far; stay here until mouseUp
        case listening
    }

    /// Minimum hold time before we treat it as a long-press.
    private let holdThreshold: TimeInterval = 0.35
    /// Maximum total cursor displacement (in points) during the hold.
    /// Anything beyond this cancels — that's a drag, not a press.
    private let movementThreshold: CGFloat = 6.0

    private let queue = DispatchQueue(label: "agentnotch.longpress", qos: .userInteractive)
    private var lock = os_unfair_lock_s()
    private var state: State = .idle

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard eventTap == nil else { return }

        let trusted = AXIsProcessTrusted()
        log.info("longpress.ax_trusted=\(trusted)")
        if !trusted {
            log.warning("Accessibility not granted — long-press disabled until granted in System Settings > Privacy > Accessibility")
            Task { @MainActor in
                AgentState.shared.set(.error(message: "Accessibility permission missing — long-press disabled"))
            }
        }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.leftMouseUp.rawValue)
                 | (1 << CGEventType.leftMouseDragged.rawValue)
                 | (1 << CGEventType.mouseMoved.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let detector = Unmanaged<LongPressDetector>.fromOpaque(refcon).takeUnretainedValue()
                return detector.handle(type: type, event: event)
            },
            userInfo: opaqueSelf
        ) else {
            log.error("longpress.ready ax_trusted=\(trusted) tap_installed=false reason=tap_create_failed")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        log.info("longpress.ready ax_trusted=\(trusted) tap_installed=true hold_s=\(self.holdThreshold) movement_pt=\(self.movementThreshold)")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Callback (runs on CGEventTap's run-loop thread, must return fast)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            handleMouseDown(at: event.location)
            return Unmanaged.passUnretained(event)

        case .leftMouseDragged, .mouseMoved:
            handleMovement(to: event.location)
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            if handleMouseUp() {
                return Unmanaged.passUnretained(event)
            } else {
                return nil // swallow — user was talking, not clicking
            }

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleMouseDown(at location: CGPoint) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if case .pressing(let oldTimer, _) = state {
            oldTimer.cancel()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + holdThreshold)
        timer.setEventHandler { [weak self] in
            self?.onThresholdCrossed()
        }
        state = .pressing(timer: timer, startLocation: location)
        timer.resume()
    }

    private func handleMovement(to location: CGPoint) {
        os_unfair_lock_lock(&lock)
        guard case .pressing(let timer, let start) = state else {
            os_unfair_lock_unlock(&lock)
            return
        }
        let dx = location.x - start.x
        let dy = location.y - start.y
        let distanceSquared = dx * dx + dy * dy
        let thresholdSquared = movementThreshold * movementThreshold
        if distanceSquared > thresholdSquared {
            timer.cancel()
            state = .cancelled
            os_unfair_lock_unlock(&lock)
            log.debug("long-press cancelled by movement distance=\(distanceSquared.squareRoot())pt")
            return
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Returns true if the mouseUp event should pass through to the OS.
    private func handleMouseUp() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        switch state {
        case .pressing(let timer, _):
            timer.cancel()
            state = .idle
            return true // quick click, let OS handle
        case .cancelled:
            state = .idle
            return true // was a drag, let OS handle the up
        case .listening:
            state = .idle
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .longPressEnded, object: nil)
            }
            return false // swallow — user was talking, not clicking
        case .idle:
            return true
        }
    }

    private func onThresholdCrossed() {
        os_unfair_lock_lock(&lock)
        guard case .pressing = state else {
            os_unfair_lock_unlock(&lock)
            return
        }
        state = .listening
        os_unfair_lock_unlock(&lock)

        log.info("hold threshold crossed without drag → longPressBegan")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .longPressBegan, object: nil)
        }
    }
}
