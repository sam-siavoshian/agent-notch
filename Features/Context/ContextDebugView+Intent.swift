//
//  ContextDebugView+Intent.swift
//  Agent in the Notch
//
//  Dev Tools "Intent" pane: recent intent resolver outcomes with detailed
//  drill-in. Live-loads from the in-memory ring buffer and backfills from
//  the on-disk JSONL log at ~/Library/Application Support/AgentNotch.
//

import SwiftUI

// MARK: - Pane root

struct ContextDebugIntentView: View {
    @StateObject private var model = ContextDebugIntentViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            countsRow
            Divider()
            list
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
            Text("Intent Resolver")
                .font(.headline)
            Spacer()
            if let lastRefresh = model.lastRefresh {
                Text("Updated \(Self.timeFormatter.string(from: lastRefresh))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                Task { await model.clearLog() }
            } label: {
                Label("Clear in-memory", systemImage: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var countsRow: some View {
        let s = model.summary
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(s.total) outcomes  |  success: \(s.success)  |  fallback: \(s.fallback)  |  avg resolver latency: \(s.avgLatencyMs)ms")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("On-disk persisted: \(model.persistedCount)  |  in-memory ring: \(model.inMemoryCount)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var list: some View {
        Group {
            if model.outcomes.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.outcomes, id: \.recordedAt) { outcome in
                            ContextIntentRow(outcome: outcome)
                            Divider()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No resolver outcomes yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

// MARK: - Row

private struct ContextIntentRow: View {
    let outcome: ContextIntentResolverOutcomeLog.Outcome
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                Text(Self.timeFormatter.string(from: outcome.recordedAt))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)

                verbPill
                if let target = outcome.intent.target, !target.isEmpty {
                    targetPill(target)
                }

                Text(transcriptPreview)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(Int(outcome.intent.confidence * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(outcome.intent.usedFallback ? .orange : .secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            Text("Goal: \(outcome.intent.inferredGoal)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
                .lineLimit(2)

            if expanded {
                expansion
                    .padding(.leading, 22)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var transcriptPreview: String {
        let trimmed = outcome.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(80)) + "…"
    }

    private var verbPill: some View {
        Text(outcome.intent.verb)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.18))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }

    private func targetPill(_ target: String) -> some View {
        Text(target)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.gray.opacity(0.16))
            .clipShape(Capsule())
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 200, alignment: .leading)
    }

    @ViewBuilder
    private var expansion: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Transcript") {
                Text(outcome.transcript.isEmpty ? "(empty)" : outcome.transcript)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            section("Resolved entities") {
                if outcome.intent.resolvedEntities.isEmpty {
                    Text("(none)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(outcome.intent.resolvedEntities.enumerated()), id: \.offset) { _, e in
                            entityRow(e)
                        }
                    }
                }
            }

            section("Candidate recipes") {
                if outcome.intent.candidateRecipes.isEmpty {
                    Text("(none)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(outcome.intent.candidateRecipes.enumerated()), id: \.offset) { _, r in
                            recipeRow(r)
                        }
                    }
                }
            }

            section("Harness outcome") {
                VStack(alignment: .leading, spacing: 2) {
                    metaRow("harnessStatus", outcome.harnessStatus)
                    if let err = outcome.harnessErrorMessage {
                        metaRow("errorMessage", err)
                    }
                    if let ms = outcome.harnessDurationMs {
                        metaRow("durationMs", "\(ms)")
                    }
                }
            }

            section("Resolver") {
                VStack(alignment: .leading, spacing: 2) {
                    metaRow("resolverLatencyMs", "\(outcome.intent.resolverLatencyMs)")
                    metaRow("usedFallback", outcome.intent.usedFallback ? "true" : "false")
                    metaRow("confidence", String(format: "%.0f%%", outcome.intent.confidence * 100))
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func entityRow(_ e: ContextEntityResolution) -> some View {
        let label = e.entityLabel?.nilIfEmpty ?? "(unmatched)"
        let kind = e.entityType?.nilIfEmpty ?? "?"
        let id = e.entityID?.nilIfEmpty ?? ""
        let evidence = e.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .top, spacing: 6) {
            Text("\(e.userPhrase) →")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.caption.weight(.medium))
                    Text("[\(kind)]")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if !id.isEmpty {
                        Text(id)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(Int(e.confidence * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !evidence.isEmpty {
                    Text(evidence)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func recipeRow(_ r: ContextRecipeMatch) -> some View {
        let surface = r.fromSurfaceID?.nilIfEmpty ?? "—"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(r.recipeName)
                    .font(.caption.weight(.medium))
                Text(String(format: "(%.2f)", r.matchScore))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("[\(r.appKey) / \(surface)]")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if r.stepsProse.isEmpty {
                Text("(no steps)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(r.stepsProse.enumerated()), id: \.offset) { _, step in
                        Text("• \(step)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

// MARK: - View model

@MainActor
final class ContextDebugIntentViewModel: ObservableObject {
    struct Summary {
        let total: Int
        let success: Int
        let fallback: Int
        let avgLatencyMs: Int
    }

    @Published private(set) var outcomes: [ContextIntentResolverOutcomeLog.Outcome] = []
    @Published private(set) var persistedCount: Int = 0
    @Published private(set) var inMemoryCount: Int = 0
    @Published private(set) var lastRefresh: Date?

    private var pollTask: Task<Void, Never>?

    func start() async {
        await refresh()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let log = ContextIntentResolverOutcomeLog.shared
        let memory = await log.recentOutcomes(limit: 100)
        let persisted = await Self.loadPersisted(from: log.persistedFileURL, limit: 50)
        self.inMemoryCount = memory.count
        self.persistedCount = persisted.totalLines
        self.outcomes = Self.merge(memory: memory, persisted: persisted.outcomes)
        self.lastRefresh = Date()
    }

    func clearLog() async {
        await ContextIntentResolverOutcomeLog.shared.clear()
        await refresh()
    }

    var summary: Summary {
        let total = outcomes.count
        let fallback = outcomes.filter { $0.intent.usedFallback }.count
        let success = total - fallback
        let avg = total == 0 ? 0 : outcomes.reduce(0) { $0 + $1.intent.resolverLatencyMs } / total
        return Summary(total: total, success: success, fallback: fallback, avgLatencyMs: avg)
    }

    private static func merge(
        memory: [ContextIntentResolverOutcomeLog.Outcome],
        persisted: [ContextIntentResolverOutcomeLog.Outcome]
    ) -> [ContextIntentResolverOutcomeLog.Outcome] {
        var seen = Set<String>()
        var combined: [ContextIntentResolverOutcomeLog.Outcome] = []
        for o in memory + persisted {
            let key = "\(o.recordedAt.timeIntervalSince1970)|\(o.transcript)"
            if seen.insert(key).inserted {
                combined.append(o)
            }
        }
        return combined.sorted { $0.recordedAt > $1.recordedAt }
    }

    private struct PersistedLoad {
        let outcomes: [ContextIntentResolverOutcomeLog.Outcome]
        let totalLines: Int
    }

    private static func loadPersisted(from url: URL, limit: Int) async -> PersistedLoad {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                return PersistedLoad(outcomes: [], totalLines: 0)
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let totalLines = lines.count
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let tail = lines.suffix(limit)
            let decoded: [ContextIntentResolverOutcomeLog.Outcome] = tail.compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(ContextIntentResolverOutcomeLog.Outcome.self, from: lineData)
            }
            return PersistedLoad(outcomes: decoded, totalLines: totalLines)
        }.value
    }
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
