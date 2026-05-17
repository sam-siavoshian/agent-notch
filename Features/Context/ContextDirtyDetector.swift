//
//  ContextDirtyDetector.swift
//  Agent in the Notch
//
//  Perceptual-hash (dHash) + downscaled pixel-diff classifier for screen
//  snapshots. Used to skip Gemini fan-out when the screen has not meaningfully
//  changed since the previous capture.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Compact signature for a captured screenshot. Cheap to compute, cheap to
/// store, cheap to diff.
public struct ContextDirtySignature: Sendable {
    /// 64-bit dHash (9x8 grayscale, adjacent-pixel difference).
    public let dHash: UInt64
    /// Grayscale 256x256 sample of the masked screenshot (junk regions zeroed
    /// out). 65,536 bytes per snapshot — small enough to keep in the rolling
    /// store, large enough to compute a useful bounding box.
    public let downscaledGrayscale: Data
    /// Width of the downscaled sample (always `ContextDirtyDetector.downscaleSize`).
    public let width: Int
    /// Height of the downscaled sample.
    public let height: Int

    public init(dHash: UInt64, downscaledGrayscale: Data, width: Int, height: Int) {
        self.dHash = dHash
        self.downscaledGrayscale = downscaledGrayscale
        self.width = width
        self.height = height
    }
}

/// Result of comparing two signatures.
public struct ContextDirtyComparison: Sendable {
    public let hammingDistance: Int
    /// Fraction of downscaled pixels that exceed the noise threshold, 0...1.
    public let changedAreaFraction: Double
    public let classification: ContextDirtyClassification
    /// Bounding rect of the changed region in normalized 0...1 screen coords
    /// (origin top-left). nil when no meaningful diff. Used by the coordinator
    /// to crop screenshots before sending to Gemini's update lane.
    public let dirtyBoundingRect: CGRect?

    public init(
        hammingDistance: Int,
        changedAreaFraction: Double,
        classification: ContextDirtyClassification,
        dirtyBoundingRect: CGRect? = nil
    ) {
        self.hammingDistance = hammingDistance
        self.changedAreaFraction = changedAreaFraction
        self.classification = classification
        self.dirtyBoundingRect = dirtyBoundingRect
    }
}

public enum ContextDirtyClassification: String, Sendable {
    case unchanged
    case minorChange
    case majorChange

    public var label: String {
        switch self {
        case .unchanged: return "unchanged"
        case .minorChange: return "minor_change"
        case .majorChange: return "major_change"
        }
    }
}

/// Tunable thresholds. Values may drift slightly during a session via the
/// adaptive logic in `ContextCoordinator`.
public struct ContextDirtyThresholds: Sendable {
    public var unchangedHamming: Int
    public var unchangedAreaFraction: Double
    public var minorHamming: Int
    public var minorAreaFraction: Double
    /// Per-channel byte delta that counts as "changed" when diffing 8-bit
    /// grayscale samples. Above this is real movement, below is sensor noise
    /// / antialias jitter.
    public var pixelNoiseThreshold: UInt8

    public init(
        unchangedHamming: Int = 4,
        unchangedAreaFraction: Double = 0.01,
        minorHamming: Int = 15,
        minorAreaFraction: Double = 0.08,
        pixelNoiseThreshold: UInt8 = 18
    ) {
        self.unchangedHamming = unchangedHamming
        self.unchangedAreaFraction = unchangedAreaFraction
        self.minorHamming = minorHamming
        self.minorAreaFraction = minorAreaFraction
        self.pixelNoiseThreshold = pixelNoiseThreshold
    }

    public static let `default` = ContextDirtyThresholds()
}

public enum ContextDirtyDetector {
    /// Edge length of the masked downscaled sample used for area diffing.
    public static let downscaleSize: Int = 256

    /// Compute a signature for one screenshot. Returns nil if the image bytes
    /// could not be decoded (rare — only happens for corrupt captures).
    public static func signature(
        from imageData: Data,
        screenWidth: Int?,
        screenHeight: Int?
    ) -> ContextDirtySignature? {
        guard let cgImage = makeCGImage(from: imageData) else { return nil }

        let dHash = computeDHash(from: cgImage)
        let downscaled = downscaledMaskedGrayscale(
            from: cgImage,
            originalWidth: screenWidth ?? cgImage.width,
            originalHeight: screenHeight ?? cgImage.height
        )
        return ContextDirtySignature(
            dHash: dHash,
            downscaledGrayscale: downscaled,
            width: downscaleSize,
            height: downscaleSize
        )
    }

