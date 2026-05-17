//
//  FittsTimer.swift
//  Agent in the Notch
//
//  Fitts's-law-shaped duration for a sprite hop. Bigger move + smaller target
//  = longer, more deliberate motion. Clamped 200-400ms so the agent never
//  feels teleporty (<150ms reads as "no motion") or sluggish (>500ms feels
//  like the agent stalled).
//

import CoreGraphics
import Foundation

public enum FittsTimer {

    /// Constants chosen empirically to land most hops in the 220-350ms band
    /// for screen-sized moves with normal button targets.
    public static let constantMs: Double = 80
    public static let slopeMs: Double = 120
    public static let minDurationMs: Double = 200
    public static let maxDurationMs: Double = 400

    /// Default target width when the caller does not know the actual target
    /// size (typical button is ~40pt wide).
    public static let defaultTargetWidth: CGFloat = 40

    public static func duration(
        from: CGPoint,
        to: CGPoint,
        targetWidth: CGFloat = FittsTimer.defaultTargetWidth
    ) -> TimeInterval {
        let dx = Double(to.x - from.x)
        let dy = Double(to.y - from.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        let width = max(8.0, Double(targetWidth))
        // Shannon-Welford form of Fitts's law: T = a + b * log2(D / W + 1).
        let raw = constantMs + slopeMs * log2(distance / width + 1)
        let clamped = min(max(raw, minDurationMs), maxDurationMs)
        return clamped / 1000.0
    }

    /// Same as `duration` but always returns a fast value (80-150ms) — used
    /// when the user has selected `.fast` motion in settings.
    public static func fastDuration(from: CGPoint, to: CGPoint) -> TimeInterval {
        let dx = Double(to.x - from.x)
        let dy = Double(to.y - from.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        let raw = 60 + 0.06 * distance
        let clamped = min(max(raw, 80), 150)
        return clamped / 1000.0
    }
}
