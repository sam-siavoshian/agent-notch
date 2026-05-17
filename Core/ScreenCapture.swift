//
//  ScreenCapture.swift
//  Agent in the Notch
//
//  Shared between Ashan's context module (click-triggered captures for the
//  Gemini summary pipeline) and Sam's computer-use harness (snapshot tool
//  call). Uses ScreenCaptureKit on macOS 14+.
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
        /// Full-resolution CGImage BEFORE the downsample-for-Gemini step.
        /// Used for OCR so small UI text stays readable. Nil only if the
        /// raw capture is unavailable. Holds a Core Graphics reference —
        /// don't retain past the immediate capture turn.
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

    // MARK: - ScreenCaptureKit path

    private func snapshotViaSCKit(displayId: CGDirectDisplayID?, quality: CGFloat, maxLongEdge: Int?) async throws -> Snapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = displayId.flatMap({ id in content.displays.first(where: { $0.displayID == id }) })
                ?? content.displays.first else {
            throw NSError(domain: "ScreenCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(display.width) * display.pointPixelScale())
        cfg.height = Int(CGFloat(display.height) * display.pointPixelScale())
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
            scale: display.pointPixelScale(),
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

    /// Lossless PNG encode of a CGImage. Used only by the Gemini observer path
    /// (PNG ensures the model gets crisp UI text edges that JPEG would smear).
    /// JPEG remains the default for OCR, dirty-detection, and the agent's
    /// initiation screenshot — do not switch those to PNG.
    public nonisolated func pngEncode(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}

private extension SCDisplay {
    func pointPixelScale() -> CGFloat {
        let nsScreens = NSScreen.screens
        let match = nsScreens.first { screen in
            let desc = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return desc?.uint32Value == displayID
        }
        return match?.backingScaleFactor ?? 2.0
    }
}
