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
            initiationScreenshot: result.initiationScreenshot
        )
        currentRunTask?.cancel()
        let t = Task { @MainActor in
            await ComputerUseHarness.shared.run(input)
        }
        currentRunTask = t
        await t.value
        currentRunTask = nil
    }
}