    /// Compare two signatures and classify the change.
    public static func compare(
        current: ContextDirtySignature,
        previous: ContextDirtySignature,
        thresholds: ContextDirtyThresholds = .default
    ) -> ContextDirtyComparison {
        let hamming = hammingDistance(current.dHash, previous.dHash)
        let (changedArea, dirtyRect) = changedAreaAndBoundingRect(
            current: current.downscaledGrayscale,
            previous: previous.downscaledGrayscale,
            sampleSize: current.width,
            noiseThreshold: thresholds.pixelNoiseThreshold
        )
        let classification = classify(
            hamming: hamming,
            changedArea: changedArea,
            thresholds: thresholds
        )
        return ContextDirtyComparison(
            hammingDistance: hamming,
            changedAreaFraction: changedArea,
            classification: classification,
            dirtyBoundingRect: dirtyRect
        )
    }

    public static func classify(
        hamming: Int,
        changedArea: Double,
        thresholds: ContextDirtyThresholds
    ) -> ContextDirtyClassification {
        if hamming <= thresholds.unchangedHamming && changedArea < thresholds.unchangedAreaFraction {
            return .unchanged
        }
        if hamming > thresholds.minorHamming || changedArea > thresholds.minorAreaFraction {
            return .majorChange
        }
        return .minorChange
    }

    // MARK: - dHash

