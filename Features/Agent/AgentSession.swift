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

        // Resolve intent first (capped at 3s) so we can ask context for a
        // tailored packet. Context gather itself blocks on a fresh capture, so
        // serializing here barely costs latency vs the old parallel layout.
        let intent = await Self.resolveIntent(transcript: transcript, deadlineSeconds: 3.0)
        let hint = intent.map(Self.makeHint)
        let context = await (AgentInterfaces.context?.getRecentActivityContext(hint: hint) ?? "")
        log.info("session.context context_len=\(context.count) has_context=\(AgentInterfaces.context != nil) intent=\(intent != nil)")

        let input = ComputerUseHarness.Input(
            transcript: transcript,
            contextSummary: context,
            resolvedIntent: intent
        )
        await ComputerUseHarness.shared.run(input)
    }

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

    private static func findAppMemory(for appName: String?) async -> ContextAppMemory? {
        guard let appName, !appName.isEmpty else { return nil }
        let memories = await ContextMemoryStore.shared.debugMemories(limit: 50)
        return memories.first { $0.appName.compare(appName, options: .caseInsensitive) == .orderedSame }
    }

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
