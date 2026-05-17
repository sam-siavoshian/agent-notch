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

        // Phase 4 Mercury path: a single Selector call returns BOTH the resolved
        // intent and the markdown brief (formerly two passes — Haiku resolver +
        // ContextActivationBuilder). Brief is handed to the harness verbatim as
        // `contextSummary`; intent is mapped to the legacy `ContextResolvedIntent`
        // shape until Phase 5b cuts the legacy type from `ComputerUseHarness.Input`.
        let result = await ContextSelector.shared.select(transcript: transcript)
        log.info("session.selector latency=\(String(format: "%.2f", result.latencyS))s degraded=\(result.degraded) model=\(result.modelUsed ?? "<local>") brief_len=\(result.brief.count)")

        let legacyIntent = Self.mapToLegacyIntent(result.intent, degraded: result.degraded, latencyS: result.latencyS)

        let input = ComputerUseHarness.Input(
            transcript: transcript,
            contextSummary: result.brief,
            resolvedIntent: legacyIntent,
            initiationScreenshot: result.initiationScreenshot
        )
        await ComputerUseHarness.shared.run(input)
    }

    /// Maps the Phase 4 `CIntent` (Selector output) into the legacy
    /// `ContextResolvedIntent` shape still required by `ComputerUseHarness.Input`.
    /// Phase 5b is expected to delete `ContextResolvedIntent` (and this helper)
    /// once the harness consumes `CIntent` directly.
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

    @available(*, deprecated, message: "Legacy intent→hint path; replaced by Selector. Removed in Phase 5b.")
    private static func makeHint(_ intent: ContextResolvedIntent) -> ActivationContextHint {
        var mentionedApps: [String] = []
        var entityLabels: [String] = []
        for entity in intent.resolvedEntities {
            let label = entity.entityLabel ?? entity.userPhrase
            entityLabels.append(label)
            if (entity.entityType ?? "").lowercased() == "app" {
                mentionedApps.append(label)
            }
        }
        var keywords = Set<String>()
        let verbLower = intent.verb.lowercased()
        if !verbLower.isEmpty { keywords.insert(verbLower) }
        for entity in intent.resolvedEntities {
            keywords.insert(entity.userPhrase.lowercased())
        }
        for recipe in intent.candidateRecipes {
            recipe.recipeName.split(separator: " ").forEach { word in
                let w = word.lowercased()
                if w.count > 2 { keywords.insert(w) }
            }
        }
        return ActivationContextHint(
            verb: intent.verb,
            target: intent.target,
            inferredGoal: intent.inferredGoal,
            mentionedApps: Array(Set(mentionedApps)),
            mentionedEntityLabels: Array(Set(entityLabels)),
            keywords: Array(keywords),
            confidence: intent.confidence
        )
    }

    /// Race the resolver against a hard wall-clock deadline so a slow Haiku
    /// response can never delay the harness. Returns nil if we time out.
    @available(*, deprecated, message: "Legacy Haiku resolver path; replaced by Selector. Removed in Phase 5b.")
    private static func resolveIntent(transcript: String, deadlineSeconds: TimeInterval) async -> ContextResolvedIntent? {
        let snapshots = await ContextCoordinator.shared.recentSnapshots()
        let currentApp = snapshots.last?.appName
        let currentWindow = snapshots.last?.windowTitle ?? ""
        let memory = await findAppMemory(for: currentApp)
        let surfaceID = currentApp.map { appName -> String in
            normalizeSurfaceID(appName: appName, windowTitle: currentWindow)
        }

        return await withTaskGroup(of: ContextResolvedIntent?.self) { group in
            group.addTask {
                await ContextIntentResolver.shared.resolve(
                    transcript: transcript,
                    currentApp: currentApp,
                    currentSurfaceID: surfaceID,
                    appMemory: memory,
                    globalMemorySummary: nil
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadlineSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @available(*, deprecated, message: "Legacy resolver helper; replaced by Selector. Removed in Phase 5b.")
    private static func findAppMemory(for appName: String?) async -> ContextAppMemory? {
        guard let appName, !appName.isEmpty else { return nil }
        let memories = await ContextMemoryStore.shared.debugMemories(limit: 50)
        return memories.first { $0.appName.compare(appName, options: .caseInsensitive) == .orderedSame }
    }

    @available(*, deprecated, message: "Legacy resolver helper; replaced by Selector. Removed in Phase 5b.")
    private static func normalizeSurfaceID(appName: String, windowTitle: String) -> String {
        let normalizedTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled window"
            : windowTitle
        func normalize(_ s: String) -> String {
            s.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .joined(separator: "-")
        }
        return "\(normalize(appName))#\(normalize(normalizedTitle))"
    }
}
