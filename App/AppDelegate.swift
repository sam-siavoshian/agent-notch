//
//  AppDelegate.swift
//  Agent in the Notch
//
//  AppKit hook for things SwiftUI can't do alone: notch-positioned panel,
//  global event taps, accessibility prompts. Stubbed for now.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // TODO(Wyatt): replace WindowGroup with an NSPanel pinned to the notch.
        // Reference: vendored/boring.notch/boringNotch/components/Notch/
        //   BoringNotchWindow.swift and BoringNotchSkyLightWindow.swift.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
