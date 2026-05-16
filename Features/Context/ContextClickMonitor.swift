//
//  ContextClickMonitor.swift
//  Agent in the Notch
//
//  Passive global click observer. It never swallows events; it only wakes the
//  context coordinator after a debounced click so the app can snapshot what
//  the user just interacted with.
//

import Foundation
import CoreGraphics

final class ContextClickMonitor {
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "agentnotch.context.click-monitor", qos: .utility)
    private let onClick: @Sendable (CGPoint) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastCaptureAt: Date = .distantPast

    init(debounce: TimeInterval = 1.0, onClick: @escaping @Sendable (CGPoint) -> Void) {
        self.debounce = debounce
        self.onClick = onClick
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.leftMouseUp.rawValue)
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<ContextClickMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            NSLog("[ContextClickMonitor] Failed to create event tap. Accessibility permission probably not granted.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
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

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }

        case .leftMouseUp:
            let location = event.location
            queue.async { [weak self] in
                self?.emitClickIfNeeded(location)
            }

        default:
            break
        }
    }

    private func emitClickIfNeeded(_ location: CGPoint) {
        let now = Date()
        guard now.timeIntervalSince(lastCaptureAt) >= debounce else { return }
        lastCaptureAt = now
        onClick(location)
    }
}
