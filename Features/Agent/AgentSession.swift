//
//  AgentSession.swift
//  Agent in the Notch
//
//  Glue between voice transcription and the agent loop. Subscribes to
//  .transcriptReady — posted by VoiceRecordingService after Whisper finishes.
//  Reads the transcript from AgentState, pulls activity context, and fires
//  one ComputerUseHarness turn.
//

import Foundation

private let log = Log(category: "session")

@MainActor
public final class AgentSession {
    public static let shared = AgentSession()

    private var readyObserver: NSObjectProtocol?
    private var currentRunTask: Task<Void, Never>?

    private init() {}

    /// Cancel any in-flight harness run. Triggered by the kill-switch
    /// soft-stop path; safe to call when no run is active.
    public func cancelCurrentRun() {
        currentRunTask?.cancel()
        currentRunTask = nil
    }

    public func start() {
        guard readyObserver == nil else { return }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .transcriptReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.fireAgentTurn()
            }
        }
        log.info("session.ready")
    }

    public func stop() {
        if let readyObserver { NotificationCenter.default.removeObserver(readyObserver) }
        readyObserver = nil
    }

    private func fireAgentTurn() async {
        let transcript = AgentState.shared.lastTranscript
        guard !transcript.isEmpty else {
            log.warning("session.fire skipped — empty transcript")
            return
        }
        log.info("session.fire transcript=\(transcript)")

        AgentObservabilityLog.shared.record(.longPressTranscript(
            id: UUID(), t: Date(), transcript: transcript
        ))

        // Fast-path: run before Mercury so obvious commands (open URL, Spotify,
        // Reminders) complete in ~0ms without paying the ~600ms Mercury round-trip.
        let routed = await IntentRouter.tryHandle(transcript: transcript)
        if case .handled(let summary, let affirmation) = routed {
            log.info("session.fast_path summary=\(summary)")
            TextToSpeechService.shared.speak(affirmation)
            AgentState.shared.set(.idle, detail: summary)
            return
        }

        // Mercury path: Selector assembles L2+L3+L4+L5+story and returns a brief
        // + structured intent in ~600ms.
        let result = await ContextSelector.shared.select(transcript: transcript)
        log.info("session.selector latency=\(String(format: "%.2f", result.latencyS))s degraded=\(result.degraded) model=\(result.modelUsed ?? "<local>") brief_len=\(result.brief.count)")
        Self.dumpTurnToDisk(transcript: transcript, result: result)

        AgentObservabilityLog.shared.record(.l2Snapshot(
            id: UUID(),
            t: result.l2.capturedAt,
            app: result.l2.app,
            window: result.l2.windowTitle,
            axElementCount: result.l2.axElements.count,
            ocrLineCount: result.l2.ocrLines.count,
            screenshotJPEG: result.initiationScreenshot
        ))
        AgentObservabilityLog.shared.record(.selectorRun(
            id: UUID(),
            t: Date(),
            latencyS: result.latencyS,
            degraded: result.degraded,
            model: result.modelUsed,
            intentVerb: result.intent.verb,
            intentTarget: result.intent.target,
            briefLength: result.brief.count
        ))

        let input = ComputerUseHarness.Input(
            transcript: transcript,
            contextSummary: result.brief,
            intentVerb: result.intent.verb,
            initiationScreenshot: result.initiationScreenshot,
            initiationTransform: result.initiationTransform
        )
        currentRunTask?.cancel()
        let t = Task { @MainActor in
            await ComputerUseHarness.shared.run(input)
        }
        currentRunTask = t
        await t.value
        currentRunTask = nil
    }

    // MARK: - Disk dump (debug/observability)

    /// Drop per-turn artifacts onto disk so an outside reader (a tail in
    /// another terminal, a teammate, a future me) can see exactly what the
    /// harness saw without opening the in-app Dev Tools window. Gated on
    /// `AGENTNOTCH_DUMP_DIR` so production builds without the env var do
    /// nothing. Two artifacts per turn:
    ///   - `agentnotch-last-turn.md` (overwritten) — the brief Claude actually
    ///      sees this turn, prefixed with transcript + selector stats.
    ///   - `agentnotch-turns.jsonl` (appended) — one line per turn with the
    ///      full structured payload (transcript, intent, L2 summary, brief
    ///      markdown, structured brief if Mercury succeeded). Easy to grep
    ///      or pipe through jq for analysis.
    private static func dumpTurnToDisk(transcript: String, result: ContextSelector.Result) {
        guard let root = ProcessInfo.processInfo.environment["AGENTNOTCH_DUMP_DIR"], !root.isEmpty else { return }
        let lastBrief = URL(fileURLWithPath: "\(root)/agentnotch-last-turn.md")
        let turnsJsonl = URL(fileURLWithPath: "\(root)/agentnotch-turns.jsonl")
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)

        var header = "# Turn @ \(iso)\n\n"
        header += "**Transcript:** \(transcript)\n\n"
        header += "**App:** \(result.l2.app) (`\(result.l2.bundleID)`)  \n"
        header += "**Window:** \(result.l2.windowTitle ?? "—")  \n"
        header += "**Selector:** \(String(format: "%.2fs", result.latencyS)) — degraded: \(result.degraded) — model: \(result.modelUsed ?? "<local>")  \n"
        header += "**Intent:** verb=`\(result.intent.verb)` target=`\(result.intent.target ?? "—")` conf=\(String(format: "%.2f", result.intent.confidence))  \n\n"
        header += "---\n\n"
        let body = header + result.brief
        try? body.data(using: .utf8)?.write(to: lastBrief, options: [.atomic])

        struct Record: Encodable {
            let t: Date
            let transcript: String
            let latencyS: Double
            let degraded: Bool
            let model: String?
            let intentVerb: String
            let intentTarget: String?
            let intentConfidence: Double
            let app: String
            let bundleID: String
            let windowTitle: String?
            let axElementCount: Int
            let ocrLineCount: Int
            let brief: String
            let structuredBrief: StructuredBrief?
        }
        let rec = Record(
            t: now,
            transcript: transcript,
            latencyS: result.latencyS,
            degraded: result.degraded,
            model: result.modelUsed,
            intentVerb: result.intent.verb,
            intentTarget: result.intent.target,
            intentConfidence: result.intent.confidence,
            app: result.l2.app,
            bundleID: result.l2.bundleID,
            windowTitle: result.l2.windowTitle,
            axElementCount: result.l2.axElements.count,
            ocrLineCount: result.l2.ocrLines.count,
            brief: result.brief,
            structuredBrief: result.structuredBrief
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var data = try? enc.encode(rec) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: turnsJsonl) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: turnsJsonl, options: [.atomic])
        }
        log.info("session.dump wrote \(lastBrief.path) (+ appended turns.jsonl)")
    }
}
