//
//  MCPBridge.swift
//  Agent in the Notch
//
//  In-app Model Context Protocol server. Exposes AgentNotch's computer-use
//  tools (screenshot, left_click, type, key, scroll, ax_*, open_url, etc) to
//  a spawned `claude` subprocess running in CC-provider mode.
//
//  Wire transport: POSIX Unix domain socket at
//    /tmp/agentnotch-mcp-<pid>.sock      (mode 0600, owner-only)
//
//  The helper sidecar binary `AgentNotchMCP` connects to that socket, then
//  bidirectionally forwards bytes between Claude Code's stdin/stdout and our
//  socket. We speak newline-delimited JSON-RPC 2.0 (MCP framing).
//
//  Lifecycle:
//    - start()  on app boot. Cleans stale socket files from prior crashed
//                runs (same PID would-be-collision is impossible — `getpid`
//                always rotates), binds with 0600 perms, listens for 1 conn
//                at a time.
//    - stop()   on app quit. Closes listen FD, unlinks socket file.
//
//  Only one concurrent client is supported — Claude Code spawns the helper,
//  the helper opens one socket. If a second connection comes in while one
//  is active we accept-and-immediately-close it.
//

import Foundation
import AppKit
import Darwin

private let log = Log(category: "mcp.bridge")

public final class MCPBridge: @unchecked Sendable {
    public static let shared = MCPBridge()

    // MARK: - Configuration

    public var socketPath: String {
        "/tmp/agentnotch-mcp-\(getpid()).sock"
    }

    /// Display size advertised by `screenshot` and accepted by mouse ops.
    /// Pinned to 1280x800 so it matches the harness's API-mode pipeline.
    private let agentDisplaySize = CGSize(width: 1280, height: 800)

    // MARK: - State

    private let stateQueue = DispatchQueue(label: "com.agentnotch.mcp.bridge.state")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var activeClient: ClientHandler?
    /// `let` after start() completes — accessed without locking from
    /// `handleToolsCall` since `ToolDispatcher` is itself an actor.
    private var dispatcher: ToolDispatcher?

    private init() {}

    // MARK: - Lifecycle

    @MainActor
    public func start() {
        stateQueue.sync {
            guard self.dispatcher == nil else { return }
            let logical = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
            self.dispatcher = ToolDispatcher(
                agentDisplaySize: agentDisplaySize,
                logicalDisplaySize: logical,
                initialTransform: ScreenCapture.CoordTransform.identity(size: logical)
            )
        }

        do {
            try bind()
            log.info("mcp.start path=\(self.socketPath)")
        } catch {
            log.error("mcp.start_failed path=\(self.socketPath) error=\(error)")
        }
    }

    public func stop() {
        stateQueue.sync {
            self.acceptSource?.cancel()
            self.acceptSource = nil
            if self.listenFD >= 0 {
                Darwin.close(self.listenFD)
                self.listenFD = -1
            }
            self.activeClient?.close()
            self.activeClient = nil
            unlink(self.socketPath)
        }
    }

    // MARK: - Socket bind / accept

    private func bind() throws {
        // Stale socket cleanup. Any previous file at the path (crashed prior
        // app instance, e.g.) blocks bind() with EADDRINUSE. Always unlink.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXErr("socket() failed errno=\(errno)")
        }

