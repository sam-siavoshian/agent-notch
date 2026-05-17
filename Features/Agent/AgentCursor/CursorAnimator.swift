//
//  CursorAnimator.swift
//  Agent in the Notch
//
//  Drives smooth sprite motion using CADisplayLink (macOS 14+). Each tick:
//   1. interpolates the WindMouse polyline by elapsed/duration progress
//   2. moves the sprite via CursorCompanion.setSpriteOriginAbsolute
//   3. posts a synthetic mouseMoved CGEvent at the same point — required so
//      hover-menu / JS mousemove / drag-detection paths in the underlying app
//      receive continuous updates. Posted via postToPid so the user's real
//      cursor does not warp.
//
//  Honors NSWorkspace reduce-motion: if the user has reduced motion enabled,
//  the sprite jumps to the endpoint without animation (still no real cursor
//  movement).
//

import AppKit
import CoreGraphics
import QuartzCore

@MainActor
final class CursorAnimator {
    private var displayLink: CADisplayLink?
    private var polyline: [CGPoint] = []
    private var startedAt: CFTimeInterval = 0
    private var duration: TimeInterval = 0.25
    private var targetPID: pid_t = 0
    private var emitMoves: Bool = true
    private var continuation: CheckedContinuation<Void, Never>?

    func animate(
        polyline: [CGPoint],
        duration: TimeInterval,
        targetPID: pid_t,
        emitMoves: Bool = true
    ) async {
        guard !polyline.isEmpty else { return }
        // Reduce motion: jump straight to endpoint.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || duration <= 0.001 {
            await place(polyline.last!, pid: targetPID, emitMoves: emitMoves)
            return
        }
        // Cancel any in-flight animation.
        finishImmediately()

        self.polyline = polyline
        self.duration = duration
        self.targetPID = targetPID
        self.emitMoves = emitMoves
        self.startedAt = CACurrentMediaTime()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            guard let screen = NSScreen.main else {
                // No screen → no display link possible. Jump to endpoint.
                cont.resume()
                self.continuation = nil
                CursorCompanion.shared.setSpriteOriginAbsolute(polyline.last!)
                if emitMoves { self.postMouseMoved(at: polyline.last!, pid: targetPID) }
                return
            }
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
    }

    /// Place the sprite at a single point without animating. Used for
    /// reduce-motion and as the synchronous "land click" helper.
    func place(_ point: CGPoint, pid: pid_t, emitMoves: Bool) async {
        CursorCompanion.shared.setSpriteOriginAbsolute(point)
        if emitMoves {
            postMouseMoved(at: point, pid: pid)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let elapsed = now - startedAt
        let t = min(max(elapsed / duration, 0), 1)
        let point = sample(progress: t)

        CursorCompanion.shared.setSpriteOriginAbsolute(point)
        if emitMoves {
            postMouseMoved(at: point, pid: targetPID)
        }

        if t >= 1.0 {
            finishImmediately()
        }
    }

    private func finishImmediately() {
        displayLink?.invalidate()
        displayLink = nil
        let cont = continuation
        continuation = nil
        cont?.resume()
    }

    /// Linear sample of the polyline by progress. WindMouse's path already
    /// encodes ease-out via the damped step term, so we do NOT layer
    /// additional easing on top — that would double-decelerate.
    private func sample(progress t: Double) -> CGPoint {
        guard polyline.count > 1 else { return polyline.first ?? .zero }
        if t <= 0 { return polyline.first! }
        if t >= 1 { return polyline.last! }
        let scaled = t * Double(polyline.count - 1)
        let lo = Int(scaled.rounded(.down))
        let hi = min(lo + 1, polyline.count - 1)
        let frac = scaled - Double(lo)
        let a = polyline[lo]
        let b = polyline[hi]
        return CGPoint(
            x: CGFloat(Double(a.x) + (Double(b.x) - Double(a.x)) * frac),
            y: CGFloat(Double(a.y) + (Double(b.y) - Double(a.y)) * frac)
        )
    }

    private func postMouseMoved(at point: CGPoint, pid: pid_t) {
        guard let source = AgentEventSource.shared,
              let event = CGEvent(
                  mouseEventSource: source,
                  mouseType: .mouseMoved,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ) else { return }
        if pid > 0 {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}
