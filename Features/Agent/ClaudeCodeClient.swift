//
//  ClaudeCodeClient.swift
//  Agent in the Notch
//
//  Drives the user's locally-installed `claude` CLI as a subprocess so the
//  computer-use loop can run against the user's CC subscription/auth instead
//  of AgentNotch's Anthropic API key.
//
//  Wiring:
//    1. Build prompt: system + context brief + transcript.
//    2. Spawn:
//         claude -p "<prompt>"
//           --output-format stream-json
//           --verbose                       (required with -p + stream-json)
//           --mcp-config <inline-json>      (points at our bundled helper)
//           --allowedTools "mcp__agentnotch__*"
//           [--resume <session-id>]         (when session.shouldResume() != nil)
//    3. Read stdout line-by-line. Each line is a JSON event in the Anthropic
//       streaming protocol (passthrough), wrapped by CC's envelope adding
//       `session_id` + `uuid`.
//    4. Emit Event values via AsyncThrowingStream so the harness updates UI
//       in real time:
//         - session id on first event   →  ClaudeCodeSession.setSessionId
//         - tool_use blocks             →  UI strip
//         - text_delta chunks           →  accumulate into final reply
//         - usage events                →  ClaudeCodeSession.addUsage
//         - process exit                →  emit .finished
//
//  CC drives its own tool loop via the MCP bridge — this client never sees
//  tool_result blocks. CC asks for tools, our `AgentNotchMCP` helper forwards
//  to MCPBridge, dispatcher executes, result returns to CC inside CC's own
//  process. We only observe CC's announcements.
//

import Foundation
import AppKit

private let log = Log(category: "claude.code")

/// Sliding cap on the stderr buffer we keep for diagnostic surfacing. CC can
/// emit megabytes of debug noise with `--verbose`; we only need the tail for
/// non-zero-exit error reports.
private let stderrTailLimit = 16 * 1024

/// AsyncThrowingStream buffering policy. Streaming `assistantText` deltas
/// arrive faster than TTS / SwiftUI can consume them on a long verbose run;
/// drop the oldest chunks rather than letting the queue grow without bound.
/// The final `.finished` event carries the full reply regardless.
private let eventBuffer = AsyncThrowingStream<ClaudeCodeClient.Event, Error>.Continuation.BufferingPolicy.bufferingOldest(256)

public final class ClaudeCodeClient: @unchecked Sendable {

    public enum Event: Sendable {
        case spawned
        case hookStarted(name: String)
        case hookCompleted(name: String)
        case sessionStarted(id: String)
        case toolStarted(name: String, id: String)
        case toolCompleted(name: String, id: String)
        case assistantText(String)
        case thinking
        case usage(inputTokens: Int, outputTokens: Int)
        case finished(finalText: String)
        case stderr(String)
    }

    public struct Prompt: Sendable {
        public var system: String
        public var userText: String
        public init(system: String, userText: String) {
            self.system = system
            self.userText = userText
        }
    }

    public enum ClientError: Error, CustomStringConvertible {
        case claudeNotFound
        case helperNotFound(path: String)
        case spawnFailed(underlying: Error)
        case nonZeroExit(code: Int32, stderr: String)
        case timedOut(seconds: Int)
        case cancelled
        public var description: String {
            switch self {
            case .claudeNotFound:
                return "claude CLI not found on PATH or in standard install locations"
            case .helperNotFound(let path):
                return "AgentNotchMCP helper missing at \(path)"
            case .spawnFailed(let e):
                return "spawn failed: \(e)"
            case .nonZeroExit(let code, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = trimmed.isEmpty ? "" : ": \(trimmed.prefix(200))"
                return "claude exited \(code)\(snippet)"
            case .timedOut(let secs):
                return "claude went silent for \(secs)s — terminating"
            case .cancelled:
                return "cancelled"
            }
        }
    }

    /// Kill the subprocess if no stdout event arrives in this many seconds.
    /// CC's `SessionStart` hooks + cold cache can take 30s easily; pick 90 to
    /// stay well clear of normal startup but still surface a real hang.
    public static let watchdogSeconds = 90

