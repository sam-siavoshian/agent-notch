//
//  ComputerUseHarness.swift
//  Agent in the Notch
//
//  One agent turn: assemble inputs → call Anthropic → execute tool calls →
//  feed results back → loop until stop_reason != "tool_use". Updates
//  AgentState as it goes so the notch UI reflects what's happening.
//
//  Optimizations layered on top of the basic loop:
//  - Pre-flight IntentRouter handles obvious commands (open URL, Spotify,
//    add reminder) WITHOUT any model call. Many tasks now complete in 0
//    model turns.
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
        public var resolvedIntent: ContextResolvedIntent?
        public init(
            transcript: String,
            contextSummary: String,
            resolvedIntent: ContextResolvedIntent? = nil
        ) {
            self.transcript = transcript
            self.contextSummary = contextSummary
            self.resolvedIntent = resolvedIntent
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

        let displaySize = primaryDisplayPixelSize()
        let dispatcher = ToolDispatcher(displaySize: displaySize)
        let client = AnthropicClient(apiKey: apiKey)

        let tools = buildTools(displaySize: displaySize)
        let system = buildSystemBlocks(
            settings: settings,
            contextSummary: input.contextSummary,
            resolvedIntent: input.resolvedIntent
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
            resolvedIntentVerb: input.resolvedIntent?.verb
        ))

        var messages: [Message] = [
            Message(role: "user", content: [.text(input.transcript)])
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

            if let intent = input.resolvedIntent {
                let outcome = ContextIntentResolverOutcomeLog.Outcome(
                    recordedAt: endedAt,
                    transcript: input.transcript,
                    intent: intent,
                    harnessStatus: status,
                    harnessErrorMessage: errorMessage,
                    harnessDurationMs: milliseconds(from: startedAt, to: endedAt)
                )
                await ContextIntentResolverOutcomeLog.shared.record(outcome)

                // Recipe feedback loop: when the harness completed successfully
                // and the resolver had surfaced a candidate recipe, bump that
                // recipe's confidence. Successful completion = no anthropic /
                // network / max_turn error AND tool calls actually ran.
                let succeeded = (status == "completed_without_tool" || status == "completed_after_tools")
                if succeeded, let topRecipe = intent.candidateRecipes.first,
                   !topRecipe.appKey.isEmpty, !topRecipe.recipeID.isEmpty {
                    await ContextMemoryStore.shared.bumpRecipeConfidence(
                        appName: topRecipe.appKey,
                        recipeID: topRecipe.recipeID
                    )
                    NSLog("[Harness] Bumped confidence for recipe \(topRecipe.recipeID) in \(topRecipe.appKey)")
                }
            }
        }

        while turn < maxTurns {
            if stopRequested {
                AgentState.shared.set(.idle, detail: "Stopped")
                await recordMetrics(status: "stopped_by_user")
                return
            }
            turn += 1
            log.info("harness.turn run_id=\(runID.uuidString) turn=\(turn) model=\(currentModel)")

            // Move the cache breakpoint to the most recent tool_result so the
            // next request reads everything before it from cache. Older
            // breakpoints get stripped to stay within Anthropic's 4-marker cap.
            applyRollingCacheMarker(to: &messages)

            let request = AnthropicMessageRequest(
                model: currentModel,
                maxTokens: maxOutputTokens,
                system: system,
                messages: messages,
                tools: tools,
                toolChoice: nil
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
                log.info("harness.done run_id=\(runID.uuidString) status=completed_without_tool turns=\(turn)")
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
                let result = await dispatcher.dispatch(toolUseId: use.id, name: use.name, input: use.input)
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
        contextSummary: String,
        resolvedIntent: ContextResolvedIntent? = nil
    ) -> [SystemBlock] {
        let staticText = """
        You are an on-screen computer-use agent on macOS. You control the user's machine via several tools.

        ALWAYS prefer tools in this order, falling back only when the prior tool cannot do the task:
          1. open_url — for any URL (https, mailto, sms, spotify, shortcuts, raycast, things). Zero clicks. Use this FIRST whenever the goal is "go to / open <thing>".
          2. applescript — for Safari, Google Chrome, Spotify, Music, Messages, Mail, Notes, Reminders, Calendar, Finder. One call, no UI traversal.
          3. run_shortcut — for user-installed macOS Shortcuts.
          4. ax_query + ax_press / ax_set_value — for buttons, links, and text fields you can name. Faster and more reliable than clicking pixels.
          5. menu_shortcut — for any menu item; sends the registered keyboard shortcut instead of clicking the menu.
          6. computer — vision + click/type/scroll. ONLY when nothing above applies. Do NOT screenshot first if a fast path works.

        Plan-then-act: on turn 1, output one short sentence stating the goal and your first concrete action, THEN your spoken affirmation, THEN call the tool. Keep the spoken affirmation under 9 words — it will be read aloud (e.g. "Opening that now." or "On it.").

        Screenshots are expensive. DO NOT take a screenshot before a tool call unless prior tool results are ambiguous AND no fast path applies. The activation context provided separately already tells you the frontmost app and recent on-screen text.

        Typing: for entering text > 4 chars into a normal field, the computer.type action pastes via the pasteboard automatically — no extra steps needed. For text fields you can address via AX, prefer ax_set_value.

        Refuse irreversible destructive actions (delete files, format drives, send payments, send messages to people you cannot confirm) without explicit user confirmation. If a fast-path tool would cause one of these, decline and ask first.
        """

        var blocks: [SystemBlock] = [SystemBlock(text: staticText, cache: true)]

        var dynamicParts: [String] = []
        if let intent = resolvedIntent, !intent.usedFallback {
            dynamicParts.append(Self.renderResolvedIntent(intent))
        }
        if !contextSummary.isEmpty {
            dynamicParts.append("""
            Local activation context (recent on-screen state — treat as a hint, not exact coordinates; refresh via screenshot only if it looks stale):
            \(contextSummary)
            """)
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

    private static func renderResolvedIntent(_ intent: ContextResolvedIntent) -> String {
        var lines: [String] = []
        lines.append("Resolved user intent: \(intent.inferredGoal)")
        lines.append("Verb: \(intent.verb)")
        if let target = intent.target, !target.isEmpty {
            lines.append("Target: \(target)")
        }
        if !intent.resolvedEntities.isEmpty {
            let entityLines = intent.resolvedEntities.prefix(5).map { entity -> String in
                let label = entity.entityLabel ?? "(unmatched)"
                let type = entity.entityType.map { " [\($0)]" } ?? ""
                return "  - \"\(entity.userPhrase)\" → \(label)\(type) — \(entity.evidence)"
            }
            lines.append("Resolved entities:")
            lines.append(contentsOf: entityLines)
        }
        if !intent.candidateRecipes.isEmpty {
            lines.append("Candidate recipes (ranked):")
            for recipe in intent.candidateRecipes.prefix(3) {
                lines.append("  - \(recipe.recipeName) (score \(String(format: "%.2f", recipe.matchScore)))")
                for step in recipe.stepsProse.prefix(6) {
                    lines.append("      • \(step)")
                }
            }
        }
        lines.append("Resolver confidence: \(String(format: "%.2f", intent.confidence)). Treat this as a hint — re-derive only if it clearly contradicts the live screen.")
        return lines.joined(separator: "\n")
    }

    private func primaryDisplayPixelSize() -> CGSize {
        guard let screen = NSScreen.main else { return CGSize(width: 2560, height: 1664) }
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        return CGSize(width: size.width * scale, height: size.height * scale)
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