    private static func computeDHash(from cgImage: CGImage) -> UInt64 {
        let width = 9
        let height = 8
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                  data: &bytes,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else {
            return 0
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                let left = bytes[row * width + col]
                let right = bytes[row * width + col + 1]
                if left > right {
                    hash |= (UInt64(1) << bit)
                }
                bit += 1
            }
        }
        return hash
    }

    /// Population count of the XOR of two 64-bit hashes — number of differing
    /// bits.
    public static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    // MARK: - Downscaled masked sample

    private static func downscaledMaskedGrayscale(
        from cgImage: CGImage,
        originalWidth: Int,
        originalHeight: Int
    ) -> Data {
        let size = downscaleSize
        var bytes = [UInt8](repeating: 0, count: size * size)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                  data: &bytes,
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bytesPerRow: size,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else {
            return Data(bytes)
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        applyMasks(
            to: &bytes,
            sampleSize: size,
            originalWidth: max(1, originalWidth),
            originalHeight: max(1, originalHeight)
        )
        return Data(bytes)
    }

    /// Zero out menu-bar / dock / clock regions on the downscaled sample so they
    /// don't trip dirty detection on their own.
    private static func applyMasks(
        to bytes: inout [UInt8],
        sampleSize size: Int,
        originalWidth: Int,
        originalHeight: Int
    ) {
        // CGContext default coordinate system has y growing upward. After
        // `draw(_:in:)` with the rect we used, image row 0 in the byte buffer
        // corresponds to the *bottom* of the screen, and row (size-1) the top.
        let xScale = Double(size) / Double(originalWidth)
        let yScale = Double(size) / Double(originalHeight)

        // 1) Menu bar: top 32 pixels of the screen → top of the image →
        //    high-index rows in the byte buffer.
        let menuBarRows = max(1, Int((32.0 * yScale).rounded(.up)))
        let menuStartRow = max(0, size - menuBarRows)
        zeroRows(in: &bytes, sampleSize: size, fromRow: menuStartRow, toRowExclusive: size)

        // 2) Dock area: bottom 80 pixels of the screen → low-index rows.
        let dockRows = max(1, Int((80.0 * yScale).rounded(.up)))
        zeroRows(in: &bytes, sampleSize: size, fromRow: 0, toRowExclusive: min(size, dockRows))

        // 3) Clock / notifications strip in the upper-right: roughly 250x24
        //    pixels in the top-right of the screen. Sits inside the menu bar
        //    but we mask explicitly in case the menu-bar height differs.
        let clockWidth = max(1, Int((250.0 * xScale).rounded(.up)))
        let clockHeight = max(1, Int((24.0 * yScale).rounded(.up)))
        let clockStartX = max(0, size - clockWidth)
        let clockStartRow = max(0, size - clockHeight)
        zeroRect(
            in: &bytes,
            sampleSize: size,
            startX: clockStartX,
            startRow: clockStartRow,
            width: clockWidth,
            height: clockHeight
        )
    }

    private static func zeroRows(in bytes: inout [UInt8], sampleSize size: Int, fromRow: Int, toRowExclusive: Int) {
        guard fromRow < toRowExclusive, fromRow < size else { return }
        let start = fromRow * size
        let end = min(size * size, toRowExclusive * size)
        guard end > start else { return }
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            (base + start).update(repeating: 0, count: end - start)
        }
    }

    private static func zeroRect(
        in bytes: inout [UInt8],
        sampleSize size: Int,
        startX: Int,
        startRow: Int,
        width: Int,
        height: Int
    ) {
        for row in startRow..<min(size, startRow + height) {
            let base = row * size
            let xEnd = min(size, startX + width)
            for column in startX..<xEnd {
                bytes[base + column] = 0
            }
        }
    }

    // MARK: - Area diff

    /// Returns both the fraction of pixels that changed AND the bounding rect
    /// of the changed region in normalized 0...1 screen coords (origin
    /// top-left). The downscaled sample stores row 0 at the bottom of the
    /// screen (CGContext convention), so we flip when building the rect.
    private static func changedAreaAndBoundingRect(
        current: Data,
        previous: Data,
        sampleSize size: Int,
        noiseThreshold: UInt8
    ) -> (Double, CGRect?) {
        let count = min(current.count, previous.count)
        guard count > 0, size > 0 else { return (1.0, nil) }
        var changed = 0
        var minX = size, minY = size, maxX = -1, maxY = -1
        current.withUnsafeBytes { currentRaw in
            previous.withUnsafeBytes { previousRaw in
                guard let currentPtr = currentRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let previousPtr = previousRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }
                let threshold = Int(noiseThreshold)
                var x = 0
                var y = 0
                for index in 0..<count {
                    let delta = Int(currentPtr[index]) - Int(previousPtr[index])
                    let magnitude = delta < 0 ? -delta : delta
                    if magnitude > threshold {
                        changed += 1
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                    x += 1
                    if x == size { x = 0; y += 1 }
                }
            }
        }
        let fraction = Double(changed) / Double(count)
        guard maxX >= 0, maxY >= 0 else { return (fraction, nil) }

        // Flip y to top-origin and normalize.
        let widthFraction = Double(maxX - minX + 1) / Double(size)
        let heightFraction = Double(maxY - minY + 1) / Double(size)
        let xFraction = Double(minX) / Double(size)
        // Sample row 0 is bottom of screen, so top-origin y = size - 1 - maxY.
        let topY = Double(size - 1 - maxY) / Double(size)
        let rect = CGRect(x: xFraction, y: topY, width: widthFraction, height: heightFraction)
        return (fraction, rect)
    }

    // MARK: - Crop + thumbnail

    /// Crop the full-screen image to the dirty bounding rect (normalized
    /// 0...1, top-origin) with padding so the model has surrounding context.
    /// Always expands the bbox to at least `minEdgePixels` square to keep the
    /// crop interpretable. Returns PNG bytes, or nil if the image can't be
    /// decoded or the bbox is degenerate.
    public static func croppedPNG(
        from imageData: Data,
        normalizedBBox: CGRect,
        paddingPixels: Int = 96,
        minEdgePixels: Int = 384
    ) -> Data? {
        guard let cgImage = makeCGImage(from: imageData) else { return nil }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 0, h > 0 else { return nil }

        let pad = CGFloat(paddingPixels)
        let minEdge = CGFloat(minEdgePixels)
        var x = normalizedBBox.minX * w - pad
        var y = normalizedBBox.minY * h - pad
        var width = normalizedBBox.width * w + pad * 2
        var height = normalizedBBox.height * h + pad * 2

        if width < minEdge {
            let extra = (minEdge - width) / 2
            x -= extra
            width = minEdge
        }
        if height < minEdge {
            let extra = (minEdge - height) / 2
            y -= extra
            height = minEdge
        }
        x = max(0, min(w - 1, x))
        y = max(0, min(h - 1, y))
        width = min(w - x, width)
        height = min(h - y, height)

        // CGImage origin is top-left, matching our normalized space.
        let cropRect = CGRect(x: x, y: y, width: width, height: height).integral
        guard cropRect.width > 1, cropRect.height > 1,
              let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return encodePNG(cropped)
    }

    /// Downsample the full screenshot to a small thumbnail (longest edge ==
    /// `maxEdge`) used as an orientation image alongside a focused crop.
    public static func thumbnailPNG(from imageData: Data, maxEdge: Int = 480) -> Data? {
        guard let cgImage = makeCGImage(from: imageData) else { return nil }
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        let scale = Double(maxEdge) / Double(max(w, h))
        if scale >= 1.0 { return encodePNG(cgImage) }
        let newW = max(1, Int(Double(w) * scale))
        let newH = max(1, Int(Double(h) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: newW,
                  height: newH,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let scaled = context.makeImage() else { return nil }
        return encodePNG(scaled)
    }

    private static func encodePNG(_ cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Decoding

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
