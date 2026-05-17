//
//  ContextMemoryStore.swift
//  Agent in the Notch
//
//  Persists lightweight UI memory learned from screen captures. This is the
//  first native learning layer: app/window surfaces, observed transitions, and
//  same-surface click evidence.
//

import Darwin
import Foundation

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
    private var previousSnapshot: ContextSnapshot?

    public init(rootURL: URL? = nil) {
        let baseURL = rootURL ?? Self.defaultDirectoryURL
        self.appDirectoryURL = baseURL.appendingPathComponent("Apps", isDirectory: true)
        self.observationsURL = baseURL.appendingPathComponent("observations.jsonl")

        try? FileManager.default.createDirectory(at: appDirectoryURL, withIntermediateDirectories: true)
    }

    public func record(_ snapshot: ContextSnapshot) {
        let appKey = storageKey(for: snapshot.appName)
        var memory = loadMemory(appKey: appKey, appName: snapshot.appName, now: snapshot.capturedAt)
        let surfaceID = Self.surfaceID(appName: snapshot.appName, windowTitle: snapshot.windowTitle)
        let surfaceTitle = Self.displayTitle(snapshot.windowTitle)

        memory.lastSeen = snapshot.capturedAt
        recordSurface(
            surfaceID: surfaceID,
            title: surfaceTitle,
            trigger: snapshot.trigger,
            textHighlights: textHighlights(from: snapshot),
            capturedAt: snapshot.capturedAt,
            memory: &memory
        )

        if let previousSnapshot {
            recordTransition(
                from: previousSnapshot,
                to: snapshot,
                currentSurfaceID: surfaceID,
                currentSurfaceTitle: surfaceTitle,
                memory: &memory
            )
        }

        previousSnapshot = snapshot
        appMemories[appKey] = memory
        persist(memory, appKey: appKey)
        appendObservation(snapshot, surfaceID: surfaceID)
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
        let surfaceID = clean(observation.surfaceID)
            ?? Self.surfaceID(appName: appName, windowTitle: surfaceTitle)

        memory.lastSeen = capturedAt
        recordSurface(
            surfaceID: surfaceID,
            title: surfaceTitle,
            trigger: .manual,
            textHighlights: memoryHighlights(observation.entities + observation.landmarks),
            capturedAt: capturedAt,
            memory: &memory
        )
        recordSemanticObservation(
            observation,
            surfaceID: surfaceID,
            capturedAt: capturedAt,
            memory: &memory
        )

        appMemories[appKey] = memory
        persist(memory, appKey: appKey)
    }

    public func activationMemory(appName: String) -> String {
        guard !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        let appKey = storageKey(for: appName)
        let memory = loadMemory(appKey: appKey, appName: appName, now: Date())
        guard !memory.surfaces.isEmpty else { return "" }
        return ContextMemoryRenderer.activationSnippet(for: memory)
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
            let decoded = try? Self.decoder.decode(ContextAppMemory.self, from: data)
        {
            appMemories[appKey] = decoded
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

        for url in urls where url.pathExtension == "json" {
            let appKey = url.deletingPathExtension().lastPathComponent
            guard appMemories[appKey] == nil else { continue }
            guard
                let data = try? Data(contentsOf: url),
                let decoded = try? Self.decoder.decode(ContextAppMemory.self, from: data)
            else {
                continue
            }
            appMemories[appKey] = decoded
        }
    }

    private func recordSurface(
        surfaceID: String,
        title: String,
        trigger: ContextCaptureTrigger,
        textHighlights: [String],
        capturedAt: Date,
        memory: inout ContextAppMemory
    ) {
        if let index = memory.surfaces.firstIndex(where: { $0.id == surfaceID }) {
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
        } else {
            memory.surfaces.append(ContextSurfaceMemory(
                id: surfaceID,
                title: title,
                firstSeen: capturedAt,
                lastSeen: capturedAt,
                observationCount: 1,
                clickCount: trigger == .click ? 1 : 0,
                activationCount: trigger == .activation ? 1 : 0,
                textHighlights: textHighlights
            ))
        }
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
            return ContextControlMemory(
                id: "control#\(Self.normalize(label))#\(Self.normalize(role))#\(Self.normalize(region))",
                label: label.isEmpty ? "Unlabeled control" : label,
                role: role.isEmpty ? "control" : role,
                region: region.isEmpty ? "unknown-region" : region,
                actionHint: actionHint,
                firstSeen: capturedAt,
                lastSeen: capturedAt,
                evidenceCount: 1,
                confidence: control.confidence
            )
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
                confidence: observation.confidence
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
                merged[index].confidence = max(merged[index].confidence, entity.confidence)
                merged[index].source = entity.source
            } else {
                merged.append(entity)
            }
        }
        return Array(merged.sorted { $0.lastSeen > $1.lastSeen }.prefix(maxCount))
    }

    private func persist(_ memory: ContextAppMemory, appKey: String) {
        do {
            let jsonData = try Self.encoder.encode(memory)
            try jsonData.write(to: jsonURL(for: appKey), options: .atomic)

            let markdown = ContextMemoryRenderer.markdown(for: memory)
            try markdown.write(to: markdownURL(for: appKey), atomically: true, encoding: .utf8)
        } catch {
            fputs("[ERROR] [context.memory] failed to persist memory for \(memory.appName): \(error)\n", Darwin.stderr)
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
            fputs("[ERROR] [context.memory] failed to append observation: \(error)\n", Darwin.stderr)
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

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let jsonlEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
