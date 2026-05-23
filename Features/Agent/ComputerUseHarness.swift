//
//  ComputerUseHarness.swift
//  Agent in the Notch
//
//  One agent turn: assemble inputs → call Anthropic → execute tool calls →
//  feed results back → loop until stop_reason != "tool_use". Updates
//  AgentState as it goes so the notch UI reflects what's happening.
//
//  Optimizations layered on top of the basic loop (mirrors anthropic-quickstarts
//  computer-use-demo/loop.py):
//  - SSE streaming. Each turn streams via AnthropicClient.sendStreaming and
//    is assembled in `streamMessage` to the existing AnthropicMessageResponse
//    shape, so the rest of the loop stays unchanged.
//  - Prompt caching: 4 breakpoints per request. (1) cache_control on the
//    system block caches tools + system together (tools come earlier in the
//    request prefix). (2,3,4) cache_control on the LAST content block of
//    each of the 3 most-recent user messages, rolling forward each turn. See
//    `injectPromptCaching`.
//  - Fixed WXGA 1280x800 coordinate space. ScreenCapture.targetSnapshot
//    center-crops + scales the source to match; the returned CoordTransform
//    inverts model clicks back to logical-point space (`ToolDispatcher`).
//  - Extended thinking gated to reasoningEffort == .high. .low / .medium
//    send no `thinking` field, keeping the messages cache warm across
//    adjacent turns. `interleaved-thinking-2025-05-14` beta only shipped
//    when thinking is on.
//  - Retry on 429 / 500 / 529 with exponential backoff + jitter
//    (`AnthropicClient.withRetry` / `streamWithRetry`).
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
    /// What the model SEES + emits coordinates in. Hard-pinned to WXGA
    /// (1280x800) because Anthropic's computer-use models peak in click
    /// accuracy at exactly this resolution. Non-16:10 displays are
    /// center-cropped to fit (see `ScreenCapture.targetSnapshot`).
    public let agentDisplaySize: CGSize = CGSize(width: 1280, height: 800)

    public private(set) var isRunning: Bool = false
    private var stopRequested: Bool = false
    /// Live CC subprocess wrapper during CC-provider runs. Captured so the
    /// kill-switch can terminate it. Nil in API-provider mode.
    private var activeClaudeClient: ClaudeCodeClient?

    private init() {}

    public func requestStop() {
        guard isRunning else { return }
        stopRequested = true
        activeClaudeClient?.cancel()
        NSLog("[Harness] stop requested")
    }

    public struct Input {
        public var transcript: String
        public var contextSummary: String
        /// Intent verb from the Selector — forwarded to HarnessRunDetail for DevTools display.
        public var intentVerb: String?
        /// JPEG bytes of the screen at long-press time, ALREADY sized to
        /// `agentDisplaySize` (1280x800). When non-nil the harness prepends
        /// an image block to the FIRST user message so Claude sees the
        /// screen on turn 1, eliminating the throwaway `computer.screenshot`
        /// tool call most agent runs used to start with.
        public var initiationScreenshot: Data?
        /// CoordTransform produced alongside the initiation screenshot —
        /// describes how to map clicks emitted in the screenshot's coordinate
        /// space back to logical-point space. Required for turn-1 clicks to
        /// land on-target. If nil, dispatcher uses identity (correct only
        /// when source display already matches agentDisplaySize).
        public var initiationTransform: ScreenCapture.CoordTransform?
        public init(
            transcript: String,
            contextSummary: String,
            intentVerb: String? = nil,
            initiationScreenshot: Data? = nil,
            initiationTransform: ScreenCapture.CoordTransform? = nil
        ) {
            self.transcript = transcript
            self.contextSummary = contextSummary
            self.intentVerb = intentVerb
            self.initiationScreenshot = initiationScreenshot
            self.initiationTransform = initiationTransform
        }
    }

    public func run(_ input: Input) async {
        // Re-entry guard. Without this, a second long-press while a turn is
        // in flight would race: API mode would interleave AgentState updates,
        // CC mode would spawn a second `claude` subprocess that gets
        // rejected by the MCP bridge (single client at a time).
        if isRunning {
            log.warning("harness.skip reason=already_running")
            return
        }

        // Provider switch lives BEFORE the API-key guard. CC mode uses the
        // user's own `claude` auth — our Anthropic key isn't needed.
        let provider = AgentSettingsStore.shared.provider
        if provider == .claudeCodeCLI {
            await runClaudeCodeMode(input)
            return
        }

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
        AgentCursorDriver.shared.beginRun()
        isRunning = true
        stopRequested = false
        await AXFastPath.shared.reset()
        defer {
            AgentCursorDriver.shared.endRun()
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

        // Two coordinate spaces collide here — keep them straight:
        //   * logicalSize: macOS logical points (NSScreen.frame). What
        //     CGEvent / CGWarpMouseCursorPosition operate in.
        //   * agentDisplaySize: fixed 1280x800. What the model SEES —
        //     screenshot dimensions + the coordinate space we advertise to
        //     Anthropic. Picked to match WXGA per Anthropic computer-use
        //     accuracy guidance.
        // The CoordTransform produced alongside each screenshot maps the
        // model's emitted click point back to logical space.
        let logicalSize = primaryLogicalDisplaySize()
        let initialTransform = input.initiationTransform
            ?? ScreenCapture.CoordTransform.identity(size: logicalSize)
        let dispatcher = ToolDispatcher(
            agentDisplaySize: agentDisplaySize,
            logicalDisplaySize: logicalSize,
            initialTransform: initialTransform
        )

        // Per-run model resolution. `currentAgentModel` is the typed selection
        // — we derive the computer-use tool TYPE and beta HEADER from it,
        // since those must match (e.g. Sonnet 4.6 requires computer_20251124
        // + computer-use-2025-11-24; Haiku 4.5 requires computer_20250124 +
        // computer-use-2025-01-24). Falls back to .haiku if the settings
        // store is unreachable.
        var currentAgentModel = AgentSettingsStore.shared.agentModel
        let thinkingEnabled = (AgentSettingsStore.shared.reasoningEffort == .high)
        // var, not let — `AnthropicClient` is a struct and we mutate its
        // `betaHeaders` on the fallback path (the computer-use beta has to
        // switch with the model family).
        var client = AnthropicClient(
            apiKey: apiKey,
            betaHeaders: Self.betaHeaders(for: currentAgentModel, thinkingEnabled: thinkingEnabled)
        )
        var tools = buildTools(displaySize: agentDisplaySize, toolType: currentAgentModel.computerUseToolType)
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
        // The Selector pre-sized the JPEG to exactly `agentDisplaySize` and
        // shipped the matching CoordTransform in `input.initiationTransform`,
        // so we attach the bytes as-is.
        let firstUserContent: [ContentBlock]
        if let jpeg = input.initiationScreenshot, !jpeg.isEmpty {
            let base64 = jpeg.base64EncodedString()
            firstUserContent = [
                .text(input.transcript),
                .image(mediaType: "image/jpeg", base64: base64, cache: false)
            ]
            log.info("harness.first_user has_image=true image_bytes=\(jpeg.count) target=\(Int(agentDisplaySize.width))x\(Int(agentDisplaySize.height))")
        } else {
            firstUserContent = [.text(input.transcript)]
        }
        var messages: [Message] = [
            Message(role: "user", content: firstUserContent)
        ]

        var currentModel = currentAgentModel.modelID
        if currentModel.isEmpty { currentModel = modelID }
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

            Self.injectPromptCaching(messages: &messages)

            // Thinking is gated to .high effort only. .low and .medium send NO
            // thinking block at all so the messages-cache stays warm across
            // adjacent turns (any flip of the thinking field invalidates the
            // messages cache). Beta header tracks the same gate.
            let thinkingConfig: ThinkingConfig? = thinkingEnabled
                ? AgentSettingsStore.shared.reasoningEffort.thinkingBudgetTokens.map { ThinkingConfig(budgetTokens: $0) }
                : nil
            // max_tokens must exceed budget_tokens; leave headroom for the actual
            // tool-call output that follows reasoning.
            let effectiveMaxTokens: Int = {
                guard let budget = thinkingConfig?.budgetTokens else { return maxOutputTokens }
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
                response = try await Self.streamMessage(request, client: client)
            } catch let err as AnthropicClient.Error {
                if !triedFallback, shouldFallback(err) {
                    log.warning("harness.fallback run_id=\(runID.uuidString) from=\(currentModel) to=\(self.fallbackModelID) status=\(err.status ?? -1)")
                    triedFallback = true
                    usedFallback = true
                    currentModel = fallbackModelID
                    // The fallback model lives in a different computer-use
                    // family than the original (Sonnet/Opus → Haiku), so the
                    // tools array AND the beta header have to switch with it,
                    // or the next request fails with the same 400 we're
                    // recovering from.
                    currentAgentModel = .haiku
                    tools = buildTools(displaySize: agentDisplaySize, toolType: currentAgentModel.computerUseToolType)
                    client.betaHeaders = Self.betaHeaders(for: currentAgentModel, thinkingEnabled: thinkingEnabled)
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
                var textParts: [String] = []
                for case .text(let t) in response.content { textParts.append(t) }
                let text = textParts.joined(separator: " ")

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
                var affirmationParts: [String] = []
                for case .text(let t) in response.content { affirmationParts.append(t) }
                let affirmation = affirmationParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !affirmation.isEmpty {
                    TextToSpeechService.shared.speak(capped(affirmation))
                }
            }

            var resultBlocks: [ContentBlock] = []
            resultBlocks.reserveCapacity(toolUses.count)
            var toolRecords: [HarnessTurnRecord.ToolCallRecord] = []
            toolRecords.reserveCapacity(toolUses.count)
            var observabilityToolCalls: [AgentObservabilityLog.ToolCallSummary] = []
            observabilityToolCalls.reserveCapacity(toolUses.count)
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

    // MARK: - Claude Code (CLI) provider mode

    /// CC-provider replacement for the API-mode loop. Spawns the user's
    /// `claude` binary, streams its stream-json output, and lets it drive
    /// tools via the MCP bridge instead of running our own multi-turn loop.
    /// The user-visible UX (notch state, TTS, tool strip, observability) is
    /// the same — the difference is whose model + auth runs the show.
    private func runClaudeCodeMode(_ input: Input) async {
        let runID = UUID()
        let startedAt = Date()
        log.info("harness.start run_id=\(runID.uuidString) provider=claudeCodeCLI transcript_len=\(input.transcript.count)")

        AgentState.shared.set(.thinking)
        CursorCompanion.shared.setThinking(true)
        isRunning = true
        stopRequested = false
        defer {
            CursorCompanion.shared.setThinking(false)
            isRunning = false
            stopRequested = false
            activeClaudeClient = nil
        }

        // Same fast-path as API mode — handles open-URL / Spotify / Reminders
        // without any CLI spawn. Keeps CC turnaround for trivial commands
        // at zero cost.
        let routed = await IntentRouter.tryHandle(transcript: input.transcript)
        if case .handled(let summary, let affirmation) = routed {
            TextToSpeechService.shared.speak(capped(affirmation))
            AgentState.shared.set(.idle, detail: summary)
            log.info("harness.done run_id=\(runID.uuidString) provider=claudeCodeCLI status=completed_fast_path")
            return
        }

        let settings = AgentSettingsStore.shared.settings
        let systemText = Self.composeClaudeCodeSystem(settings: settings, contextSummary: input.contextSummary)
        let prompt = ClaudeCodeClient.Prompt(system: systemText, userText: input.transcript)

        let client = ClaudeCodeClient()
        self.activeClaudeClient = client

        var sawAffirmation = false
        var finalText = ""
        var hadError = false
        var errorDetail: String?

        var hooksInFlight = 0
        do {
            for try await event in client.run(prompt: prompt) {
                if stopRequested { break }
                switch event {
                case .spawned:
                    AgentState.shared.set(.thinking, detail: "Launching Claude Code…")
                case .hookStarted(let name):
                    hooksInFlight += 1
                    AgentState.shared.set(.thinking, detail: "Running hook: \(name)")
                case .hookCompleted:
                    hooksInFlight = max(0, hooksInFlight - 1)
                    if hooksInFlight == 0 {
                        AgentState.shared.set(.thinking, detail: "Waiting for model…")
                    }
                case .sessionStarted(let id):
                    log.info("cc.session run_id=\(runID.uuidString) session=\(id)")
                    AgentState.shared.set(.thinking, detail: "Waiting for model…")
                case .thinking:
                    AgentState.shared.set(.thinking, detail: "Thinking…")
                case .toolStarted(let name, _):
                    AgentState.shared.set(.toolCall(name: name), detail: name)
                case .toolCompleted:
                    break
                case .assistantText(let chunk):
                    finalText += chunk
                    // Speak the first non-empty assistant chunk as the
                    // turn-1 affirmation, capped to N words.
                    if !sawAffirmation {
                        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            sawAffirmation = true
                            TextToSpeechService.shared.speak(capped(trimmed))
                        }
                    }
                case .usage(let inT, let outT):
                    log.info("cc.usage run_id=\(runID.uuidString) input=\(inT) output=\(outT)")
                case .finished(let text):
                    if !text.isEmpty { finalText = text }
                case .stderr(let line):
                    log.warning("cc.stderr line=\(line.prefix(200))")
                }
            }
        } catch {
            hadError = true
            errorDetail = "\(error)"
            log.error("cc.error run_id=\(runID.uuidString) error=\(error)")
        }

        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        if stopRequested {
            AgentState.shared.set(.idle, detail: "Stopped")
            log.info("harness.done run_id=\(runID.uuidString) provider=claudeCodeCLI status=stopped_by_user duration_ms=\(elapsed)")
            return
        }
        if hadError {
            let detail = errorDetail ?? "Claude Code error"
            AgentState.shared.set(.error(message: detail))
            log.info("harness.done run_id=\(runID.uuidString) provider=claudeCodeCLI status=error duration_ms=\(elapsed)")
            return
        }

        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sawAffirmation && !trimmed.isEmpty {
            TextToSpeechService.shared.speak(capped(trimmed))
        }
        AgentState.shared.set(.idle, detail: trimmed.isEmpty ? "" : trimmed)
        log.info("harness.done run_id=\(runID.uuidString) provider=claudeCodeCLI status=completed duration_ms=\(elapsed) final_len=\(trimmed.count)")
    }

    /// System prompt for CC mode. Shorter than the API-mode block — Claude
    /// Code already knows how to be an agent. We just tell it about our MCP
    /// tools and the user's preferences.
    private static func composeClaudeCodeSystem(
        settings: AgentSettings,
        contextSummary: String
    ) -> String {
        var parts: [String] = []
        parts.append("""
        You are an on-screen macOS computer-use agent running inside AgentNotch. The user spoke a command into the cursor companion; act on it.

        Tools available to you live under the `agentnotch` MCP server. PREFER them in this order, falling back when the prior tool cannot do the task:
          1. open_app    — plain "open <DesktopApp>" goals.
          2. open_url    — web URLs (https, mailto, sms) and deep links (spotify:, things:///add, etc).
          3. applescript — Safari, Chrome, Spotify, Music, Messages, Mail, Notes, Reminders, Calendar, Terminal, Finder.
          4. run_shortcut — user-installed macOS Shortcuts.
          5. ax_query + ax_press / ax_set_value — buttons / links / text fields you can name.
          6. menu_shortcut — sends the registered shortcut for a menu item.
          7. screenshot + left_click / type / key / scroll — vision-driven, last resort.

        Conventions:
          - Coordinates are in 1280x800 model space. The MCP `screenshot` tool returns that view.
          - On the first reply emit one short spoken-style sentence (under 9 words) BEFORE any tool call. That sentence is read aloud to the user.
          - Do not ask clarifying questions. Pick the most likely interpretation and act.
          - Stop only when EVERY explicit sub-goal in the command is observably done.
          - Refuse irreversible destructive actions (delete files, send payments, send messages to people you cannot confirm) without explicit user confirmation.

        Do not use any of your built-in Bash / Read / Edit / Write tools — they are not relevant on this surface. The MCP tools above are your only action surface.
        """)

        if !contextSummary.isEmpty {
            parts.append("# Context brief\n\(contextSummary)")
        }
        if !settings.preferences.isEmpty {
            parts.append("# User preferences\n\(settings.preferences)")
        }
        if !settings.systemPrompt.isEmpty {
            parts.append(settings.systemPrompt)
        }
        return parts.joined(separator: "\n\n")
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
        // No cache_control on tools — Anthropic caps at 4 breakpoints per
        // request. Reference impl (anthropic-quickstarts loop.py:265-288) puts
        // the shared breakpoint on the system block; the request prefix is
        // hashed front-to-back, so caching at system also caches tools that
        // appear before it. Total: 1 (system) + 3 (rolling user) = 4.
        let computer: Tool = .computer(
            displayWidth: Int(displaySize.width),
            displayHeight: Int(displaySize.height),
            displayNumber: 1,
            cache: false,
            toolType: toolType
        )

        return [openApp, openURL, applescript, runShortcut, axQuery, axPress, axSetValue, menuShortcut, computer]
    }

    /// Beta headers for a given user-selected model. The computer-use header
    /// is model-family-specific (see `AgentModel.computerUseBetaHeader`).
    /// `interleaved-thinking-2025-05-14` is added ONLY when thinking is on for
    /// this run — sending it with `thinking: nil` would still expose the
    /// model to the interleaved schema and risks cache misses every time the
    /// effort dropdown flips between sessions.
    private static func betaHeaders(for model: AgentModel, thinkingEnabled: Bool) -> [String] {
        var headers = [
            model.computerUseBetaHeader,
            "prompt-caching-2024-07-31"
        ]
        if thinkingEnabled {
            headers.append("interleaved-thinking-2025-05-14")
        }
        return headers
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
          3. applescript — for Safari, Google Chrome, Spotify, Music, Messages, Mail, Notes, Reminders, Calendar, Finder. One call, no UI traversal. EXCEPTION: when the brief's `steps[0]`, `navigation_anchors`, or `resolved_references` point the target (especially a named person like "phone1k" or a specific resource) to a DIFFERENT app, use that app — do not default to Messages/Mail just because the transcript verb is "message" or "email". The brief reflects the user's actual usage; the AppleScript list is a fallback for when no surface match exists.
          4. run_shortcut — for user-installed macOS Shortcuts.
          5. ax_query + ax_press / ax_set_value — for buttons, links, and text fields you can name. Faster and more reliable than clicking pixels.
          6. menu_shortcut — for any menu item; sends the registered keyboard shortcut instead of clicking the menu.
          7. computer — vision + click/type/scroll. ONLY when nothing above applies.

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

    /// Reference-impl prompt-caching strategy. Ported from anthropic-quickstarts
    /// computer-use-demo/loop.py:265-288 (`_inject_prompt_caching`).
    ///
    /// Goal: keep cache_control on the LAST content block of the 3 most-recent
    /// user messages, and strip it from older user messages so we stay under
    /// Anthropic's 4-breakpoint cap (the other slot is held by the system+tools
    /// caches). Every new turn now reads the entire prior trajectory from cache
    /// at 10% input cost.
    ///
    /// `cache_control` lives only on `tool_result` and `image` blocks per the
    /// API. For each rolling user message we stamp the LAST such block; for
    /// older user messages we strip every cache marker.
    private static func injectPromptCaching(messages: inout [Message]) {
        // Indices of the 3 most-recent user messages (newest first).
        var userIndices: [Int] = []
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            if messages[i].role == "user" {
                userIndices.append(i)
                if userIndices.count == 3 { break }
            }
        }
        let rollingSet = Set(userIndices)

        for i in messages.indices where messages[i].role == "user" {
            if rollingSet.contains(i) {
                // Stamp cache_control on the LAST cache-eligible block in this
                // user message. Walk backward, stop at the first toolResult or
                // image and mark it; strip cache from any earlier ones.
                var blocks = messages[i].content
                var stamped = false
                for j in stride(from: blocks.count - 1, through: 0, by: -1) {
                    switch blocks[j] {
                    case .toolResult, .image:
                        blocks[j] = blocks[j].withCache(!stamped)
                        stamped = true
                    default:
                        break
                    }
                }
                messages[i].content = blocks
            } else if Self.hasAnyCacheMarker(messages[i].content) {
                // Older user message that still carries a marker from a prior
                // turn — strip. Skip the Array realloc when there is nothing
                // to strip (most older messages on long runs).
                messages[i].content = messages[i].content.map { $0.withCache(false) }
            }
        }
    }

    private static func hasAnyCacheMarker(_ blocks: [ContentBlock]) -> Bool {
        for block in blocks {
            switch block {
            case .toolResult(_, _, _, let cache) where cache: return true
            case .image(_, _, let cache) where cache: return true
            default: continue
            }
        }
        return false
    }

    /// Drive the streaming endpoint to completion, assembling the same
    /// `AnthropicMessageResponse` the non-streaming endpoint would have
    /// returned. The harness can hand off the assembled response to its
    /// existing loop logic untouched.
    private static func streamMessage(
        _ request: AnthropicMessageRequest,
        client: AnthropicClient
    ) async throws -> AnthropicMessageResponse {
        var responseID: String = ""
        var responseModel: String = request.model
        var responseRole: String = "assistant"
        var stopReason: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreationInputTokens: Int?

        var builders: [Int: BlockBuilder] = [:]
        var blockOrder: [Int] = []

        for try await event in client.sendStreaming(request) {
            switch event {
            case .messageStart(let m):
                responseID = m.id
                responseModel = m.model
                responseRole = m.role
                if let u = m.usage {
                    inputTokens = u.inputTokens
                    outputTokens = u.outputTokens
                    cacheReadInputTokens = u.cacheReadInputTokens
                    cacheCreationInputTokens = u.cacheCreationInputTokens
                }

            case .contentBlockStart(let index, let block):
                if !blockOrder.contains(index) { blockOrder.append(index) }
                var b = BlockBuilder(kind: .unknown)
                switch block {
                case .text(let t):
                    b.kind = .text
                    b.text = t
                case .toolUse(let id, let name, _):
                    b.kind = .toolUse
                    b.toolUseId = id
                    b.toolName = name
                case .thinking(let t, let sig):
                    b.kind = .thinking
                    b.thinking = t
                    b.signature = sig
                default:
                    b.kind = .unknown
                }
                builders[index] = b

            case .contentBlockDelta(let index, let delta):
                guard var b = builders[index] else { continue }
                switch delta {
                case .text(let s):        b.text += s
                case .thinking(let s):    b.thinking += s
                case .signature(let s):   b.signature += s
                case .partialJSON(let s): b.partialJSON += s
                }
                builders[index] = b

            case .contentBlockStop:
                break

            case .messageDelta(let sr, _, let outTokens):
                stopReason = sr
                if let n = outTokens { outputTokens = n }

            case .messageStop, .ping:
                break

            case .streamError(let type, let message):
                throw AnthropicClient.Error(
                    status: 500,
                    body: "{\"type\":\"\(type)\",\"message\":\"\(message)\"}",
                    underlying: nil
                )
            }
        }

        // Materialize the content list in stream order.
        var content: [ContentBlock] = []
        for index in blockOrder {
            guard let b = builders[index] else { continue }
            switch b.kind {
            case .text:
                content.append(.text(b.text))
            case .toolUse:
                // Re-parse the accumulated JSON string into our JSON enum so
                // the dispatcher can read it the same way it reads non-stream
                // tool_use blocks.
                let inputJSON = parseToolInputJSON(b.partialJSON, toolID: b.toolUseId, toolName: b.toolName)
                content.append(.toolUse(id: b.toolUseId, name: b.toolName, input: inputJSON))
            case .thinking:
                content.append(.thinking(thinking: b.thinking, signature: b.signature))
            case .unknown:
                continue
            }
        }

        return AnthropicMessageResponse(
            id: responseID,
            model: responseModel,
            role: responseRole,
            content: content,
            stopReason: stopReason,
            usage: AnthropicMessageResponse.Usage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens,
                cacheReadInputTokens: cacheReadInputTokens
            )
        )
    }

    /// In-progress assembly state for one stream block. Anthropic emits blocks
    /// in monotonic index order; the index field disambiguates concurrent
    /// thinking + tool_use + text blocks.
    private struct BlockBuilder {
        enum Kind { case text, toolUse, thinking, unknown }
        var kind: Kind
        var text: String = ""
        var toolUseId: String = ""
        var toolName: String = ""
        var partialJSON: String = ""
        var thinking: String = ""
        var signature: String = ""
    }

    private static func parseToolInputJSON(_ raw: String, toolID: String, toolName: String) -> JSON {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmed.isEmpty ? "{}" : trimmed
        do {
            return try JSON.parse(payload)
        } catch {
            // Silent fallback to {} hides real Anthropic schema changes — the
            // dispatcher would then see a tool call with no coordinates / no
            // text and fail with "Missing 'coordinate'" without any upstream
            // signal. Log loudly so we can spot it.
            log.error("stream.tool_input_decode_failed tool=\(toolName) id=\(toolID) raw_len=\(raw.count) preview=\(payload.prefix(160)) error=\(error)")
            return .object([:])
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
                  let parsed = try? Self.verifierDecoder.decode(Parsed.self, from: data) else {
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

    /// Compact JSON representation of a tool input. Used for the Dev Tools
    /// per-turn drill-in — small enough to render inline, big enough to debug.
    private static let verifierDecoder = JSONDecoder()

    private static let compactJSONEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    fileprivate static func compactJSON(_ value: JSON, limit: Int = 240) -> String {
        if let data = try? compactJSONEncoder.encode(value), let text = String(data: data, encoding: .utf8) {
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