        // Non-blocking listen socket so accept-source doesn't stall I/O queue.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < 104 else {
            Darwin.close(fd)
            throw POSIXErr("socket path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let dst = raw.bindMemory(to: UInt8.self).baseAddress!
            for (i, byte) in pathBytes.enumerated() { dst[i] = byte }
            dst[pathBytes.count] = 0
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, addrLen)
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXErr("bind() failed errno=\(errno)")
        }

        // Owner-only access: nobody else on a shared box (or another user
        // account) should be able to call our tools.
        chmod(socketPath, 0o600)

        guard Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw POSIXErr("listen() failed errno=\(errno)")
        }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: stateQueue)
        src.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        src.setCancelHandler {
            // FD is closed in stop(); cancel handler just releases the source.
        }
        src.resume()

        stateQueue.sync {
            self.listenFD = fd
            self.acceptSource = src
        }
    }

    private func acceptConnection() {
        // Drain all pending accepts in one trip — the read source fires once
        // per ready edge.
        while true {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(self.listenFD, sockPtr, &len)
                }
            }
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                log.error("mcp.accept_failed errno=\(errno)")
                return
            }

            // Only one client at a time. If we have an active session, the
            // new one is closed immediately — sidecar will surface the EOF.
            if self.activeClient != nil {
                log.warning("mcp.accept_rejected reason=already_have_client")
                Darwin.close(clientFD)
                continue
            }

            // The listener is O_NONBLOCK; on Darwin the accepted FD inherits
            // that flag, which would make our blocking-read pump spin on
            // EAGAIN forever. Force the per-client FD back to blocking mode.
            let clientFlags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)

            log.info("mcp.client_connected fd=\(clientFD)")
            let handler = ClientHandler(fd: clientFD, bridge: self)
            self.activeClient = handler
            handler.start()
        }
    }

    fileprivate func clientDidClose(_ handler: ClientHandler) {
        stateQueue.async {
            if self.activeClient === handler {
                self.activeClient = nil
            }
        }
    }

    // MARK: - Method dispatch

    fileprivate func handle(envelope: MCP.Envelope) async -> MCP.Response? {
        guard let method = envelope.method else {
            // Server-bound message without method — likely a stray response.
            // Drop silently.
            return nil
        }

        let id = envelope.id ?? .null

        switch method {
        case "initialize":
            return MCP.Response(id: id, result: Self.initializeResult())

        case "notifications/initialized":
            // Notification — no id, no response required.
            return nil

        case "tools/list":
            return MCP.Response(id: id, result: Self.toolCatalogResult)

        case "tools/call":
            return await handleToolsCall(id: id, params: envelope.params)

        case "ping":
            return MCP.Response(id: id, result: .object([:]))

        default:
            return MCP.Response(id: id, error: .methodNotFound)
        }
    }

    private static func initializeResult() -> JSON {
        // MCP `initialize` reply. Advertise the protocol version we speak +
        // the `tools` capability (we don't serve resources, prompts, or
        // notifications/list_changed in this minimal server).
        .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "serverInfo": .object([
                "name": .string("agentnotch"),
                "version": .string("0.1.0")
            ])
        ])
    }

    private func handleToolsCall(id: MCP.JSONRPCID, params: JSON?) async -> MCP.Response {
        guard let params = params,
              let obj = params.objectValue,
              let name = obj["name"]?.stringValue else {
            return MCP.Response(id: id, error: .invalidParams)
        }
        let args = obj["arguments"] ?? .object([:])

        let dispatcher = stateQueue.sync { self.dispatcher }
        guard let dispatcher else {
            return MCP.Response(id: id, error: .internalError)
        }

        // Map MCP tool name → ToolDispatcher invocation. Computer subactions
        // expand into a single `computer` call with `action` set; fast-path
        // tools pass through 1:1.
        let toolUseId = "mcp-\(UUID().uuidString.prefix(8))"
        let dispatched: DispatchedToolResult

        if let action = Self.computerActions[name] {
            // Splice the action keyword into the args dict and dispatch to
            // the `computer` family.
            var combined: [String: JSON] = args.objectValue ?? [:]
            combined["action"] = .string(action)
            dispatched = await dispatcher.dispatch(toolUseId: toolUseId, name: "computer", input: .object(combined))
        } else if Self.passthroughTools.contains(name) {
            dispatched = await dispatcher.dispatch(toolUseId: toolUseId, name: name, input: args)
        } else {
            return MCP.Response(id: id, error: MCP.JSONRPCError(code: -32601, message: "Tool not found: \(name)"))
        }

        // Build MCP CallToolResult from dispatched ContentBlocks.
        let contentItems: [MCP.ContentItem] = dispatched.content.compactMap { block in
            switch block {
            case .text(let t):
                return .text(t)
            case .image(let media, let base64, _):
                return .image(base64: base64, mimeType: media)
            default:
                return nil
            }
        }
        let result = MCP.CallToolResult(content: contentItems, isError: dispatched.isError)
        do {
            return MCP.Response(id: id, result: try JSON.from(result))
        } catch {
            log.error("mcp.tools_call_encode_failed name=\(name) error=\(error)")
            return MCP.Response(id: id, error: .internalError)
        }
    }

    // MARK: - Tool catalog

    /// MCP tool name → `computer` subaction. Mirrors the subactions the
    /// existing API-mode harness already handles in ToolDispatcher.
    private static let computerActions: [String: String] = [
        "screenshot":      "screenshot",
        "left_click":      "left_click",
        "right_click":     "right_click",
        "middle_click":    "middle_click",
        "double_click":    "double_click",
        "triple_click":    "triple_click",
        "mouse_move":      "mouse_move",
        "left_click_drag": "left_click_drag",
        "cursor_position": "cursor_position",
        "type":            "type",
        "key":             "key",
        "scroll":          "scroll",
        "wait":            "wait",
        "hold_key":        "hold_key"
    ]

    /// Fast-path tools — passed through to ToolDispatcher unchanged.
    private static let passthroughTools: Set<String> = [
        "open_url", "open_app", "applescript", "run_shortcut",
        "ax_query", "ax_press", "ax_set_value", "menu_shortcut"
    ]

    /// Cached `tools/list` result. Built once on first access — every CC
    /// session re-asks for the catalog and the contents never change.
    private static let toolCatalogResult: JSON = {
        (try? toolCatalog().asResultJSON()) ?? .object(["tools": .array([])])
    }()

    private static func toolCatalog() -> [MCP.ToolDescriptor] {
        let coord: JSON = .object([
            "type": .string("array"),
            "description": .string("[x, y] in 1280x800 model coords."),
            "items": .object(["type": .string("integer")]),
            "minItems": .int(2),
            "maxItems": .int(2)
        ])

        let emptyObject: JSON = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])

        func obj(_ properties: [String: JSON], required: [String] = []) -> JSON {
            var o: [String: JSON] = [
                "type": .string("object"),
                "properties": .object(properties)
            ]
            if !required.isEmpty {
                o["required"] = .array(required.map { .string($0) })
            }
            return .object(o)
        }

        return [
            // Computer-family
            MCP.ToolDescriptor(name: "screenshot", description: "Capture the screen and return a JPEG image scaled to 1280x800. Updates the click-coordinate transform.", inputSchema: emptyObject),
            MCP.ToolDescriptor(name: "left_click", description: "Click at a 1280x800 coordinate.", inputSchema: obj(["coordinate": coord], required: ["coordinate"])),
            MCP.ToolDescriptor(name: "right_click", description: "Right-click at a 1280x800 coordinate.", inputSchema: obj(["coordinate": coord], required: ["coordinate"])),
            MCP.ToolDescriptor(name: "middle_click", description: "Middle-click at a 1280x800 coordinate.", inputSchema: obj(["coordinate": coord], required: ["coordinate"])),
            MCP.ToolDescriptor(name: "double_click", description: "Double-click at a 1280x800 coordinate.", inputSchema: obj(["coordinate": coord], required: ["coordinate"])),
            MCP.ToolDescriptor(name: "triple_click", description: "Triple-click at a 1280x800 coordinate.", inputSchema: obj(["coordinate": coord], required: ["coordinate"])),
            MCP.ToolDescriptor(name: "mouse_move", description: "Move the cursor to a 1280x800 coordinate without clicking.", inputSchema: obj(["coordinate": coord], required: ["coordinate"])),
            MCP.ToolDescriptor(name: "left_click_drag", description: "Press, drag, and release between two 1280x800 coordinates.", inputSchema: obj([
                "start_coordinate": coord,
                "coordinate": coord
            ], required: ["start_coordinate", "coordinate"])),
            MCP.ToolDescriptor(name: "cursor_position", description: "Return the current mouse position as text.", inputSchema: emptyObject),
            MCP.ToolDescriptor(name: "type", description: "Type a string. Pastes via clipboard for >4 ASCII characters; otherwise types char-by-char.", inputSchema: obj([
                "text": .object(["type": .string("string")]),
                "via_paste": .object(["type": .string("boolean"), "description": .string("Force paste path.")])
            ], required: ["text"])),
            MCP.ToolDescriptor(name: "key", description: "Send a keyboard shortcut chord. Example: 'cmd+s', 'ctrl+shift+t'.", inputSchema: obj([
                "text": .object(["type": .string("string"), "description": .string("Chord, e.g. cmd+s.")])
            ], required: ["text"])),
            MCP.ToolDescriptor(name: "scroll", description: "Scroll at a coordinate. scroll_amount is a count of wheel clicks (~100px each); use 5-10 for half-screen, 15-20 for full screen.", inputSchema: obj([
                "coordinate": coord,
                "scroll_direction": .object(["type": .string("string"), "enum": .array([.string("up"), .string("down"), .string("left"), .string("right")])]),
                "scroll_amount": .object(["type": .string("integer"), "minimum": .int(1)])
            ], required: ["coordinate", "scroll_direction", "scroll_amount"])),
            MCP.ToolDescriptor(name: "wait", description: "Sleep for N milliseconds.", inputSchema: obj([
                "duration": .object(["type": .string("number"), "description": .string("Seconds to wait.")])
            ], required: ["duration"])),
            MCP.ToolDescriptor(name: "hold_key", description: "Hold a key chord for a duration.", inputSchema: obj([
                "text": .object(["type": .string("string")]),
                "duration": .object(["type": .string("number"), "description": .string("Seconds to hold.")])
            ], required: ["text", "duration"])),

            // Fast-path family
            MCP.ToolDescriptor(name: "open_url", description: "Open a URL via NSWorkspace (https, mailto, sms, app schemes).", inputSchema: obj([
                "url": .object(["type": .string("string")])
            ], required: ["url"])),
            MCP.ToolDescriptor(name: "open_app", description: "Launch (or activate) a macOS app by exact .app name. Prefer this over open_url for plain 'open <App>' goals.", inputSchema: obj([
                "name": .object(["type": .string("string")])
            ], required: ["name"])),
            MCP.ToolDescriptor(name: "applescript", description: "Run an AppleScript via NSAppleScript. Allow-listed target apps only (Safari, Chrome, Spotify, Music, Messages, Mail, Notes, Reminders, Calendar, Terminal, Finder).", inputSchema: obj([
                "script": .object(["type": .string("string")])
            ], required: ["script"])),
            MCP.ToolDescriptor(name: "run_shortcut", description: "Run a user-installed macOS Shortcut by name. Optional stdin input.", inputSchema: obj([
                "name": .object(["type": .string("string")]),
                "input": .object(["type": .string("string")])
            ], required: ["name"])),
            MCP.ToolDescriptor(name: "ax_query", description: "Find Accessibility elements in the frontmost app by role + label substring. Returns ids usable with ax_press / ax_set_value.", inputSchema: obj([
                "role": .object(["type": .string("string")]),
                "label_contains": .object(["type": .string("string")]),
                "value_contains": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")])
            ])),
            MCP.ToolDescriptor(name: "ax_press", description: "Perform AXPress on an element id.", inputSchema: obj([
                "id": .object(["type": .string("string")])
            ], required: ["id"])),
            MCP.ToolDescriptor(name: "ax_set_value", description: "Set the value attribute of an element by id (text field, etc).", inputSchema: obj([
                "id": .object(["type": .string("string")]),
                "value": .object(["type": .string("string")])
            ], required: ["id", "value"])),
            MCP.ToolDescriptor(name: "menu_shortcut", description: "Look up the keyboard shortcut for a menu item in the frontmost app and send that keystroke.", inputSchema: obj([
                "title": .object(["type": .string("string")])
            ], required: ["title"]))
        ]
    }
}

