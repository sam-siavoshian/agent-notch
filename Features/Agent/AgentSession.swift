//
//  AgentSession.swift
//  Agent in the Notch
//
//  Glue between long-press events and the agent loop. Subscribes to
//  .longPressEnded — that's the "user finished talking" signal. Pulls the
//  most recent voice transcript (from AgentState, written by Ashan's whisper
//  module) and the activity context, and fires one harness turn.
//
//  For demo dry-runs without Ashan's whisper online: ANTHROPIC_NOTCH_DEMO_PROMPT
//  env var, if set, is used as the transcript so we can fire the agent
//  without microphone input.
//

import Foundation

@MainActor
public final class AgentSession {
    public static let shared = AgentSession()

    private var endedObserver: NSObjectProtocol?

    private init() {}

    public func start() {
        guard endedObserver == nil else { return }
        endedObserver = NotificationCenter.default.addObserver(
            forName: .longPressEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.fireAgentTurn()
            }
        }
    }

    public func stop() {
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
        endedObserver = nil
    }

    private func fireAgentTurn() async {
        let demoTranscript = ProcessInfo.processInfo.environment["ANTHROPIC_NOTCH_DEMO_PROMPT"] ?? ""
        let transcript: String
        if !AgentState.shared.lastTranscript.isEmpty {
            transcript = AgentState.shared.lastTranscript
        } else if !demoTranscript.isEmpty {
            transcript = demoTranscript
        } else {
            NSLog("[AgentSession] No transcript available. Set ANTHROPIC_NOTCH_DEMO_PROMPT for dry-run testing.")
            return
        }

        let context = await AgentInterfaces.context?.getRecentActivityContext() ?? ""

        let input = ComputerUseHarness.Input(transcript: transcript, contextSummary: context)
        await ComputerUseHarness.shared.run(input)
    }
}
