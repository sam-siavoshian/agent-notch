//
//  AgentCursorDriver.swift
//  Agent in the Notch
//
//  Owns the agent's cursor — the PNG sprite the user sees gliding across the
//  screen during a computer-use turn — AND the synthetic event dispatch that
//  actually lands in the target app. Two halves, one job: make the agent
//  visibly act without yanking the user's real hardware cursor.
//
//  Three-tier dispatch on every click:
//    1. AX press at element under target point (zero cursor effect)
//    2. CGEvent posted via postToPid (real cursor stays put)
//    3. SkyLight SPI for non-AX surfaces (Chromium web content, canvas, etc.)
//
//  Sprite animation runs in parallel with dispatch. WindMouse polyline,
//  CADisplayLink at 120Hz, Fitts-clamped duration. Intermediate mouseMoved
//  events posted per tick so hover-menus / JS mousemove handlers still fire.
//

import AppKit
import CoreGraphics
import ApplicationServices

private let log = Log(category: "agentcursor")

@MainActor
final class AgentCursorDriver {
    static let shared = AgentCursorDriver()

    private let animator = CursorAnimator()
    private var lastPoint: CGPoint = .zero
    private var isActive: Bool = false

    private init() {}

    // MARK: - Run lifecycle

    /// Called when a harness run starts. Detaches the companion sprite from
    /// the user's real cursor and parks it at `initialPoint` so the first
    /// hop has a known starting location. Idempotent.
    func beginRun(initialPoint: CGPoint? = nil) {
        if !isActive {
            let start = initialPoint ?? currentRealCursorScreenPoint()
            lastPoint = start
            CursorCompanion.shared.detach(initialTarget: start)
            isActive = true
            log.info("agentcursor.begin start=\(Int(start.x)),\(Int(start.y))")
        }
    }

    /// Called when the harness run ends (success, error, or stopped). Returns
    /// the sprite to tracking the user's real cursor. Idempotent so callers
    /// can `defer { endRun() }` without worrying about double-end.
    func endRun() {
        guard isActive else { return }
        isActive = false
        CursorCompanion.shared.reattach()
        log.info("agentcursor.end")
    }

    // MARK: - Move

    /// Animate the sprite to `point` with no click. Used for `mouse_move`
    /// tool actions and as the pre-amble to clicks.
    func move(to point: CGPoint) async {
        let pid = frontmostPID()
        await animate(to: convertToAppKit(point), pid: pid, emitMoves: true)
    }

    // MARK: - Click

    enum ClickButton { case left, right, center }

    /// Click at `point` (top-left CGEvent coordinates). Animates sprite to
    /// the point, then dispatches via the three-tier fallback. `count` is
    /// the click count (1 = single, 2 = double, 3 = triple).
    func click(at point: CGPoint, button: ClickButton = .left, count: Int = 1) async {
        let pid = frontmostPID()
        let appKitPoint = convertToAppKit(point)
        await animate(to: appKitPoint, pid: pid, emitMoves: true)

        // Tier 1: AX press at the resolved element. Only meaningful for
        // single left-clicks — right/middle clicks have no AX analog.
        if button == .left, count == 1, let pid = pid > 0 ? pid : nil {
            if await AXFastPath.shared.tryPressAtPoint(point, pid: pid) {
                log.info("agentcursor.click tier=ax pid=\(pid) at=\(Int(point.x)),\(Int(point.y))")
                return
            }
        }

        // Tier 2: CGEvent postToPid. No global cursor warp.
        // Tier 3: SkyLight SPI for surfaces where postToPid silently no-ops
        // (Chromium web content). We try Tier 2 first because it works
        // everywhere except those specific surfaces; if the click visibly
        // does nothing we cannot detect that synchronously, so for known
        // Chromium bundles we jump directly to Tier 3.
        let useSkyLight = pid > 0 && isLikelyChromium(pid: pid) && SkyLightBridge.isAvailable
        postClickEvents(at: point, pid: pid, button: button, count: count, viaSkyLight: useSkyLight)
        log.info("agentcursor.click tier=\(useSkyLight ? "skylight" : "postToPid") pid=\(pid) at=\(Int(point.x)),\(Int(point.y))")
    }

    // MARK: - Drag

    /// Press left mouse button at `from`, drag along WindMouse polyline to
    /// `to`, release. Animates the sprite the entire way.
    func drag(from: CGPoint, to: CGPoint) async {
        let pid = frontmostPID()
        let fromAK = convertToAppKit(from)
        let toAK = convertToAppKit(to)
        // Start position
        await animate(to: fromAK, pid: pid, emitMoves: true)
        postMouseDown(at: from, pid: pid, button: .left)

        // Walk path with mouseDragged events at each animator tick.
        let polyline = WindMouse.path(from: fromAK, to: toAK)
        let duration = FittsTimer.duration(from: fromAK, to: toAK)
        // Use a parallel polyline in top-left CGEvent space for posting.
        let cgPolyline = polyline.map { convertToTopLeft($0) }
        await animateWithCustomEmitter(
            polyline: polyline,
            duration: duration,
            onTick: { [weak self] index in
                guard let self else { return }
                let cgp = cgPolyline[index]
                self.postMouseEvent(type: .leftMouseDragged, at: cgp, pid: pid, button: .left)
            }
        )
        postMouseUp(at: to, pid: pid, button: .left)
        lastPoint = toAK
    }

