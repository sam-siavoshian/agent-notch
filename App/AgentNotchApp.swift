//
//  AgentNotchApp.swift
//  Agent in the Notch
//
//  Entry point. We don't use a SwiftUI WindowGroup — the real UI is an
//  NSPanel installed by AppDelegate. The Settings scene exists only so the
//  App protocol has a Scene to return.
//

import SwiftUI

@main
struct AgentNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
