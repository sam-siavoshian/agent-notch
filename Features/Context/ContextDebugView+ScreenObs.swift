import SwiftUI

/// Dev Tools pane: live stream of the most recent `SurfaceObservation`s
/// produced by `GeminiObserver`. Polls `ScreenObservationLog.shared.tail(20)`
/// every 2s. Each row expands to show the full structured observation as
/// pretty-printed JSON.
public struct ContextDebugScreenObsView: View {
    @State private var observations: [SurfaceObservation] = []
    @State private var lastRefreshed: Date = .distantPast
    @State private var expanded: Set<UUID> = []
    @State private var timer: Timer?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                Divider()
                if observations.isEmpty {
                    Text("<no screen observations yet — GeminiObserver fires on major-change captures; gated on GEMINI_API_KEY + settings toggle, throttled to >=8s>")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                        .padding(.vertical, 8)
                } else {
                    ForEach(observations.reversed(), id: \.id) { obs in
                        row(obs)
                        Divider()
                    }
                }
            }
            .padding(16)
            .font(.system(size: 12, design: .monospaced))
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("Screen Observations").font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("\(observations.count) recent · refreshed \(timeString)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var timeString: String {
        guard lastRefreshed > .distantPast else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: lastRefreshed)
    }

    private func row(_ obs: SurfaceObservation) -> some View {
        let isExpanded = expanded.contains(obs.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(obs.t.formatted(.dateTime.hour().minute().second()))
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(obs.frontmostApp ?? "<unknown app>")
                    .frame(width: 120, alignment: .leading)
                    .lineLimit(1)
                Text(obs.currentSurface ?? "<no surface>")
                    .lineLimit(1)
                Spacer()
                Text("\(obs.observableControls.count) ctrls")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                Text("\(Int(obs.modelLatencyS * 1000))ms")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                Button(isExpanded ? "Hide" : "Show") {
                    if isExpanded { expanded.remove(obs.id) } else { expanded.insert(obs.id) }
                }
                .font(.system(size: 10))
            }
            .font(.system(size: 11, design: .monospaced))

            if let layout = obs.screenLayout, !layout.isEmpty {
                Text(layout)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 72)
                    .lineLimit(2)
            }

            if isExpanded {
                expandedDetail(obs)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(4)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func expandedDetail(_ obs: SurfaceObservation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // S17: Capture Story fields — surfaced at the top because they
            // describe what the USER is doing (the most useful telemetry
            // when triaging a brief).
            if let narrative = obs.narrative, !narrative.isEmpty {
                Text(narrative)
                    .font(.system(size: 11))
                    .padding(.bottom, 2)
            }
            HStack(spacing: 6) {
                if let goal = obs.currentGoalGuess, !goal.isEmpty {
                    Text("goal: \(goal)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(3)
                }
                if let ct = obs.contentType, !ct.isEmpty {
                    Text(ct)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.18))
                        .cornerRadius(3)
                }
            }
            if let link = obs.continuityLink, !link.isEmpty {
                Text(link)
                    .font(.system(size: 11).italic())
                    .foregroundColor(.secondary)
            }
            if let artifact = obs.artifact, !artifact.isEmpty {
                DisclosureGroup("artifact") {
                    Text(prettyJSONArtifact(artifact))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
                .font(.system(size: 11, weight: .semibold))
            }

            if !obs.allVisibleApps.isEmpty {
                Text("Visible apps: \(obs.allVisibleApps.joined(separator: ", "))")
                    .font(.system(size: 11))
            }
            if let state = obs.userVisibleState, !state.isEmpty {
                Text("User state: \(state)")
                    .font(.system(size: 11))
            }
            if !obs.observableControls.isEmpty {
                Text("Controls:")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.top, 2)
                ForEach(0..<obs.observableControls.count, id: \.self) { i in
                    let c = obs.observableControls[i]
                    HStack(spacing: 6) {
                        Text("•").foregroundColor(.secondary)
                        Text(c.label).font(.system(size: 11, weight: .medium))
                        if let purpose = c.purpose {
                            Text("— \(purpose)").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                        }
                        if let location = c.location {
                            Text("@ \(location)").font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if !obs.crossAppCorrelations.isEmpty {
                Text("Correlations:")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.top, 2)
                ForEach(0..<obs.crossAppCorrelations.count, id: \.self) { i in
                    Text("• \(obs.crossAppCorrelations[i])")
                        .font(.system(size: 11))
                }
            }
            Text(prettyJSON(obs))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.top, 4)
                .textSelection(.enabled)
        }
    }

    private func prettyJSON(_ obs: SurfaceObservation) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(obs),
              let s = String(data: data, encoding: .utf8) else { return "<encode failed>" }
        return s
    }

    private func prettyJSONArtifact(_ artifact: [String: AnyCodable]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(artifact),
              let s = String(data: data, encoding: .utf8) else { return "<encode failed>" }
        return s
    }

    private func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        observations = ScreenObservationLog.shared.tail(20)
        lastRefreshed = Date()
    }
}
