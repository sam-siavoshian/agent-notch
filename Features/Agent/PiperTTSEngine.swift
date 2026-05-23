//
//  PiperTTSEngine.swift
//  Agent in the Notch
//
//  Local Piper-based TTS. Long-lived `piper` subprocess synthesises raw s16le
//  mono PCM at 22.05 kHz directly to stdout. We pipe that into an
//  AVAudioEngine player node so the first audio plays the moment Piper emits
//  the first chunk — no per-utterance cold start.
//
//  Selected by `AgentSettingsStore.ttsVoice == .jarvis`.
//
//  Requirements on the host machine:
//    - `piper` CLI (e.g. `pip3 install piper-tts`)
//    - Voice model at `~/jarvis-voice/voices/jarvis-high.onnx` (+ `.json`)
//
//  If either is missing, `speak()` no-ops and logs once; the harness falls
//  through silently so the agent run isn't blocked.
//

import AVFoundation
import Foundation

private let log = Log(category: "tts.piper")

/// Piper voice model output: 22050 Hz mono s16le PCM. Pinned in code because
/// the upstream model card declares the same rate; if a user swaps in a
/// different voice file with a different rate, audio will pitch-shift until
/// they edit this constant.
private let piperSampleRate: Double = 22_050

@MainActor
final class PiperTTSEngine {
    static let shared = PiperTTSEngine()

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let pcmFormat: AVAudioFormat = {
        // swiftlint:disable:next force_unwrapping — sample rate + channels are valid
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: piperSampleRate,
                      channels: 1,
                      interleaved: false)!
    }()

    private var proc: Process?
    private var inPipe: Pipe?
    private var boundOutputUID: String?
    private var warnedMissing = false

    private init() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: pcmFormat)
        applyOutputDeviceIfChanged()
    }

    // MARK: - Public

    /// Spawn the piper subprocess eagerly so the first real `speak()` call
    /// doesn't pay the ~500ms-1s python+model load. Safe to call multiple
    /// times — no-op when already alive. Called from `AppDelegate.bootAgent`
    /// and on any settings flip to the JARVIS voice.
    func warmup() {
        _ = ensureSpawned()
        do { if !audioEngine.isRunning { try audioEngine.start() } } catch {
            log.error("piper.audio_start_failed_during_warmup error=\(error)")
        }
    }

    /// Speak a sentence. Spawns Piper on first call. Subsequent calls reuse
    /// the live subprocess so latency stays low.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard ensureSpawned() else { return }
        applyOutputDeviceIfChanged()
        do {
            if !audioEngine.isRunning { try audioEngine.start() }
        } catch {
            log.error("piper.audio_start_failed error=\(error)")
            return
        }
        if !playerNode.isPlaying { playerNode.play() }

        guard let inPipe else { return }
        guard let payload = (trimmed + "\n").data(using: .utf8) else { return }
        do {
            try inPipe.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            // Pipe broken (subprocess died). Respawn and retry once.
            log.warning("piper.write_failed error=\(error) respawning")
            shutdown()
            guard ensureSpawned(), let retryPipe = self.inPipe else { return }
            try? retryPipe.fileHandleForWriting.write(contentsOf: payload)
        }
    }

    /// Stop in-flight playback + drop the queued PCM. Subprocess is kept alive
    /// for the next utterance.
    func stop() {
        if playerNode.isPlaying { playerNode.stop() }
    }

    /// Hard kill. Used on app shutdown or kill-switch.
    func shutdown() {
        proc?.terminate()
        proc = nil
        inPipe = nil
        if playerNode.isPlaying { playerNode.stop() }
    }

    /// True when both the piper binary and the voice model exist. Settings
    /// UI uses this to flag a warning when the user picks JARVIS without the
    /// prerequisites installed.
    static func isAvailable() -> Bool {
        resolveBinary() != nil && FileManager.default.isReadableFile(atPath: modelPath().path)
    }

    // MARK: - Subprocess lifecycle

    private func ensureSpawned() -> Bool {
        if let proc, proc.isRunning { return true }
        proc = nil
        inPipe = nil

        guard let binary = Self.resolveBinary() else {
            if !warnedMissing {
                warnedMissing = true
                log.warning("piper.binary_missing — install via `pip3 install piper-tts` or set PATH")
            }
            return false
        }
        let model = Self.modelPath()
        guard FileManager.default.isReadableFile(atPath: model.path) else {
            if !warnedMissing {
                warnedMissing = true
                log.warning("piper.model_missing path=\(model.path)")
            }
            return false
        }

        let p = Process()
        p.executableURL = binary
        p.arguments = [
            "-m", model.path,
            "--output-raw",
            "--sentence-silence", "0.15"
        ]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.enqueuePCM(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.contains("real-time factor") { return }
            log.warning("piper.stderr \(line.prefix(200))")
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.proc = nil
                self?.inPipe = nil
            }
        }

        do {
            try p.run()
            self.proc = p
            self.inPipe = stdin
            log.info("piper.spawn pid=\(p.processIdentifier) model=\(model.lastPathComponent)")
            return true
        } catch {
            log.error("piper.spawn_failed error=\(error)")
            return false
        }
    }

    private func enqueuePCM(_ data: Data) {
        let sampleCount = data.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                            frameCapacity: AVAudioFrameCount(sampleCount))
        else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let dst = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                dst[i] = Float(samples[i]) / 32_768.0
            }
        }
        playerNode.scheduleBuffer(buffer)
    }

    private func applyOutputDeviceIfChanged() {
        let target = AgentSettingsStore.shared.voiceOutputDeviceUID
        if target == boundOutputUID { return }
        let wasRunning = audioEngine.isRunning
        if wasRunning { audioEngine.stop() }
        AudioDeviceManager.setOutputDevice(uid: target, on: audioEngine)
        boundOutputUID = target
        if wasRunning { try? audioEngine.start() }
    }

    // MARK: - Path resolution

    /// Standard locations the piper CLI lands in across pip / homebrew /
    /// pyenv installs. First match wins.
    private static func resolveBinary() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/piper"),
            URL(fileURLWithPath: "/usr/local/bin/piper")
        ]
        // Pip user-site installs under ~/Library/Python/<version>/bin
        let pythonRoot = home.appendingPathComponent("Library/Python", isDirectory: true)
        if let versions = try? fm.contentsOfDirectory(atPath: pythonRoot.path) {
            for v in versions {
                candidates.append(pythonRoot.appendingPathComponent("\(v)/bin/piper"))
            }
        }
        candidates.append(home.appendingPathComponent(".local/bin/piper"))
        candidates.append(home.appendingPathComponent(".pyenv/shims/piper"))
        return candidates.first(where: { fm.isExecutableFile(atPath: $0.path) })
    }

    private static func modelPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("jarvis-voice/voices/jarvis-high.onnx")
    }
}