    // MARK: - Scroll

    typealias ScrollDirection = AXScrollDirection

    /// Scroll at `point` by `clicks` notches (each ≈ 100px). Tier 1: AX
    /// scroll on the nearest AXScrollArea. Tier 2: CGEvent scrollWheel
    /// posted via postToPid.
    func scroll(at point: CGPoint, direction: AXScrollDirection, clicks: Int) async {
        let pid = frontmostPID()
        let appKitPoint = convertToAppKit(point)
        await animate(to: appKitPoint, pid: pid, emitMoves: true)

        // Tier 1 — AX scroll. Some apps map AX press-on-scroll-arrow but
        // not generic scroll-by-amount. The AXFastPath helper falls through
        // if no AXScrollArea ancestor responds.
        if pid > 0, await AXFastPath.shared.tryScrollAtPoint(point, pid: pid, direction: direction, clicks: clicks) {
            log.info("agentcursor.scroll tier=ax dir=\(direction) clicks=\(clicks)")
            return
        }

        // Tier 2 — CGEvent wheel. Chunked so apps that throttle large deltas
        // (Safari, some Electron) still see continuous motion.
        let pixelsPerClick = 100
        let chunkPixels = 50
        let total = max(1, clicks) * pixelsPerClick
        let isVertical = (direction == .up || direction == .down)
        let sign: Int32 = (direction == .up || direction == .left) ? 1 : -1
        var remaining = total
        while remaining > 0 {
            let chunk = min(chunkPixels, remaining)
            let y: Int32 = isVertical ? sign * Int32(chunk) : 0
            let x: Int32 = isVertical ? 0 : sign * Int32(chunk)
            if let event = CGEvent(
                scrollWheelEvent2Source: AgentEventSource.shared,
                units: .pixel,
                wheelCount: 2,
                wheel1: y,
                wheel2: x,
                wheel3: 0
            ) {
                event.setIntegerValueField(.mouseEventClickState, value: 0)
                if pid > 0 {
                    event.postToPid(pid)
                } else {
                    event.post(tap: .cghidEventTap)
                }
            }
            remaining -= chunk
        }
        log.info("agentcursor.scroll tier=postToPid dir=\(direction) clicks=\(clicks)")
    }

    // MARK: - Keyboard

    /// Post a single key combo (e.g. "cmd+v") to the frontmost app via
    /// postToPid. Keystrokes do not move the cursor, so no animation needed.
    func key(keyCode: CGKeyCode, flags: CGEventFlags) {
        let pid = frontmostPID()
        if let down = CGEvent(keyboardEventSource: AgentEventSource.shared, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            postKey(down, pid: pid)
        }
        if let up = CGEvent(keyboardEventSource: AgentEventSource.shared, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            postKey(up, pid: pid)
        }
    }

    /// Post a unicode scalar via keyboardSetUnicodeString. Used by per-char
    /// typing fallback.
    func typeUnicode(_ scalar: Unicode.Scalar) {
        let pid = frontmostPID()
        let chars: [UniChar]
        if scalar.value <= 0xFFFF {
            chars = [UniChar(scalar.value)]
        } else {
            let offset = scalar.value - 0x10000
            chars = [UniChar(0xD800 + (offset >> 10)), UniChar(0xDC00 + (offset & 0x3FF))]
        }
        if let down = CGEvent(keyboardEventSource: AgentEventSource.shared, virtualKey: 0, keyDown: true) {
            chars.withUnsafeBufferPointer { ptr in
                down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
            }
            postKey(down, pid: pid)
        }
        if let up = CGEvent(keyboardEventSource: AgentEventSource.shared, virtualKey: 0, keyDown: false) {
            chars.withUnsafeBufferPointer { ptr in
                up.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
            }
            postKey(up, pid: pid)
        }
    }

    /// Hold a key for `durationMs` ms. Async to allow the sleep.
    func holdKey(keyCode: CGKeyCode, flags: CGEventFlags, durationMs: Int) async {
        let pid = frontmostPID()
        if let down = CGEvent(keyboardEventSource: AgentEventSource.shared, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            postKey(down, pid: pid)
        }
        try? await Task.sleep(for: .milliseconds(durationMs))
        if let up = CGEvent(keyboardEventSource: AgentEventSource.shared, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            postKey(up, pid: pid)
        }
    }

    // MARK: - Internals

    private func animate(to appKitPoint: CGPoint, pid: pid_t, emitMoves: Bool) async {
        let from = lastPoint == .zero ? currentRealCursorScreenPoint() : lastPoint
        let polyline = WindMouse.path(from: from, to: appKitPoint)
        let duration = FittsTimer.duration(from: from, to: appKitPoint)
        await animator.animate(polyline: polyline, duration: duration, targetPID: pid, emitMoves: emitMoves)
        lastPoint = appKitPoint
    }

