//
//  EnvLoader.swift
//  Agent in the Notch
//
//  Loads .env into the process environment at launch so every consumer
//  (Secrets, Gemini service, demo prompt) sees the same values via
//  ProcessInfo.processInfo.environment or Env.value(_:).
//
//  Search order: bundle Resources (built copy of repo-root .env) → directory
//  containing the .app bundle. First hit wins; missing file is not fatal.
//
//  Format: KEY=VALUE per line. Blank lines and lines starting with '#' ignored.
//  Surrounding quotes on the value stripped. No interpolation, no multiline.
//

import Darwin
import Foundation

public enum Env {
    private static var overrides: [String: String] = [:]

    /// Reads agentnotch.env once and pushes values into the process environment.
    /// Safe to call multiple times; later calls are no-ops.
    public static func load() {
        guard overrides.isEmpty else { return }

        guard let url = locateEnvFile() else {
            print("[INFO]  [env] no .env found — using process environment only")
            return
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            fputs("[ERROR] [env] failed to read \(url.path)\n", Darwin.stderr)
            return
        }

        let parsed = parse(contents)
        overrides = parsed

        for (key, value) in parsed where !value.isEmpty {
            setenv(key, value, 1)
        }

        print("[INFO]  [env] loaded \(parsed.count) keys from \(url.lastPathComponent)")
    }

    /// Returns the value for `key`. Checks process environment first (so Xcode
    /// scheme env vars win), then the parsed .env file.
    public static func value(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        if let v = overrides[key], !v.isEmpty { return v }
        return nil
    }

    // MARK: - Private

    private static func locateEnvFile() -> URL? {
        let fm = FileManager.default
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent(".env"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".env"),
        ].compactMap { $0 }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private static func parse(_ contents: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            if value.count >= 2,
               let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }

            guard !key.isEmpty else { continue }
            out[key] = value
        }
        return out
    }
}
