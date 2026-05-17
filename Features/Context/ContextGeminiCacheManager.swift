//
//  ContextGeminiCacheManager.swift
//  Agent in the Notch
//
//  Per-lane Gemini context cache. Creates one cachedContents entry per lane
//  on first use, stores the returned name in-memory, and refreshes on
//  404/expired-cache responses. Disable with AGENTNOTCH_GEMINI_DISABLE_CACHE=1.
//

import Foundation

public actor ContextGeminiCacheManager {
    public static let shared = ContextGeminiCacheManager()

    public static let defaultTTLSeconds: Int = 3600
    public static let defaultEndpointBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    public static var isDisabled: Bool {
        let raw = Env.value("AGENTNOTCH_GEMINI_DISABLE_CACHE")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    public enum CacheStatus: String, Sendable {
        case active
        case permanentlyRejected
        case none
    }

    private struct Entry: Sendable {
        let name: String
        let model: String
        let promptVersion: String
        let createdAt: Date
        let ttlSeconds: Int

        var isLikelyExpired: Bool {
            Date().timeIntervalSince(createdAt) > TimeInterval(max(0, ttlSeconds - 60))
        }

        var expiresInSeconds: Int {
            let remaining = TimeInterval(ttlSeconds) - Date().timeIntervalSince(createdAt)
            return max(0, Int(remaining))
        }
    }

    private struct Key: Hashable {
        let lane: ContextGeminiObservationLane
        let model: String
        let promptVersion: String
    }

    private var entries: [Key: Entry] = [:]
    private var inflight: [Key: Task<String?, Never>] = [:]
    /// Lane keys whose system instruction is permanently too small for caching
    /// (Gemini requires >=1024 tokens). Skip the create call entirely for these.
    private var permanentlyRejected: Set<Key> = []

    public private(set) var hitCount: Int = 0
    public private(set) var missCount: Int = 0
    public private(set) var permanentRejectCount: Int = 0

    public struct LaneState: Sendable {
        public let lane: ContextGeminiObservationLane
        public let status: CacheStatus
        public let name: String?
        public let createdAt: Date?
        public let expiresInSeconds: Int?
    }

    public struct Counters: Sendable {
        public let hitCount: Int
        public let missCount: Int
        public let permanentRejectCount: Int
        public var totalLookups: Int { hitCount + missCount }
        public var hitRate: Double {
            let total = totalLookups
            guard total > 0 else { return 0 }
            return Double(hitCount) / Double(total)
        }
    }

    public func counters() -> Counters {
        Counters(hitCount: hitCount, missCount: missCount, permanentRejectCount: permanentRejectCount)
    }

    public func state() -> [LaneState] {
        ContextGeminiObservationLane.allCases.map { lane in
            let candidates = entries.filter { $0.key.lane == lane }
            let permanent = permanentlyRejected.contains(where: { $0.lane == lane })
            if let newest = candidates.values.max(by: { $0.createdAt < $1.createdAt }) {
                return LaneState(lane: lane, status: .active, name: newest.name, createdAt: newest.createdAt, expiresInSeconds: newest.expiresInSeconds)
            }
            if permanent {
                return LaneState(lane: lane, status: .permanentlyRejected, name: nil, createdAt: nil, expiresInSeconds: nil)
            }
            return LaneState(lane: lane, status: .none, name: nil, createdAt: nil, expiresInSeconds: nil)
        }
    }
    private let endpointBaseURL: URL
    private let session: URLSession
    private let ttlSeconds: Int

    public init(
        endpointBaseURL: URL = ContextGeminiCacheManager.defaultEndpointBaseURL,
        session: URLSession = .shared,
        ttlSeconds: Int = ContextGeminiCacheManager.defaultTTLSeconds
    ) {
        self.endpointBaseURL = endpointBaseURL
        self.session = session
        self.ttlSeconds = ttlSeconds
    }

    /// Returns a `cachedContents/...` name to attach to a generateContent call,
    /// or nil if caching is disabled, unsupported for this lane, or creation failed.
    public func cachedContentName(
        for lane: ContextGeminiObservationLane,
        model: String,
        promptVersion: String,
        systemInstruction: String,
        apiKey: String
    ) async -> String? {
        guard !Self.isDisabled else { return nil }

        let key = Key(lane: lane, model: model, promptVersion: promptVersion)
        if permanentlyRejected.contains(key) { return nil }
        if let entry = entries[key], !entry.isLikelyExpired {
            hitCount += 1
            return entry.name
        }
        missCount += 1
        if let task = inflight[key] {
            return await task.value
        }

        let task = Task { [endpointBaseURL, session, ttlSeconds] () async -> CreateCachedContentResult in
            await ContextGeminiCacheManager.createCachedContent(
                lane: lane,
                model: model,
                systemInstruction: systemInstruction,
                ttlSeconds: ttlSeconds,
                endpointBaseURL: endpointBaseURL,
                session: session,
                apiKey: apiKey
            )
        }
        // Wrap into the legacy String? task-output for any other inflight waiters,
        // but also keep the structured result locally for permanent-reject tracking.
        let resultTask = Task { @Sendable [task] in
            return await task.value.name
        }
        inflight[key] = resultTask
        let result = await task.value
        inflight[key] = nil

        if let name = result.name {
            entries[key] = Entry(
                name: name,
                model: model,
                promptVersion: promptVersion,
                createdAt: Date(),
                ttlSeconds: ttlSeconds
            )
            return name
        }
        if result.permanentlyRejected {
            permanentlyRejected.insert(key)
            permanentRejectCount += 1
        }
        return nil
    }

    /// Invalidate a single lane's cache entry after a 404/expired response.
    public func invalidate(
        lane: ContextGeminiObservationLane,
        model: String,
        promptVersion: String
    ) {
        let key = Key(lane: lane, model: model, promptVersion: promptVersion)
        entries.removeValue(forKey: key)
    }

    public func invalidateAll() {
        entries.removeAll()
    }

    // MARK: - Network

    struct CreateCachedContentResult: Sendable {
        let name: String?
        /// True iff the failure is permanent for this (lane, model, promptVersion)
        /// — e.g. the system instruction is below Gemini's minimum cacheable size.
        let permanentlyRejected: Bool
    }

    private static func createCachedContent(
        lane: ContextGeminiObservationLane,
        model: String,
        systemInstruction: String,
        ttlSeconds: Int,
        endpointBaseURL: URL,
        session: URLSession,
        apiKey: String
    ) async -> CreateCachedContentResult {
        let url = endpointBaseURL.appendingPathComponent("cachedContents")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.timeoutInterval = 15

        let payload = CreateCachedContentRequest(
            model: model.hasPrefix("models/") ? model : "models/\(model)",
            displayName: "agentnotch-\(lane.rawValue)",
            systemInstruction: .init(role: "system", parts: [.init(text: systemInstruction)]),
            ttl: "\(ttlSeconds)s"
        )

        do {
            urlRequest.httpBody = try JSONEncoder().encode(payload)
        } catch {
            NSLog("[ContextGeminiCacheManager] Failed to encode cache request for \(lane.rawValue): \(error)")
            return CreateCachedContentResult(name: nil, permanentlyRejected: false)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                NSLog("[ContextGeminiCacheManager] Cache create for \(lane.rawValue) returned non-HTTP response.")
                return CreateCachedContentResult(name: nil, permanentlyRejected: false)
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let lowerBody = body.lowercased()
                // Treat "too small" / "min_total_token_count" 400s as permanent —
                // the system instruction is below Gemini's minimum cacheable size
                // and there's no point retrying for this (lane, prompt version).
                let permanent = http.statusCode == 400 && (
                    lowerBody.contains("too small") ||
                    lowerBody.contains("min_total_token_count")
                )
                NSLog("[ContextGeminiCacheManager] Cache create for \(lane.rawValue) failed (\(http.statusCode))\(permanent ? " — marking permanently rejected" : ""): \(body.prefix(200))")
                return CreateCachedContentResult(name: nil, permanentlyRejected: permanent)
            }
            let decoded = try JSONDecoder().decode(CreateCachedContentResponse.self, from: data)
            guard let name = decoded.name, !name.isEmpty else {
                NSLog("[ContextGeminiCacheManager] Cache create for \(lane.rawValue) returned empty name.")
                return CreateCachedContentResult(name: nil, permanentlyRejected: false)
            }
            NSLog("[ContextGeminiCacheManager] Created cache \(name) for \(lane.rawValue)")
            return CreateCachedContentResult(name: name, permanentlyRejected: false)
        } catch {
            NSLog("[ContextGeminiCacheManager] Cache create for \(lane.rawValue) threw: \(error)")
            return CreateCachedContentResult(name: nil, permanentlyRejected: false)
        }
    }
}

private struct CreateCachedContentRequest: Encodable {
    var model: String
    var displayName: String
    var systemInstruction: SystemInstruction
    var ttl: String

    private enum CodingKeys: String, CodingKey {
        case model
        case displayName = "display_name"
        case systemInstruction = "system_instruction"
        case ttl
    }

    struct SystemInstruction: Encodable {
        var role: String
        var parts: [Part]

        struct Part: Encodable {
            var text: String
        }
    }
}

private struct CreateCachedContentResponse: Decodable {
    var name: String?
}
