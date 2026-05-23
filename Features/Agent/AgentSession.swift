//
//  AgentSession.swift
//  Agent in the Notch
//
//  Glue between voice transcription and the agent loop. Subscribes to
//  .transcriptReady — posted by VoiceRecordingService after Whisper finishes.
//  Reads the transcript from AgentState, captures a 1280x800 initiation
//  screenshot, and fires one ComputerUseHarness turn.
//

import Foundation

private let log = Log(category: "session")

@MainActor
public final class AgentSession {
    public static let shared = AgentSession()

    private var readyObserver: NSObjectProtocol?
    private var currentRunTask: Task<Void, Never>?

    private init() {}

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
            Task { await self?.fireAgentTurn() }
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

        let routed = await IntentRouter.tryHandle(transcript: transcript)
        if case .handled(let summary, let affirmation) = routed {
            log.info("session.fast_path summary=\(summary)")
            TextToSpeechService.shared.speak(affirmation)
            AgentState.shared.set(.idle, detail: summary)
            return
        }

        let snap = try? await ScreenCapture.shared.targetSnapshot(
            target: ComputerUseHarness.shared.agentDisplaySize,
            quality: 0.8
        )

        let input = ComputerUseHarness.Input(
            transcript: transcript,
            initiationScreenshot: snap?.jpegData,
            initiationTransform: snap?.transform
        )
        currentRunTask?.cancel()
        let t = Task { await ComputerUseHarness.shared.run(input) }
        currentRunTask = t
        await t.value
        currentRunTask = nil
    }
}
