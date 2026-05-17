//
//  ComputerUseHarness.swift
//  Agent in the Notch
//
//  One agent turn: assemble inputs → call Anthropic → execute tool calls →
//  feed results back → loop until stop_reason != "tool_use". Updates
//  AgentState as it goes so the notch UI reflects what's happening.
//
//  Optimizations layered on top of the basic loop:
//  - Static system prompt cached server-side via cache_control. Dynamic
//    context (activation packet, prefs, custom prompt) lives after the
//    cache breakpoint.
//  - Tools list also cached (one cache breakpoint on the last tool).
//  - Rolling cache_control on the most recent tool_result so every
//    subsequent turn reads the prior turns' state from cache instead of
//    re-tokenizing the whole history.
//  - max_tokens bumped to 4096 so the model can plan + describe + act
//    without truncation.
//  - The model is taught (in system prompt) a strict tool preference order
//    so it picks fast paths (URL, AppleScript, AX) before vision+click.
//

import Foundation
import AppKit

private let log = Log(category: "harness")

@MainActor
public final class ComputerUseHarness {
    public static let shared = ComputerUseHarness()

    public var modelID: String = AnthropicModel.haiku45
    public var fallbackModelID: String = AnthropicModel.haiku45
    public var maxTurns: Int = 100
    public var maxOutputTokens: Int = 4096
    /// Long-edge ceiling for what the agent sees + clicks in. Anthropic's
    /// computer-use models are most accurate at XGA/WXGA scale and degrade
    /// noticeably past ~1280px; keep this small unless we change models.
    public var agentScreenshotLongEdge: Int = 1280

    public private(set) var isRunning: Bool = false
    private var stopRequested: Bool = false

    private init() {}

    public func requestStop() {
        guard isRunning else { return }
        stopRequested = true
        NSLog("[Harness] stop requested")
    }

    public struct Input {
        public var transcript: String
        public var contextSummary: String
        /// Intent verb from the Selector — forwarded to HarnessRunDetail for DevTools display.
        public var intentVerb: String?
        /// JPEG bytes of the screen at long-press time. When non-nil the
        /// harness prepends an image block to the FIRST user message so
        /// Claude sees the screen on turn 1 — eliminating the throwaway
        /// `computer.screenshot` tool call most agent runs used to start with.
        public var initiationScreenshot: Data?
        public init(
            transcript: String,
            contextSummary: String,
            intentVerb: String? = nil,
            initiationScreenshot: Data? = nil
        ) {
            self.transcript = transcript
            self.contextSummary = contextSummary
            self.intentVerb = intentVerb
            self.initiationScreenshot = initiationScreenshot
        }
    }