    private let bufferLock = NSLock()
    private var currentProcess: Process?
    private var stderrTail = Data()
    /// Accumulator for the assistant's final reply. Streaming `text_delta`
    /// chunks append; envelope-style `assistant` messages overwrite per
    /// turn; a terminal `result.success` overwrites with the canonical text.
    private var finalText = ""
    private var liveToolNamesById: [String: String] = [:]
    private var lastEventAt = Date()
    private var watchdogFired = false

    public init() {}

    /// One CC invocation start-to-finish. The returned stream completes (or
    /// throws) when the subprocess exits.
    public func run(prompt: Prompt) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream(bufferingPolicy: eventBuffer) { [self] continuation in
            Task.detached { [self] in
                do {
                    try await self.runOnce(prompt: prompt, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
        }
    }

    public func cancel() {
        let p = bufferLock.withLock { currentProcess }
        if let p, p.isRunning {
            p.terminate()
        }
    }

    // MARK: - Run pipeline

    private func runOnce(
        prompt: Prompt,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async throws {
        let claudePath = try await resolveClaudeBinary()
        let helperPath = try resolveHelperBinary()
        let socketPath = MCPBridge.shared.socketPath

        let mcpConfig: [String: Any] = [
            "mcpServers": [
                "agentnotch": [
                    "command": helperPath,
                    "args": ["--socket", socketPath]
                ] as [String: Any]
            ]
        ]
        let mcpConfigJSON = try Self.jsonString(from: mcpConfig)

        let resumeID = await ClaudeCodeSession.shared.shouldResume()
        let composedPrompt = Self.composedPrompt(prompt)

        var args: [String] = [
            "-p", composedPrompt,
            "--output-format", "stream-json",
            "--verbose",
            "--mcp-config", mcpConfigJSON,
            "--allowedTools", "mcp__agentnotch__*"
        ]
        if let resumeID, !resumeID.isEmpty {
            args.append(contentsOf: ["--resume", resumeID])
        }

        // Per-run Process — Foundation forbids re-running a terminated Process.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = args
        process.environment = Self.sanitizedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Detaching stdin — leaving it inherited can cause CC to hang
        // waiting on a TTY in some shells even when `-p` is used.
        process.standardInput = FileHandle.nullDevice

        bufferLock.withLock { self.currentProcess = process }

        let resumeLog = resumeID.map { "session=\($0)" } ?? "session=fresh"
        log.info("cc.spawn binary=\(claudePath) \(resumeLog) prompt_len=\(composedPrompt.count)")

        do {
            try process.run()
        } catch {
            bufferLock.withLock { self.currentProcess = nil }
            throw ClientError.spawnFailed(underlying: error)
        }
        continuation.yield(.spawned)

        bufferLock.withLock { self.lastEventAt = Date() }
        let stdoutTask = Task.detached { [self] in
            await self.pumpStdout(pipe: stdoutPipe, continuation: continuation)
        }
        let stderrTask = Task.detached { [self] in
            await self.pumpStderr(pipe: stderrPipe, continuation: continuation)
        }
        let watchdog = Task.detached { [weak self] in
            await self?.watchdogLoop()
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                cont.resume()
            }
        }

        watchdog.cancel()
        await stdoutTask.value
        await stderrTask.value

        let code = process.terminationStatus
        let fired = bufferLock.withLock { watchdogFired }
        bufferLock.withLock { self.currentProcess = nil }

        if fired {
            throw ClientError.timedOut(seconds: Self.watchdogSeconds)
        }
        if code != 0 && code != 15 /* SIGTERM */ {
            let stderrSnapshot: String = bufferLock.withLock {
                String(data: stderrTail, encoding: .utf8) ?? ""
            }
            throw ClientError.nonZeroExit(code: code, stderr: stderrSnapshot)
        }

        let snapshot = bufferLock.withLock { finalText }
        continuation.yield(.finished(finalText: snapshot))
    }

    private func watchdogLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            let (last, proc) = bufferLock.withLock { (lastEventAt, currentProcess) }
            let stale = Date().timeIntervalSince(last)
            guard stale >= Double(Self.watchdogSeconds), let proc, proc.isRunning else { continue }
            log.error("cc.watchdog stale_s=\(Int(stale)) terminating")
            bufferLock.withLock { watchdogFired = true }
            proc.terminate()
            return
        }
    }

