//
//  SpotifyWebClient.swift
//  Agent in the Notch
//
//  Spotify Web API client + PKCE OAuth flow. Strictly opt-in — without auth
//  the Tier-1 AppleScript path in `SpotifyController` keeps the basic
//  experience working.
//
//  Storage:
//    - Refresh token in Keychain under service `com.agentnotch.app` /
//      account `SPOTIFY_REFRESH_TOKEN`. Survives launches.
//    - Access token + expiry in-memory only (re-minted from the refresh
//      token on launch via `warmAccessToken()`).
//
//  Auth UX:
//    - PKCE flow with loopback redirect (`http://127.0.0.1:<ephemeralPort>/callback`).
//      Spotify whitelists loopback redirects on any port, so the user only
//      needs to put their Client ID in `.env` once.
//    - We bind an `NWListener` to a random local port, open Spotify's
//      authorize URL in the default browser, and stop the listener as soon
//      as we capture the `?code=` callback.
//
//  Why PKCE + loopback (not ASWebAuthenticationSession): ASWebAuthSession
//  on macOS requires a custom URL scheme, which would mean registering
//  `CFBundleURLTypes` in Info.plist plus a window-message handler. The
//  loopback path is one self-contained file, no Info.plist mutation, no
//  app-delegate touch, and matches the IETF recommendation for native apps
//  (RFC 8252). Trade-off: requires firewall-allowing 127.0.0.1 inbound,
//  which is permitted by default on macOS.
//

import AppKit
import CryptoKit
import Foundation
import Network

// MARK: - Public model types

/// Lean playlist record kept in memory for fuzzy-match lookup. We only need
/// id + name + ownership to decide which playlists the user can modify.
public struct SpotifyPlaylist: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let ownerID: String
    public let isCollaborative: Bool
    /// Resolved at fetch time — set when the row's `ownerID` matches the
    /// signed-in user's ID, or the playlist is collaborative.
    public let canModify: Bool
}

/// Snapshot of the user's Web-API playback state. Fields we actually use.
public struct SpotifyPlaybackSnapshot: Sendable {
    public let isPlaying: Bool
    public let trackURI: String?
    public let shuffleState: Bool
    /// Raw repeat state string from the Web API: `off` / `track` / `context`.
    public let repeatState: String
}

// MARK: - Client

@MainActor
public final class SpotifyWebClient {
    public static let shared = SpotifyWebClient()
    private init() {}

    // Keychain accounts. Service is `Keychain.service` (com.agentnotch.app).
    private enum Account {
        static let refresh = "SPOTIFY_REFRESH_TOKEN"
        static let userID = "SPOTIFY_USER_ID"
    }

    /// User's Spotify ID — needed to decide which playlists they own.
    /// Cached in Keychain so we don't have to call `/me` every launch.
    public private(set) var userID: String = ""

    /// In-memory access token + expiry timestamp. Re-minted from the refresh
    /// token whenever it's within 60s of expiring.
    private var accessToken: String?
    private var accessTokenExpiry: Date = .distantPast

    /// Set by `beginPKCEFlow()` so the refresh path can reuse the same Client ID.
    private var cachedClientID: String?

    /// Scopes we ask for. Minimum to power the three new features:
    ///  - `user-modify-playback-state`  → set repeat / shuffle (Web API)
    ///  - `user-read-playback-state`    → read three-state repeat for UI sync
    ///  - `playlist-read-private`       → list playlists (incl. private)
    ///  - `playlist-modify-private`     → add tracks to private playlists
    ///  - `playlist-modify-public`      → add tracks to public playlists
    ///  - `user-library-modify`         → save / unsave tracks
    ///  - `user-library-read`           → /me/tracks/contains for heart state
    ///  - `user-read-currently-playing` → tighter currently-playing fallback
    private static let scopes: [String] = [
        "user-modify-playback-state",
        "user-read-playback-state",
        "playlist-read-private",
        "playlist-modify-private",
        "playlist-modify-public",
        "user-library-modify",
        "user-library-read",
        "user-read-currently-playing"
    ]

    private static let authBase = "https://accounts.spotify.com"
    private static let apiBase  = "https://api.spotify.com/v1"

    // MARK: - Errors

    public enum AuthError: LocalizedError {
        case missingClientID
        case userCancelled
        case callbackTimedOut
        case callbackMissingCode
        case tokenExchangeFailed(String)
        case meEndpointFailed
        case loopbackBindFailed

        public var errorDescription: String? { userMessage }