    public func run(_ input: Input) async {
        guard let apiKey = Secrets.anthropicAPIKey else {
            log.error("harness.start missing_api_key=true")
            AgentState.shared.set(.error(message: "Missing ANTHROPIC_API_KEY"))
            return
        }

        let runID = UUID()
        let startedAt = Date()
        let transcriptLength = input.transcript.count
        let contextLength = input.contextSummary.count
        log.info("harness.start run_id=\(runID.uuidString) model=\(self.modelID) transcript_len=\(transcriptLength) context_len=\(contextLength)")
        var toolCallCount = 0
        var screenshotToolCallCount = 0
        var actionCounts: [String: Int] = [:]
        var firstToolCallAt: Date?
        var firstNonScreenshotActionAt: Date?
        var usedFallback = false
        var completedTurns = 0
        var verifierRetries = 0
        let maxVerifierRetries = 2

        let settings = AgentSettingsStore.shared.settings

        AgentState.shared.set(.thinking)
        CursorCompanion.shared.setThinking(true)
        isRunning = true
        stopRequested = false
        await AXFastPath.shared.reset()
        defer {
            CursorCompanion.shared.setThinking(false)
            isRunning = false
            stopRequested = false
        }

        // Pre-flight fast path. If a deterministic handler can finish
        // the task, skip the model loop entirely.
        let routed = await IntentRouter.tryHandle(transcript: input.transcript)
        if case .handled(let summary, let affirmation) = routed {
            TextToSpeechService.shared.speak(capped(affirmation))
            AgentState.shared.set(.idle, detail: summary)
            printRunMetrics(AgentRunMetricsRecord(
                id: runID,
                startedAt: startedAt,
                endedAt: Date(),
                durationMs: milliseconds(from: startedAt, to: Date()),
                modelID: "fast_path",
                fallbackModelID: fallbackModelID,
                usedFallback: false,
                transcriptLength: transcriptLength,
                contextLength: contextLength,
                contextIncluded: !input.contextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                turnCount: 0,
                toolCallCount: 0,
                screenshotToolCallCount: 0,
                actionCounts: ["fast_path": 1],
                timeToFirstToolCallMs: nil,
                timeToFirstNonScreenshotActionMs: nil,
                finalStatus: "completed_fast_path",
                errorMessage: nil
            ))
            return
        }

        // Three distinct coordinate spaces collide here — keep them straight:
        //   * logicalSize: macOS logical points (NSScreen.frame). What
        //     CGEvent / CGWarpMouseCursorPosition operate in.
        //   * backingSize: backing-store pixels (logical × backingScaleFactor).
        //     Useful for almost nothing except SCKit raw captures.
        //   * agentTargetSize: what the model SEES — screenshot dimensions +
        //     coordinate space we advertise to Anthropic. Capped at 1280 long
        //     edge per Anthropic's computer-use accuracy guidance.
        let logicalSize = primaryLogicalDisplaySize()
        let agentTargetSize = computeAgentTargetSize(logicalSize: logicalSize, maxLongEdge: agentScreenshotLongEdge)
        let dispatcher = ToolDispatcher(
            agentDisplaySize: agentTargetSize,
            logicalDisplaySize: logicalSize,
            screenshotLongEdge: agentScreenshotLongEdge
        )
        let client = AnthropicClient(apiKey: apiKey)

        let tools = buildTools(displaySize: agentTargetSize)
        let system = buildSystemBlocks(
            settings: settings,
            contextSummary: input.contextSummary
        )

        let systemSummaries = system.map { block in
            HarnessRunDetail.SystemBlockSummary(
                cached: block.cacheControl != nil,
                charCount: block.text.count,
                preview: String(block.text.prefix(240))
            )
        }
        await HarnessRunDetailStore.shared.startRun(HarnessRunDetail(
            id: runID,
            startedAt: startedAt,
            transcript: input.transcript,
            systemBlocks: systemSummaries,
            resolvedIntentVerb: input.intentVerb
        ))

        // First user message: transcript + (optionally) the long-press
        // screenshot as an image block. Including the screenshot here saves
        // a full round-trip — Claude no longer needs to take a
        // `computer.screenshot` tool call on turn 1 just to see the screen.
        let firstUserContent: [ContentBlock]
        if let jpeg = input.initiationScreenshot, !jpeg.isEmpty {
            // Selector hands us a 1568-long-edge JPEG (sized for OCR). The
            // agent's coordinate space is `agentTargetSize` (≤1280 long edge),
            // so resize the initiation image to match — otherwise the model
            // sees one resolution but is told the display is another, and
            // every turn-1 click lands off-target.
            let resizedJPEG = Self.resizeJPEG(jpeg, maxLongEdge: agentScreenshotLongEdge) ?? jpeg
            let base64 = resizedJPEG.base64EncodedString()
            firstUserContent = [
                .text(input.transcript),
                .image(mediaType: "image/jpeg", base64: base64, cache: false)
            ]
            log.info("harness.first_user has_image=true image_bytes=\(resizedJPEG.count) original_bytes=\(jpeg.count)")
        } else {
            firstUserContent = [.text(input.transcript)]
        }
        var messages: [Message] = [
            Message(role: "user", content: firstUserContent)
        ]

        var currentModel = modelID
        var triedFallback = false
        var turn = 0

        func recordMetrics(status: String, errorMessage: String? = nil) async {
            let endedAt = Date()
            await HarnessRunDetailStore.shared.finalizeRun(
                runID: runID,
                endedAt: endedAt,
                finalStatus: status
            )
            printRunMetrics(AgentRunMetricsRecord(
                id: runID,
                startedAt: startedAt,
                endedAt: endedAt,
                durationMs: milliseconds(from: startedAt, to: endedAt),
                modelID: modelID,
                fallbackModelID: fallbackModelID,
                usedFallback: usedFallback,
                transcriptLength: transcriptLength,
                contextLength: contextLength,
                contextIncluded: !input.contextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                turnCount: completedTurns,
                toolCallCount: toolCallCount,
                screenshotToolCallCount: screenshotToolCallCount,
                actionCounts: actionCounts,
                timeToFirstToolCallMs: firstToolCallAt.map { milliseconds(from: startedAt, to: $0) },
                timeToFirstNonScreenshotActionMs: firstNonScreenshotActionAt.map { milliseconds(from: startedAt, to: $0) },
                finalStatus: status,
                errorMessage: errorMessage
            ))

        }

        // Preview of the latest user message — used in the observability log so
        // each harness turn carries the input that drove it.
        func latestUserPreview() -> String {
            guard let lastUser = messages.last(where: { $0.role == "user" }) else { return "" }
            for block in lastUser.content {
                if case .text(let t) = block {
                    return String(t.prefix(200))
                }
                if case .toolResult(_, let inner, _, _) = block {
                    for ib in inner {
                        if case .text(let t) = ib { return "tool_result: \(String(t.prefix(180)))" }
                        if case .image = ib { return "tool_result: <image>" }
                    }
                }
            }
            return ""
        }

        let systemBlocksPreview = Self.systemBlocksPreview(system)

        while turn < maxTurns {
            if stopRequested {
                AgentState.shared.set(.idle, detail: "Stopped")
                await recordMetrics(status: "stopped_by_user")
                return
            }
            turn += 1
            log.info("harness.turn run_id=\(runID.uuidString) turn=\(turn) model=\(currentModel)")
            let turnStartedAt = Date()
            let userPreviewForTurn = latestUserPreview()

            // Move the cache breakpoint to the most recent tool_result so the
            // next request reads everything before it from cache. Older
            // breakpoints get stripped to stay within Anthropic's 4-marker cap.
            applyRollingCacheMarker(to: &messages)

            let effort = AgentSettingsStore.shared.reasoningEffort
            let thinkingConfig: ThinkingConfig? = effort.thinkingBudgetTokens.map { ThinkingConfig(budgetTokens: $0) }
            // max_tokens must exceed budget_tokens; leave headroom for the actual
            // tool-call output that follows reasoning.
            let effectiveMaxTokens: Int = {
                guard let budget = effort.thinkingBudgetTokens else { return maxOutputTokens }
                return max(maxOutputTokens, budget + 2048)
            }()
            let request = AnthropicMessageRequest(
                model: currentModel,
                maxTokens: effectiveMaxTokens,
                system: system,
                messages: messages,
                tools: tools,
                toolChoice: nil,
                thinking: thinkingConfig
            )

            let requestedAt = Date()
            let response: AnthropicMessageResponse
            do {
                response = try await client.send(request)
            } catch let err as AnthropicClient.Error {
                if !triedFallback, shouldFallback(err) {
                    log.warning("harness.fallback run_id=\(runID.uuidString) from=\(currentModel) to=\(self.fallbackModelID) status=\(err.status ?? -1)")
                    triedFallback = true
                    usedFallback = true
                    currentModel = fallbackModelID
                    continue
                }
                let status = err.status.map(String.init) ?? "nil"
                log.error("harness.api_error run_id=\(runID.uuidString) turn=\(turn) status=\(status) body=\(err.body ?? "nil")")
                let snippet = (err.body ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(400)
                AgentState.shared.set(.error(message: "Anthropic \(status): \(snippet)"))
                await recordMetrics(status: "anthropic_error", errorMessage: "\(err)")
                return
            } catch {
                log.error("harness.network_error run_id=\(runID.uuidString) turn=\(turn) error=\(error)")
                AgentState.shared.set(.error(message: "Network error"))
                await recordMetrics(status: "network_error", errorMessage: "\(error)")
                return
            }
            let respondedAt = Date()

            if let usage = response.usage {
                NSLog("[Harness] usage turn=\(turn) in=\(usage.inputTokens ?? -1) out=\(usage.outputTokens ?? -1) cache_create=\(usage.cacheCreationInputTokens ?? -1) cache_read=\(usage.cacheReadInputTokens ?? -1)")
            }

            completedTurns = turn
            messages.append(Message(role: "assistant", content: response.content))

            let toolUses = response.content.compactMap { block -> (id: String, name: String, input: JSON)? in
                if case .toolUse(let id, let name, let inp) = block { return (id, name, inp) }
                return nil
            }

            log.info("harness.response run_id=\(runID.uuidString) turn=\(turn) stop_reason=\(response.stopReason ?? "nil") tool_uses=\(toolUses.count)")

            if toolUses.isEmpty {
                let text = response.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t } else { return nil }
                }.joined(separator: " ")

                // Pre-stop verification — catch the "opened Spotify, said done,
                // never played Taylor Swift" failure mode. Verifier diffs the
                // user's original transcript against the model's final claim
                // and rejects stop if any explicit sub-goal is unfulfilled.
                if verifierRetries < maxVerifierRetries {
                    let verdict = await verifyCompletion(
                        transcript: input.transcript,
                        finalText: text,
                        client: client
                    )
                    if !verdict.complete {
                        verifierRetries += 1
                        log.info("harness.verifier_rejected run_id=\(runID.uuidString) retry=\(verifierRetries) missing=\(verdict.missing.prefix(200))")
                        let nudge = """
                        [Harness verification] You stopped but the task is NOT complete. Outstanding sub-goal(s): \(verdict.missing)

                        Take a screenshot right now to see the current state, then continue executing until EVERY explicit part of the original request — "\(input.transcript)" — is satisfied. Do not declare done again until that is true.
                        """
                        messages.append(Message(role: "user", content: [.text(nudge)]))
                        AgentState.shared.set(.thinking, detail: "Verifying…")
                        continue
                    }
                }

                log.info("harness.done run_id=\(runID.uuidString) status=completed_without_tool turns=\(turn) verifier_retries=\(verifierRetries)")
                TextToSpeechService.shared.speak(capped(text))
                await HarnessRunDetailStore.shared.appendTurn(
                    runID: runID,
                    turn: HarnessTurnRecord(
                        turnIndex: turn,
                        model: response.model,
                        requestedAt: requestedAt,
                        respondedAt: respondedAt,
                        stopReason: response.stopReason,
                        inputTokens: response.usage?.inputTokens,
                        outputTokens: response.usage?.outputTokens,
                        cacheReadInputTokens: response.usage?.cacheReadInputTokens,
                        cacheCreationInputTokens: response.usage?.cacheCreationInputTokens,
                        toolCalls: []
                    )
                )
                AgentObservabilityLog.shared.record(.harnessTurn(
                    id: UUID(),
                    t: turnStartedAt,
                    turnIndex: turn,
                    modelID: response.model,
                    systemBlocksPreview: systemBlocksPreview,
                    userContentPreview: userPreviewForTurn,
                    assistantPreview: String(text.prefix(200)),
                    toolCalls: [],
                    inputTokens: response.usage?.inputTokens,
                    outputTokens: response.usage?.outputTokens,
                    latencyS: Date().timeIntervalSince(turnStartedAt)
                ))
                AgentState.shared.set(.idle, detail: text)
                await recordMetrics(status: "completed_without_tool")
                return
            }

            if turn == 1 {
                let affirmation = response.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t } else { return nil }
                }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !affirmation.isEmpty {
                    TextToSpeechService.shared.speak(capped(affirmation))
                }
            }

            var resultBlocks: [ContentBlock] = []
            var toolRecords: [HarnessTurnRecord.ToolCallRecord] = []
            var observabilityToolCalls: [AgentObservabilityLog.ToolCallSummary] = []
            for use in toolUses {
                if stopRequested {
                    await HarnessRunDetailStore.shared.appendTurn(
                        runID: runID,
                        turn: HarnessTurnRecord(
                            turnIndex: turn,
                            model: response.model,
                            requestedAt: requestedAt,
                            respondedAt: respondedAt,
                            stopReason: response.stopReason,
                            inputTokens: response.usage?.inputTokens,
                            outputTokens: response.usage?.outputTokens,
                            cacheReadInputTokens: response.usage?.cacheReadInputTokens,
                            cacheCreationInputTokens: response.usage?.cacheCreationInputTokens,
                            toolCalls: toolRecords
                        )
                    )
                    AgentState.shared.set(.idle, detail: "Stopped")
                    await recordMetrics(status: "stopped_by_user")
                    return
                }
                let action = actionLabel(use)
                let now = Date()
                if firstToolCallAt == nil {
                    firstToolCallAt = now
                }
                if action != "screenshot", firstNonScreenshotActionAt == nil {
                    firstNonScreenshotActionAt = now
                }
                toolCallCount += 1
                actionCounts[action, default: 0] += 1
                if action == "screenshot" {
                    screenshotToolCallCount += 1
                }

                log.info("harness.tool run_id=\(runID.uuidString) turn=\(turn) action=\(action) tool_id=\(use.id)")
                AgentState.shared.set(.toolCall(name: use.name), detail: action)
                let dispatchStart = Date()
                let result = await dispatcher.dispatch(toolUseId: use.id, name: use.name, input: use.input)
                let dispatchDuration = Date().timeIntervalSince(dispatchStart)
                log.info("harness.tool_result run_id=\(runID.uuidString) action=\(action) is_error=\(result.isError)")
                resultBlocks.append(.toolResult(toolUseId: result.toolUseId, content: result.content, isError: result.isError, cache: false))

                toolRecords.append(HarnessTurnRecord.ToolCallRecord(
                    id: use.id,
                    name: use.name,
                    inputSummary: Self.compactJSON(use.input),
                    action: use.name == "computer" ? action : nil,
                    resultIsError: result.isError,
                    resultTextPreview: Self.previewText(of: result.content, limit: 200)
                ))

                observabilityToolCalls.append(AgentObservabilityLog.ToolCallSummary(
                    toolName: use.name == "computer" ? "computer.\(action)" : use.name,
                    argumentsPreview: Self.compactJSON(use.input, limit: 200),
                    resultPreview: Self.toolResultPreview(content: result.content, isError: result.isError),
                    durationS: dispatchDuration
                ))
            }
            messages.append(Message(role: "user", content: resultBlocks))

            await HarnessRunDetailStore.shared.appendTurn(
                runID: runID,
                turn: HarnessTurnRecord(
                    turnIndex: turn,
                    model: response.model,
                    requestedAt: requestedAt,
                    respondedAt: respondedAt,
                    stopReason: response.stopReason,
                    inputTokens: response.usage?.inputTokens,
                    outputTokens: response.usage?.outputTokens,
                    cacheReadInputTokens: response.usage?.cacheReadInputTokens,
                    cacheCreationInputTokens: response.usage?.cacheCreationInputTokens,
                    toolCalls: toolRecords
                )
            )

            let assistantPreviewForTurn: String = {
                let text = response.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t } else { return nil }
                }.joined(separator: " ")
                return String(text.prefix(200))
            }()
            AgentObservabilityLog.shared.record(.harnessTurn(
                id: UUID(),
                t: turnStartedAt,
                turnIndex: turn,
                modelID: response.model,
                systemBlocksPreview: systemBlocksPreview,
                userContentPreview: userPreviewForTurn,
                assistantPreview: assistantPreviewForTurn,
                toolCalls: observabilityToolCalls,
                inputTokens: response.usage?.inputTokens,
                outputTokens: response.usage?.outputTokens,
                latencyS: Date().timeIntervalSince(turnStartedAt)
            ))

            if response.stopReason != "tool_use" {
                log.info("harness.done run_id=\(runID.uuidString) status=completed_after_tools turns=\(turn)")
                AgentState.shared.set(.idle)
                await recordMetrics(status: "completed_after_tools")
                return
            }
        }

        log.error("harness.max_turns run_id=\(runID.uuidString) max=\(self.maxTurns)")
        AgentState.shared.set(.error(message: "Hit max turns (\(maxTurns))"))
        await recordMetrics(status: "max_turns", errorMessage: "Hit max turns (\(maxTurns))")
    }

    // MARK: - Tools

    private func buildTools(displaySize: CGSize) -> [Tool] {
        let openURL: Tool = .custom(
            name: "open_url",
            description: "Open a URL via NSWorkspace. Accepts https://, mailto:, sms:, spotify:, shortcuts://, raycast://, things:///add, etc. Zero-click intent dispatch — strongly preferred over clicking through a browser. Returns immediately.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string"), "description": .string("Fully-qualified URL or app-scheme URL.")])
                ]),
                "required": .array([.string("url")])
            ])
        )
        let applescript: Tool = .custom(
            name: "applescript",
            description: "Run an AppleScript via NSAppleScript. ALLOWLISTED target apps only: Safari, Google Chrome, Spotify, Music, Messages, Mail, Notes, Reminders, Calendar, Finder. Use for one-shot intents like 'tell application \"Spotify\" to play track \"...\"' or 'tell application \"Notes\" to make new note...'. Far faster than clicking the UI.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "script": .object(["type": .string("string"), "description": .string("AppleScript source.")])
                ]),
                "required": .array([.string("script")])
            ])
        )
        let runShortcut: Tool = .custom(
            name: "run_shortcut",
            description: "Run a user-installed macOS Shortcut by name via `shortcuts run`. Optional text input piped to stdin. Returns stdout.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                    "input": .object(["type": .string("string"), "description": .string("Optional stdin text.")])
                ]),
                "required": .array([.string("name")])
            ])
        )
        let axQuery: Tool = .custom(
            name: "ax_query",
            description: "Find Accessibility elements in the FRONTMOST app matching role and/or label substring. Returns up to `limit` matches with ids you can pass to ax_press / ax_set_value. Try this BEFORE taking a screenshot when the user names a button, link, field, or menu by label.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "role": .object(["type": .string("string"), "description": .string("AX role substring, e.g. 'Button', 'TextField', 'Link', 'MenuItem'.")]),
                    "label_contains": .object(["type": .string("string"), "description": .string("Substring to match against the element's title/description/help text (case insensitive).")]),
                    "value_contains": .object(["type": .string("string"), "description": .string("Substring to match against the element's value.")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max matches. Default 8.")])
                ])
            ])
        )
        let axPress: Tool = .custom(
            name: "ax_press",
            description: "Perform AXPress on an element id returned by ax_query. No mouse movement, no focus steal.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")])
                ]),
                "required": .array([.string("id")])
            ])
        )
        let axSetValue: Tool = .custom(
            name: "ax_set_value",
            description: "Set the value attribute of an element id (text field, etc) without typing character by character.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "value": .object(["type": .string("string")])
                ]),
                "required": .array([.string("id"), .string("value")])
            ])
        )
        let menuShortcut: Tool = .custom(
            name: "menu_shortcut",
            description: "Look up the keyboard shortcut for a menu item in the frontmost app by title substring (e.g. 'New Tab', 'Save', 'Find'), then send that keystroke. Faster than navigating the menu bar with the mouse.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("Menu item title substring, case insensitive.")])
                ]),
                "required": .array([.string("title")])
            ])
        )
        let computer: Tool = .computer(
            displayWidth: Int(displaySize.width),
            displayHeight: Int(displaySize.height),
            displayNumber: 1,
            cache: true
        )

        return [openURL, applescript, runShortcut, axQuery, axPress, axSetValue, menuShortcut, computer]
    }

    // MARK: - System prompt (split for caching)

    private func buildSystemBlocks(
        settings: AgentSettings,
        contextSummary: String
    ) -> [SystemBlock] {
        let staticText = """
        You are an on-screen macOS computer-use ACTOR — not a chatbot, not an assistant. Your only outputs are tool calls and (on turn 1) a 9-word spoken affirmation read aloud to the user.

        ALWAYS prefer tools in this order, falling back only when the prior tool cannot do the task:
          1. open_url — for any URL (https, mailto, sms, spotify, shortcuts, raycast, things). Zero clicks. Use this FIRST whenever the goal is "go to / open <thing>".
          2. applescript — for Safari, Google Chrome, Spotify, Music, Messages, Mail, Notes, Reminders, Calendar, Finder. One call, no UI traversal.
          3. run_shortcut — for user-installed macOS Shortcuts.
          4. ax_query + ax_press / ax_set_value — for buttons, links, and text fields you can name. Faster and more reliable than clicking pixels.
          5. menu_shortcut — for any menu item; sends the registered keyboard shortcut instead of clicking the menu.
          6. computer — vision + click/type/scroll. ONLY when nothing above applies.

        Plan-then-act: on turn 1, output one short sentence stating the goal and your first concrete action, THEN your spoken affirmation, THEN call the tool. Keep the spoken affirmation under 9 words — it will be read aloud (e.g. "Opening that now." or "On it."). After turn 1, do NOT write user-facing prose — your work product is tool calls, not commentary. A teammate auditing the trace later reads tool calls and outcomes, not your inner monologue.

        Screenshots are your eyes. You start every turn with a current visual of the screen — the initiation screenshot is in your first user message and tool results provide updated screenshots after every computer.* action. If you ever feel unsure what's on screen, take a computer.screenshot as your FIRST action that turn. Acting blindly is worse than spending one screenshot.
        Secondary rule: do not screenshot purely to "verify" before calling a fast-path tool (open_url, applescript, run_shortcut, ax_press, menu_shortcut) that you already know how to invoke. Those tools either succeed or fail loudly — no preview needed.

        NEVER ask the user a clarifying question. If the goal is ambiguous, pick the most-likely interpretation given the brief, the user prefs, the initiation screenshot, and recent_resources — then execute. The user told you what to do via voice; they're not at the keyboard to type a clarification. If you truly cannot resolve, take a screenshot, infer from what's visible, and proceed.

        Every assistant message MUST contain at least one tool call OR a final stop_task declaration. Pure prose messages without a tool call are a protocol violation — the harness counts them as a failed turn. If you have nothing to act on, call stop_task with a one-sentence result; do not narrate.

        Completion discipline (NON-NEGOTIABLE). Before you stop, break the user's request into every explicit sub-goal joined by "and" / commas / sequencing words ("then", "also", "after"). Execute EACH one. Opening an app is NOT the same as performing the action inside it — "open Spotify and play Taylor Swift" requires (1) Spotify open AND (2) a Taylor Swift track actually playing. "Email Marcus and tell him I'm running late" requires the message composed AND sent. If any sub-goal is incomplete, you MUST continue acting. A harness-side verifier audits your final claim against the original request; if you stop early it will reject your stop and force you to resume, costing turns and tokens. Stop ONLY when every part is observably done.

        Typing: for entering text > 4 chars into a normal field, the computer.type action pastes via the pasteboard automatically — no extra steps needed. For text fields you can address via AX, prefer ax_set_value.

        Refuse irreversible destructive actions (delete files, format drives, send payments, send messages to people you cannot confirm) without explicit user confirmation. If a fast-path tool would cause one of these, decline and ask first.

        When in doubt: take a screenshot, then act. Default to action over asking. Default to one tool call over a paragraph of prose.
        """

        var blocks: [SystemBlock] = [SystemBlock(text: staticText, cache: true)]

        var dynamicParts: [String] = []
        if !contextSummary.isEmpty {
            // The contextSummary is the Mercury/local-renderer brief itself — already
            // structured ("## What the user wants" / "## You are here" / ...). Phase 4
            // moved authority from raw "activation context" prose into the selector's brief,
            // so we emit it as-is without wrapper text.
            dynamicParts.append(contextSummary)
        }
        if !settings.preferences.isEmpty {
            dynamicParts.append("User preferences:\n\(settings.preferences)")
        }
        if !settings.systemPrompt.isEmpty {
            dynamicParts.append(settings.systemPrompt)
        }
        dynamicParts.append("Reasoning effort: \(settings.reasoningEffort.rawValue).")

        if !dynamicParts.isEmpty {
            blocks.append(SystemBlock(text: dynamicParts.joined(separator: "\n\n"), cache: false))
        }
        return blocks
    }

    // MARK: - Cache marker management

    private func applyRollingCacheMarker(to messages: inout [Message]) {
        var latestIdx: Int?
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            if messages[i].role == "user",
               messages[i].content.contains(where: { if case .toolResult = $0 { return true } else { return false } }) {
                latestIdx = i
                break
            }
        }
        guard let latestIdx else { return }

        for i in messages.indices {
            guard messages[i].role == "user" else { continue }
            let shouldMark = (i == latestIdx)
            messages[i].content = messages[i].content.map { block in
                if case .toolResult = block { return block.withCache(shouldMark) }
                return block
            }
        }
    }

    // MARK: - Completion verifier

    private struct CompletionVerdict {
        let complete: Bool
        let missing: String
    }

    /// Single fast Haiku call that grades whether the agent's final claim
    /// actually satisfies every explicit sub-goal in the user's voice
    /// transcript. Returns `complete=true` on any parse failure so the verifier
    /// fails open — we don't want to trap the harness in a verification loop
    /// because the grader misbehaved. The harness caps total retries above.
    private func verifyCompletion(
        transcript: String,
        finalText: String,
        client: AnthropicClient
    ) async -> CompletionVerdict {
        let userTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentClaim = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty transcript → nothing to verify against.
        guard !userTranscript.isEmpty else { return CompletionVerdict(complete: true, missing: "") }

        let system = """
        You grade whether an on-screen computer-use agent completed every part of the user's spoken request, based ONLY on the agent's own final claim. Be strict. If the request has multiple conjoined sub-goals (e.g. "open X AND play Y" / "find A and reply with B"), every sub-goal must be explicitly confirmed in the agent's claim. Opening an app is NOT the same as performing the action inside the app.

        Reply with exactly one JSON object, no prose:
        {"complete": true|false, "missing": "short description of what is still undone, or empty string if complete"}
        """
        let userMsg = """
        User's spoken request: "\(userTranscript)"

        Agent's final claim: "\(agentClaim.isEmpty ? "(no final claim provided)" : agentClaim)"

        Did the agent satisfy EVERY explicit sub-goal? Output JSON only.
        """
        do {
            let raw = try await client.sendPlainText(
                model: AnthropicModel.haiku45,
                system: system,
                userText: userMsg,
                maxTokens: 200
            )
            // Extract the first {...} JSON object in case the model wraps it.
            guard let start = raw.firstIndex(of: "{"),
                  let end = raw.lastIndex(of: "}"),
                  start <= end else {
                log.warning("harness.verifier_parse_fail raw=\(raw.prefix(120))")
                return CompletionVerdict(complete: true, missing: "")
            }
            let jsonSlice = String(raw[start...end])
            struct Parsed: Decodable { let complete: Bool; let missing: String? }
            guard let data = jsonSlice.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(Parsed.self, from: data) else {
                log.warning("harness.verifier_decode_fail json=\(jsonSlice.prefix(200))")
                return CompletionVerdict(complete: true, missing: "")
            }
            return CompletionVerdict(
                complete: parsed.complete,
                missing: parsed.missing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        } catch {
            log.warning("harness.verifier_error error=\(error)")
            return CompletionVerdict(complete: true, missing: "")
        }
    }

    // MARK: - Helpers

    // Hard-cap spoken text to N words so TTS stays brief even if the model ignores the prompt.
    private func capped(_ text: String, maxWords: Int = 9) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > maxWords else { return text }
        return words.prefix(maxWords).joined(separator: " ")
    }

    private func shouldFallback(_ err: AnthropicClient.Error) -> Bool {
        guard let status = err.status else { return false }
        return status == 400 || status == 404
    }

    private func actionLabel(_ use: (id: String, name: String, input: JSON)) -> String {
        if use.name == "computer" {
            return use.input.objectValue?["action"]?.stringValue ?? "tool"
        }
        return use.name
    }

    private func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1000))
    }

    private func primaryDisplayPixelSize() -> CGSize {
        guard let screen = NSScreen.main else { return CGSize(width: 2560, height: 1664) }
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// macOS logical points (NSScreen.frame). The coordinate space CGEvent
    /// uses for mouse positioning. NOT backing-store pixels.
    private func primaryLogicalDisplaySize() -> CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
    }

    /// Resize a JPEG so its longest edge is ≤ `maxLongEdge`. Returns nil on
    /// any decode/encode failure so the caller can fall back to the original.
    static func resizeJPEG(_ data: Data, maxLongEdge: Int) -> Data? {
        guard let src = NSBitmapImageRep(data: data) else { return nil }
        let w = src.pixelsWide
        let h = src.pixelsHigh
        let longest = max(w, h)
        guard longest > maxLongEdge, longest > 0 else { return data }
        let scale = CGFloat(maxLongEdge) / CGFloat(longest)
        let newW = Int(CGFloat(w) * scale)
        let newH = Int(CGFloat(h) * scale)
        guard newW > 0, newH > 0,
              let cs = src.cgImage?.colorSpace,
              let ctx = CGContext(
                  data: nil, width: newW, height: newH,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .medium
        if let cg = src.cgImage {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        }
        guard let outCG = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: outCG)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// Scale the logical display down so the longest edge equals `maxLongEdge`,
    /// preserving aspect ratio. Used to derive the agent's coordinate space —
    /// also matches what `ScreenCapture.snapshot(maxLongEdge:)` will produce
    /// when we ask it for screenshots at the same cap.
    private func computeAgentTargetSize(logicalSize: CGSize, maxLongEdge: Int) -> CGSize {
        let longest = max(logicalSize.width, logicalSize.height)
        guard longest > CGFloat(maxLongEdge), longest > 0 else { return logicalSize }
        let scale = CGFloat(maxLongEdge) / longest
        return CGSize(
            width: (logicalSize.width * scale).rounded(),
            height: (logicalSize.height * scale).rounded()
        )
    }

    /// Compact JSON representation of a tool input. Used for the Dev Tools
    /// per-turn drill-in — small enough to render inline, big enough to debug.
    fileprivate static func compactJSON(_ value: JSON, limit: Int = 240) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
            if text.count <= limit { return text }
            let prefix = text.prefix(limit)
            return "\(prefix)…"
        }
        return "<unencodable>"
    }

    /// Condensed multi-block preview for the observability log. Unlike
    /// `previewText`, this surfaces image dimensions and error markers because
    /// the timeline viewer treats screenshots as load-bearing data.
    fileprivate static func toolResultPreview(content: [ContentBlock], isError: Bool) -> String {
        var pieces: [String] = []
        if isError { pieces.append("ERROR") }
        for block in content {
            switch block {
            case .text(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pieces.append(String(trimmed.prefix(180)))
                }
            case .image(_, let base64, _):
                if let data = Data(base64Encoded: base64),
                   let img = NSImage(data: data) {
                    let w = Int(img.size.width)
                    let h = Int(img.size.height)
                    pieces.append("screenshot \(w)x\(h)")
                } else {
                    pieces.append("screenshot")
                }
            case .toolUse:
                pieces.append("<tool_use>")
            case .toolResult:
                pieces.append("<tool_result>")
            case .thinking(let t, _):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pieces.append("thinking: \(String(trimmed.prefix(120)))")
                }
            case .redactedThinking:
                pieces.append("<redacted_thinking>")
            }
            if pieces.joined(separator: " · ").count > 200 { break }
        }
        let joined = pieces.joined(separator: " · ")
        if joined.count > 200 { return String(joined.prefix(200)) + "…" }
        return joined.isEmpty ? "<empty>" : joined
    }

    /// Joined preview of the harness's system blocks (cached + dynamic) for
    /// the observability timeline. First 240 chars per block, capped at 400 total.
    fileprivate static func systemBlocksPreview(_ blocks: [SystemBlock]) -> String {
        let joined = blocks.map { String($0.text.prefix(240)) }.joined(separator: "\n---\n")
        if joined.count > 400 { return String(joined.prefix(400)) + "…" }
        return joined
    }

    /// Pulls the first text block out of a tool result's content array and
    /// truncates it. Image results render as `<image>`.
    fileprivate static func previewText(of content: [ContentBlock], limit: Int) -> String {
        for block in content {
            switch block {
            case .text(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if trimmed.count <= limit { return trimmed }
                return "\(trimmed.prefix(limit))…"
            case .image:
                return "<image>"
            default:
                continue
            }
        }
        return ""
    }
}