// MARK: - Client connection handler

private final class ClientHandler: @unchecked Sendable {
    private let fd: Int32
    private weak var bridge: MCPBridge?
    private let readQueue = DispatchQueue(label: "com.agentnotch.mcp.client.read")
    private var processTask: Task<Void, Never>?
    private var closed = false
    private let closedLock = NSLock()

    init(fd: Int32, bridge: MCPBridge) {
        self.fd = fd
        self.bridge = bridge
    }

    func start() {
        // Two-stage pipeline. The read thread (`readQueue`) blocks on
        // Darwin.read — robust against Unix-socket EOF, where the
        // FileHandle.bytes async API silently never returns. Each complete
        // line gets yielded into an AsyncStream; a single async Task drains
        // the stream, awaits the dispatcher, and writes the response
        // inline. Serial processing here is load-bearing — closing the FD
        // on EOF while the dispatcher Task was still mid-await would race
        // any pending writes (EBADF on the response side). The read thread
        // signals "no more input" via `continuation.finish()` but does NOT
        // touch the FD; the consume Task drains the queue, lets the last
        // response write through, and only THEN closes the FD.
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        processTask = Task.detached { [weak self] in
            for await lineData in stream {
                await self?.processLine(lineData)
            }
            self?.close()
        }
        readQueue.async { [weak self] in
            self?.readLoop(emit: { continuation.yield($0) })
            continuation.finish()
        }
    }