    // MARK: - Resolution helpers

    private func resolveClaudeBinary() async throws -> String {
        let custom = await MainActor.run { AgentSettingsStore.shared.claudeCodePath }
        if let path = ClaudeBinaryResolver.resolve(override: custom) {
            return path
        }
        // Last resort: a `which` shell-out. Covers exotic installs (asdf,
        // mise, custom shims) the candidate list does not enumerate.
        if let viaWhich = try? Self.runWhich("claude"),
           FileManager.default.isExecutableFile(atPath: viaWhich) {
            return viaWhich
        }
        throw ClientError.claudeNotFound
    }

    private func resolveHelperBinary() throws -> String {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/AgentNotchMCP")
        let path = helperURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ClientError.helperNotFound(path: path)
        }
        return path
    }

    private static func runWhich(_ tool: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [tool]
        p.environment = ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ClientError.claudeNotFound }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8) ?? ""
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips our own ANTHROPIC_API_KEY etc — CC mode runs on the user's CC
    /// auth, not ours. Keep HOME, USER, PATH, and any CLAUDE_* / NPM_* bits
    /// the CLI needs.
    private static func sanitizedEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        let allow: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TERM", "TMPDIR"]
        for key in allow {
            if let v = parent[key] { env[key] = v }
        }
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        for (k, v) in parent where k.hasPrefix("CLAUDE_") || k.hasPrefix("NPM_") {
            env[k] = v
        }
        return env
    }

    private static func composedPrompt(_ p: Prompt) -> String {
        var parts: [String] = []
        if !p.system.isEmpty {
            parts.append("# System\n\(p.system)")
        }
        parts.append("# User\n\(p.userText)")
        return parts.joined(separator: "\n\n")
    }

    private static func jsonString(from object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Stream parsing

    private func pumpStdout(
        pipe: Pipe,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async {
        let handle = pipe.fileHandleForReading
        do {
            for try await line in handle.bytes.lines {
                bufferLock.withLock { self.lastEventAt = Date() }
                await handleLine(line, continuation: continuation)
            }
        } catch {
            log.warning("cc.stdout_read_ended error=\(error)")
        }
    }

    private func pumpStderr(
        pipe: Pipe,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async {
        let handle = pipe.fileHandleForReading
        do {
            for try await line in handle.bytes.lines {
                guard !line.isEmpty else { continue }
                bufferLock.withLock {
                    if let bytes = line.data(using: .utf8) {
                        stderrTail.append(bytes)
                        stderrTail.append(0x0A)
                    }
                    if stderrTail.count > stderrTailLimit {
                        let overflow = stderrTail.count - stderrTailLimit
                        stderrTail.removeFirst(overflow)
                    }
                }
                continuation.yield(.stderr(line))
            }
        } catch {
            log.warning("cc.stderr_read_ended error=\(error)")
        }
    }

    private func handleLine(
        _ line: String,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let sessionID = json["session_id"] as? String, !sessionID.isEmpty {
            await ClaudeCodeSession.shared.setSessionId(sessionID)
            continuation.yield(.sessionStarted(id: sessionID))
        }

        // CC version drift: stream-json carries any of these top-level
        // envelopes (system/init, wrapped assistant/user messages, final
        // result summary) AND, on older versions, raw Anthropic streaming
        // events. Handle whichever shows up.
        let type = (json["type"] as? String) ?? ""
        switch type {
        case "system":
            // CC surfaces hook lifecycle + init under type=system,subtype=...
            // Forward them so the harness can show "running hooks..." progress.
            if let subtype = json["subtype"] as? String {
                switch subtype {
                case "hook_started":
                    let name = (json["hook_name"] as? String) ?? "hook"
                    continuation.yield(.hookStarted(name: name))
                case "hook_response", "hook_completed":
                    let name = (json["hook_name"] as? String) ?? "hook"
                    continuation.yield(.hookCompleted(name: name))
                default:
                    break
                }
            }

        case "assistant":
            if let message = json["message"] as? [String: Any] {
                await handleAssistantMessage(message, continuation: continuation)
                if let usage = message["usage"] as? [String: Any] {
                    await handleUsage(usage, continuation: continuation)
                }
            }

        case "user":
            let echoedIDs = Self.toolResultIDs(in: json)
            for toolUseID in echoedIDs {
                let name = bufferLock.withLock {
                    liveToolNamesById.removeValue(forKey: toolUseID) ?? "<unknown>"
                }
                continuation.yield(.toolCompleted(name: name, id: toolUseID))
            }

        case "result":
            if let subtype = json["subtype"] as? String,
               subtype == "success",
               let text = json["result"] as? String, !text.isEmpty {
                bufferLock.withLock { finalText = text }
            }
            if let usage = json["usage"] as? [String: Any] {
                await handleUsage(usage, continuation: continuation)
            }

        default:
            await handleRawStreamingEvent(json, continuation: continuation)
        }
    }

    /// Pull `tool_result.tool_use_id` values out of a wrapped CC `user`
    /// envelope. Returns empty if the shape is unexpected.
    private static func toolResultIDs(in json: [String: Any]) -> [String] {
        guard let message = json["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else {
            return []
        }
        return blocks.compactMap { block in
            guard (block["type"] as? String) == "tool_result",
                  let id = block["tool_use_id"] as? String else { return nil }
            return id
        }
    }

    private func handleAssistantMessage(
        _ message: [String: Any],
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async {
        guard let contentArr = message["content"] as? [[String: Any]] else { return }
        var messageText = ""
        for block in contentArr {
            guard let ctype = block["type"] as? String else { continue }
            switch ctype {
            case "text":
                if let t = block["text"] as? String {
                    messageText += t
                    if !t.isEmpty {
                        continuation.yield(.assistantText(t))
                    }
                }
            case "tool_use":
                let id = (block["id"] as? String) ?? UUID().uuidString
                let name = (block["name"] as? String) ?? "<unnamed>"
                bufferLock.withLock { liveToolNamesById[id] = name }
                continuation.yield(.toolStarted(name: name, id: id))
            case "thinking":
                continuation.yield(.thinking)
            default:
                continue
            }
        }
        // CC's loop terminates after a text-only assistant message, so the
        // last text-bearing message wins as the canonical final reply.
        if !messageText.isEmpty {
            bufferLock.withLock { finalText = messageText }
        }
    }

    private func handleRawStreamingEvent(
        _ json: [String: Any],
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async {
        guard let type = json["type"] as? String else { return }
        switch type {
        case "content_block_start":
            guard let block = json["content_block"] as? [String: Any],
                  (block["type"] as? String) == "tool_use" else { return }
            let id = (block["id"] as? String) ?? UUID().uuidString
            let name = (block["name"] as? String) ?? "<unnamed>"
            bufferLock.withLock { liveToolNamesById[id] = name }
            continuation.yield(.toolStarted(name: name, id: id))
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any],
                  (delta["type"] as? String) == "text_delta",
                  let text = delta["text"] as? String else { return }
            bufferLock.withLock { finalText += text }
            continuation.yield(.assistantText(text))
        case "content_block_stop":
            break
        case "message_delta":
            if let usage = json["usage"] as? [String: Any] {
                await handleUsage(usage, continuation: continuation)
            }
        case "message_stop":
            break
        default:
            break
        }
    }

    private func handleUsage(
        _ usage: [String: Any],
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async {
        let inp = (usage["input_tokens"] as? Int) ?? 0
        let out = (usage["output_tokens"] as? Int) ?? 0
        guard inp > 0 || out > 0 else { return }
        await ClaudeCodeSession.shared.addUsage(input: inp, output: out)
        continuation.yield(.usage(inputTokens: inp, outputTokens: out))
    }
}
