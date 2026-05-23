//
//  ScreenCapture.swift
//  Agent in the Notch
//
//  Shared between the context module (click-triggered captures) and the
//  computer-use harness (snapshot tool call). Uses ScreenCaptureKit on
//  macOS 14+.
//
//  Performance notes:
//  - JPEG-only encode (PNG path removed; both pipelines accept JPEG).
//  - Optional downsample to maxLongEdge (default 1568px) — matches the size
//    Anthropic auto-downsamples to anyway, so we save tokens + TTFT with
//    zero quality loss.
//

import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

public actor ScreenCapture {
    public static let shared = ScreenCapture()

    public struct Snapshot: Sendable {
        public let jpegData: Data
        public let width: Int
        public let height: Int
        public let scale: CGFloat
        public let capturedAt: Date
        /// Full-resolution CGImage BEFORE the downsample step. Used for OCR
        /// so small UI text stays readable. Nil only if the raw capture is
        /// unavailable. Holds a Core Graphics reference — don't retain past
        /// the immediate capture turn.
        public let rawImage: CGImage?

        public init(jpegData: Data, width: Int, height: Int, scale: CGFloat, capturedAt: Date, rawImage: CGImage? = nil) {
            self.jpegData = jpegData
            self.width = width
            self.height = height
            self.scale = scale
            self.capturedAt = capturedAt
            self.rawImage = rawImage
        }
    }

    /// Maps coordinates the MODEL emits (in the WXGA-ish target space) back
    /// to the OS's logical-point space that CGEvent / CGWarpMouseCursor use.
    /// Center-crop semantics: when the source aspect differs from the target,
    /// we crop a centered rectangle of the source before scaling, so the
    /// inverse on a (mx, my) click is:
    ///     logicalX = cropOriginLogical.x + (mx / target.width)  * cropSizeLogical.width
    ///     logicalY = cropOriginLogical.y + (my / target.height) * cropSizeLogical.height
    public struct CoordTransform: Sendable, Equatable {
        /// What the model sees + emits coordinates in (e.g. 1280x800).
        public var targetSize: CGSize
        /// The cropped rectangle of the source the target image was derived from,
        /// in logical points (top-left origin).
        public var cropRectLogical: CGRect

        public init(targetSize: CGSize, cropRectLogical: CGRect) {
            self.targetSize = targetSize
            self.cropRectLogical = cropRectLogical
        }

        public func toLogical(_ modelPoint: CGPoint) -> CGPoint {
            let sx = cropRectLogical.width  / max(1, targetSize.width)
            let sy = cropRectLogical.height / max(1, targetSize.height)
            return CGPoint(
                x: cropRectLogical.minX + modelPoint.x * sx,
                y: cropRectLogical.minY + modelPoint.y * sy
            )
        }

        /// Identity (no crop / no scale). Use as a safe fallback if a real
        /// capture has not happened yet.
        public static func identity(size: CGSize) -> CoordTransform {
            CoordTransform(
                targetSize: size,
                cropRectLogical: CGRect(origin: .zero, size: size)
            )
        }
    }

    /// Bundle for the harness path: JPEG + dimensions + the coord transform
    /// the model's click coordinates have to be inverted through.
    public struct TargetSnapshot: Sendable {
        public let jpegData: Data
        public let width: Int
        public let height: Int
        public let transform: CoordTransform
        public let capturedAt: Date
        /// Full-res raw image (pre-crop, pre-scale) for OCR + adapters.
        public let rawImage: CGImage?
    }

    public init() {}

    /// Capture a JPEG of the (primary) display.
    ///
    /// - Parameters:
    ///   - displayId: Specific display to capture. nil = first display.
    ///   - quality: JPEG compression quality 0...1.
    ///   - maxLongEdge: Downsample so the longest edge ≤ this. nil = no resize.
    public func snapshot(
        displayId: CGDirectDisplayID? = nil,
        quality: CGFloat = 0.7,
        maxLongEdge: Int? = 1568
    ) async throws -> Snapshot {
        return try await snapshotViaSCKit(displayId: displayId, quality: quality, maxLongEdge: maxLongEdge)
    }

    /// Computer-use harness path. Center-crops the source display to match the
    /// target aspect ratio, scales to the exact target dimensions, returns the
    /// JPEG plus the CoordTransform the harness needs to invert click
    /// coordinates back to logical-point space.
    ///
    /// Why fixed target dimensions: Anthropic's computer-use models are most
    /// accurate when the screenshot dimensions match one of their canonical
    /// targets (XGA 1024x768, WXGA 1280x800, FWXGA 1366x768). We hard-pick
    /// WXGA — most MacBook Pro displays are 16:10 (≈1.6 aspect), the same
    /// aspect as 1280x800, so the center-crop on those displays is a no-op.
    public func targetSnapshot(
        displayId: CGDirectDisplayID? = nil,
        target: CGSize,
        quality: CGFloat = 0.75
    ) async throws -> TargetSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display: SCDisplay?
        if let id = displayId {
            display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first
        } else {
            display = content.displays.first
        }
        guard let display else {
            throw NSError(domain: "ScreenCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        let scale = display.pointPixelScale()
        cfg.width = Int(CGFloat(display.width) * scale)
        cfg.height = Int(CGFloat(display.height) * scale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = true

        let raw = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

        let srcW = CGFloat(raw.width)
        let srcH = CGFloat(raw.height)
        let srcAspect = srcW / max(1, srcH)
        let tgtAspect = target.width / max(1, target.height)

        // Center-crop the source (in pixel space) so its aspect matches target.
        let cropPixel: CGRect = {
            if srcAspect > tgtAspect {
                let newW = srcH * tgtAspect
                let originX = (srcW - newW) / 2.0
                return CGRect(x: originX, y: 0, width: newW, height: srcH)
            } else if srcAspect < tgtAspect {
                let newH = srcW / tgtAspect
                let originY = (srcH - newH) / 2.0
                return CGRect(x: 0, y: originY, width: srcW, height: newH)
            } else {
                return CGRect(x: 0, y: 0, width: srcW, height: srcH)
            }
        }()

        guard let cropped = raw.cropping(to: cropPixel) else {
            throw NSError(domain: "ScreenCapture", code: -3, userInfo: [NSLocalizedDescriptionKey: "Crop failed"])
        }

        // Now scale the cropped image to exact target dimensions.
        let outW = Int(target.width)
        let outH = Int(target.height)
        guard let cs = cropped.colorSpace,
              let ctx = CGContext(
                  data: nil, width: outW, height: outH,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw NSError(domain: "ScreenCapture", code: -4, userInfo: [NSLocalizedDescriptionKey: "Context alloc failed"])
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let scaled = ctx.makeImage(),
              let jpeg = jpegEncode(scaled, quality: quality) else {
            throw NSError(domain: "ScreenCapture", code: -5, userInfo: [NSLocalizedDescriptionKey: "JPEG encode failed"])
        }

        // Convert the pixel-space crop to logical points by dividing out the
        // capture scale. CGEvent operates on logical points.
        let cropLogical = CGRect(
            x: cropPixel.minX / scale,
            y: cropPixel.minY / scale,
            width: cropPixel.width / scale,
            height: cropPixel.height / scale
        )
        let transform = CoordTransform(
            targetSize: target,
            cropRectLogical: cropLogical
        )

        return TargetSnapshot(
            jpegData: jpeg,
            width: outW,
            height: outH,
            transform: transform,
            capturedAt: Date(),
            rawImage: raw
        )
    }

    // MARK: - ScreenCaptureKit path

    private func snapshotViaSCKit(displayId: CGDirectDisplayID?, quality: CGFloat, maxLongEdge: Int?) async throws -> Snapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display: SCDisplay?
        if let id = displayId {
            display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first
        } else {
            display = content.displays.first
        }
        guard let display else {
            throw NSError(domain: "ScreenCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        let scale = display.pointPixelScale()
        cfg.width = Int(CGFloat(display.width) * scale)
        cfg.height = Int(CGFloat(display.height) * scale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = true

        let raw = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let image = downsample(raw, maxLongEdge: maxLongEdge)
        guard let jpeg = jpegEncode(image, quality: quality) else {
            throw NSError(domain: "ScreenCapture", code: -2, userInfo: [NSLocalizedDescriptionKey: "JPEG encode failed"])
        }
        return Snapshot(
            jpegData: jpeg,
            width: image.width,
            height: image.height,
            scale: scale,
            capturedAt: Date(),
            rawImage: raw
        )
    }

    private func downsample(_ image: CGImage, maxLongEdge: Int?) -> CGImage {
        guard let maxLongEdge else { return image }
        let longest = max(image.width, image.height)
        guard longest > maxLongEdge else { return image }
        let scale = CGFloat(maxLongEdge) / CGFloat(longest)
        let newW = Int(CGFloat(image.width) * scale)
        let newH = Int(CGFloat(image.height) * scale)
        guard let cs = image.colorSpace,
              let ctx = CGContext(
                  data: nil,
                  width: newW,
                  height: newH,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    private func jpegEncode(_ image: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

private let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

private extension SCDisplay {
    func pointPixelScale() -> CGFloat {
        let match = NSScreen.screens.first { screen in
            let desc = screen.deviceDescription[screenNumberKey] as? NSNumber
            return desc?.uint32Value == displayID
        }
        return match?.backingScaleFactor ?? 2.0
    }
}
