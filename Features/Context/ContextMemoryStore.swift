//
//  ContextMemoryStore.swift
//  Agent in the Notch
//
//  Persists lightweight UI memory learned from screen captures. This is the
//  first native learning layer: app/window surfaces, observed transitions, and
//  same-surface click evidence.
//

import Foundation
import CryptoKit

public actor ContextMemoryStore {
    public static let shared = ContextMemoryStore()
    public static var defaultDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextMemory", isDirectory: true)
    }

    private let appDirectoryURL: URL
    private let observationsURL: URL
    private var appMemories: [String: ContextAppMemory] = [:]
    private var observationsSinceConsolidation: [String: Int] = [:]
    private var previousSnapshot: ContextSnapshot?
    private static let surfaceMergeThreshold: Double = 0.6
    private static let surfaceConsolidationThreshold: Double = 0.7
    private static let consolidationInterval: Int = 25
    private static let recentEntryCap: Int = 20
    private static let recipePromotionThreshold: Int = 3
    private static let negativeNotesPerSurfaceCap: Int = 4
    private static let confidencePruneFloor: Double = 0.15
    private static let confidenceDecayPerDay: Double = 0.9
    private static let fingerprintRefreshHours: Double = 24
    private static let fingerprintDriftConsolidationThreshold: Double = 0.4
    private static let recipeUnusedDecayPerDay: Double = 0.95

    public init(rootURL: URL? = nil) {
        let baseURL = rootURL ?? Self.defaultDirectoryURL
        self.appDirectoryURL = baseURL.appendingPathComponent("Apps", isDirectory: true)
        self.observationsURL = baseURL.appendingPathComponent("observations.jsonl")

        try? FileManager.default.createDirectory(at: appDirectoryURL, withIntermediateDirectories: true)
    }

    public func record(_ snapshot: ContextSnapshot) {
        let appKey = storageKey(for: snapshot.appName)
        var memory = loadMemory(appKey: appKey, appName: snapshot.appName, now: snapshot.capturedAt)
        let providedSurfaceID = Self.surfaceID(appName: snapshot.appName, windowTitle: snapshot.windowTitle)
        let surfaceTitle = Self.displayTitle(snapshot.windowTitle)
        let fingerprintTokens = Self.fingerprintTokens(forOCR: snapshot.recognizedText)

        memory.lastSeen = snapshot.capturedAt
        let resolvedSurfaceID = recordSurface(
            providedSurfaceID: providedSurfaceID,
            title: surfaceTitle,
            trigger: snapshot.trigger,
            textHighlights: textHighlights(from: snapshot),
            fingerprintTokens: fingerprintTokens,
            capturedAt: snapshot.capturedAt,
            memory: &memory
        )

        recordRecentActivity(
            app: snapshot.appName,
            surfaceID: resolvedSurfaceID,
            surfaceTitle: surfaceTitle,
            summary: "\(snapshot.trigger.rawValue) capture",
            trigger: snapshot.trigger,
            at: snapshot.capturedAt,
            memory: &memory
        )
        recordHabit(
            surfaceID: resolvedSurfaceID,
            surfaceTitle: surfaceTitle,
            previousSurfaceID: previousSnapshot.map { Self.surfaceID(appName: $0.appName, windowTitle: $0.windowTitle) },
            previousSurfaceTitle: previousSnapshot.map { Self.displayTitle($0.windowTitle) },
            sameApp: previousSnapshot?.appName == snapshot.appName,
            previousSeenAt: previousSnapshot?.capturedAt,
            at: snapshot.capturedAt,
            memory: &memory
        )

        if let previousSnapshot {
            recordTransition(
                from: previousSnapshot,
                to: snapshot,
                currentSurfaceID: resolvedSurfaceID,
                currentSurfaceTitle: surfaceTitle,
                memory: &memory
            )
        }

        memory.current = ContextCurrentWorkMemory(
            updatedAt: snapshot.capturedAt,
            app: snapshot.appName,
            surfaceID: resolvedSurfaceID,
            surfaceTitle: surfaceTitle,
            task: memory.current?.task ?? "",
            topEntities: Array(memory.entities
                .sorted { $0.mentionCount > $1.mentionCount }
                .prefix(3)
                .map(\.label))
        )

        previousSnapshot = snapshot
        appMemories[appKey] = memory
        tickConsolidation(appKey: appKey)
        persist(memory, appKey: appKey)
        appendObservation(snapshot, surfaceID: resolvedSurfaceID)
    }

    public func record(
        _ observation: ContextGeminiObservation,
        appName appNameHint: String? = nil,
        windowTitle windowTitleHint: String? = nil,
        capturedAt: Date = Date()
    ) {
        let appName = clean(appNameHint) ?? clean(observation.appLabel) ?? "Unknown app"
        let appKey = storageKey(for: appName)
        var memory = loadMemory(appKey: appKey, appName: appName, now: capturedAt)
        let surfaceTitle = clean(observation.surfaceLabel)
            ?? clean(windowTitleHint)
            ?? Self.displayTitle(observation.windowTitle)
        let providedSurfaceID = clean(observation.surfaceID)
            ?? Self.surfaceID(appName: appName, windowTitle: surfaceTitle)
        let fingerprintTokens = Self.fingerprintTokens(forSemantic: observation)

        memory.lastSeen = capturedAt
        let resolvedSurfaceID = recordSurface(
            providedSurfaceID: providedSurfaceID,
            title: surfaceTitle,
            trigger: .manual,
            textHighlights: memoryHighlights(observation.entities + observation.landmarks),
            fingerprintTokens: fingerprintTokens,
            capturedAt: capturedAt,
            memory: &memory
        )
        recordSemanticObservation(
            observation,
            surfaceID: resolvedSurfaceID,
            capturedAt: capturedAt,
            memory: &memory
        )
        promoteAppLevelEntities(
            from: observation,
            surfaceID: resolvedSurfaceID,
            capturedAt: capturedAt,
            memory: &memory
        )
        promoteStableStateFacts(memory: &memory)

        let taskSummary = clean(observation.primaryTask) ?? clean(observation.summary) ?? ""
        memory.current = ContextCurrentWorkMemory(
            updatedAt: capturedAt,
            app: appName,
            surfaceID: resolvedSurfaceID,
            surfaceTitle: surfaceTitle,
            task: taskSummary,
            topEntities: Array(memory.entities
                .sorted { $0.mentionCount > $1.mentionCount }
                .prefix(3)
                .map(\.label))
        )
        let recentSummary: String
        if !taskSummary.isEmpty {
            recentSummary = taskSummary
        } else if let summary = clean(observation.summary) {
            recentSummary = summary
        } else {
            recentSummary = "observation"
        }
        recordRecentActivity(
            app: appName,
            surfaceID: resolvedSurfaceID,
            surfaceTitle: surfaceTitle,
            summary: recentSummary,
            trigger: .manual,
            at: capturedAt,
            memory: &memory
        )

        appMemories[appKey] = memory
        tickConsolidation(appKey: appKey)
        persist(memory, appKey: appKey)
    }

    public func activationMemory(appName: String) -> String {
        guard !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        let appKey = storageKey(for: appName)
        let memory = loadMemory(appKey: appKey, appName: appName, now: Date())
        guard !memory.surfaces.isEmpty || memory.current != nil else { return "" }
        return ContextMemoryRenderer.activationSnippet(for: memory)
    }

    /// Bump a recipe's confidence after the computer-use harness used it
    /// successfully. Called by the harness on completion when a candidate
    /// recipe was surfaced and the run did not error. Caps confidence at 0.98.
    public func bumpRecipeConfidence(appName: String, recipeID: String, increment: Double = 0.05) {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !recipeID.isEmpty else { return }
        let appKey = storageKey(for: trimmed)
        var memory = loadMemory(appKey: appKey, appName: trimmed, now: Date())
        guard let index = memory.recipes.firstIndex(where: { $0.id == recipeID }) else { return }
        memory.recipes[index].confidence = min(0.98, memory.recipes[index].confidence + increment)
        memory.recipes[index].lastUsed = Date()
        appMemories[appKey] = memory
        persist(memory, appKey: appKey)
    }

    public func appMemory(appName: String) -> ContextAppMemory? {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let appKey = storageKey(for: trimmed)
        let memory = loadMemory(appKey: appKey, appName: trimmed, now: Date())
        guard !memory.surfaces.isEmpty || memory.current != nil else { return nil }
        return memory
    }

    public func allKnownAppNames() -> [String] {
        loadPersistedMemories()
        return appMemories.values.map { $0.appName }
    }

    public func debugMemories(limit: Int = 20) -> [ContextAppMemory] {
        loadPersistedMemories()
        return Array(
            appMemories.values
                .sorted { $0.lastSeen > $1.lastSeen }
                .prefix(max(0, limit))
        )
    }

    private func loadMemory(appKey: String, appName: String, now: Date) -> ContextAppMemory {
        if let memory = appMemories[appKey] {
            return memory
        }

        let jsonURL = jsonURL(for: appKey)
        if
            let data = try? Data(contentsOf: jsonURL),
            var decoded = try? Self.decoder.decode(ContextAppMemory.self, from: data)
        {
            let mutated = migrateLegacy(memory: &decoded)
            Self.applyDecayAndPrune(memory: &decoded, now: now)
            appMemories[appKey] = decoded
            if mutated {
                persist(decoded, appKey: appKey)
            }
            return decoded
        }

        let memory = ContextAppMemory(appName: appName, firstSeen: now, lastSeen: now)
        appMemories[appKey] = memory
        return memory
    }

    private func loadPersistedMemories() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: appDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        for url in urls where url.pathExtension == "json" {
            let appKey = url.deletingPathExtension().lastPathComponent
            guard appMemories[appKey] == nil else { continue }
            guard
                let data = try? Data(contentsOf: url),
                var decoded = try? Self.decoder.decode(ContextAppMemory.self, from: data)
            else {
                continue
            }
            let mutated = migrateLegacy(memory: &decoded)
            Self.applyDecayAndPrune(memory: &decoded, now: now)
            appMemories[appKey] = decoded
            if mutated {
                persist(decoded, appKey: appKey)
            }
        }
    }

    /// One-shot backfill for memory files written before recipes/habits/current/
    /// fingerprintTokens were durable fields. Defensive — any step that fails
    /// or yields nothing is silently skipped. Returns true if any field was
    /// changed so the caller can persist back to disk.
    private func migrateLegacy(memory: inout ContextAppMemory) -> Bool {
        var mutated = false

        // 1) Backfill habits from surfaces when totals are empty.
        if memory.habits.totalVisits == 0, !memory.surfaces.isEmpty {
            let totalObservations = memory.surfaces.reduce(0) { $0 + max(0, $1.observationCount) }
            let totalClicks = memory.surfaces.reduce(0) { $0 + max(0, $1.clickCount) }
            let derivedVisits = totalObservations + totalClicks
            if derivedVisits > 0 {
                memory.habits.totalVisits = derivedVisits
                mutated = true
            }
            if memory.habits.topSurfaces.isEmpty {
                let topSurfaces = memory.surfaces
                    .sorted { $0.observationCount > $1.observationCount }
                    .prefix(5)
                    .map { surface in
                        ContextSurfaceCount(
                            surfaceID: surface.id,
                            title: surface.title,
                            count: max(1, surface.observationCount)
                        )
                    }
                if !topSurfaces.isEmpty {
                    memory.habits.topSurfaces = Array(topSurfaces)
                    mutated = true
                }
            }
        }

        // 2) Backfill recipes from transitions that have already crossed the
        // promotion threshold. Skip any (from, to) pair already represented.
        if !memory.transitions.isEmpty {
            let existing = Set(memory.recipes.map { "recipe#\($0.fromSurfaceID)->\($0.id.split(separator: ">").last.map(String.init) ?? "")" })
            for transition in memory.transitions {
                guard transition.evidenceCount >= Self.recipePromotionThreshold else { continue }
                let recipeID = "recipe#\(transition.fromSurfaceID)->\(transition.toSurfaceID)"
                if memory.recipes.contains(where: { $0.id == recipeID }) { continue }
                if existing.contains(recipeID) { continue }
                promoteRecipe(
                    fromSurfaceID: transition.fromSurfaceID,
                    fromTitle: transition.fromTitle,
                    toSurfaceID: transition.toSurfaceID,
                    toTitle: transition.toTitle,
                    count: transition.evidenceCount,
                    capturedAt: transition.lastSeen,
                    memory: &memory
                )
                mutated = true
            }
        }

        // 3) Recompute fingerprintTokens for surfaces that have signals but no tokens.
        for index in memory.surfaces.indices {
            guard memory.surfaces[index].fingerprintTokens.isEmpty else { continue }
            var candidates: [String] = []
            candidates.append(contentsOf: memory.surfaces[index].textHighlights)
            candidates.append(contentsOf: memory.surfaces[index].semanticHighlights)
            candidates.append(contentsOf: memory.surfaces[index].controlHighlights)
            candidates.append(contentsOf: memory.surfaces[index].affordanceHighlights)
            guard !candidates.isEmpty else { continue }
            let tokens = Self.canonicalTokens(from: candidates)
            guard !tokens.isEmpty else { continue }
            memory.surfaces[index].fingerprintTokens = tokens
            memory.surfaces[index].surfaceFingerprint = Self.fingerprintHash(tokens)
            mutated = true
        }

        return mutated
    }

    /// Confidence decay + pruning. Runs lazily on load (and right before any
    /// activation render goes out the door) so the agent never sees facts that
    /// the user hasn't actually re-encountered recently.
    private static func applyDecayAndPrune(memory: inout ContextAppMemory, now: Date) {
        for surfaceIndex in memory.surfaces.indices {
            // Facts
            memory.surfaces[surfaceIndex].facts = memory.surfaces[surfaceIndex].facts.compactMap { fact in
                var updated = fact
                let days = max(0, now.timeIntervalSince(fact.lastSeen) / 86400.0)
                if days > 0 {
                    updated.confidence = fact.confidence * pow(confidenceDecayPerDay, days)
                }
                return updated.confidence < confidencePruneFloor ? nil : updated
            }
            // Controls
            memory.surfaces[surfaceIndex].controls = memory.surfaces[surfaceIndex].controls.compactMap { control in
                var updated = control
                let days = max(0, now.timeIntervalSince(control.lastSeen) / 86400.0)
                if days > 0 {
                    updated.confidence = control.confidence * pow(confidenceDecayPerDay, days)
                }
                return updated.confidence < confidencePruneFloor ? nil : updated
            }
            // Negative-memory cap per surface — top-N by evidenceCount, drop the rest.
            // We do this here so old crufty notes from a different layout era get
            // bounded before render.
        }

        // Cap negative notes per-surface by evidence count.
        var groupedNegatives: [String: [ContextNegativeMemory]] = [:]
        for note in memory.negativeNotes {
            groupedNegatives[note.surfaceID, default: []].append(note)
        }
        memory.negativeNotes = groupedNegatives.flatMap { _, notes -> [ContextNegativeMemory] in
            Array(notes.sorted { $0.evidenceCount > $1.evidenceCount }.prefix(negativeNotesPerSurfaceCap))
        }
        .sorted { $0.lastSeen > $1.lastSeen }

        // Recipes decay slower (they're stable habits). Drop if confidence floors out.
        memory.recipes = memory.recipes.compactMap { recipe in
            var updated = recipe
            let days = max(0, now.timeIntervalSince(recipe.lastUsed) / 86400.0)
            if days > 0 {
                updated.confidence = recipe.confidence * pow(recipeUnusedDecayPerDay, days)
            }
            return updated.confidence < confidencePruneFloor ? nil : updated
        }
    }

    @discardableResult
    private func recordSurface(
        providedSurfaceID: String,
        title: String,
        trigger: ContextCaptureTrigger,
        textHighlights: [String],
        fingerprintTokens: [String],
        capturedAt: Date,
        memory: inout ContextAppMemory
    ) -> String {
        let resolvedIndex = findOrMatchSurface(
            providedSurfaceID: providedSurfaceID,
            fingerprintTokens: fingerprintTokens,
            memory: memory
        )

        if let index = resolvedIndex {
            memory.surfaces[index].title = title
            memory.surfaces[index].lastSeen = capturedAt
            memory.surfaces[index].observationCount += 1
            if trigger == .click {
                memory.surfaces[index].clickCount += 1
            }
            if trigger == .activation {
                memory.surfaces[index].activationCount += 1
            }
            memory.surfaces[index].textHighlights = mergedHighlights(
                existing: memory.surfaces[index].textHighlights,
                new: textHighlights
            )

            // Stale fingerprint refresh: if tokens haven't been recomputed in >24h,
            // recompute on this observation and trigger consolidation if drift > 0.4.
            let hoursSinceRefresh = capturedAt.timeIntervalSince(memory.surfaces[index].fingerprintRefreshedAt) / 3600.0
            if hoursSinceRefresh > Self.fingerprintRefreshHours, !fingerprintTokens.isEmpty {
                let drift = 1.0 - Self.jaccard(memory.surfaces[index].fingerprintTokens, fingerprintTokens)
                memory.surfaces[index].fingerprintTokens = fingerprintTokens
                memory.surfaces[index].fingerprintRefreshedAt = capturedAt
                if drift > Self.fingerprintDriftConsolidationThreshold {
                    NSLog("[ContextMemoryStore] Fingerprint drift \(drift) on surface \(memory.surfaces[index].id) — flagging for consolidation")
                    observationsSinceConsolidation[storageKey(for: memory.appName)] = Self.consolidationInterval
                }
            } else {
                memory.surfaces[index].fingerprintTokens = Self.mergedFingerprint(
                    existing: memory.surfaces[index].fingerprintTokens,
                    new: fingerprintTokens
                )
            }
            memory.surfaces[index].surfaceFingerprint = Self.fingerprintHash(memory.surfaces[index].fingerprintTokens)
            return memory.surfaces[index].id
        }

        let newSurface = ContextSurfaceMemory(
            id: providedSurfaceID,
            title: title,
            firstSeen: capturedAt,
            lastSeen: capturedAt,
            observationCount: 1,
            clickCount: trigger == .click ? 1 : 0,
            activationCount: trigger == .activation ? 1 : 0,
            textHighlights: textHighlights,
            fingerprintTokens: fingerprintTokens,
            surfaceFingerprint: Self.fingerprintHash(fingerprintTokens),
            fingerprintRefreshedAt: capturedAt
        )
        memory.surfaces.append(newSurface)
        return providedSurfaceID
    }

    private func findOrMatchSurface(
        providedSurfaceID: String,
        fingerprintTokens: [String],
        memory: ContextAppMemory
    ) -> Int? {
        if let direct = memory.surfaces.firstIndex(where: { $0.id == providedSurfaceID }) {
            return direct
        }
        guard !fingerprintTokens.isEmpty else { return nil }
        var best: (index: Int, score: Double)?
        for (index, surface) in memory.surfaces.enumerated() {
            guard !surface.fingerprintTokens.isEmpty else { continue }
            let score = Self.jaccard(surface.fingerprintTokens, fingerprintTokens)
            if score > Self.surfaceMergeThreshold, score > (best?.score ?? 0) {
                best = (index, score)
            }
        }
        return best?.index
    }

    private func recordTransition(
        from previous: ContextSnapshot,
        to current: ContextSnapshot,
        currentSurfaceID: String,
        currentSurfaceTitle: String,
        memory: inout ContextAppMemory
    ) {
        guard previous.appName == current.appName else { return }
        guard current.trigger == .click || current.trigger == .activation else { return }

        let previousSurfaceID = Self.surfaceID(appName: previous.appName, windowTitle: previous.windowTitle)
        let previousSurfaceTitle = Self.displayTitle(previous.windowTitle)

        if previousSurfaceID == currentSurfaceID {
            guard current.trigger == .click else { return }
            recordStableClick(
                surfaceID: currentSurfaceID,
                surfaceTitle: currentSurfaceTitle,
                capturedAt: current.capturedAt,
                memory: &memory
            )
            return
        }

        let transitionID = "\(previousSurfaceID)->\(currentSurfaceID)#\(current.trigger.rawValue)"
        if let index = memory.transitions.firstIndex(where: { $0.id == transitionID }) {
            memory.transitions[index].lastSeen = current.capturedAt
            memory.transitions[index].evidenceCount += 1
            memory.transitions[index].fromTitle = previousSurfaceTitle
            memory.transitions[index].toTitle = currentSurfaceTitle
        } else {
            memory.transitions.append(ContextTransitionMemory(
                id: transitionID,
                fromSurfaceID: previousSurfaceID,
                fromTitle: previousSurfaceTitle,
                toSurfaceID: currentSurfaceID,
                toTitle: currentSurfaceTitle,
                trigger: current.trigger,
                firstSeen: current.capturedAt,
                lastSeen: current.capturedAt,
                evidenceCount: 1
            ))
        }
    }

    private func recordStableClick(
        surfaceID: String,
        surfaceTitle: String,
        capturedAt: Date,
        memory: inout ContextAppMemory
    ) {
        let noteID = "stable-click#\(surfaceID)"
        let note = "Recent clicks updated this surface in place. Treat this as weak evidence until a specific control or region is learned."

        if let index = memory.negativeNotes.firstIndex(where: { $0.id == noteID }) {
            memory.negativeNotes[index].surfaceTitle = surfaceTitle
            memory.negativeNotes[index].lastSeen = capturedAt
            memory.negativeNotes[index].evidenceCount = min(memory.negativeNotes[index].evidenceCount + 1, 3)
        } else {
            memory.negativeNotes.append(ContextNegativeMemory(
                id: noteID,
                surfaceID: surfaceID,
                surfaceTitle: surfaceTitle,
                note: note,
                firstSeen: capturedAt,
                lastSeen: capturedAt,
                evidenceCount: 1
            ))
        }
    }

    private func recordRecentActivity(
        app: String,
        surfaceID: String,
        surfaceTitle: String,
        summary: String,
        trigger: ContextCaptureTrigger,
        at timestamp: Date,
        memory: inout ContextAppMemory
    ) {
        let entry = ContextRecentActivityEntry(
            timestamp: timestamp,
            app: app,
            surfaceID: surfaceID,
            surfaceTitle: surfaceTitle,
            summary: summary,
            trigger: trigger
        )
        if let last = memory.recent.last,
           last.surfaceID == surfaceID,
           last.summary == summary,
           timestamp.timeIntervalSince(last.timestamp) < 5 {
            return
        }
        memory.recent.append(entry)
        if memory.recent.count > Self.recentEntryCap {
            memory.recent.removeFirst(memory.recent.count - Self.recentEntryCap)
        }
    }

    private func recordHabit(
        surfaceID: String,
        surfaceTitle: String,
        previousSurfaceID: String?,
        previousSurfaceTitle: String?,
        sameApp: Bool,
        previousSeenAt: Date?,
        at timestamp: Date,
        memory: inout ContextAppMemory
    ) {
        memory.habits.totalVisits += 1
        if let last = previousSeenAt, sameApp {
            let elapsed = max(0, Int(timestamp.timeIntervalSince(last) * 1000))
            // Cap any single dwell at 5 minutes to avoid runaway counters from idle gaps.
            memory.habits.totalDwellMs += min(elapsed, 5 * 60 * 1000)
        }

        if let index = memory.habits.topSurfaces.firstIndex(where: { $0.surfaceID == surfaceID }) {
            memory.habits.topSurfaces[index].count += 1
            memory.habits.topSurfaces[index].title = surfaceTitle
        } else {
            memory.habits.topSurfaces.append(ContextSurfaceCount(
                surfaceID: surfaceID,
                title: surfaceTitle,
                count: 1
            ))
        }
        memory.habits.topSurfaces.sort { $0.count > $1.count }
        if memory.habits.topSurfaces.count > 10 {
            memory.habits.topSurfaces = Array(memory.habits.topSurfaces.prefix(10))
        }

        if let fromID = previousSurfaceID, let fromTitle = previousSurfaceTitle, sameApp, fromID != surfaceID {
            var updatedCount = 1
            if let index = memory.habits.commonTransitions.firstIndex(where: {
                $0.fromSurfaceID == fromID && $0.toSurfaceID == surfaceID
            }) {
                memory.habits.commonTransitions[index].count += 1
                memory.habits.commonTransitions[index].toTitle = surfaceTitle
                memory.habits.commonTransitions[index].fromTitle = fromTitle
                updatedCount = memory.habits.commonTransitions[index].count
            } else {
                memory.habits.commonTransitions.append(ContextTransitionCount(
                    fromSurfaceID: fromID,
                    toSurfaceID: surfaceID,
                    fromTitle: fromTitle,
                    toTitle: surfaceTitle,
                    count: 1
                ))
            }
            memory.habits.commonTransitions.sort { $0.count > $1.count }
            if memory.habits.commonTransitions.count > 12 {
                memory.habits.commonTransitions = Array(memory.habits.commonTransitions.prefix(12))
            }

            // Layer 6: promote/refresh a task recipe once a transition has been
            // observed ≥ recipePromotionThreshold times. Recipe lives at app-level,
            // keyed off (fromSurfaceID -> toSurfaceID).
            if updatedCount >= Self.recipePromotionThreshold {
                promoteRecipe(
                    fromSurfaceID: fromID,
                    fromTitle: fromTitle,
                    toSurfaceID: surfaceID,
                    toTitle: surfaceTitle,
                    count: updatedCount,
                    capturedAt: timestamp,
                    memory: &memory
                )
            }
        }

        let bucket = Self.timeOfDayBucket(for: timestamp)
        memory.habits.timeOfDayBuckets[bucket, default: 0] += 1
    }

    private func promoteRecipe(
        fromSurfaceID: String,
        fromTitle: String,
        toSurfaceID: String,
        toTitle: String,
        count: Int,
        capturedAt: Date,
        memory: inout ContextAppMemory
    ) {
        let appKey = storageKey(for: memory.appName)
        let recipeID = "recipe#\(fromSurfaceID)->\(toSurfaceID)"
        let cleanFrom = Self.displayTitle(fromTitle)
        let cleanTo = Self.displayTitle(toTitle)
        let recipeName = "Navigate from \(cleanFrom) to \(cleanTo)"

        // Build navigation steps. We deliberately do NOT use the destination's
        // affordanceHighlights as steps — those describe actions available ON
        // the destination, not the click that gets you there. Instead, look at
        // the SOURCE surface for any workflow hint that mentions the
        // destination, then fall back to a clean template that names both
        // surfaces correctly.
        var stepsProse: [String] = []
        let sourceWorkflows = memory.surfaces.first(where: { $0.id == fromSurfaceID })?.affordanceHighlights ?? []
        let destLower = cleanTo.lowercased()
        let matchingHint = sourceWorkflows.first { hint in
            hint.count <= 140 && hint.lowercased().contains(destLower)
        }
        if let matchingHint {
            stepsProse.append(matchingHint)
        } else {
            stepsProse.append("From '\(cleanFrom)', click the control or tab labeled '\(cleanTo)'.")
        }
        stepsProse.append("Verify '\(cleanTo)' is the active surface before continuing.")

        let keywords = Self.deriveIntentKeywords(name: recipeName, destinationTitle: cleanTo)

        if let index = memory.recipes.firstIndex(where: { $0.id == recipeID }) {
            memory.recipes[index].evidenceCount = max(memory.recipes[index].evidenceCount, count)
            memory.recipes[index].lastUsed = capturedAt
            memory.recipes[index].name = recipeName
            memory.recipes[index].intentKeywords = keywords
            // Promote confidence on every fresh use, capped at 0.98.
            memory.recipes[index].confidence = min(0.98, memory.recipes[index].confidence + 0.05)
            // Always refresh stepsProse — older recipes may have been written
            // by buggy step-synthesis code that used destination affordances
            // as steps. The new template is deterministic and correct.
            memory.recipes[index].stepsProse = stepsProse
        } else {
            memory.recipes.append(ContextTaskRecipe(
                id: recipeID,
                appKey: appKey,
                fromSurfaceID: fromSurfaceID,
                name: recipeName,
                intentKeywords: keywords,
                stepsProse: stepsProse,
                evidenceCount: count,
                firstSeen: capturedAt,
                lastUsed: capturedAt,
                confidence: 0.5
            ))
        }
        memory.recipes.sort { $0.evidenceCount > $1.evidenceCount }
        if memory.recipes.count > 24 {
            memory.recipes = Array(memory.recipes.prefix(24))
        }
    }

    private static func deriveIntentKeywords(name: String, destinationTitle: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "a", "an", "to", "of", "in", "on", "with", "for", "and",
            "or", "this", "that", "is", "are", "open", "go", "from"
        ]
        let raw = (name + " " + destinationTitle).lowercased()
        var seen = Set<String>()
        var out: [String] = []
        for word in raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let str = String(word)
            guard str.count >= 3, !stopwords.contains(str) else { continue }
            if seen.insert(str).inserted {
                out.append(str)
            }
        }
        return out
    }

    private func recordSemanticObservation(
        _ observation: ContextGeminiObservation,
        surfaceID: String,
        capturedAt: Date,
        memory: inout ContextAppMemory
    ) {
        guard let index = memory.surfaces.firstIndex(where: { $0.id == surfaceID }) else { return }

        let controls = observation.visibleControls.map { control -> String in
            if let actionHint = control.actionHint, !actionHint.isEmpty {
                return "\(control.label) (\(control.role), \(control.region)): \(actionHint)"
            }
            return "\(control.label) (\(control.role), \(control.region))"
        }

        memory.surfaces[index].semanticHighlights = mergedHighlights(
            existing: memory.surfaces[index].semanticHighlights,
            new: semanticHighlights(from: observation),
            maxCount: 8
        )
        memory.surfaces[index].controlHighlights = mergedHighlights(
            existing: memory.surfaces[index].controlHighlights,
            new: controls,
            maxCount: 16
        )
        memory.surfaces[index].affordanceHighlights = mergedHighlights(
            existing: memory.surfaces[index].affordanceHighlights,
            new: observation.affordances + observation.workflowHints + observation.navigationPaths,
            maxCount: 16
        )
        memory.surfaces[index].uncertaintyHighlights = mergedHighlights(
            existing: memory.surfaces[index].uncertaintyHighlights,
            new: observation.uncertainty + observation.negativeCues,
            maxCount: 10
        )
        memory.surfaces[index].facts = mergeFacts(
            existing: memory.surfaces[index].facts,
            new: structuredFacts(from: observation, capturedAt: capturedAt),
            maxCount: 36
        )
        memory.surfaces[index].controls = mergeControls(
            existing: memory.surfaces[index].controls,
            new: structuredControls(from: observation, capturedAt: capturedAt),
            maxCount: 32
        )
        memory.surfaces[index].entities = mergeEntities(
            existing: memory.surfaces[index].entities,
            new: structuredEntities(from: observation, capturedAt: capturedAt),
            maxCount: 40
        )

        // Layer 1: synthesize a prose description of the surface — what it IS,
        // not what's happening right now. Refresh when the new observation has
        // more detail than what's stored.
        let synthesized = Self.synthesizeSurfaceDescription(
            title: memory.surfaces[index].title,
            appName: memory.appName,
            observation: observation
        )
        if !synthesized.isEmpty,
           synthesized.count > memory.surfaces[index].description.count
            || memory.surfaces[index].description.isEmpty {
            memory.surfaces[index].description = synthesized
        }
    }

    private static func synthesizeSurfaceDescription(
        title: String,
        appName: String,
        observation: ContextGeminiObservation
    ) -> String {
        var parts: [String] = []
        let trimmedSummary = observation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            parts.append(trimmedSummary)
        } else {
            let kind = observation.screenType.trimmingCharacters(in: .whitespacesAndNewlines)
            if !kind.isEmpty {
                parts.append("\(title) is a \(kind) inside \(appName).")
            } else {
                parts.append("\(title) inside \(appName).")
            }
        }
        let layout = observation.layoutSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !layout.isEmpty {
            parts.append("Layout: \(layout)")
        }
        if !observation.landmarks.isEmpty {
            let landmarkText = observation.landmarks
                .prefix(4)
                .joined(separator: ", ")
            parts.append("Key regions: \(landmarkText).")
        }
        if !observation.dataRegions.isEmpty {
            let regionText = observation.dataRegions
                .prefix(3)
                .joined(separator: "; ")
            parts.append("Shows: \(regionText).")
        }
        return parts.joined(separator: " ")
    }

    private func promoteAppLevelEntities(
        from observation: ContextGeminiObservation,
        surfaceID: String,
        capturedAt: Date,
        memory: inout ContextAppMemory
    ) {
        for raw in observation.entities {
            guard let cleanedRaw = ContextTextSignalFilter.memoryText(raw, maxLength: 140) else { continue }
            // Gemini's entityContent lane now emits "<label> [<type>]". Parse
            // off the bracketed suffix; if absent (older lanes, or model
            // didn't follow the rule), fall back to the heuristic.
            let (label, parsedType) = Self.parseTypedEntity(cleanedRaw)
            guard let label = ContextTextSignalFilter.memoryText(label, maxLength: 120) else { continue }
            let entityID = "entity#\(Self.normalize(label))"
            let resolvedType = parsedType ?? Self.guessEntityType(label)
            if let index = memory.entities.firstIndex(where: { $0.id == entityID }) {
                memory.entities[index].lastSeen = capturedAt
                memory.entities[index].evidenceCount += 1
                memory.entities[index].mentionCount += 1
                memory.entities[index].confidence = max(memory.entities[index].confidence, observation.confidence)
                // Upgrade type if we now have a model-classified one and the
                // stored value was the generic fallback.
                if parsedType != nil, memory.entities[index].type == "entity" || memory.entities[index].type == "other" {
                    memory.entities[index].type = resolvedType
                }
                if !memory.entities[index].surfaces.contains(surfaceID) {
                    memory.entities[index].surfaces.append(surfaceID)
                }
            } else {
                memory.entities.append(ContextEntityMemory(
                    id: entityID,
                    text: label,
                    source: observation.source.rawValue,
                    firstSeen: capturedAt,
                    lastSeen: capturedAt,
                    evidenceCount: 1,
                    confidence: observation.confidence,
                    label: label,
                    type: resolvedType,
                    mentionCount: 1,
                    surfaces: [surfaceID]
                ))
            }
        }
        memory.entities.sort { $0.mentionCount > $1.mentionCount }
        if memory.entities.count > 60 {
            memory.entities = Array(memory.entities.prefix(60))
        }
    }

    private func promoteStableStateFacts(memory: inout ContextAppMemory) {
        var counts: [String: Int] = [:]
        var firstSeenByKey: [String: ContextMemoryFact] = [:]
        for surface in memory.surfaces {
            for fact in surface.facts where fact.category == "state" {
                let key = Self.normalize(fact.text)
                guard !key.isEmpty else { continue }
                counts[key, default: 0] += 1
                if firstSeenByKey[key] == nil {
                    firstSeenByKey[key] = fact
                }
            }
        }
        for (key, count) in counts where count >= 3 {
            guard let template = firstSeenByKey[key] else { continue }
            for index in memory.surfaces.indices {
                let stableID = "fact#state-stable#\(key)"
                if memory.surfaces[index].facts.contains(where: { $0.id == stableID }) {
                    continue
                }
                if memory.surfaces[index].facts.contains(where: {
                    $0.category == "state" && Self.normalize($0.text) == key
                }) {
                    memory.surfaces[index].facts.append(ContextMemoryFact(
                        id: stableID,
                        category: "state-stable",
                        text: template.text,
                        durability: "stable",
                        source: template.source,
                        firstSeen: template.firstSeen,
                        lastSeen: template.lastSeen,
                        evidenceCount: count,
                        confidence: template.confidence
                    ))
                }
            }
        }
    }

    private func semanticHighlights(from observation: ContextGeminiObservation) -> [String] {
        memoryHighlights([
            observation.summary,
            observation.primaryTask.isEmpty ? nil : "Task: \(observation.primaryTask)",
            observation.layoutSummary.isEmpty ? nil : "Layout: \(observation.layoutSummary)",
            observation.contentSummary.isEmpty ? nil : "Content: \(observation.contentSummary)"
        ].compactMap { $0 } + observation.memoryCandidates + observation.stateIndicators + observation.dataRegions)
    }

    private func structuredFacts(
        from observation: ContextGeminiObservation,
        capturedAt: Date
    ) -> [ContextMemoryFact] {
        var pairs: [(String, String, String)] = []
        addFact(observation.summary, category: "summary", durability: durability(for: observation.summary, preferred: "stable"), to: &pairs)
        addFact(observation.primaryTask, category: "task", durability: "transient", to: &pairs)
        addFact(observation.layoutSummary, category: "layout", durability: durability(for: observation.layoutSummary, preferred: "stable"), to: &pairs)
        addFact(observation.contentSummary, category: "content", durability: "transient", to: &pairs)
        for value in observation.stateIndicators {
            addFact(value, category: "state", durability: "transient", to: &pairs)
        }
        for value in observation.dataRegions {
            addFact(value, category: "data-region", durability: "stable", to: &pairs)
        }
        for value in observation.navigationPaths {
            addFact(value, category: "navigation", durability: "stable", to: &pairs)
        }
        for value in observation.workflowHints {
            addFact(value, category: "workflow", durability: "stable", to: &pairs)
        }
        for value in observation.affordances {
            addFact(value, category: "affordance", durability: "stable", to: &pairs)
        }
        for value in observation.memoryCandidates {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = cleaned.lowercased()
            let durability = lower.hasPrefix("transient:") ? "transient" : "stable"
            let text = cleaned
                .replacingOccurrences(of: #"(?i)^stable:\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)^transient:\s*"#, with: "", options: .regularExpression)
            addFact(text, category: "memory", durability: self.durability(for: text, preferred: durability), to: &pairs)
        }

        return pairs.map { category, text, durability in
            let safeText = ContextTextSignalFilter.redacted(text)
            return ContextMemoryFact(
                id: "fact#\(Self.normalize(category))#\(Self.normalize(safeText))",
                category: category,
                text: safeText,
                durability: durability,
                source: observation.source.rawValue,
                firstSeen: capturedAt,
                lastSeen: capturedAt,
                evidenceCount: 1,
                confidence: observation.confidence
            )
        }
    }

    private func addFact(
        _ value: String,
        category: String,
        durability: String,
        to pairs: inout [(String, String, String)]
    ) {
        guard let text = ContextTextSignalFilter.memoryText(value) else { return }
        pairs.append((category, text, durability))
    }

    private func durability(for value: String, preferred: String) -> String {
        ContextTextSignalFilter.looksTransientState(value) ? "transient" : preferred
    }

    private func structuredControls(
        from observation: ContextGeminiObservation,
        capturedAt: Date
    ) -> [ContextControlMemory] {
        observation.visibleControls.map { control in
            let label = ContextTextSignalFilter.redacted(control.label)
            let role = ContextTextSignalFilter.redacted(control.role)
            let region = ContextTextSignalFilter.redacted(control.region)
            let actionHint = control.actionHint.flatMap { ContextTextSignalFilter.memoryText($0) } ?? ""
            let safeLabel = label.isEmpty ? "Unlabeled control" : label
            let safeRole = role.isEmpty ? "control" : role
            let safeRegion = region.isEmpty ? "unknown-region" : region
            return ContextControlMemory(
                id: "control#\(Self.normalize(safeLabel))#\(Self.normalize(safeRole))#\(Self.normalize(safeRegion))",
                label: safeLabel,
                role: safeRole,
                region: safeRegion,
                actionHint: actionHint,
                firstSeen: capturedAt,
                lastSeen: capturedAt,
                evidenceCount: 1,
                confidence: control.confidence,
                verbPhrase: Self.deriveVerbPhrase(label: safeLabel, role: safeRole, actionHint: actionHint)
            )
        }
    }

    private static func deriveVerbPhrase(label: String, role: String, actionHint: String) -> String {
        // Layer 2: turn noun-shaped affordances into verb-shaped imperatives.
        // Prefer the action hint when present (it usually starts with a verb); otherwise
        // infer from role + label.
        let trimmedHint = actionHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHint.isEmpty {
            let lowerFirst = trimmedHint.first.map(String.init)?.lowercased() ?? ""
            if let first = trimmedHint.first, first.isLetter {
                return lowerFirst + trimmedHint.dropFirst()
            }
            return trimmedHint
        }

        let lowerLabel = label.lowercased()
        let lowerRole = role.lowercased()
        let actionVerbs: [String: String] = [
            "send": "send the current message",
            "submit": "submit the form",
            "save": "save changes",
            "cancel": "dismiss without saving",
            "close": "close this view",
            "search": "open search",
            "back": "go back",
            "next": "advance to the next step",
            "open": "open it",
            "delete": "delete the item",
            "add": "create a new item",
            "new": "create a new item",
            "edit": "edit the item"
        ]
        for (needle, phrase) in actionVerbs where lowerLabel.contains(needle) {
            return phrase
        }

        switch lowerRole {
        case "button", "submit":
            return "trigger '\(label)'"
        case "link", "menu-item", "menuitem":
            return "navigate via '\(label)'"
        case "tab":
            return "switch to the '\(label)' tab"
        case "textfield", "input", "text-field", "search":
            return "type into '\(label)'"
        case "sidebar-entry", "sidebar-item", "list-item", "listitem", "row":
            return "switch to '\(label)'"
        case "toggle", "checkbox", "switch":
            return "toggle '\(label)'"
        case "icon-button":
            return "press the '\(label)' icon"
        default:
            return "interact with '\(label)'"
        }
    }

    private func structuredEntities(
        from observation: ContextGeminiObservation,
        capturedAt: Date
    ) -> [ContextEntityMemory] {
        observation.entities.compactMap { entity in
            guard let text = ContextTextSignalFilter.memoryText(entity, maxLength: 120) else { return nil }
            return ContextEntityMemory(
                id: "entity#\(Self.normalize(text))",
                text: text,
                source: observation.source.rawValue,
                firstSeen: capturedAt,
                lastSeen: capturedAt,
                evidenceCount: 1,
                confidence: observation.confidence,
                label: text,
                type: Self.guessEntityType(text),
                mentionCount: 1,
                surfaces: []
            )
        }
    }

    private func mergeFacts(
        existing: [ContextMemoryFact],
        new: [ContextMemoryFact],
        maxCount: Int
    ) -> [ContextMemoryFact] {
        var merged = existing
        for fact in new {
            if let index = merged.firstIndex(where: { $0.id == fact.id }) {
                merged[index].lastSeen = fact.lastSeen
                merged[index].evidenceCount += 1
                merged[index].confidence = max(merged[index].confidence, fact.confidence)
                merged[index].source = fact.source
            } else {
                merged.append(fact)
            }
        }
        return Array(merged.sorted { $0.lastSeen > $1.lastSeen }.prefix(maxCount))
    }

    private func mergeControls(
        existing: [ContextControlMemory],
        new: [ContextControlMemory],
        maxCount: Int
    ) -> [ContextControlMemory] {
        var merged = existing
        for control in new {
            if let index = merged.firstIndex(where: { $0.id == control.id }) {
                merged[index].lastSeen = control.lastSeen
                merged[index].evidenceCount += 1
                merged[index].confidence = max(merged[index].confidence, control.confidence)
                if !control.actionHint.isEmpty {
                    merged[index].actionHint = control.actionHint
                }
                if !control.verbPhrase.isEmpty {
                    merged[index].verbPhrase = control.verbPhrase
                }
            } else {
                merged.append(control)
            }
        }
        return Array(merged.sorted { $0.lastSeen > $1.lastSeen }.prefix(maxCount))
    }

    private func mergeEntities(
        existing: [ContextEntityMemory],
        new: [ContextEntityMemory],
        maxCount: Int
    ) -> [ContextEntityMemory] {
        var merged = existing
        for entity in new {
            if let index = merged.firstIndex(where: { $0.id == entity.id }) {
                merged[index].lastSeen = entity.lastSeen
                merged[index].evidenceCount += 1
                merged[index].mentionCount += 1
                merged[index].confidence = max(merged[index].confidence, entity.confidence)
                merged[index].source = entity.source
            } else {
                merged.append(entity)
            }
        }
        return Array(merged.sorted { $0.lastSeen > $1.lastSeen }.prefix(maxCount))
    }

    private func tickConsolidation(appKey: String) {
        let count = (observationsSinceConsolidation[appKey] ?? 0) + 1
        if count < Self.consolidationInterval {
            observationsSinceConsolidation[appKey] = count
            return
        }
        observationsSinceConsolidation[appKey] = 0
        guard var memory = appMemories[appKey] else { return }
        consolidateSurfaces(in: &memory)
        appMemories[appKey] = memory
    }

    private func consolidateSurfaces(in memory: inout ContextAppMemory) {
        guard memory.surfaces.count > 1 else { return }
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in 0..<memory.surfaces.count {
                for j in (i + 1)..<memory.surfaces.count {
                    let left = memory.surfaces[i]
                    let right = memory.surfaces[j]
                    guard !left.fingerprintTokens.isEmpty, !right.fingerprintTokens.isEmpty else { continue }
                    let score = Self.jaccard(left.fingerprintTokens, right.fingerprintTokens)
                    if score > Self.surfaceConsolidationThreshold {
                        memory.surfaces[i] = mergeSurfaces(into: left, other: right)
                        memory.surfaces.remove(at: j)
                        didMerge = true
                        break outer
                    }
                }
            }
        }
    }

    private func mergeSurfaces(into primary: ContextSurfaceMemory, other: ContextSurfaceMemory) -> ContextSurfaceMemory {
        var merged = primary
        merged.firstSeen = min(primary.firstSeen, other.firstSeen)
        merged.lastSeen = max(primary.lastSeen, other.lastSeen)
        merged.observationCount += other.observationCount
        merged.clickCount += other.clickCount
        merged.activationCount += other.activationCount
        merged.textHighlights = mergedHighlights(existing: primary.textHighlights, new: other.textHighlights)
        merged.semanticHighlights = mergedHighlights(existing: primary.semanticHighlights, new: other.semanticHighlights, maxCount: 8)
        merged.controlHighlights = mergedHighlights(existing: primary.controlHighlights, new: other.controlHighlights, maxCount: 16)
        merged.affordanceHighlights = mergedHighlights(existing: primary.affordanceHighlights, new: other.affordanceHighlights, maxCount: 16)
        merged.uncertaintyHighlights = mergedHighlights(existing: primary.uncertaintyHighlights, new: other.uncertaintyHighlights, maxCount: 10)
        merged.facts = mergeFacts(existing: primary.facts, new: other.facts, maxCount: 36)
        merged.controls = mergeControls(existing: primary.controls, new: other.controls, maxCount: 32)
        merged.entities = mergeEntities(existing: primary.entities, new: other.entities, maxCount: 40)
        merged.fingerprintTokens = Self.mergedFingerprint(existing: primary.fingerprintTokens, new: other.fingerprintTokens)
        merged.surfaceFingerprint = Self.fingerprintHash(merged.fingerprintTokens)
        if other.title.count > merged.title.count, !other.title.lowercased().contains("untitled") {
            merged.title = other.title
        }
        return merged
    }

    private func persist(_ memory: ContextAppMemory, appKey: String) {
        do {
            let jsonData = try Self.encoder.encode(memory)
            try jsonData.write(to: jsonURL(for: appKey), options: .atomic)

            let markdown = ContextMemoryRenderer.markdown(for: memory)
            try markdown.write(to: markdownURL(for: appKey), atomically: true, encoding: .utf8)
        } catch {
            NSLog("[ContextMemoryStore] Failed to persist memory for \(memory.appName): \(error)")
        }
    }

    private func appendObservation(_ snapshot: ContextSnapshot, surfaceID: String) {
        let record = ContextMemoryObservationRecord(
            id: snapshot.id,
            capturedAt: snapshot.capturedAt,
            trigger: snapshot.trigger,
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            surfaceID: surfaceID,
            recognizedText: textHighlights(from: snapshot, maxCount: 20),
            cursorX: snapshot.cursorLocation.map { Int($0.x) },
            cursorY: snapshot.cursorLocation.map { Int($0.y) },
            width: snapshot.width,
            height: snapshot.height
        )

        do {
            let data = try Self.jsonlEncoder.encode(record) + Data([0x0A])
            if FileManager.default.fileExists(atPath: observationsURL.path) {
                let handle = try FileHandle(forWritingTo: observationsURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: observationsURL, options: .atomic)
            }
        } catch {
            NSLog("[ContextMemoryStore] Failed to append observation: \(error)")
        }
    }

    private func jsonURL(for appKey: String) -> URL {
        appDirectoryURL.appendingPathComponent("\(appKey).json")
    }

    private func markdownURL(for appKey: String) -> URL {
        appDirectoryURL.appendingPathComponent("\(appKey).md")
    }

    private func textHighlights(from snapshot: ContextSnapshot, maxCount: Int = 12) -> [String] {
        memoryHighlights(ContextTextSignalFilter.usefulText(from: snapshot.recognizedText, maxCount: maxCount * 2))
            .prefix(maxCount)
            .map { $0 }
    }

    private func mergedHighlights(existing: [String], new: [String], maxCount: Int = 24) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []

        for text in new + existing {
            guard let cleaned = ContextTextSignalFilter.memoryText(text) else { continue }
            let key = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(cleaned)
            if merged.count >= maxCount {
                break
            }
        }

        return merged
    }

    private func memoryHighlights(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            guard let cleaned = ContextTextSignalFilter.memoryText(value) else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(cleaned)
        }
        return output
    }

    private func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func storageKey(for appName: String) -> String {
        let cleaned = appName
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "-")
            .joined(separator: "-")
        return cleaned.isEmpty ? "unknown-app" : cleaned
    }

    private static func surfaceID(appName: String, windowTitle: String) -> String {
        "\(normalize(appName))#\(normalize(displayTitle(windowTitle)))"
    }

    private static func displayTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled window" : title
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
    }

    private static func fingerprintTokens(forOCR recognizedText: [ContextRecognizedText]) -> [String] {
        let raw = recognizedText
            .sorted { $0.confidence > $1.confidence }
            .map(\.text)
        return canonicalTokens(from: raw)
    }

    private static func fingerprintTokens(forSemantic observation: ContextGeminiObservation) -> [String] {
        var raw = observation.landmarks
        raw.append(contentsOf: observation.visibleControls.map(\.label))
        raw.append(contentsOf: observation.dataRegions)
        raw.append(contentsOf: observation.navigationPaths)
        raw.append(observation.surfaceLabel)
        raw.append(observation.screenType)
        return canonicalTokens(from: raw)
    }

    private static func canonicalTokens(from values: [String]) -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        for value in values {
            let lower = value.lowercased()
            let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            for word in words {
                guard word.count >= 3 else { continue }
                guard !isVolatileToken(word) else { continue }
                if seen.insert(word).inserted {
                    tokens.append(word)
                }
                if tokens.count >= 12 {
                    return tokens
                }
            }
        }
        return tokens
    }

    private static func isVolatileToken(_ word: String) -> Bool {
        if word == "cpu" { return true }
        if word.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return true }
        // Drop bare time-of-day fragments
        if word == "am" || word == "pm" { return true }
        // Drop numbers with more than 2 digits (likely timestamps, percentages, counts).
        if Int(word) != nil, word.count > 2 { return true }
        // Drop percentages embedded in the token (e.g. "21%").
        if word.contains("%") { return true }
        // Day-of-week prefixes used in OCR clock fragments.
        let weekdays: Set<String> = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        if weekdays.contains(word) { return true }
        let months: Set<String> = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        if months.contains(word) { return true }
        return false
    }

    private static func mergedFingerprint(existing: [String], new: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        // Running average: keep tokens that appear in either set, preferring shared ones first.
        let shared = Set(existing).intersection(Set(new))
        for token in existing where shared.contains(token) {
            if seen.insert(token).inserted { output.append(token) }
        }
        for token in existing where !shared.contains(token) {
            if seen.insert(token).inserted { output.append(token) }
            if output.count >= 12 { break }
        }
        for token in new {
            if output.count >= 12 { break }
            if seen.insert(token).inserted { output.append(token) }
        }
        return output
    }

    private static func fingerprintHash(_ tokens: [String]) -> String {
        guard !tokens.isEmpty else { return "" }
        let joined = tokens.sorted().joined(separator: " ")
        let digest = Insecure.SHA1.hash(data: Data(joined.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let setA = Set(a)
        let setB = Set(b)
        guard !setA.isEmpty || !setB.isEmpty else { return 0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private static func timeOfDayBucket(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }

    private static let knownEntityTypes: Set<String> = [
        "person", "file", "url", "app", "ticket", "record", "error",
        "message", "document", "account", "folder", "project", "command", "other"
    ]

    /// Parse Gemini's "<label> [<type>]" convention. Returns the bare label
    /// and the parsed type if present and known; otherwise returns the
    /// original string and nil.
    private static func parseTypedEntity(_ raw: String) -> (String, String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("]"),
              let openBracketIdx = trimmed.lastIndex(of: "[") else {
            return (trimmed, nil)
        }
        let typeStart = trimmed.index(after: openBracketIdx)
        let typeEnd = trimmed.index(before: trimmed.endIndex)
        guard typeStart < typeEnd else { return (trimmed, nil) }
        let typeRaw = String(trimmed[typeStart..<typeEnd]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard knownEntityTypes.contains(typeRaw) else { return (trimmed, nil) }
        let label = String(trimmed[..<openBracketIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return (trimmed, nil) }
        return (label, typeRaw)
    }

    private static func guessEntityType(_ text: String) -> String {
        let lower = text.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // URLs
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return "url" }
        if lower.contains(".com/") || lower.contains(".io/") || lower.contains(".dev/") || lower.contains(".app/") || lower.contains(".org/") {
            return "url"
        }
        // Email-shaped tokens
        if lower.contains("@"), lower.contains(".") { return "account" }
        // Ticket-shaped (LETTERS-NUMBERS)
        if trimmed.range(of: "^[A-Z]{2,}-[0-9]+$", options: .regularExpression) != nil { return "ticket" }
        // File paths and known extensions
        let fileExts = ["swift", "ts", "tsx", "js", "py", "rs", "go", "java", "kt", "c", "cpp", "h", "md", "json", "yml", "yaml", "toml", "html", "css", "sh", "txt", "pdf", "csv", "log"]
        if trimmed.contains("/") || trimmed.hasPrefix(".") {
            if let dotIdx = trimmed.lastIndex(of: "."),
               let ext = trimmed[trimmed.index(after: dotIdx)...].split(separator: " ").first.map(String.init)?.lowercased(),
               fileExts.contains(ext) {
                return "file"
            }
            if trimmed.contains("/"), trimmed.hasSuffix(".sh") || trimmed.hasPrefix("./") { return "file" }
            if trimmed.contains("/") { return "file" }
        }
        // Error-shaped (CamelCase ending in "Error" / "Exception")
        if trimmed.hasSuffix("Error") || trimmed.hasSuffix("Exception") { return "error" }
        // Project / folder hints
        if lower.hasSuffix(" project") || lower.contains(" project ") { return "project" }
        if lower.contains("folder") { return "folder" }
        // Command-line hints
        if trimmed.hasPrefix("./") || lower.hasPrefix("$ ") || lower.hasPrefix("npm ") || lower.hasPrefix("git ") {
            return "command"
        }
        // Person heuristic — two capitalized words
        if trimmed.range(of: "^[A-Z][a-z]+( [A-Z][a-z]+){1,2}$", options: .regularExpression) != nil {
            return "person"
        }
        return "other"
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var jsonlEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
