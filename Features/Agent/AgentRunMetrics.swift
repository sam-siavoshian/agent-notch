//
//  AgentRunMetrics.swift
//  Agent in the Notch
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

public func printRunMetrics(_ r: AgentRunMetricsRecord) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(r), let json = String(data: data, encoding: .utf8) {
        print("[INFO]  [metrics] run \(json)")
    }
}
