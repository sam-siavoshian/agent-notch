import Foundation
import AppKit

private let log = Log(category: "harness")

@MainActor
public final class ComputerUseHarness {
    public static let shared = ComputerUseHarness()

    /// Long-edge ceiling for what the agent sees + clicks in. Anthropic's
    /// computer-use models are most accurate at XGA/WXGA scale and degrade
    /// past ~1280px.
    private let agentScreenshotLongEdge = 1280
    private let fallbackModelID = AnthropicModel.haiku45
    private let maxTurns = 100
    private let maxOutputTokens = 4096

    private var isRunning = false
    private var stopRequested = false

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
        let initialModelID = AgentSettingsStore.shared.agentModel.modelID
        log.info("harness.start run_id=\(runID.uuidString) model=\(initialModelID) transcript_len=\(transcriptLength) context_len=\(contextLength)")
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

        // logicalSize = macOS points (CGEvent / mouse positioning space).
        // agentTargetSize = what the model SEES + the coordinate space we
        // advertise to Anthropic. Capped at agentScreenshotLongEdge.
        let logicalSize = primaryLogicalDisplaySize()
        let agentTargetSize = computeAgentTargetSize(logicalSize: logicalSize, maxLongEdge: agentScreenshotLongEdge)
        let dispatcher = ToolDispatcher(
            agentDisplaySize: agentTargetSize,
            logicalDisplaySize: logicalSize,
            screenshotLongEdge: agentScreenshotLongEdge
        )

        // The computer-use tool TYPE and the beta HEADER both depend on the
        // active model family (Haiku → 20250124, Sonnet 4.6 → 20251124); they
        // must match. On a 400/404 fallback we swap both atomically below.
        var currentAgentModel = AgentSettingsStore.shared.agentModel
        var client = AnthropicClient(
            apiKey: apiKey,
            betaHeaders: Self.betaHeaders(for: currentAgentModel)
        )
        var tools = buildTools(displaySize: agentTargetSize, toolType: currentAgentModel.computerUseToolType)
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

        // Attach the long-press screenshot as the first user-message image so
        // Claude doesn't burn a turn-1 computer.screenshot. Selector hands us a
        // 1568-long-edge JPEG (sized for OCR); resize to agentScreenshotLongEdge
        // so the image and the advertised display dimensions agree.
        let firstUserContent: [ContentBlock]
        if let jpeg = input.initiationScreenshot, !jpeg.isEmpty {
            let resizedJPEG = Self.resizeJPEG(jpeg, maxLongEdge: agentScreenshotLongEdge) ?? jpeg
            firstUserContent = [
                .text(input.transcript),
                .image(mediaType: "image/jpeg", base64: resizedJPEG.base64EncodedString(), cache: false)
            ]
            log.info("harness.first_user has_image=true image_bytes=\(resizedJPEG.count) original_bytes=\(jpeg.count)")
        } else {
            firstUserContent = [.text(input.transcript)]
        }
        var messages: [Message] = [Message(role: "user", content: firstUserContent)]

        var currentModel = currentAgentModel.modelID.isEmpty ? fallbackModelID : currentAgentModel.modelID
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
                modelID: currentModel,
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

            // Rolling cache breakpoint on the most recent tool_result so each
            // turn reads prior history from cache; Anthropic caps active markers at 4.
            applyRollingCacheMarker(to: &messages)

            let effort = AgentSettingsStore.shared.reasoningEffort
            let thinkingConfig: ThinkingConfig? = effort.thinkingBudgetTokens.map { ThinkingConfig(budgetTokens: $0) }
            // max_tokens must exceed budget_tokens; leave headroom for tool-call output.
            let effectiveMaxTokens = effort.thinkingBudgetTokens.map { max(maxOutputTokens, $0 + 2048) } ?? maxOutputTokens
            let request = AnthropicMessageRequest(
                model: currentModel,
                maxTokens: effectiveMaxTokens,
                system: system,
                messages: messages,
                tools: tools,
                thinking: thinkingConfig
            )

