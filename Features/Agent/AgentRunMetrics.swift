//
//  AgentRunMetrics.swift
//  Agent in the Notch
//
//  Lightweight per-run metrics for testing whether local context and UI memory
//  reduce computer-use exploration.
//

import Foundation

public struct AgentRunMetricsRecord: Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let durationMs: Int
    public let modelID: String
    public let fallbackModelID: String
    public let usedFallback: Bool
    public let transcriptLength: Int
    public let contextLength: Int
    public let contextIncluded: Bool
    public let turnCount: Int
    public let toolCallCount: Int
    public let screenshotToolCallCount: Int
    public let actionCounts: [String: Int]
    public let timeToFirstToolCallMs: Int?
    public let timeToFirstNonScreenshotActionMs: Int?
    public let finalStatus: String
    public let errorMessage: String?
}

public actor AgentMetricsStore {
    public static let shared = AgentMetricsStore()
    public static var defaultDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("AgentMetrics", isDirectory: true)
    }

    private let metricsURL: URL

    public init(rootURL: URL? = nil) {
        let directory = rootURL ?? Self.defaultDirectoryURL
        self.metricsURL = directory.appendingPathComponent("runs.jsonl")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func record(_ metrics: AgentRunMetricsRecord) {
        do {
            var data = try Self.encoder.encode(metrics)
            data.append(0x0A)

            if FileManager.default.fileExists(atPath: metricsURL.path) {
                let handle = try FileHandle(forWritingTo: metricsURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: metricsURL, options: .atomic)
            }
        } catch {
            NSLog("[AgentMetricsStore] Failed to record run metrics: \(error)")
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
