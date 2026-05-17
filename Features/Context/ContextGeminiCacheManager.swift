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

    private struct Entry: Sendable {
        let name: String
        let model: String
        let promptVersion: String
        let createdAt: Date
        let ttlSeconds: Int

        var isLikelyExpired: Bool {
            Date().timeIntervalSince(createdAt) > TimeInterval(max(0, ttlSeconds - 60))
        }
    }

    private struct Key: Hashable {
        let lane: ContextGeminiObservationLane
        let model: String
        let promptVersion: String
    }

    private var entries: [Key: Entry] = [:]
    private var inflight: [Key: Task<String?, Never>] = [:]
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
        if let entry = entries[key], !entry.isLikelyExpired {
            return entry.name
        }
        if let task = inflight[key] {
            return await task.value
        }

        let task = Task { [endpointBaseURL, session, ttlSeconds] () async -> String? in
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
        inflight[key] = task
        let name = await task.value
        inflight[key] = nil

        if let name {
            entries[key] = Entry(
                name: name,
                model: model,
                promptVersion: promptVersion,
                createdAt: Date(),
                ttlSeconds: ttlSeconds
            )
        }
        return name
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

    private static func createCachedContent(
        lane: ContextGeminiObservationLane,
        model: String,
        systemInstruction: String,
        ttlSeconds: Int,
        endpointBaseURL: URL,
        session: URLSession,
        apiKey: String
    ) async -> String? {
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
            return nil
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                NSLog("[ContextGeminiCacheManager] Cache create for \(lane.rawValue) returned non-HTTP response.")
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("[ContextGeminiCacheManager] Cache create for \(lane.rawValue) failed (\(http.statusCode)): \(body.prefix(400))")
                return nil
            }
            let decoded = try JSONDecoder().decode(CreateCachedContentResponse.self, from: data)
            guard let name = decoded.name, !name.isEmpty else {
                NSLog("[ContextGeminiCacheManager] Cache create for \(lane.rawValue) returned empty name.")
                return nil
            }
            NSLog("[ContextGeminiCacheManager] Created cache \(name) for \(lane.rawValue)")
            return name
        } catch {
            NSLog("[ContextGeminiCacheManager] Cache create for \(lane.rawValue) threw: \(error)")
            return nil
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
