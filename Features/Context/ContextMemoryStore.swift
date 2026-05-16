//
//  ContextMemoryStore.swift
//  Agent in the Notch
//
//  Persists lightweight UI memory learned from screen captures. This is the
//  first native learning layer: app/window surfaces, observed transitions, and
//  same-surface click evidence.
//

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

    public func activationMemory(appName: String) -> String {
        guard !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        let appKey = storageKey(for: appName)
        let memory = loadMemory(appKey: appKey, appName: appName, now: Date())
        guard !memory.surfaces.isEmpty else { return "" }
        return ContextMemoryRenderer.activationSnippet(for: memory)
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
        let note = "Clicks here have recently stayed on the same app/window surface; they may update controls in place instead of navigating elsewhere."

        if let index = memory.negativeNotes.firstIndex(where: { $0.id == noteID }) {
            memory.negativeNotes[index].surfaceTitle = surfaceTitle
            memory.negativeNotes[index].lastSeen = capturedAt
            memory.negativeNotes[index].evidenceCount += 1
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
            let data = try Self.encoder.encode(record) + Data([0x0A])
            if FileManager.default.fileExists(atPath: observationsURL.path) {
                let handle = try FileHandle(forWritingTo: observationsURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
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
        var seen = Set<String>()
        var highlights: [String] = []

        for item in snapshot.recognizedText {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { continue }
            let key = text.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            highlights.append(text)
            if highlights.count >= maxCount {
                break
            }
        }

        return highlights
    }

    private func mergedHighlights(existing: [String], new: [String], maxCount: Int = 24) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []

        for text in new + existing {
            let key = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(text)
            if merged.count >= maxCount {
                break
            }
        }

        return merged
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

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
