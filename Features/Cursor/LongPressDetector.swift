//
//  LongPressDetector.swift
//  Agent in the Notch
//
//  Session-level CGEventTap that detects a left-mouse-button hold of 350ms+.
//  Emits .longPressBegan when threshold crosses, .longPressEnded on release.
//  Swallows the eventual mouseUp so the underlying app doesn't fire a click.
//
//  Tradeoff: the initial mouseDown is passed through immediately (otherwise
//  every click pays 350ms latency), which means an app that latches state on
//  mouseDown alone (rare on macOS — most fire on mouseUp) will appear stuck
//  until the user clicks elsewhere. Long-press is meant to be performed over
//  the cursor companion or a neutral area, not on a UI control.
//

import ApplicationServices
import Foundation
import CoreGraphics
import os.lock

final class LongPressDetector {
    private enum State {
        case idle
        case pressing(timer: DispatchSourceTimer)
        case listening
    }

    private let threshold: TimeInterval = 0.20
    private let queue = DispatchQueue(label: "agentnotch.longpress", qos: .userInteractive)
    private var lock = os_unfair_lock_s()
    private var state: State = .idle

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard eventTap == nil else { return }

        let trusted = AXIsProcessTrusted()
        NSLog("[LongPressDetector] AXIsProcessTrusted=\(trusted)")
        if !trusted {
            NSLog("[LongPressDetector] WARNING: Accessibility not granted. Open System Settings > Privacy & Security > Accessibility and enable AgentNotch, then relaunch.")
            Task { @MainActor in
                AgentState.shared.set(.error(message: "Accessibility permission missing — long-press disabled"))
            }
        }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.leftMouseUp.rawValue)

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
            NSLog("[LongPressDetector] Failed to create event tap. Accessibility permission probably not granted.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        NSLog("[LongPressDetector] event tap installed (threshold=\(threshold)s)")
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
            handleMouseDown()
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            if handleMouseUp() {
                return Unmanaged.passUnretained(event)
            } else {
                return nil // swallow
            }

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleMouseDown() {
        NSLog("[LongPressDetector] mouseDown")
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if case .pressing(let oldTimer) = state {
            oldTimer.cancel()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + threshold)
        timer.setEventHandler { [weak self] in
            self?.onThresholdCrossed()
        }
        state = .pressing(timer: timer)
        timer.resume()
    }

    /// Returns true if the mouseUp event should pass through to the OS.
    private func handleMouseUp() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        switch state {
        case .pressing(let timer):
            timer.cancel()
            state = .idle
            return true // quick click, let OS handle
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

        NSLog("[LongPressDetector] threshold crossed → posting longPressBegan")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .longPressBegan, object: nil)
        }
    }
}
