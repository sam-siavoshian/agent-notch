import SwiftUI
import AppKit

/// Phase 1-3 context-system inspector.
/// Polls `EventLog.shared` / `L5Store.shared` / `PrivacyGate.shared` /
/// `AnchorRecorder.shared` every 1s and renders the latest state.
public struct ContextDebugNewSystemView: View {

    @State private var tail: [CEvent] = []
    @State private var activeTask: CActiveTask?
    @State private var resources: [CResourceRef] = []
    @State private var recipes: [CRecipe] = []
    @State private var frontmostApp: (name: String, bundleID: String) = ("<unknown>", "<unknown>")
    @State private var redactionCounts: [CEvent.RedactionReason: Int] = [:]
    @State private var paused: Bool = false
    @State private var refreshTimer: Timer?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                healthRow
                Divider()
                activeTaskSection
                Divider()
                recipesSection
                Divider()
                eventLogSection
                Divider()
                resourcesSection
                Divider()
                redactionSection
            }
            .padding(16)
            .font(.system(size: 12, design: .monospaced))
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    // MARK: - Sections

    private var healthRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Monitor health").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 24) {
                healthPill("Frontmost", "\(frontmostApp.name) (\(frontmostApp.bundleID))")
                healthPill("Collection", paused ? "PAUSED" : "active", warning: paused)
                healthPill("EventLog", "\(tail.count) tail")
            }
        }
    }

    private var activeTaskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active Task").font(.system(size: 13, weight: .semibold))
            if let task = activeTask {
                Text(task.label).font(.system(size: 12, weight: .medium))
                Text("kind: \(task.kind) · started: \(task.startedAt.formatted(.relative(presentation: .named)))")
                    .foregroundColor(.secondary).font(.system(size: 11))
                if let stale = task.staleSince {
                    Text("STALE since \(stale.formatted(.relative(presentation: .named)))")
                        .foregroundColor(.orange).font(.system(size: 11, weight: .semibold))
                }
                Text(task.narrative)
                    .font(.system(size: 11))
                    .padding(8).background(Color.gray.opacity(0.08)).cornerRadius(4)
                if !task.resources.isEmpty {
                    Text("Resources:").font(.system(size: 11, weight: .semibold)).padding(.top, 4)
                    ForEach(Array(task.resources.prefix(5).enumerated()), id: \.offset) { _, uri in
                        Text("  • \(uri)").font(.system(size: 11)).lineLimit(1)
                    }
                }
            } else {
                Text("<no active task yet>").foregroundColor(.secondary)
            }
        }
    }

    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recipes — \(frontmostApp.name)").font(.system(size: 13, weight: .semibold))
            if recipes.isEmpty {
                Text("<no promoted recipes yet>").foregroundColor(.secondary).font(.system(size: 11))
            } else {
                ForEach(Array(recipes.sorted { $0.seenCount > $1.seenCount }.prefix(5).enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(r.seenCount)×").foregroundColor(.secondary).frame(width: 32, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(.system(size: 11, weight: .medium))
                            Text(stepSummary(r.steps)).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var eventLogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EventLog tail (last 20)").font(.system(size: 13, weight: .semibold))
            if tail.isEmpty {
                Text("<no events>").foregroundColor(.secondary).font(.system(size: 11))
            } else {
                ForEach(tail.suffix(20).reversed(), id: \.id) { e in
                    HStack(alignment: .top, spacing: 6) {
                        Text(e.t.formatted(.dateTime.hour().minute().second()))
                            .foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                        Text(e.kind.rawValue).frame(width: 80, alignment: .leading)
                        Text(e.app ?? "").frame(width: 100, alignment: .leading).lineLimit(1)
                        Text(eventSummary(e))
                            .lineLimit(1)
                            .foregroundColor(e.redacted ? .orange : .primary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
    }

    private var resourcesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent resources (top 10)").font(.system(size: 13, weight: .semibold))
            if resources.isEmpty {
                Text("<empty>").foregroundColor(.secondary).font(.system(size: 11))
            } else {
                ForEach(Array(resources.prefix(10).enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 6) {
                        Text(r.kind).frame(width: 64, alignment: .leading).foregroundColor(.secondary)
                        Text(r.label ?? r.uri).lineLimit(1)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    private var redactionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PrivacyGate redactions").font(.system(size: 13, weight: .semibold))
            if redactionCounts.isEmpty {
                Text("<none yet>").foregroundColor(.secondary).font(.system(size: 11))
            } else {
                ForEach(redactionCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { pair in
                    HStack {
                        Text(pair.key.rawValue).foregroundColor(.secondary)
                        Spacer()
                        Text("\(pair.value)").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }

    // MARK: - Helpers

    private func healthPill(_ label: String, _ value: String, warning: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundColor(.secondary).font(.system(size: 11))
            Text(value).font(.system(size: 11, weight: .semibold))
                .foregroundColor(warning ? .orange : .primary)
        }
    }

    private func stepSummary(_ steps: [CRecipe.Step]) -> String {
        steps.map { s -> String in
            switch s {
            case .shortcut(let k):   return k
            case .type(let v):       return "type \(v)"
            case .key(let k):        return k
            case .menu(let p):       return p.joined(separator: ">")
            case .url(let v):        return "url \(v)"
            case .shellCmd(let v, _): return "$ \(v)"
            case .openFile(let v, _): return "open \(v)"
            case .appleScript:        return "applescript"
            }
        }.joined(separator: " → ")
    }

    private func eventSummary(_ e: CEvent) -> String {
        switch e.payload {
        case .screen(let surface):    return surface ?? "(screen)"
        case .input(_, let text, _, _, _): return "input: \(text.prefix(40))"
        case .click(let label, _, _): return "click: \(label ?? "?")"
        case .copyPaste(let from, let to, _): return "\(from.app) → \(to.app)"
        case .dwell(let s, let sig):  return "dwell \(Int(s))s \(sig ?? "")"
        case .backtrack(let f, let t, _, _): return "\(f) ↔ \(t)"
        case .search(let q):          return "search \(q)"
        case .appSwitch(let f, let t): return "\(f ?? "?") → \(t)"
        }
    }

    // MARK: - Refresh loop

    private func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    private func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        tail = EventLog.shared.tail(20)
        activeTask = L5Store.shared.loadActiveTask()
        resources = L5Store.shared.loadResourcesIndex()
        redactionCounts = PrivacyGate.shared.redactionCounts
        paused = PrivacyGate.shared.collectionPaused

        if let app = NSWorkspace.shared.frontmostApplication {
            let name = app.localizedName ?? "<unknown>"
            let bundle = app.bundleIdentifier ?? "<unknown>"
            frontmostApp = (name, bundle)
            recipes = AnchorRecorder.shared.recipes(for: bundle).recipes
        }
    }
}
