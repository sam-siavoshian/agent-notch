//
//  TerminalAdapter.swift
//  Agent in the Notch
//
//  AppContextAdapter for macOS terminal emulators (Terminal.app, iTerm2,
//  Ghostty). The primary cwd path is an OSC 7-style reporter installed
//  into the user's shell rc by `scripts/install-cwd-reporter.sh`. The
//  reporter writes the current working directory to
//  `~/.cache/agentnotch/term-cwd-<ttyname>` on every prompt/cd. We read
//  whichever file was modified most recently — that's the foreground tab.
//
//  Fallback: scrape the visible terminal buffer via AppleScript and pick
//  out the last `~`/`/`-prefixed token. Best-effort only — fails under
//  tmux, ssh, and custom prompts.
//

import Foundation
import AppKit

/// AppContextAdapter for macOS terminal emulators (Terminal.app, iTerm2, Ghostty).
///
/// Primary cwd path: OSC 7 reporter (installed via `scripts/install-cwd-reporter.sh`)
/// writes the current cwd to `~/.cache/agentnotch/term-cwd-<ttyname>` on every prompt.
/// We read whichever file was modified most recently.
///
/// Fallback when no OSC 7 file exists: AppleScript reads the visible buffer and parses
/// the prompt for a `~`/`/`-prefixed path. Unreliable under tmux / ssh / custom prompts.
public final class TerminalAdapter: AppContextAdapter {

    public static let bundleIDs: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty"
    ]

    public init() {}

    public func snapshot(bundleID: String) async throws -> [String: AnyCodable] {
        let cwd: String?
        if let osc7 = readCwdViaOSC7() {
            cwd = osc7
        } else {
            cwd = try? await readCwdViaAppleScript(bundleID: bundleID)
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var dict: [String: AnyCodable] = [
            "shell": AnyCodable((shell as NSString).lastPathComponent),
            "ssh_host": AnyCodable(NSNull())
        ]
        if let cwd {
            dict["cwd"] = AnyCodable(cwd)
            let (branch, dirty) = readGitInfo(cwd: cwd)
            if let branch { dict["git_branch"] = AnyCodable(branch) }
            dict["git_dirty"] = AnyCodable(dirty)
        }
        return dict
    }

    public func recentResources(bundleID: String) async -> [CResourceRef] {
        guard let cwd = readCwdViaOSC7() else { return [] }
        let appLabel = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName ?? bundleID
        return [
            CResourceRef(
                kind: "cwd",
                uri: cwd,
                label: (cwd as NSString).lastPathComponent,
                app: appLabel,
                lastSeen: Date()
            )
        ]
    }

    // MARK: - OSC 7 file reader

    private static let cacheDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("agentnotch", isDirectory: true)
    }()

    /// Return the cwd from the most-recently-modified `term-cwd-*` file. nil if no files exist.
    private func readCwdViaOSC7() -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: Self.cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let cwdFiles = contents.filter { $0.lastPathComponent.hasPrefix("term-cwd-") }
        guard let mostRecent = cwdFiles.max(by: {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }) else { return nil }
        let raw = (try? String(contentsOf: mostRecent, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }

    // MARK: - AppleScript fallback (parse visible buffer)

    /// Best-effort buffer scrape for a path prefix. Returns nil if it can't find one.
    private func readCwdViaAppleScript(bundleID: String) async throws -> String? {
        let script: String?
        switch bundleID {
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
                try
                    return contents of selected tab of window 1 as string
                on error
                    return ""
                end try
            end tell
            """
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm"
                try
                    return contents of current session of current window as string
                on error
                    return ""
                end try
            end tell
            """
        default:
            script = nil
        }
        guard let source = script else { return nil }
        return await Task.detached(operation: {
            var error: NSDictionary?
            guard let s = NSAppleScript(source: source) else { return nil }
            let descriptor = s.executeAndReturnError(&error)
            if error != nil { return nil }
            let buffer = descriptor.stringValue ?? ""
            // Grab the last token that looks path-like.
            let lines = buffer.split(separator: "\n").reversed()
            for line in lines {
                let parts = line.split(separator: " ")
                for token in parts.reversed() {
                    let s = String(token)
                    if s.hasPrefix("/") || s.hasPrefix("~") {
                        return s.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
                    }
                }
            }
            return nil
        }).value
    }

    // MARK: - git info

    private func readGitInfo(cwd: String) -> (branch: String?, dirty: Bool) {
        // Walk up to find .git dir
        var dir = URL(fileURLWithPath: cwd, isDirectory: true)
        var foundGit: URL? = nil
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: candidate.path) {
                foundGit = candidate
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        guard let gitDir = foundGit else { return (nil, false) }

        // Read HEAD for branch
        let headURL = gitDir.appendingPathComponent("HEAD")
        let branch: String? = {
            guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
            // Format: "ref: refs/heads/main\n" or "<sha>\n" (detached)
            if let range = head.range(of: "refs/heads/") {
                return head[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }()

        // Dirty check via shell: `git status --porcelain` returns non-empty if dirty.
        // For a non-shell-blocking spike, just call `git status --porcelain` via Process.
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["status", "--porcelain"]
        task.currentDirectoryPath = cwd
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (branch, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch {
            return (branch, false)
        }
    }
}