    func close() {
        closedLock.lock()
        let already = closed
        closed = true
        closedLock.unlock()
        guard !already else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        bridge?.clientDidClose(self)
    }

    private func readLoop(emit: (Data) -> Void) {
        var buf = [UInt8](repeating: 0, count: 8192)
        var inbox = Data()
        while true {
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                Darwin.read(fd, p.baseAddress, p.count)
            }
            if n > 0 {
                inbox.append(buf, count: n)
                while let nl = inbox.firstIndex(of: 0x0A) {
                    let line = inbox.subdata(in: 0..<nl)
                    inbox.removeSubrange(0...nl)
                    guard !line.isEmpty else { continue }
                    emit(line)
                }
            } else if n == 0 {
                log.info("mcp.client_eof fd=\(self.fd)")
                return
            } else {
                if errno == EINTR { continue }
                log.error("mcp.read_error errno=\(errno)")
                return
            }
        }
    }

    private func processLine(_ lineData: Data) async {
        let envelope: MCP.Envelope
        do {
            envelope = try JSONDecoder().decode(MCP.Envelope.self, from: lineData)
        } catch {
            log.warning("mcp.parse_error bytes=\(lineData.count) error=\(error)")
            return
        }
        guard let bridge = bridge,
              let response = await bridge.handle(envelope: envelope) else { return }
        writeResponse(response)
    }

    private func writeResponse(_ response: MCP.Response) {
        do {
            var data = try JSONEncoder().encode(response)
            data.append(0x0A)
            data.withUnsafeBytes { raw in
                var remaining = raw.count
                var ptr = raw.baseAddress
                while remaining > 0 {
                    let n = Darwin.write(self.fd, ptr, remaining)
                    if n <= 0 {
                        if errno == EINTR { continue }
                        // EPIPE on response write = client disconnected after
                        // sending the request. Routine; don't pollute logs.
                        if errno != EPIPE {
                            log.error("mcp.write_error errno=\(errno)")
                        }
                        return
                    }
                    remaining -= n
                    ptr = ptr?.advanced(by: n)
                }
            }
        } catch {
            log.error("mcp.response_encode_error error=\(error)")
        }
    }
}

// MARK: - Errors

private struct POSIXErr: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
