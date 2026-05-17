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

    private init() {}

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

        let context = await AgentInterfaces.context?.getRecentActivityContext() ?? ""
        log.info("session.context context_len=\(context.count) has_context=\(AgentInterfaces.context != nil)")

        let input = ComputerUseHarness.Input(transcript: transcript, contextSummary: context)
        await ComputerUseHarness.shared.run(input)
    }
}
