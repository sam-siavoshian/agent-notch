import Foundation

/// Observes EventLog for repeated key/click sequences and promotes them to L3 recipes
/// (per-app coord-free shortcuts) at 3 matching occurrences. Stores per-app recipe
/// collections at ~/Library/Application Support/AgentNotch/ContextMemory/anchors/<bundleID>.json.
///
/// Scope for Phase 3: a simplified inference that:
///   - polls EventLog every 5 s
///   - segments events into "sequences" bracketed by screen / dwell / appSwitch events
///   - normalizes each sequence's typed text into template slots when it matches known
///     entity shapes (e.g., looks like a person handle, looks like a URL, looks like
///     a search query in a search-shaped input)
///   - matches sequences by (app + step-kind tuple + normalized slot signature)
///   - promotes a candidate to a recipe at seenCount == 3
public final class AnchorRecorder {

    public static let shared = AnchorRecorder()

    private let queue = DispatchQueue(label: "AgentNotch.AnchorRecorder.queue")
    private var lastSeenSeq: Int = 0
    private var pollTimer: Timer?
    private var pendingSeq: [CEvent] = []
    private var pendingApp: String?

    public static let storageRoot: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextMemory", isDirectory: true)
            .appendingPathComponent("anchors", isDirectory: true)
    }()

    public static let promotionThreshold: Int = 3

    private init() {
        try? FileManager.default.createDirectory(at: Self.storageRoot, withIntermediateDirectories: true)
    }

    // MARK: - Lifecycle

    public func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Tick

    private func tick() {
        let snapshot = EventLog.shared.snapshot()
        guard !snapshot.isEmpty else { return }
        queue.sync {
            // Walk only events newer than what we've seen.
            let fresh = snapshot.filter { $0.seq > lastSeenSeq }
            for event in fresh {
                lastSeenSeq = max(lastSeenSeq, event.seq)
                ingest(event)
            }
        }
    }

    /// MUST be called from `queue`.
    private func ingest(_ event: CEvent) {
        switch event.kind {
        case .screen, .dwell, .appSwitch, .backtrack:
            // Boundary: flush any pending sequence.
            flushPending()
        case .input, .click:
            // Action: append to pending sequence (or start one).
            if pendingApp == nil {
                pendingApp = event.bundleID
            } else if pendingApp != event.bundleID {
                // App changed mid-sequence — flush + restart.
                flushPending()
                pendingApp = event.bundleID
            }
            pendingSeq.append(event)
        case .copyPaste, .search:
            // Treat as parts of the sequence too.
            if pendingApp == nil { pendingApp = event.bundleID }
            pendingSeq.append(event)
        }
    }

    /// MUST be called from `queue`. Promote or accumulate the pending sequence.
    private func flushPending() {
        defer {
            pendingSeq.removeAll()
            pendingApp = nil
        }
        guard let bundleID = pendingApp, !bundleID.isEmpty else { return }

        let steps = pendingSeq.compactMap(Self.stepFor)
        guard !steps.isEmpty else { return }

        var collection = loadCollection(for: bundleID)
        defer { try? saveCollection(collection, for: bundleID) }

        // (1) Instant shortcut learning: any .shortcut step bumps the per-app
        //     shortcuts tally immediately. No threshold — single keypress
        //     shortcuts are inherently generalizable.
        for step in steps {
            if case let .shortcut(keys) = step {
                if let idx = collection.shortcuts.firstIndex(where: { $0.keys == keys }) {
                    collection.shortcuts[idx].seenCount += 1
                } else {
                    collection.shortcuts.append(
                        CAppRecipes.Shortcut(keys: keys, label: nil, seenCount: 1)
                    )
                }
            }
        }

        // Singletons aren't multi-step recipes — done after shortcut tally.
        guard steps.count >= 2 else { return }

        let signature = Self.signature(of: steps)

        // (2) Match against existing promoted recipes — bump confidence.
        if let idx = collection.recipes.firstIndex(where: { Self.signature(of: $0.steps) == signature }) {
            collection.recipes[idx].seenCount += 1
            collection.recipes[idx].lastSeen = Date()
            collection.recipes[idx].confidence = min(1.0, collection.recipes[idx].confidence + 0.02)
            return
        }

        // (3) Auto-promote on first observation if all type-step values are already generalized.
        //     "Generalized" = wrapped in <...> (e.g. <url>, <person.name>, <query>).
        //     Such sequences carry no literal user-specific text that needs 3 examples to abstract.
        let isFullyGeneralized = steps.allSatisfy { step in
            if case .type(let value) = step {
                return value.hasPrefix("<") && value.hasSuffix(">")
            }
            return true   // non-type steps (shortcut/key/menu/url/etc) are always generalized
        }
        if isFullyGeneralized {
            let recipe = CRecipe(
                name: "auto-\(signature.prefix(8))",
                triggerPattern: "",
                steps: steps,
                seenCount: 1,
                lastSeen: Date(),
                confidence: 0.5   // medium — generalized but only 1 observation so far
            )
            collection.recipes.append(recipe)
            return
        }

        // (4) Multi-step with literal text — use the 3-occurrence candidate→promote flow.
        if let idx = collection.candidates.firstIndex(where: { Self.signature(of: $0.steps) == signature }) {
            collection.candidates[idx].seenCount += 1
            collection.candidates[idx].lastSeen = Date()
            if collection.candidates[idx].seenCount >= Self.promotionThreshold {
                let promoted = collection.candidates.remove(at: idx)
                var r = promoted
                r.confidence = Double(promoted.seenCount) / Double(promoted.seenCount + 2)
                collection.recipes.append(r)
            }
            return
        }
        let candidate = CRecipe(
            name: "candidate-\(signature.prefix(8))",
            triggerPattern: "",
            steps: steps,
            seenCount: 1,
            lastSeen: Date(),
            confidence: 0.0
        )
        collection.candidates.append(candidate)
    }

    // MARK: - Step extraction + normalization

    /// Convert one CEvent to a CRecipe.Step, or nil if it shouldn't be in a recipe.
    private static func stepFor(_ event: CEvent) -> CRecipe.Step? {
        switch event.payload {
        case let .input(element, text, _, _, modifiers):
            // If the text starts with a single character + modifiers, treat as shortcut.
            if !modifiers.isEmpty && text.count == 1 {
                return .shortcut(keys: (modifiers + [text.lowercased()]).joined(separator: "+"))
            }
            // Otherwise it's a literal type — normalize to template slot when shape matches.
            return .type(value: normalizeSlot(text: text, focused: element))
        case let .click(elementLabel, _, _):
            // We don't have a great way to express a click as a coord-free step;
            // for now, encode it as a typed label that the Selector can ax_press by.
            // Use `.type` as a generic carrier — Phase 4 may add a `.axPress` step kind.
            return .type(value: "<click:\(elementLabel ?? "?")>")
        default:
            return nil
        }
    }

    /// Deterministic slot typing per spec §5: replace literal text with a template
    /// slot when it looks like a person/file/url/query, otherwise keep literal.
    private static func normalizeSlot(text: String, focused: String?) -> String {
        // URL
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            return "<url>"
        }
        // Search-shaped focused element
        if let f = focused, f.lowercased().contains("search") {
            return "<query>"
        }
        // Person-like (@handle or "Name LastName")
        if text.hasPrefix("@") { return "<person.name>" }
        if text.split(separator: " ").count == 2 && text.first?.isUppercase == true {
            return "<person.name>"
        }
        // Default: keep literal.
        return text
    }

    /// Stable signature of a step sequence — used to match candidates across observations.
    private static func signature(of steps: [CRecipe.Step]) -> String {
        steps.map(stepSignature).joined(separator: "|")
    }

    private static func stepSignature(_ step: CRecipe.Step) -> String {
        switch step {
        case .shortcut(let keys):       return "shortcut:\(keys)"
        case .type(let v):              return "type:\(v)"
        case .key(let keys):            return "key:\(keys)"
        case .menu(let p):              return "menu:\(p.joined(separator: ">"))"
        case .url(let v):               return "url:\(v)"
        case .shellCmd(let v, _):       return "shell:\(v)"
        case .openFile(let v, _):       return "file:\(v)"
        case .appleScript(_):           return "applescript"
        }
    }

    // MARK: - Per-app storage

    private func loadCollection(for bundleID: String) -> CAppRecipes {
        let url = Self.storageRoot.appendingPathComponent("\(bundleID).json")
        if let data = try? Data(contentsOf: url),
           let coll = try? JSONDecoder().decode(CAppRecipes.self, from: data) {
            return coll
        }
        return CAppRecipes(appBundleID: bundleID, recipes: [], candidates: [], shortcuts: [], menuPaths: [])
    }

    private func saveCollection(_ collection: CAppRecipes, for bundleID: String) throws {
        let url = Self.storageRoot.appendingPathComponent("\(bundleID).json")
        let data = try JSONEncoder().encode(collection)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Public read for Selector (Phase 4)

    public func recipes(for bundleID: String) -> CAppRecipes {
        queue.sync { loadCollection(for: bundleID) }
    }
}
