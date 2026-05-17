import Foundation
import AppKit

/// AppContextAdapter for code editors (VSCode, Cursor, Xcode, Zed).
///
/// Strategy per editor:
///   - **VSCode / Cursor**: parse the window title (format: "<filename> — <project> — <app>")
///     and walk up to find .git for project_root + git_branch.
///   - **Xcode**: AppleScript scripting dictionary exposes path of front document + selected text.
///   - **Zed**: window title only (no scripting interface as of writing).
///
/// Returns nil app_specific only on permission errors — best-effort otherwise.
public final class IDEAdapter: AppContextAdapter {

    public static let bundleIDs: [String] = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.apple.dt.Xcode",
        "dev.zed.Zed"
    ]

    public init() {}

    public func snapshot(bundleID: String) async throws -> [String: AnyCodable] {
        switch bundleID {
        case "com.apple.dt.Xcode":
            return await snapshotXcode()
        case "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92":
            return snapshotVSCodeLike(bundleID: bundleID)
        case "dev.zed.Zed":
            return snapshotZed()
        default:
            throw AdapterError.unsupportedBundle(bundleID)
        }
    }

    public func recentResources(bundleID: String) async -> [CResourceRef] {
        guard let snap = try? await snapshot(bundleID: bundleID) else { return [] }
        var out: [CResourceRef] = []
        let appLabel = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.localizedName ?? bundleID
        if let openFile = snap["open_file"]?.value as? String, !openFile.isEmpty {
            out.append(CResourceRef(kind: "file", uri: "file://\(openFile)", label: (openFile as NSString).lastPathComponent, app: appLabel, lastSeen: Date()))
        }
        if let root = snap["project_root"]?.value as? String, !root.isEmpty {
            out.append(CResourceRef(kind: "cwd", uri: root, label: (root as NSString).lastPathComponent, app: appLabel, lastSeen: Date()))
        }
        return out
    }

    // MARK: - Xcode (AppleScript)

    private func snapshotXcode() async -> [String: AnyCodable] {
        let script = """
        tell application "Xcode"
            try
                set docPath to path of front document
                set wkRoot to ""
                try
                    set wkRoot to path of active workspace document
                end try
                return {docPath, wkRoot}
            on error
                return {"", ""}
            end try
        end tell
        """
        let descriptor: NSAppleEventDescriptor? = await Task.detached(operation: {
            var error: NSDictionary?
            guard let s = NSAppleScript(source: script) else { return nil }
            let d = s.executeAndReturnError(&error)
            return error == nil ? d : nil
        }).value
        let openFile = descriptor?.atIndex(1)?.stringValue ?? ""
        let workspaceRoot = descriptor?.atIndex(2)?.stringValue ?? ""
        let projectRoot = workspaceRoot.isEmpty
            ? walkToGit(from: openFile)
            : (workspaceRoot as NSString).deletingLastPathComponent
        let branch = readGitBranch(at: projectRoot)
        var dict: [String: AnyCodable] = [:]
        if !openFile.isEmpty {
            dict["open_file"] = AnyCodable(openFile)
            dict["language"] = AnyCodable(languageHint(for: openFile))
        }
        if !projectRoot.isEmpty { dict["project_root"] = AnyCodable(projectRoot) }
        if let branch { dict["git_branch"] = AnyCodable(branch) }
        return dict
    }

    // MARK: - VSCode / Cursor (window title + globalStorage)

    private func snapshotVSCodeLike(bundleID: String) -> [String: AnyCodable] {
        // Parse window title via AX (front window of frontmost app)
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return [:]
        }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement], let win = windows.first else {
            return [:]
        }
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleValue)
        let title = (titleValue as? String) ?? ""

        // Title format (most VSCode/Cursor variants): "<filename> — <project> — <app>"
        // Some installs use "•" or "–" or different em-dash variants.
        let separators: Set<Character> = ["—", "–", "-", "•"]
        var parts: [String] = []
        var current = ""
        for ch in title {
            if separators.contains(ch) {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }

        var dict: [String: AnyCodable] = [:]
        if let filename = parts.first, !filename.isEmpty {
            dict["open_file"] = AnyCodable(filename)
            dict["language"] = AnyCodable(languageHint(for: filename))
        }
        if parts.count >= 2, let project = parts.dropFirst().first {
            dict["project_label"] = AnyCodable(project)
        }
        // Best-effort: if filename is a path-like, walk to .git
        if let filename = parts.first, filename.contains("/") {
            let root = walkToGit(from: filename)
            if !root.isEmpty {
                dict["project_root"] = AnyCodable(root)
                if let branch = readGitBranch(at: root) { dict["git_branch"] = AnyCodable(branch) }
            }
        }
        return dict
    }

    // MARK: - Zed (window title only)

    private func snapshotZed() -> [String: AnyCodable] {
        // Same window-title trick, but Zed shows "<project> — <app>" without a filename.
        return snapshotVSCodeLike(bundleID: "dev.zed.Zed")
    }

    // MARK: - Helpers

    private func walkToGit(from path: String) -> String {
        guard !path.isEmpty else { return "" }
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return ""
    }

    private func readGitBranch(at projectRoot: String) -> String? {
        guard !projectRoot.isEmpty else { return nil }
        let headURL = URL(fileURLWithPath: projectRoot).appendingPathComponent(".git/HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        if let range = head.range(of: "refs/heads/") {
            return head[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func languageHint(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx": return "typescript"
        case "js", "jsx": return "javascript"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "md": return "markdown"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        default: return ext.isEmpty ? "unknown" : ext
        }
    }
}
