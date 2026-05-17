//
//  WindMouse.swift
//  Agent in the Notch
//
//  Port of Benjamin J. Land's 2007 WindMouse algorithm — a physics-style
//  integrator that produces human-looking mouse paths. `gravity` pulls toward
//  the target, `wind` adds curvature/jitter, and as the cursor nears the
//  target the step size dampens (Fitts-shaped deceleration). Output is a
//  polyline in logical-point space; the animator indexes into it per tick.
//
//  Pure functions, no UI deps. Safe to call from any actor.
//

import CoreGraphics
import Foundation

public enum WindMouse {

    public struct Parameters: Sendable {
        public var gravity: Double
        public var wind: Double
        public var maxStep: Double
        public var targetArea: Double
        public init(gravity: Double = 9, wind: Double = 3, maxStep: Double = 15, targetArea: Double = 12) {
            self.gravity = gravity
            self.wind = wind
            self.maxStep = maxStep
            self.targetArea = targetArea
        }
        public static let human = Parameters()
    }

    /// Compute a polyline from `start` to `end`. Always begins at `start` and
    /// ends exactly at `end`. Deterministic if `seed` is supplied (useful for
    /// testing); random otherwise.
    public static func path(
        from start: CGPoint,
        to end: CGPoint,
        params: Parameters = .human,
        seed: UInt64? = nil
    ) -> [CGPoint] {
        var rng: any RandomNumberGenerator = seed.map { SplitMix64(state: $0) } ?? SystemRandomNumberGenerator()

        var x = Double(start.x)
        var y = Double(start.y)
        let xe = Double(end.x)
        let ye = Double(end.y)

        var vx = 0.0
        var vy = 0.0
        var wx = 0.0
        var wy = 0.0

        var maxStep = params.maxStep
        let gravity = params.gravity
        var wind = params.wind
        let targetArea = params.targetArea

        var out: [CGPoint] = [start]
        out.reserveCapacity(64)

        // Bound the loop. A 4000pt diagonal at maxStep≈3 is ~1300 points; cap
        // at 4000 as a paranoia limit so a misbehaving param set cannot hang.
        var iterations = 0
        let maxIterations = 4000

        while iterations < maxIterations {
            iterations += 1
            let dx = xe - x
            let dy = ye - y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < 1 { break }

            wind = min(wind, dist)
            if dist >= targetArea {
                wx = wx / .sqrt3 + (Double.random(in: -wind...wind, using: &rng)) / .sqrt5
                wy = wy / .sqrt3 + (Double.random(in: -wind...wind, using: &rng)) / .sqrt5
            } else {
                wx = wx / .sqrt2
                wy = wy / .sqrt2
                if maxStep < 3 {
                    maxStep = Double.random(in: 3...6, using: &rng)
                } else {
                    maxStep = maxStep / .sqrt5
                }
            }

            vx += wx + gravity * dx / dist
            vy += wy + gravity * dy / dist
            let vMag = (vx * vx + vy * vy).squareRoot()
            if vMag > maxStep {
                let clip = maxStep / 2 + Double.random(in: 0...(maxStep / 2), using: &rng)
                vx = (vx / vMag) * clip
                vy = (vy / vMag) * clip
            }

            x += vx
            y += vy
            out.append(CGPoint(x: x, y: y))
        }

        // Always land exactly on target.
        if let last = out.last, last != end {
            out.append(end)
        }
        return out
    }
}

private extension Double {
    static let sqrt2: Double = 1.4142135623730951
    static let sqrt3: Double = 1.7320508075688772
    static let sqrt5: Double = 2.23606797749979
}

/// Deterministic 64-bit PRNG so tests / replays can reproduce paths exactly.
/// Tiny SplitMix64. Not for crypto.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
