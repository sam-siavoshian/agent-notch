//
//  ClaudeBinaryResolver.swift
//  Agent in the Notch
//
//  Single source of truth for locating the user's `claude` CLI binary.
//  Used by `PermissionChecker.checkClaudeCodeInstalled` (install detection)
//  AND `ClaudeCodeClient.resolveClaudeBinary` (subprocess spawn). Adding a
//  new install path in one place updates both call sites — drift here means
//  the user sees "not installed" in Settings while the spawner finds the
//  binary just fine, or vice versa.
//

import Foundation

public enum ClaudeBinaryResolver {

    /// Standard install destinations across the three common installers
    /// (Homebrew, Bun, npm + ~/.local). Order matters — Homebrew first
    /// matches what a user is likely to have run.
    public static let standardCandidatePaths: [String] = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        NSString("~/.bun/bin/claude").expandingTildeInPath,
        NSString("~/.local/bin/claude").expandingTildeInPath,
        NSString("~/.npm/bin/claude").expandingTildeInPath
    ]

    /// Returns the first executable path found, considering the
    /// user-supplied override (if any) and then the standard candidates.
    /// Pass `nil` for `override` to skip the override check.
    public static func resolve(override: String?) -> String? {
        let fm = FileManager.default
        if let override, !override.isEmpty, fm.isExecutableFile(atPath: override) {
            return override
        }
        return standardCandidatePaths.first(where: { fm.isExecutableFile(atPath: $0) })
    }
}
