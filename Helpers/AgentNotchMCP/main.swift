//
//  AgentNotchMCP — stdio MCP sidecar
//
//  Bundled at Contents/MacOS/AgentNotchMCP inside the main AgentNotch.app.
//  Spawned by `claude` via `--mcp-config` when AgentNotch is in CC-provider
//  mode. The helper has zero MCP semantic awareness — it is a thin
//  bidirectional pipe between Claude Code's stdio (the MCP client end) and
//  AgentNotch's in-process MCP server (over a Unix domain socket).
//
//  Wire:
//      CC stdin  ──►  helper stdin  ──►  Unix socket  ──►  MCPBridge
//      CC stdout ◄──  helper stdout ◄──  Unix socket  ◄──  MCPBridge
//
//  Args: `--socket <path>`  required.
//
//  Connect retries for 2s in case the user fires CC before AgentNotch has
//  finished its boot sequence. After that we exit non-zero and CC reports a
//  startup failure.
//

import Foundation
import Darwin

// Default SIGPIPE behaviour kills the process when a peer closes their end
// of a pipe / socket mid-write. We handle EPIPE explicitly via errno in the
// pump loops; ignore the signal so a closed Claude Code stdout or a bridge
// disconnect terminates the helper cleanly via its return paths.
signal(SIGPIPE, SIG_IGN)

private func die(_ message: String, code: Int32 = 1) -> Never {
    fputs("AgentNotchMCP: \(message)\n", stderr)
    exit(code)
}

// MARK: - Arg parsing

let args = CommandLine.arguments
var socketPath: String?
var i = 1
while i < args.count {
    let arg = args[i]
    switch arg {
    case "--socket":
        guard i + 1 < args.count else { die("--socket requires a path") }
        socketPath = args[i + 1]
        i += 2
    case "-h", "--help":
        print("AgentNotchMCP --socket <path>")
        print("  Stdio MCP sidecar. Forwards JSON-RPC between Claude Code and AgentNotch.")
        exit(0)
    default:
        die("unknown arg: \(arg)")
    }
}
guard let socketPath else { die("missing --socket") }

// MARK: - Connect (with retry)

func connectUDS(path: String, timeoutSeconds: Double = 2.0) -> Int32 {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while true {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            die("socket() failed errno=\(errno)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < 104 else {
            close(fd)
            die("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let dst = raw.bindMemory(to: UInt8.self).baseAddress!
            for (idx, byte) in bytes.enumerated() { dst[idx] = byte }
            dst[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        if r == 0 { return fd }
        close(fd)
        if Date() >= deadline {
            die("could not connect to \(path) within \(timeoutSeconds)s — is AgentNotch running?")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

let socketFD = connectUDS(path: socketPath)

// MARK: - Bidirectional pump

let stdinFD: Int32 = 0
let stdoutFD: Int32 = 1

func writeAll(fd: Int32, bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
    var remaining = count
    var ptr: UnsafePointer<UInt8>? = bytes
    while remaining > 0 {
        let n = Darwin.write(fd, ptr, remaining)
        if n <= 0 {
            if errno == EINTR { continue }
            return false
        }
        remaining -= n
        ptr = ptr?.advanced(by: n)
    }
    return true
}

let verbose = ProcessInfo.processInfo.environment["AGENTNOTCH_MCP_DEBUG"] == "1"

func dbg(_ s: String) {
    guard verbose else { return }
    fputs("AgentNotchMCP: \(s)\n", stderr)
}

func pump(from src: Int32, to dst: Int32, label: String, onEOF: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                Darwin.read(src, p.baseAddress, p.count)
            }
            if n > 0 {
                dbg("\(label) read \(n) bytes")
                let ok = buf.withUnsafeBufferPointer { p -> Bool in
                    writeAll(fd: dst, bytes: p.baseAddress!, count: n)
                }
                if !ok {
                    // EPIPE just means the peer closed its read end — normal
                    // when claude exits or a downstream pipe truncates. Other
                    // errors are real.
                    if errno != EPIPE {
                        fputs("AgentNotchMCP: write failed on \(label) errno=\(errno)\n", stderr)
                    }
                    onEOF()
                    return
                }
                dbg("\(label) wrote \(n) bytes")
            } else if n == 0 {
                dbg("\(label) EOF")
                onEOF()
                return
            } else {
                if errno == EINTR { continue }
                fputs("AgentNotchMCP: read failed on \(label) errno=\(errno)\n", stderr)
                onEOF()
                return
            }
        }
    }
}

// Half-close semantics. When one direction ends, signal EOF to the other
// end of the socket WITHOUT closing the FD — a fast stdin EOF (claude
// finishing its prompt write) would otherwise close the socket under the
// response pump and we'd drop the bridge's reply.
let group = DispatchGroup()
group.enter()
group.enter()

let shutdownLock = NSLock()
var stdinEnded = false
var socketEnded = false

func onStdinEnd() {
    shutdownLock.lock()
    let already = stdinEnded
    stdinEnded = true
    shutdownLock.unlock()
    guard !already else { return }
    Darwin.shutdown(socketFD, SHUT_WR)
    group.leave()
}

func onSocketEnd() {
    shutdownLock.lock()
    let already = socketEnded
    socketEnded = true
    shutdownLock.unlock()
    guard !already else { return }
    Darwin.shutdown(socketFD, SHUT_RD)
    group.leave()
}

pump(from: stdinFD, to: socketFD, label: "stdin→socket", onEOF: onStdinEnd)
pump(from: socketFD, to: stdoutFD, label: "socket→stdout", onEOF: onSocketEnd)

group.wait()
Darwin.close(socketFD)
exit(0)
