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

        // Mark the start of a new agent run in the observability timeline. The
        // `currentRunEvents()` slice depends on this being the first event of
        // the run.
        AgentObservabilityLog.shared.record(.longPressTranscript(
            id: UUID(), t: Date(), transcript: transcript
        ))

        // Phase 4 Mercury path: a single Selector call returns BOTH the resolved
        // intent and the markdown brief (formerly two passes — Haiku resolver +
        // ContextActivationBuilder, both deleted in Phase 5b). Brief is handed
        // to the harness verbatim as `contextSummary`; intent is mapped to the
        // transport `ContextResolvedIntent` shape until the harness Input is
        // retyped to take `CIntent` directly.
        let result = await ContextSelector.shared.select(transcript: transcript)
        log.info("session.selector latency=\(String(format: "%.2f", result.latencyS))s degraded=\(result.degraded) model=\(result.modelUsed ?? "<local>") brief_len=\(result.brief.count)")

        // Record L2 + selector result for the timeline.
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

        let legacyIntent = Self.mapToLegacyIntent(result.intent, degraded: result.degraded, latencyS: result.latencyS)

        let input = ComputerUseHarness.Input(
            transcript: transcript,
            contextSummary: result.brief,
            resolvedIntent: legacyIntent,
            initiationScreenshot: result.initiationScreenshot
        )
        await ComputerUseHarness.shared.run(input)
    }

    /// Maps the Phase 4 `CIntent` (Selector output) into the
    /// `ContextResolvedIntent` shape still consumed by `ComputerUseHarness.Input`.
    /// Phase 5b deleted the old Haiku resolver but kept the typed payload as a
    /// transport shim; a follow-up commit will retype the harness Input to
    /// take `CIntent` directly and drop this helper.
    private static func mapToLegacyIntent(_ intent: CIntent, degraded: Bool, latencyS: Double) -> ContextResolvedIntent {
        // CIntent.Entity (label, kind, resolvedTo) -> ContextEntityResolution
        // (userPhrase, entityID, entityLabel, entityType, confidence, evidence)
        let entities: [ContextEntityResolution] = intent.entities.map { e in
            ContextEntityResolution(
                userPhrase: e.label,
                entityID: e.resolvedTo,
                entityLabel: e.resolvedTo ?? e.label,
                entityType: e.kind,
                confidence: intent.confidence,
                evidence: "selector"
            )
        }
        return ContextResolvedIntent(
            verb: intent.verb,
            target: intent.target,
            resolvedEntities: entities,
            candidateRecipes: [],            // recipes are already inlined in the brief
            inferredGoal: intent.resolvedTarget ?? intent.target ?? "",
            confidence: intent.confidence,
            resolverLatencyMs: Int(latencyS * 1000.0),
            usedFallback: degraded
        )
    }
}