        var userMessage: String {
            switch self {
            case .missingClientID:
                return "Set SPOTIFY_CLIENT_ID in your .env to enable cloud Spotify features."
            case .userCancelled:
                return "Spotify sign-in cancelled."
            case .callbackTimedOut:
                return "Spotify sign-in timed out."
            case .callbackMissingCode:
                return "Spotify did not return an authorization code."
            case .tokenExchangeFailed(let m):
                return "Spotify token exchange failed: \(m)"
            case .meEndpointFailed:
                return "Could not read your Spotify profile after sign-in."
            case .loopbackBindFailed:
                return "Could not bind a local port for Spotify sign-in."
            }
        }
    }

    // MARK: - Public surface (auth state)

    public var hasRefreshToken: Bool { Keychain.get(Account.refresh) != nil }

    public func signOut() {
        accessToken = nil
        accessTokenExpiry = .distantPast
        cachedClientID = nil
        userID = ""
        Keychain.set("", account: Account.refresh)        // best-effort wipe
        Keychain.set("", account: Account.userID)
    }

    // MARK: - PKCE flow

    /// Run the full PKCE sign-in: spin a loopback listener, open the browser,
    /// exchange the code, persist the refresh token, fetch `/me` to remember
    /// the user's Spotify ID.
    public func beginPKCEFlow() async throws {
        guard let clientID = Self.resolveClientID(), !clientID.isEmpty else {
            throw AuthError.missingClientID
        }
        cachedClientID = clientID

        let verifier = Self.randomCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let stateNonce = UUID().uuidString

        let listener = try LoopbackCallbackListener.start()
        let redirectURI = listener.redirectURI

        // Build authorize URL.
        var comps = URLComponents(string: Self.authBase + "/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: stateNonce),
            URLQueryItem(name: "show_dialog", value: "false")
        ]
        guard let authURL = comps.url else {
            listener.cancel()
            throw AuthError.tokenExchangeFailed("Could not build auth URL")
        }

        // Open the browser. NSWorkspace.open returns immediately.
        NSWorkspace.shared.open(authURL)

        // Wait up to 5 minutes for the callback. If the user closes the
        // browser without finishing we time out.
        let callback: LoopbackCallback
        do {
            callback = try await listener.awaitCallback(timeout: 300)
        } catch {
            listener.cancel()
            throw error
        }
        listener.cancel()

        guard callback.state == stateNonce else {
            throw AuthError.callbackMissingCode
        }
        guard let code = callback.code else {
            throw AuthError.callbackMissingCode
        }

        // Exchange code → tokens.
        let tokens = try await exchangeCode(
            clientID: clientID,
            code: code,
            verifier: verifier,
            redirectURI: redirectURI
        )

        // Persist refresh token + load /me.
        Keychain.set(tokens.refreshToken ?? "", account: Account.refresh)
        accessToken = tokens.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))

        if let me = await fetchMe() {
            userID = me
            Keychain.set(me, account: Account.userID)
        } else {
            throw AuthError.meEndpointFailed
        }
    }

    /// On launch, restore the user ID from Keychain + mint a fresh access
    /// token from the persisted refresh token. Returns true on success.
    public func warmAccessToken() async -> Bool {
        guard let refresh = Keychain.get(Account.refresh), !refresh.isEmpty else { return false }
        guard let clientID = Self.resolveClientID(), !clientID.isEmpty else { return false }
        cachedClientID = clientID
        if let cachedUser = Keychain.get(Account.userID), !cachedUser.isEmpty {
            userID = cachedUser
        }
        return await refreshAccessToken(refresh: refresh, clientID: clientID)
    }

    // MARK: - Web API (the four features we use)

    /// PUT /me/player/repeat?state=<off|track|context>
    public func setRepeatState(_ state: String) async -> Bool {
        let url = Self.apiBase + "/me/player/repeat?state=\(state)"
        let result = await apiCall(method: "PUT", urlString: url)
        return result.ok
    }

    /// PUT /me/player/shuffle?state=<true|false>
    public func setShuffleState(_ on: Bool) async -> Bool {
        let url = Self.apiBase + "/me/player/shuffle?state=\(on ? "true" : "false")"
        let result = await apiCall(method: "PUT", urlString: url)
        return result.ok
    }

    /// PUT /me/tracks?ids=<csv>
    public func saveTracks(_ ids: [String]) async -> Bool {
        guard !ids.isEmpty else { return false }
        let csv = ids.joined(separator: ",")
        let url = Self.apiBase + "/me/tracks?ids=\(csv)"
        return await apiCall(method: "PUT", urlString: url).ok
    }

    /// DELETE /me/tracks?ids=<csv>
    public func removeSavedTracks(_ ids: [String]) async -> Bool {
        guard !ids.isEmpty else { return false }
        let csv = ids.joined(separator: ",")
        let url = Self.apiBase + "/me/tracks?ids=\(csv)"
        return await apiCall(method: "DELETE", urlString: url).ok
    }

    /// GET /me/tracks/contains?ids=<csv> → [Bool] aligned to input order.
    public func checkSavedTracks(_ ids: [String]) async -> [Bool] {
        guard !ids.isEmpty else { return [] }
        let csv = ids.joined(separator: ",")
        let url = Self.apiBase + "/me/tracks/contains?ids=\(csv)"
        let result = await apiCall(method: "GET", urlString: url)
        guard result.ok, let data = result.data,
              let arr = try? JSONDecoder().decode([Bool].self, from: data) else { return [] }
        return arr
    }

    /// POST /playlists/{id}/tracks  body: {"uris": ["spotify:track:..."]}
    public func addTrack(uri: String, toPlaylist playlistID: String) async -> Bool {
        let url = Self.apiBase + "/playlists/\(playlistID)/tracks"
        let body = try? JSONSerialization.data(withJSONObject: ["uris": [uri]])
        return await apiCall(method: "POST", urlString: url, body: body,
                             contentType: "application/json").ok
    }

    /// GET /me/playlists?limit=50&offset=...  paginated, capped at 100 total.
    public func fetchUserPlaylists() async -> [SpotifyPlaylist] {
        var out: [SpotifyPlaylist] = []
        var offset = 0
        let pageSize = 50
        let hardCap = 200
        while offset < hardCap {
            let url = Self.apiBase + "/me/playlists?limit=\(pageSize)&offset=\(offset)"
            let r = await apiCall(method: "GET", urlString: url)
            guard r.ok, let data = r.data else { break }
            guard let page = try? JSONDecoder().decode(PlaylistsPage.self, from: data) else { break }
            let me = userID
            for it in page.items {
                out.append(SpotifyPlaylist(
                    id: it.id,
                    name: it.name,
                    ownerID: it.owner.id,
                    isCollaborative: it.collaborative,
                    canModify: it.collaborative || it.owner.id == me
                ))
            }
            if page.items.count < pageSize { break }
            offset += pageSize
        }
        return out
    }

    /// GET /me/player → SpotifyPlaybackSnapshot? (nil when nothing playing).
    public func fetchPlayback() async -> SpotifyPlaybackSnapshot? {
        let url = Self.apiBase + "/me/player"
        let r = await apiCall(method: "GET", urlString: url)
        // 204 = no content (nothing playing). 200 with body otherwise.
        guard r.ok, let data = r.data, !data.isEmpty else { return nil }
        guard let raw = try? JSONDecoder().decode(PlayerRaw.self, from: data) else { return nil }
        return SpotifyPlaybackSnapshot(
            isPlaying: raw.is_playing,
            trackURI: raw.item?.uri,
            shuffleState: raw.shuffle_state,
            repeatState: raw.repeat_state
        )
    }

    // MARK: - Private helpers

    /// Single chokepoint for all Web API requests. Auto-refreshes the access
    /// token, retries once on 401, surfaces failures via the boolean / nil
    /// returns above. Never throws.
    private func apiCall(
        method: String,
        urlString: String,
        body: Data? = nil,
        contentType: String? = nil
    ) async -> (ok: Bool, data: Data?) {
        guard let url = URL(string: urlString) else { return (false, nil) }
        if Date() > accessTokenExpiry.addingTimeInterval(-60) {
            // Token expired or about to — refresh now.
            guard let refresh = Keychain.get(Account.refresh),
                  let clientID = cachedClientID ?? Self.resolveClientID() else {
                return (false, nil)
            }
            let ok = await refreshAccessToken(refresh: refresh, clientID: clientID)
            if !ok { return (false, nil) }
        }
        guard let token = accessToken else { return (false, nil) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return (false, nil) }
            if http.statusCode == 401 {
                // Token race — refresh once and retry.
                if let refresh = Keychain.get(Account.refresh),
                   let clientID = cachedClientID ?? Self.resolveClientID() {
                    let ok = await refreshAccessToken(refresh: refresh, clientID: clientID)
                    if !ok { return (false, nil) }
                    if let token2 = accessToken {
                        req.setValue("Bearer \(token2)", forHTTPHeaderField: "Authorization")
                        let (d2, r2) = try await URLSession.shared.data(for: req)
                        if let h2 = r2 as? HTTPURLResponse, (200..<300).contains(h2.statusCode) {
                            return (true, d2)
                        }
                    }
                }
                return (false, nil)
            }
            if (200..<300).contains(http.statusCode) {
                return (true, data)
            }
            return (false, data)
        } catch {
            return (false, nil)
        }
    }

    /// POST /api/token with grant_type=refresh_token. Updates `accessToken`,
    /// `accessTokenExpiry`, and rotates the stored refresh token if Spotify
    /// returned a new one.
    private func refreshAccessToken(refresh: String, clientID: String) async -> Bool {
        guard let url = URL(string: Self.authBase + "/api/token") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(refresh.percentEncoded)&client_id=\(clientID)"
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
            accessToken = tokens.access_token
            accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expires_in))
            if let rotated = tokens.refresh_token, !rotated.isEmpty {
                Keychain.set(rotated, account: Account.refresh)
            }
            return true
        } catch {
            return false
        }
    }

    /// Exchange the PKCE authorization code for an access + refresh token.
    private func exchangeCode(
        clientID: String,
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> TokenResponse {
        guard let url = URL(string: Self.authBase + "/api/token") else {
            throw AuthError.tokenExchangeFailed("Bad token URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body =
            "grant_type=authorization_code" +
            "&code=\(code.percentEncoded)" +
            "&redirect_uri=\(redirectURI.percentEncoded)" +
            "&client_id=\(clientID.percentEncoded)" +
            "&code_verifier=\(verifier.percentEncoded)"
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AuthError.tokenExchangeFailed("No HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            throw AuthError.tokenExchangeFailed(msg)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// GET /me → user.id. Used once after sign-in to remember playlist ownership.
    private func fetchMe() async -> String? {
        let r = await apiCall(method: "GET", urlString: Self.apiBase + "/me")
        guard r.ok, let data = r.data else { return nil }
        struct Me: Codable { let id: String }
        return (try? JSONDecoder().decode(Me.self, from: data))?.id
    }

    // MARK: - PKCE helpers

    /// Resolve client ID from env (`SPOTIFY_CLIENT_ID`) → Keychain
    /// (`SPOTIFY_CLIENT_ID`) → nil. Public-safe (PKCE), so user-pasted is OK.
    private static func resolveClientID() -> String? {
        if let v = Env.value("SPOTIFY_CLIENT_ID"), !v.isEmpty { return v }
        if let v = Keychain.get("SPOTIFY_CLIENT_ID"), !v.isEmpty { return v }
        return nil
    }

    /// 64-byte random base64url-encoded verifier. Spotify accepts 43-128.
    private static func randomCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    /// S256 challenge: base64url(sha256(verifier)).
    private static func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncoded
    }
}

// MARK: - Codable shapes for Web API

private struct TokenResponse: Codable {
    let access_token: String
    let token_type: String
    let expires_in: Int
    let scope: String?
    let refresh_token: String?

    var accessToken: String { access_token }
    var refreshToken: String? { refresh_token }
    var expiresIn: Int { expires_in }
}

private struct PlaylistsPage: Codable {
    let items: [Item]
    struct Item: Codable {
        let id: String
        let name: String
        let collaborative: Bool
        let owner: Owner
    }
    struct Owner: Codable { let id: String }
}

private struct PlayerRaw: Codable {
    let is_playing: Bool
    let shuffle_state: Bool
    let repeat_state: String
    let item: Item?
    struct Item: Codable { let uri: String }
}

// MARK: - Loopback callback listener

/// Tiny NWListener-based HTTP/1.1 server that accepts exactly one request,
/// parses `GET /callback?code=...&state=...`, sends a friendly HTML response
/// telling the user to come back to the app, and resolves a continuation
/// with the parsed callback.
private final class LoopbackCallbackListener: @unchecked Sendable {
    private(set) var port: UInt16
    var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    private let listener: NWListener
    private let queue: DispatchQueue
    private var continuation: CheckedContinuation<LoopbackCallback, Error>?
    private var done: Bool = false
    private let lock = NSLock()

    private init(listener: NWListener) {
        self.listener = listener
        self.port = 0
        self.queue = DispatchQueue(label: "spotify.oauth.loopback")
    }

    static func start() throws -> LoopbackCallbackListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        // Port 0 = ephemeral.
        guard let listener = try? NWListener(using: params, on: .any) else {
            throw SpotifyWebClient.AuthError.loopbackBindFailed
        }
        let inst = LoopbackCallbackListener(listener: listener)
        // We need the actual bound port — start, then read .port. NWListener
        // resolves `.any` to a concrete port asynchronously, so we use a
        // semaphore briefly here. Cheap, fires once per sign-in.
        let portReady = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { portReady.signal() }
        }
        listener.newConnectionHandler = { [weak inst] conn in
            inst?.handle(connection: conn)
        }
        listener.start(queue: inst.queue)
        // Wait at most 2s for `.ready`. If it never fires, bail.
        if portReady.wait(timeout: .now() + 2) == .timedOut {
            listener.cancel()
            throw SpotifyWebClient.AuthError.loopbackBindFailed
        }
        guard let nwport = listener.port else {
            listener.cancel()
            throw SpotifyWebClient.AuthError.loopbackBindFailed
        }
        inst.port = nwport.rawValue
        return inst
    }

    /// Suspend until the first GET request lands, then resolve with the
    /// parsed code/state. Times out after `timeout` seconds.
    func awaitCallback(timeout: TimeInterval) async throws -> LoopbackCallback {
        try await withThrowingTaskGroup(of: LoopbackCallback.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<LoopbackCallback, Error>) in
                    guard let self else {
                        c.resume(throwing: SpotifyWebClient.AuthError.callbackTimedOut)
                        return
                    }
                    self.lock.lock()
                    self.continuation = c
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SpotifyWebClient.AuthError.callbackTimedOut
            }
            guard let first = try await group.next() else {
                throw SpotifyWebClient.AuthError.callbackTimedOut
            }
            group.cancelAll()
            return first
        }
    }

    func cancel() {
        lock.lock()
        let pending = continuation
        continuation = nil
        let wasDone = done
        done = true
        lock.unlock()
        if !wasDone {
            listener.cancel()
            pending?.resume(throwing: SpotifyWebClient.AuthError.userCancelled)
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            defer { connection.cancel() }
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty,
                  let raw = String(data: data, encoding: .utf8) else { return }
            // Parse "GET /callback?code=...&state=... HTTP/1.1"
            let firstLine = raw.split(separator: "\r\n").first ?? Substring(raw)
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else { return }
            let path = String(parts[1])
            guard path.hasPrefix("/callback") else { return }

            var code: String?
            var state: String?
            var error_: String?
            if let q = path.split(separator: "?").last {
                for pair in q.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    let val = kv[1].removingPercentEncoding ?? kv[1]
                    switch kv[0] {
                    case "code":  code  = val
                    case "state": state = val
                    case "error": error_ = val
                    default: break
                    }
                }
            }

            // Reply with a friendly HTML page so the user knows to come back.
            let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <title>Agent in the Notch — Spotify</title>
            <style>
              body{font-family:-apple-system,sans-serif;background:#0f0f12;color:#fff;
                   display:flex;align-items:center;justify-content:center;
                   min-height:100vh;margin:0;text-align:center}
              .card{padding:32px 40px;border-radius:20px;background:#1c1d22;
                    box-shadow:0 8px 32px rgba(0,0,0,.5)}
              h1{margin:0 0 8px;font-size:18px;color:#1DB954}
              p{margin:0;color:#aaa;font-size:13px}
            </style></head><body><div class="card">
            <h1>Spotify connected</h1><p>You can close this tab and return to the notch.</p>
            </div></body></html>
            """
            let response =
                "HTTP/1.1 200 OK\r\n" +
                "Content-Type: text/html; charset=utf-8\r\n" +
                "Content-Length: \(html.utf8.count)\r\n" +
                "Connection: close\r\n\r\n" +
                html
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })

            self.lock.lock()
            let c = self.continuation
            self.continuation = nil
            let wasDone = self.done
            self.done = true
            self.lock.unlock()
            guard !wasDone, let c else { return }
            if let error_ {
                c.resume(throwing: SpotifyWebClient.AuthError.tokenExchangeFailed(error_))
            } else {
                c.resume(returning: LoopbackCallback(code: code, state: state))
            }
        }
    }
}

private struct LoopbackCallback: Sendable {
    let code: String?
    let state: String?
}

// MARK: - Encoding helpers

private extension Data {
    /// RFC 4648 §5 base64url, no padding.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    /// Form-encode with `+` for spaces (application/x-www-form-urlencoded).
    var percentEncoded: String {
        // RFC 3986 unreserved + the small set Spotify accepts in form bodies.
        // We err on the side of more escaping for safety.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