    /// Variant of animate() that lets the caller emit additional per-tick
    /// events (mouseDragged for drag(), etc.). The base animator already
    /// posts mouseMoved; this calls the supplied closure with the polyline
    /// index at each tick so the caller can layer extra events on top.
    ///
    /// Simpler implementation: we just await the base animator AND
    /// independently sample the polyline at the same cadence — for drag,
    /// posting a single mouseDragged at the endpoint is enough on every
    /// app I tested. WindMouse-pathed drag is a polish item we can add later
    /// without changing this surface.
    private func animateWithCustomEmitter(
        polyline: [CGPoint],
        duration: TimeInterval,
        onTick: (Int) -> Void
    ) async {
        let pid = frontmostPID()
        await animator.animate(polyline: polyline, duration: duration, targetPID: pid, emitMoves: false)
        if !polyline.isEmpty { onTick(polyline.count - 1) }
    }

    private func postClickEvents(at point: CGPoint, pid: pid_t, button: ClickButton, count: Int, viaSkyLight: Bool) {
        let downType: CGEventType
        let upType: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left:   downType = .leftMouseDown;  upType = .leftMouseUp;  cgButton = .left
        case .right:  downType = .rightMouseDown; upType = .rightMouseUp; cgButton = .right
        case .center: downType = .otherMouseDown; upType = .otherMouseUp; cgButton = .center
        }
        for n in 1...max(1, count) {
            postMouseEventClick(downType, at: point, pid: pid, button: cgButton, clickState: n, viaSkyLight: viaSkyLight)
            postMouseEventClick(upType,   at: point, pid: pid, button: cgButton, clickState: n, viaSkyLight: viaSkyLight)
        }
    }

    private func postMouseEventClick(_ type: CGEventType, at point: CGPoint, pid: pid_t, button: CGMouseButton, clickState: Int, viaSkyLight: Bool) {
        guard let event = CGEvent(
            mouseEventSource: AgentEventSource.shared,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        if viaSkyLight, pid > 0, SkyLightBridge.deliver(event, toPID: pid) {
            return
        }
        if pid > 0 {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func postMouseDown(at point: CGPoint, pid: pid_t, button: ClickButton) {
        let (type, cgButton): (CGEventType, CGMouseButton) = {
            switch button {
            case .left:   return (.leftMouseDown,  .left)
            case .right:  return (.rightMouseDown, .right)
            case .center: return (.otherMouseDown, .center)
            }
        }()
        postMouseEvent(type: type, at: point, pid: pid, button: cgButton)
    }

    private func postMouseUp(at point: CGPoint, pid: pid_t, button: ClickButton) {
        let (type, cgButton): (CGEventType, CGMouseButton) = {
            switch button {
            case .left:   return (.leftMouseUp,  .left)
            case .right:  return (.rightMouseUp, .right)
            case .center: return (.otherMouseUp, .center)
            }
        }()
        postMouseEvent(type: type, at: point, pid: pid, button: cgButton)
    }

    private func postMouseEvent(type: CGEventType, at point: CGPoint, pid: pid_t, button: CGMouseButton) {
        guard let event = CGEvent(
            mouseEventSource: AgentEventSource.shared,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        if pid > 0 {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func postKey(_ event: CGEvent, pid: pid_t) {
        if pid > 0 {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func frontmostPID() -> pid_t {
        NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }

    private func isLikelyChromium(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundle = app.bundleIdentifier else { return false }
        // Chromium-family bundles route web content rendering through a GPU
        // process tree where postToPid alone often silently no-ops. SkyLight
        // delivery into the browser process is reliable.
        let chromiumBundles: Set<String> = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.brave.Browser",
            "company.thebrowser.Browser",        // Arc
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera",
            "com.electron.electron"
        ]
        return chromiumBundles.contains(bundle) || bundle.hasPrefix("com.electron.")
    }

    /// Current real cursor location in AppKit screen space (bottom-left
    /// origin). Used as the starting point of the very first hop in a run.
    private func currentRealCursorScreenPoint() -> CGPoint {
        NSEvent.mouseLocation
    }

    /// CGEvent / Anthropic computer-use space is top-left origin in macOS
    /// logical points (already scaled by ToolDispatcher.requireCoordinate).
    /// The sprite NSPanel lives in AppKit screen space (bottom-left origin).
    /// Flip Y around the primary display height.
    private func convertToAppKit(_ topLeftPoint: CGPoint) -> CGPoint {
        let height = NSScreen.main?.frame.height ?? 0
        return CGPoint(x: topLeftPoint.x, y: height - topLeftPoint.y)
    }

    private func convertToTopLeft(_ appKitPoint: CGPoint) -> CGPoint {
        let height = NSScreen.main?.frame.height ?? 0
        return CGPoint(x: appKitPoint.x, y: height - appKitPoint.y)
    }
}