            let response: AnthropicMessageResponse
            do {
                response = try await client.send(request)
            } catch let err as AnthropicClient.Error {
                if !triedFallback, shouldFallback(err) {
                    // Fallback model is a different computer-use family; tools array
                    // AND beta header must swap together, else the retry repeats the 400.
                    log.warning("harness.fallback run_id=\(runID.uuidString) from=\(currentModel) to=\(self.fallbackModelID) status=\(err.status ?? -1)")
                    triedFallback = true
                    usedFallback = true
                    currentModel = fallbackModelID
                    currentAgentModel = .haiku
                    tools = buildTools(displaySize: agentTargetSize, toolType: currentAgentModel.computerUseToolType)
                    client.betaHeaders = Self.betaHeaders(for: currentAgentModel)
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

            let assistantText = Self.joinedText(in: response.content)

            func makeTurnRecord(toolCalls: [HarnessTurnRecord.ToolCallRecord]) -> HarnessTurnRecord {
                HarnessTurnRecord(
                    turnIndex: turn,
                    model: response.model,
                    stopReason: response.stopReason,
                    inputTokens: response.usage?.inputTokens,
                    outputTokens: response.usage?.outputTokens,
                    cacheReadInputTokens: response.usage?.cacheReadInputTokens,
                    cacheCreationInputTokens: response.usage?.cacheCreationInputTokens,
                    toolCalls: toolCalls
                )
            }

            if toolUses.isEmpty {
                // Pre-stop verifier: catches "opened Spotify, said done, never played
                // Taylor Swift" — rejects stop if any explicit sub-goal is unfulfilled.
                if verifierRetries < maxVerifierRetries {
                    let verdict = await verifyCompletion(
                        transcript: input.transcript,
                        finalText: assistantText,
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
                TextToSpeechService.shared.speak(capped(assistantText))
                await HarnessRunDetailStore.shared.appendTurn(runID: runID, turn: makeTurnRecord(toolCalls: []))
                AgentObservabilityLog.shared.record(.harnessTurn(
                    id: UUID(),
                    t: turnStartedAt,
                    turnIndex: turn,
                    modelID: response.model,
                    systemBlocksPreview: systemBlocksPreview,
                    userContentPreview: userPreviewForTurn,
                    assistantPreview: String(assistantText.prefix(200)),
                    toolCalls: [],
                    inputTokens: response.usage?.inputTokens,
                    outputTokens: response.usage?.outputTokens,
                    latencyS: Date().timeIntervalSince(turnStartedAt)
                ))
                AgentState.shared.set(.idle, detail: assistantText)
                await recordMetrics(status: "completed_without_tool")
                return
            }

            if turn == 1 {
                let affirmation = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !affirmation.isEmpty {
                    TextToSpeechService.shared.speak(capped(affirmation))
                }
            }

            var resultBlocks: [ContentBlock] = []
            var toolRecords: [HarnessTurnRecord.ToolCallRecord] = []
            var observabilityToolCalls: [AgentObservabilityLog.ToolCallSummary] = []
            for use in toolUses {
                if stopRequested {
                    await HarnessRunDetailStore.shared.appendTurn(runID: runID, turn: makeTurnRecord(toolCalls: toolRecords))
                    AgentState.shared.set(.idle, detail: "Stopped")
                    await recordMetrics(status: "stopped_by_user")
                    return
                }
                let action = actionLabel(use)
                let now = Date()
                if firstToolCallAt == nil { firstToolCallAt = now }
                if action != "screenshot", firstNonScreenshotActionAt == nil { firstNonScreenshotActionAt = now }
                toolCallCount += 1
                actionCounts[action, default: 0] += 1
                if action == "screenshot" { screenshotToolCallCount += 1 }

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

            await HarnessRunDetailStore.shared.appendTurn(runID: runID, turn: makeTurnRecord(toolCalls: toolRecords))

            AgentObservabilityLog.shared.record(.harnessTurn(
                id: UUID(),
                t: turnStartedAt,
                turnIndex: turn,
                modelID: response.model,
                systemBlocksPreview: systemBlocksPreview,
                userContentPreview: userPreviewForTurn,
                assistantPreview: String(assistantText.prefix(200)),
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

    private func buildTools(displaySize: CGSize, toolType: String) -> [Tool] {
        let openURL: Tool = .custom(
            name: "open_url",
            description: "Open a URL via NSWorkspace. Accepts https://, mailto:, sms:, spotify:, shortcuts://, raycast://, things:///add, etc. Zero-click intent dispatch. Use for web URLs and deep links (e.g. https://github.com/..., spotify:track:..., things:///add?title=...). For PLAIN 'open <DesktopApp>' goals (Discord, Slack, Notion, etc.) prefer `open_app` instead — `open_url <app-scheme>://` goes through macOS's default URL-scheme handler which may resolve to a beta/canary/dev variant of the app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string"), "description": .string("Fully-qualified URL or app-scheme URL.")])
                ]),
                "required": .array([.string("url")])
            ])
        )
        let openApp: Tool = .custom(
            name: "open_app",
            description: "Launch (or activate) a desktop app BY NAME using exact-path resolution. Resolves to /Applications/<Name>.app (or /System/Applications, ~/Applications) — bypasses macOS's URL-scheme default-handler resolution, which on machines with both Discord.app + Discord Canary.app (or Slack + Slack Beta, etc.) would otherwise pick the canary/beta variant. Use this for any 'open <App>' goal; use open_url only for web URLs and true deep links.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("The .app folder name in /Applications, exact (e.g. 'Discord', not 'Discord Canary'; 'Slack', not 'Slack Beta'). Case-sensitive — match what shows in Finder.")])
                ]),
                "required": .array([.string("name")])
            ])
        )
        let applescript: Tool = .custom(
            name: "applescript",
            description: "Run an AppleScript via NSAppleScript. ALLOWLISTED target apps only: Safari, Firefox, Terminal, Google Chrome, Spotify, Music, Messages, Mail, Notes, Reminders, Calendar, Finder. Use for one-shot intents like 'tell application \"Spotify\" to play track \"...\"' or 'tell application \"Notes\" to make new note...'. Far faster than clicking the UI.",
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
            cache: true,
            toolType: toolType
        )

        return [openApp, openURL, applescript, runShortcut, axQuery, axPress, axSetValue, menuShortcut, computer]
    }

    private static func betaHeaders(for model: AgentModel) -> [String] {
        [
            model.computerUseBetaHeader,
            "prompt-caching-2024-07-31",
            "interleaved-thinking-2025-05-14"
        ]
    }

    // MARK: - System prompt (split for caching)

    private func buildSystemBlocks(
        settings: AgentSettings,
        contextSummary: String
    ) -> [SystemBlock] {
        let staticText = """
        You are an on-screen macOS computer-use ACTOR — not a chatbot, not an assistant. Your only outputs are tool calls and (on turn 1) a 9-word spoken affirmation read aloud to the user.

        ALWAYS prefer tools in this order, falling back only when the prior tool cannot do the task:
          1. open_app — for any plain "open <DesktopApp>" goal (Discord, Slack, Notion, Spotify, etc.). Path-resolved so it ALWAYS opens the canonical /Applications/<Name>.app, never a Canary/Beta/Dev variant. Use this BEFORE open_url for desktop apps.
          2. open_url — for web URLs (https, mailto, sms) and true deep links (spotify:track:..., things:///add?title=..., shortcuts://, raycast://). Do NOT use `open_url <app>://` to launch a bare app — that goes through Launch Services' default-handler and may resolve to a beta variant; use open_app instead.
          3. applescript — for Safari, Google Chrome, Spotify, Music, Messages, Mail, Notes, Reminders, Calendar, Finder. One call, no UI traversal.
          4. run_shortcut — for user-installed macOS Shortcuts.
          5. ax_query + ax_press / ax_set_value — for buttons, links, and text fields you can name. Faster and more reliable than clicking pixels.
          6. menu_shortcut — for any menu item; sends the registered keyboard shortcut instead of clicking the menu.
          7. computer — vision + click/type/scroll. ONLY when nothing above applies.

        Application preferences — when a tool choice is flexible, apply these rules:
        - Commands / shell tasks: use Terminal.app. AppleScript: `tell application "Terminal" to do script "<cmd>"`. If Terminal is already open, target the front window. Never use iTerm2, Ghostty, or other terminals unless the user explicitly names one.
        - Web browsing: prefer Safari. Fall back to Firefox only if Safari cannot complete the task (e.g. a Firefox-specific extension is required). Never open Chrome unless the user explicitly asks for it.
        - Text editing: prefer terminal editors (vim, nano) launched inside Terminal over GUI apps (TextEdit, VSCode, Cursor). Open a Terminal window, then `vim <path>` or `nano <path>`. Only use a GUI editor if the user names one.
        - Presenting / viewing a file (not editing): use open_url with a file:// URI (e.g. `file:///Users/you/doc.pdf`) — macOS routes it to the default app for that type. Never open Finder and double-click when open_url can do it in one call.

        Plan-then-act: on turn 1, output one short sentence stating the goal and your first concrete action, THEN your spoken affirmation, THEN call the tool. Keep the spoken affirmation under 9 words — it will be read aloud (e.g. "Opening that now." or "On it."). After turn 1, do NOT write user-facing prose — your work product is tool calls, not commentary. A teammate auditing the trace later reads tool calls and outcomes, not your inner monologue.

        Screenshots are your eyes. CRITICAL TURN-1 RULE: the initiation screenshot is ALREADY attached to your first user message — it captures the screen exactly as the user saw it when they spoke. On turn 1 you MUST NOT call computer.screenshot; doing so is redundant, wastes ~1 second of latency, and burns tokens. Read the initiation screenshot and act. The ONLY time you'd take a screenshot on turn 1 is if there's literally no initiation image attached (rare — only when capture failed).
        On turn 2+, tool results from computer.* actions return updated screenshots automatically. After a non-computer tool succeeds (open_app, open_url, applescript, run_shortcut, ax_press, ax_set_value, menu_shortcut) the screen has likely changed but you do NOT get a fresh screenshot in the tool_result — if you genuinely need to see the new state to decide the next action, take a computer.screenshot then. If your next action does not depend on the new state (e.g. you're done, or you know the next keystroke regardless), skip the screenshot.
        Secondary rule: do not screenshot purely to "verify" before calling a fast-path tool (open_app, open_url, applescript, run_shortcut, ax_press, menu_shortcut) that you already know how to invoke. Those tools either succeed or fail loudly — no preview needed.

        NEVER ask the user a clarifying question. If the goal is ambiguous, pick the most-likely interpretation given the brief, the user prefs, the initiation screenshot, and recent_resources — then execute. The user told you what to do via voice; they're not at the keyboard to type a clarification. If you truly cannot resolve, take a screenshot, infer from what's visible, and proceed.

        Every assistant message MUST contain at least one tool call OR a final stop_task declaration. Pure prose messages without a tool call are a protocol violation — the harness counts them as a failed turn. If you have nothing to act on, call stop_task with a one-sentence result; do not narrate.

        Completion discipline (NON-NEGOTIABLE). Before you stop, break the user's request into every explicit sub-goal joined by "and" / commas / sequencing words ("then", "also", "after"). Execute EACH one. Opening an app is NOT the same as performing the action inside it — "open Spotify and play Taylor Swift" requires (1) Spotify open AND (2) a Taylor Swift track actually playing. "Email Marcus and tell him I'm running late" requires the message composed AND sent. If any sub-goal is incomplete, you MUST continue acting. A harness-side verifier audits your final claim against the original request; if you stop early it will reject your stop and force you to resume, costing turns and tokens. Stop ONLY when every part is observably done.

        Typing: for entering text > 4 chars into a normal field, the computer.type action pastes via the pasteboard automatically — no extra steps needed. For text fields you can address via AX, prefer ax_set_value.

        Scrolling: `scroll_amount` is a count of mouse-wheel "clicks", each ≈ 100px on screen. Defaults are too small — when you need to move the page, use scroll_amount 5-10 (≈ half a screen) and 15-20 (≈ a full screen). NEVER scroll with amount=1 or 2 expecting visible motion; you will get stuck repeating tiny scrolls. If after one scroll the target still is not on screen, double the amount on the next call instead of repeating the same value.

        Refuse irreversible destructive actions (delete files, format drives, send payments, send messages to people you cannot confirm) without explicit user confirmation. If a fast-path tool would cause one of these, decline and ask first.

        When in doubt: take a screenshot, then act. Default to action over asking. Default to one tool call over a paragraph of prose.
        """

        var blocks: [SystemBlock] = [SystemBlock(text: staticText, cache: true)]

        // contextSummary is the Mercury/local-renderer brief, already structured.
        var dynamicParts: [String] = []
        if !contextSummary.isEmpty { dynamicParts.append(contextSummary) }
        if !settings.preferences.isEmpty { dynamicParts.append("User preferences:\n\(settings.preferences)") }
        if !settings.systemPrompt.isEmpty { dynamicParts.append(settings.systemPrompt) }
        dynamicParts.append("Reasoning effort: \(settings.reasoningEffort.rawValue).")

        if !dynamicParts.isEmpty {
            blocks.append(SystemBlock(text: dynamicParts.joined(separator: "\n\n"), cache: false))
        }
        return blocks
    }

    // MARK: - Cache marker management

    private func applyRollingCacheMarker(to messages: inout [Message]) {
        let latestIdx = messages.lastIndex {
            $0.role == "user" && $0.content.contains { if case .toolResult = $0 { true } else { false } }
        }
        guard let latestIdx else { return }
        for i in messages.indices where messages[i].role == "user" {
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

    /// Grades whether the agent's final claim satisfies every sub-goal in the
    /// transcript. Fails open on parse errors so a misbehaving grader can't
    /// trap the harness; total retries are capped in `run(_:)`.
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

    /// macOS logical points (NSScreen.frame). The coordinate space CGEvent
    /// uses for mouse positioning.
    private func primaryLogicalDisplaySize() -> CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
    }

    /// Resize a JPEG so its longest edge is ≤ `maxLongEdge`. Returns nil on
    /// any decode/encode failure so the caller can fall back to the original.
    private static func resizeJPEG(_ data: Data, maxLongEdge: Int) -> Data? {
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

    /// Scale `logicalSize` so its longest edge equals `maxLongEdge`, preserving
    /// aspect ratio. Matches `ScreenCapture.snapshot(maxLongEdge:)` output.
    private func computeAgentTargetSize(logicalSize: CGSize, maxLongEdge: Int) -> CGSize {
        let longest = max(logicalSize.width, logicalSize.height)
        guard longest > CGFloat(maxLongEdge), longest > 0 else { return logicalSize }
        let scale = CGFloat(maxLongEdge) / longest
        return CGSize(
            width: (logicalSize.width * scale).rounded(),
            height: (logicalSize.height * scale).rounded()
        )
    }

    private static let compactJSONEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Compact JSON for the Dev Tools per-turn drill-in.
    fileprivate static func compactJSON(_ value: JSON, limit: Int = 240) -> String {
        guard let data = try? compactJSONEncoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return "<unencodable>" }
        return text.count <= limit ? text : "\(text.prefix(limit))…"
    }

    /// Multi-block preview that surfaces image dimensions + error markers for
    /// the observability log (screenshots are load-bearing in the timeline).
    fileprivate static func toolResultPreview(content: [ContentBlock], isError: Bool) -> String {
        var pieces: [String] = []
        if isError { pieces.append("ERROR") }
        for block in content {
            switch block {
            case .text(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(String(trimmed.prefix(180))) }
            case .image(_, let base64, _):
                if let data = Data(base64Encoded: base64), let img = NSImage(data: data) {
                    pieces.append("screenshot \(Int(img.size.width))x\(Int(img.size.height))")
                } else {
                    pieces.append("screenshot")
                }
            case .toolUse: pieces.append("<tool_use>")
            case .toolResult: pieces.append("<tool_result>")
            case .thinking(let t, _):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append("thinking: \(String(trimmed.prefix(120)))") }
            case .redactedThinking: pieces.append("<redacted_thinking>")
            }
            if pieces.joined(separator: " · ").count > 200 { break }
        }
        let joined = pieces.joined(separator: " · ")
        if joined.isEmpty { return "<empty>" }
        return joined.count > 200 ? String(joined.prefix(200)) + "…" : joined
    }

    /// First 240 chars per system block, joined and capped at 400 total.
    fileprivate static func systemBlocksPreview(_ blocks: [SystemBlock]) -> String {
        let joined = blocks.map { String($0.text.prefix(240)) }.joined(separator: "\n---\n")
        return joined.count > 400 ? String(joined.prefix(400)) + "…" : joined
    }

    /// First text block in a tool result, truncated. Image-only results render as `<image>`.
    fileprivate static func previewText(of content: [ContentBlock], limit: Int) -> String {
        for block in content {
            switch block {
            case .text(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                return trimmed.count <= limit ? trimmed : "\(trimmed.prefix(limit))…"
            case .image: return "<image>"
            default: continue
            }
        }
        return ""
    }

    /// Joined text-block contents from an assistant response.
    fileprivate static func joinedText(in content: [ContentBlock]) -> String {
        var parts: [String] = []
        for case .text(let t) in content { parts.append(t) }
        return parts.joined(separator: " ")
    }
}
