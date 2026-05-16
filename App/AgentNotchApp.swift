//
//  AgentNotchApp.swift
//  Agent in the Notch
//
//  SwiftUI entry point. The actual notch-positioned NSPanel/SkyLightWindow
//  wiring will be added on top of this — for now this gets us a Run target.
//

import SwiftUI

@main
struct AgentNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Agent in the Notch") {
            NotchContentView()
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentSize)
    }
}
