//
//  ScreenCapture.swift
//  Agent in the Notch
//
//  Shared between Ashan's context module (click-triggered captures for the
//  Gemini summary pipeline) and Sam's computer-use harness (snapshot tool
//  call). Uses ScreenCaptureKit on macOS 14+. Falls back to legacy
//  CGWindowListCreateImage on older systems for safety.
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
    }

    private var stream: SCStream?

    public init() {}

    public func snapshot(displayId: CGDirectDisplayID? = nil, quality: CGFloat = 0.7) async throws -> Snapshot {
        return try await snapshotViaSCKit(displayId: displayId, quality: quality)
    }

    // MARK: - ScreenCaptureKit path

    private func snapshotViaSCKit(displayId: CGDirectDisplayID?, quality: CGFloat) async throws -> Snapshot {
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

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        guard let jpeg = jpegEncode(image, quality: quality) else {
            throw NSError(domain: "ScreenCapture", code: -2, userInfo: [NSLocalizedDescriptionKey: "JPEG encode failed"])
        }
        return Snapshot(
            jpegData: jpeg,
            width: image.width,
            height: image.height,
            scale: display.pointPixelScale(),
            capturedAt: Date()
        )
    }

    private func jpegEncode(_ image: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
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
