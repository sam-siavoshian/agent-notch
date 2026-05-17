import SwiftUI

extension ContextDebugView {
    var memoryPane: some View {
        MemoryDrilldownView()
    }
}

// MARK: - Pane root

private struct MemoryDrilldownView: View {
    @State private var bundleIDs: [String] = []
    @State private var selected: String?
    @State private var collection: CAppRecipes?
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.person.crop")
                .foregroundStyle(.purple)
            Text("Learned per-app recipes")
                .font(.headline)
            Spacer()
            Picker("App", selection: Binding(
                get: { selected ?? "" },
                set: { selected = $0.isEmpty ? nil : $0; refresh() }
            )) {
                ForEach(bundleIDs, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320)
            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if bundleIDs.isEmpty {
            placeholder(
                icon: "tray",
                title: "No per-app recipes recorded yet",
                detail: "AnchorRecorder writes recipes to ~/Library/Application Support/AgentNotch/ContextMemory/anchors/. Use the agent for a bit and recipes will appear here."
            )
        } else if let coll = collection {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        title: "Promoted Recipes",
                        count: coll.recipes.count,
                        empty: "(no promoted recipes yet)"
                    ) {
                        ForEach(Array(coll.recipes.sorted { $0.seenCount > $1.seenCount }.enumerated()), id: \.offset) { _, r in
                            RecipeRow(recipe: r)
                        }
                    }

                    section(
                        title: "Candidates",
                        count: coll.candidates.count,
                        empty: "(no candidates — observed < 3× literal sequences live here until promoted)"
                    ) {
                        ForEach(Array(coll.candidates.sorted { $0.seenCount > $1.seenCount }.enumerated()), id: \.offset) { _, r in
                            RecipeRow(recipe: r)
                        }
                    }

                    section(
                        title: "Shortcuts",
                        count: coll.shortcuts.count,
                        empty: "(no shortcuts observed)"
                    ) {
                        ForEach(Array(coll.shortcuts.sorted { $0.seenCount > $1.seenCount }.enumerated()), id: \.offset) { _, s in
                            ShortcutRow(shortcut: s)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            placeholder(
                icon: "questionmark.folder",
                title: "Pick an app",
                detail: "Select a bundle ID from the picker to drill in."
            )
        }
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        count: Int,
        empty: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            if count == 0 {
                Text(empty)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    content()
                }
            }
        }
    }

    // MARK: - Refresh

    private func start() {
        reloadBundleIDs()
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            DispatchQueue.main.async {
                reloadBundleIDs()
                refresh()
            }
        }
    }

    private func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func reloadBundleIDs() {
        let fm = FileManager.default
        let root = AnchorRecorder.storageRoot
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            bundleIDs = []
            return
        }
        let ids = entries
            .compactMap { $0.pathExtension == "json" ? $0.deletingPathExtension().lastPathComponent : nil }
            .sorted()
        bundleIDs = ids
        if selected == nil || !(selected.map { ids.contains($0) } ?? false) {
            selected = ids.first
        }
    }

    private func refresh() {
        guard let bundle = selected else {
            collection = nil
            return
        }
        collection = AnchorRecorder.shared.recipes(for: bundle)
    }
}

// MARK: - Rows

private struct RecipeRow: View {
    let recipe: CRecipe
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                Text(recipe.name)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("seen \(recipe.seenCount)×")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.2f", recipe.confidence))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            Text(MemoryFormat.summarize(steps: recipe.steps))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 1)
                .truncationMode(.tail)
                .padding(.leading, 20)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { i, step in
                        Text("\(i + 1). \(MemoryFormat.describe(step: step))")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ShortcutRow: View {
    let shortcut: CAppRecipes.Shortcut

    var body: some View {
        HStack(spacing: 8) {
            Text(shortcut.keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            if let label = shortcut.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("seen \(shortcut.seenCount)×")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Step formatting

enum MemoryFormat {
    static func describe(step: CRecipe.Step) -> String {
        switch step {
        case .shortcut(let keys):           return "shortcut \(keys)"
        case .type(let value):              return "type \"\(value)\""
        case .key(let keys):                return "key \(keys)"
        case .menu(let path):               return "menu \(path.joined(separator: " > "))"
        case .url(let value):               return "url \(value)"
        case .shellCmd(let cmd, let cwd):
            if let cwd, !cwd.isEmpty { return "shell \(cmd) (cwd=\(cwd))" }
            return "shell \(cmd)"
        case .openFile(let path, let app):
            if let app, !app.isEmpty { return "open \(path) (with \(app))" }
            return "open \(path)"
        case .appleScript:                  return "applescript"
        }
    }

    static func summarize(steps: [CRecipe.Step]) -> String {
        steps.map(summary(step:)).joined(separator: " → ")
    }

    private static func summary(step: CRecipe.Step) -> String {
        switch step {
        case .shortcut(let k):    return k
        case .type(let v):        return "type \(v)"
        case .key(let k):         return k
        case .menu(let p):        return p.joined(separator: ">")
        case .url(let v):         return "url \(v)"
        case .shellCmd(let v, _): return "$ \(v)"
        case .openFile(let v, _): return "open \(v)"
        case .appleScript:        return "applescript"
        }
    }
}
