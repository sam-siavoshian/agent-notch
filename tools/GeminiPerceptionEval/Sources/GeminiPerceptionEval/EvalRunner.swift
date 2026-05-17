import Foundation

/// Discovers fixtures, runs each (fixture × variant) cell, scores, renders markdown.
public final class EvalRunner {

    public struct Fixture {
        public let name: String
        public let pngURL: URL
        public let expected: ExpectedFixture
    }

    public let fixturesDir: URL
    public let variants: [GeminiClient.Variant]
    public let client: GeminiClient?     // nil = dry mode

    public init(fixturesDir: URL, variants: [GeminiClient.Variant], client: GeminiClient?) {
        self.fixturesDir = fixturesDir
        self.variants = variants
        self.client = client
    }

    /// Walk `fixturesDir` for `*.png` with a matching `*.expected.json` sidecar.
    public func discoverFixtures() throws -> [Fixture] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [Fixture] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.pathExtension.lowercased() == "png" else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let sidecar = url.deletingLastPathComponent().appendingPathComponent("\(stem).expected.json")
            guard fm.fileExists(atPath: sidecar.path) else { continue }
            let data = try Data(contentsOf: sidecar)
            let expected = try JSONDecoder().decode(ExpectedFixture.self, from: data)
            out.append(Fixture(name: stem, pngURL: url, expected: expected))
        }
        return out
    }

    /// Dry-run path: print the prompt and request body for each fixture × variant.
    /// Used when GEMINI_API_KEY is missing. No network. No scoring.
    public func runDry(out: inout String) throws {
        let fixtures = try discoverFixtures()
        if fixtures.isEmpty {
            out += "(no fixtures with paired *.expected.json found in \(fixturesDir.path))\n\n"
        }
        let prompt = ObservationPrompt.prompt(frontmostHint: nil)
        out += "## Prompt\n\n"
        out += "```\n\(prompt)\n```\n\n"

        // If we have no fixtures, still demonstrate the variant request bodies
        // by using a 1x1 transparent PNG so reviewers can sanity-check shape.
        let pngs: [(String, Data)] = fixtures.isEmpty
            ? [("<placeholder 1x1 png>", Self.minimalPNG())]
            : fixtures.map { ($0.name, (try? Data(contentsOf: $0.pngURL)) ?? Data()) }

        for (name, png) in pngs {
            for v in variants {
                out += "### Fixture `\(name)` · Variant `\(v.name)`\n\n"
                let body = try GeminiClient.encodeBody(prompt: prompt, imagePNG: png, variant: v)
                // Redact the inline_data.data base64 to keep the body readable —
                // reviewers care about config keys, not megabytes of base64.
                let redacted = Self.redactInlineData(body)
                out += "```json\n\(redacted)\n```\n\n"
            }
        }
    }

    /// Live path: call Gemini, score, render markdown to `out`.
    public func runLive(out: inout String) async throws {
        guard let client = client else {
            throw NSError(domain: "EvalRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "runLive called without a client"])
        }
        let fixtures = try discoverFixtures()
        if fixtures.isEmpty {
            out += "(no fixtures with paired *.expected.json found in \(fixturesDir.path))\n"
            return
        }

        var rows: [ScoreRow] = []
        for fx in fixtures {
            out += "## Fixture `\(fx.name)`\n\n"
            out += "Expected surface: `\(fx.expected.expectedSurface)`  ·  Expected controls: \(fx.expected.expectedControls.count)\n\n"
            out += "| Variant | Surface | Recall | Precision | Latency (s) | Error |\n"
            out += "|---|---:|---:|---:|---:|---|\n"
            let png = try Data(contentsOf: fx.pngURL)
            for v in variants {
                let started = Date()
                do {
                    let prompt = ObservationPrompt.prompt(frontmostHint: nil)
                    let raw = try await client.generate(prompt: prompt, imagePNG: png, variant: v)
                    let latency = Date().timeIntervalSince(started)
                    guard let data = raw.data(using: .utf8),
                          let observed = try? JSONDecoder().decode(ObservedFixture.self, from: data) else {
                        let row = ScoreRow(fixture: fx.name, variant: v.name, surfaceMatch: 0, controlRecall: 0, controlPrecision: 0, latencyS: latency, error: "parse-failed")
                        rows.append(row)
                        out += renderRow(row)
                        continue
                    }
                    let s = Scorer.score(expected: fx.expected, observed: observed)
                    let row = ScoreRow(fixture: fx.name, variant: v.name, surfaceMatch: s.surface, controlRecall: s.recall, controlPrecision: s.precision, latencyS: latency)
                    rows.append(row)
                    out += renderRow(row)
                } catch {
                    let latency = Date().timeIntervalSince(started)
                    let row = ScoreRow(fixture: fx.name, variant: v.name, surfaceMatch: 0, controlRecall: 0, controlPrecision: 0, latencyS: latency, error: String(describing: error))
                    rows.append(row)
                    out += renderRow(row)
                }
            }
            out += "\n"
        }

        out += "## Aggregate (per variant)\n\n"
        out += "| Variant | Mean Surface | Mean Recall | Mean Precision | Mean Latency (s) | p95 Latency (s) | Errors |\n"
        out += "|---|---:|---:|---:|---:|---:|---:|\n"
        for v in variants {
            let vrows = rows.filter { $0.variant == v.name }
            guard !vrows.isEmpty else { continue }
            let meanSurface = mean(vrows.map(\.surfaceMatch))
            let meanRecall = mean(vrows.map(\.controlRecall))
            let meanPrecision = mean(vrows.map(\.controlPrecision))
            let meanLat = mean(vrows.map(\.latencyS))
            let p95Lat = percentile(vrows.map(\.latencyS), p: 0.95)
            let errs = vrows.filter { $0.error != nil }.count
            out += "| \(v.name) | \(fmt(meanSurface)) | \(fmt(meanRecall)) | \(fmt(meanPrecision)) | \(fmt(meanLat)) | \(fmt(p95Lat)) | \(errs) |\n"
        }
    }

    // MARK: - helpers

    private func renderRow(_ r: ScoreRow) -> String {
        "| \(r.variant) | \(fmt(r.surfaceMatch)) | \(fmt(r.controlRecall)) | \(fmt(r.controlPrecision)) | \(fmt(r.latencyS)) | \(r.error ?? "") |\n"
    }

    private func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    private func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    private func percentile(_ xs: [Double], p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    /// Replace the giant base64 payload in the encoded body with a marker so
    /// dry-mode output stays scannable. Operates on the JSON string form.
    private static func redactInlineData(_ data: Data) -> String {
        guard let str = String(data: data, encoding: .utf8) else { return "<unreadable>" }
        // The encoder uses sortedKeys → `data` is the field name inside inline_data.
        // Replace the value with a marker. Be conservative: only redact long values.
        var out = ""
        var inData = false
        var buffer = ""
        var i = str.startIndex
        while i < str.endIndex {
            let ch = str[i]
            buffer.append(ch)
            if !inData, buffer.hasSuffix("\"data\" : \"") {
                inData = true
                out += buffer
                buffer = ""
                // skip to next unescaped quote
                i = str.index(after: i)
                while i < str.endIndex, str[i] != "\"" {
                    i = str.index(after: i)
                }
                out += "<base64 png redacted>"
                if i < str.endIndex { out.append(str[i]) }
                inData = false
                if i < str.endIndex { i = str.index(after: i) }
                continue
            }
            i = str.index(after: i)
        }
        out += buffer
        return out
    }

    /// 1x1 transparent PNG bytes — used in dry mode when no fixtures present.
    private static func minimalPNG() -> Data {
        // Smallest valid PNG: 1x1 RGBA fully transparent.
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        return Data(base64Encoded: b64) ?? Data()
    }
}
