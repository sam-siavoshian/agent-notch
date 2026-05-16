//
//  ContextDebugArtifactStore.swift
//  Agent in the Notch
//
//  Local-only inspection artifacts for the context pipeline. These files are
//  deliberately outside git so we can inspect what the app actually saw
//  without the user copying logs into chat.
//

import Foundation

public actor ContextDebugArtifactStore {
    public static let shared = ContextDebugArtifactStore()

    public static var defaultDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextDebugArtifacts", isDirectory: true)
    }

    private let directoryURL: URL
    private let capturesURL: URL
    private let indexURL: URL
    private let maxCaptureArtifacts: Int

    public init(
        directoryURL: URL = ContextDebugArtifactStore.defaultDirectoryURL,
        maxCaptureArtifacts: Int = 80
    ) {
        self.directoryURL = directoryURL
        self.capturesURL = directoryURL.appendingPathComponent("Captures", isDirectory: true)
        self.indexURL = directoryURL.appendingPathComponent("capture-index.jsonl")
        self.maxCaptureArtifacts = maxCaptureArtifacts

        try? FileManager.default.createDirectory(at: capturesURL, withIntermediateDirectories: true)
    }

    public func recordCapture(_ snapshot: ContextSnapshot) -> ContextCaptureDebugArtifact? {
        let key = artifactKey(date: snapshot.capturedAt, id: snapshot.id)
        let jpegURL = capturesURL.appendingPathComponent("\(key).jpg")
        let jsonURL = capturesURL.appendingPathComponent("\(key).json")
        let usefulText = ContextTextSignalFilter.usefulText(from: snapshot.recognizedText, maxCount: 32)

        let artifact = ContextCaptureDebugArtifact(
            id: snapshot.id,
            capturedAt: snapshot.capturedAt,
            trigger: snapshot.trigger,
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            cursorX: snapshot.cursorLocation.map { Int($0.x) },
            cursorY: snapshot.cursorLocation.map { Int($0.y) },
            width: snapshot.width,
            height: snapshot.height,
            jpegBytes: snapshot.jpegData.count,
            jpegPath: jpegURL.path,
            recognizedTextCount: snapshot.recognizedText.count,
            usefulText: usefulText,
            recognizedText: snapshot.recognizedText
        )

        do {
            try snapshot.jpegData.write(to: jpegURL, options: .atomic)
            let data = try Self.encoder.encode(artifact)
            try data.write(to: jsonURL, options: .atomic)
            appendIndex(artifact)
            try data.write(to: directoryURL.appendingPathComponent("latest-capture.json"), options: .atomic)
            pruneOldCaptures()
            return artifact
        } catch {
            NSLog("[ContextDebugArtifactStore] Failed to write capture artifact: \(error)")
            return nil
        }
    }

    private func appendIndex(_ artifact: ContextCaptureDebugArtifact) {
        do {
            let data = try Self.compactEncoder.encode(artifact) + Data([0x0A])
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let handle = try FileHandle(forWritingTo: indexURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: indexURL, options: .atomic)
            }
        } catch {
            NSLog("[ContextDebugArtifactStore] Failed to append capture index: \(error)")
        }
    }

    private func pruneOldCaptures() {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: capturesURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else {
            return
        }

        let jsonURLs = urls
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                modificationDate(lhs) > modificationDate(rhs)
            }

        for jsonURL in jsonURLs.dropFirst(maxCaptureArtifacts) {
            let jpegURL = jsonURL.deletingPathExtension().appendingPathExtension("jpg")
            try? FileManager.default.removeItem(at: jsonURL)
            try? FileManager.default.removeItem(at: jpegURL)
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private func artifactKey(date: Date, id: UUID) -> String {
        let timestamp = Self.fileDateFormatter.string(from: date)
        return "\(timestamp)-\(id.uuidString.prefix(8))"
    }

    private static let fileDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var compactEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public struct ContextCaptureDebugArtifact: Codable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let trigger: ContextCaptureTrigger
    public let appName: String
    public let windowTitle: String
    public let cursorX: Int?
    public let cursorY: Int?
    public let width: Int
    public let height: Int
    public let jpegBytes: Int
    public let jpegPath: String
    public let jsonPath: String
    public let recognizedTextCount: Int
    public let usefulText: [String]
    public let recognizedText: [ContextRecognizedText]

    public init(
        id: UUID,
        capturedAt: Date,
        trigger: ContextCaptureTrigger,
        appName: String,
        windowTitle: String,
        cursorX: Int?,
        cursorY: Int?,
        width: Int,
        height: Int,
        jpegBytes: Int,
        jpegPath: String,
        recognizedTextCount: Int,
        usefulText: [String],
        recognizedText: [ContextRecognizedText]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.trigger = trigger
        self.appName = appName
        self.windowTitle = windowTitle
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.width = width
        self.height = height
        self.jpegBytes = jpegBytes
        self.jpegPath = jpegPath
        self.jsonPath = jpegPath.replacingOccurrences(of: ".jpg", with: ".json")
        self.recognizedTextCount = recognizedTextCount
        self.usefulText = usefulText
        self.recognizedText = recognizedText
    }
}
