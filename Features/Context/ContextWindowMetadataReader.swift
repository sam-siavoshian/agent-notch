//
//  ContextWindowMetadataReader.swift
//  Agent in the Notch
//
//  Lightweight app/window metadata attached to each screenshot. This is
//  supplemental context, not a replacement for screenshots.
//

import AppKit
import CoreGraphics
import Foundation

enum ContextWindowMetadataReader {
    static func current() -> ContextWindowMetadata {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown app"
        let pid = app?.processIdentifier
        let windowTitle = pid.flatMap { frontmostWindowTitle(processIdentifier: $0) } ?? ""
        return ContextWindowMetadata(appName: appName, windowTitle: windowTitle)
    }

    private static let ownerPIDKey = kCGWindowOwnerPID as String
    private static let layerKey = kCGWindowLayer as String
    private static let nameKey = kCGWindowName as String

    private static func frontmostWindowTitle(processIdentifier: pid_t) -> String? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        return windowInfo.first { info in
            let ownerPID = info[ownerPIDKey] as? pid_t
            let layer = info[layerKey] as? Int
            return ownerPID == processIdentifier && layer == 0
        }?[nameKey] as? String
    }
}
