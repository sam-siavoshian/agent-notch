//
//  AppRelaunch.swift
//  Agent in the Notch
//
//  Cold-restart helper. macOS caches TCC trust per-process — once the user
//  grants Accessibility / Screen Recording in System Settings, our running
//  process keeps reading the stale "denied" answer until we exec a new copy.
//  This util spawns a shell helper that waits for our PID to fully exit,
//  then `open -n`s a fresh instance, then quits us.
//
//  Without the wait-then-open dance, LaunchServices dedupes against the
//  dying process and `open -n` silently no-ops.
//

import AppKit
import Foundation

@MainActor
enum AppRelaunch {
    /// Spawn helper + terminate. Returns immediately.
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done
        /usr/bin/open -n '\(escaped)'
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", cmd]
        task.standardOutput = nil
        task.standardError = nil
        do {
            try task.run()
        } catch {
            NSLog("[AppRelaunch] helper spawn failed: \(error)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(0) }
        }
    }
}
