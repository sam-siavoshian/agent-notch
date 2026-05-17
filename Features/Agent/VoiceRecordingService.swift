//
//  VoiceRecordingService.swift
//  Agent in the Notch
//
//  Handles the full voice pipeline: record on longPressBegan, transcribe on
//  longPressEnded, write result to AgentState.lastTranscript, then post
//  .transcriptReady for AgentSession to consume.
//
//  WhisperKit (openai/whisper-tiny) runs on-device via Core ML. The model
//  downloads once (~75 MB) to the system cache on first launch.
//
//  Demo mode: if ANTHROPIC_NOTCH_DEMO_PROMPT is set and no recording happened
//  (or Whisper is still initializing), the env var is used as the transcript
//  so the end-to-end loop works without a microphone.
//

import AVFoundation
import WhisperKit

private let log = Log(category: "voice")

@MainActor
public final class VoiceRecordingService {
    public static let shared = VoiceRecordingService()

    private var whisper: WhisperKit?
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    private var beganObserver: NSObjectProtocol?
    private var endedObserver: NSObjectProtocol?

    private init() {}

    public func start() {
        Task { await initWhisper() }
        Task.detached {
            let tmp = FileManager.default.temporaryDirectory
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
            for name in files where name.hasPrefix("agentnotch_voice_") {
                try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
            }
        }

        beganObserver = NotificationCenter.default.addObserver(
            forName: .longPressBegan,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.startRecording() }
        }

        endedObserver = NotificationCenter.default.addObserver(
            forName: .longPressEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.stopAndTranscribe() }
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log.info("voice.ready mic_authorized=\(micStatus == .authorized) whisper_loading=true")
    }

    public func stop() {
        if let beganObserver { NotificationCenter.default.removeObserver(beganObserver) }
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
        beganObserver = nil
        endedObserver = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    // MARK: - Private

    private func initWhisper() async {
        // Model names follow argmaxinc/whisperkit-coreml folder paths
        // (e.g. "openai_whisper-tiny"), not the OpenAI repo slugs.
        let modelName = "openai_whisper-tiny"
        do {
            whisper = try await WhisperKit(model: modelName)
            log.info("voice.whisper_ready model=\(modelName)")
        } catch {
            log.error("voice.whisper_failed model=\(modelName) error=\(error)")
        }
    }

    private func startRecording() async {
        guard !audioEngine.isRunning else { return }

        AgentState.shared.set(.listening, detail: "Listening…")
        AgentState.shared.lastTranscript = ""

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch_voice_\(Date().timeIntervalSince1970).wav")
        recordingURL = url

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
            audioFile = file
        } catch {
            log.error("failed to create audio file: \(error)")
            AgentState.shared.set(.idle)
            return
        }

        // Capture `file` by value so the tap closure holds its own strong
        // reference independent of self.audioFile (which gets nilled on stop).
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? file.write(from: buffer)
        }

        do {
            try audioEngine.start()
        } catch {
            log.error("AVAudioEngine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            audioFile = nil
            recordingURL = nil
            AgentState.shared.set(.idle)
        }
    }

    private func stopAndTranscribe() async {
        let demoPrompt = Env.value("ANTHROPIC_NOTCH_DEMO_PROMPT") ?? ""

        // No recording in progress — demo mode only path
        if !audioEngine.isRunning {
            guard !demoPrompt.isEmpty else { return }
            AgentState.shared.lastTranscript = demoPrompt
            NotificationCenter.default.post(name: .transcriptReady, object: nil)
            return
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioFile = nil

        guard let url = recordingURL else {
            AgentState.shared.set(.idle)
            return
        }
        recordingURL = nil

        AgentState.shared.set(.listening, detail: "Transcribing…")

        var transcript = ""
        var transcriptError: Error? = nil
        if let whisper {
            do {
                let results = try await whisper.transcribe(audioPath: url.path)
                transcript = results.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                log.error("transcription failed: \(error)")
                transcriptError = error
            }
        }

        try? FileManager.default.removeItem(at: url)

        // Fall back to demo prompt if Whisper produced nothing
        if transcript.isEmpty { transcript = demoPrompt }

        guard !transcript.isEmpty else {
            log.warning("no transcript — agent not fired")
            let msg = transcriptError != nil ? "Transcription error — try again" : "Nothing captured — try speaking again"
            AgentState.shared.set(.error(message: msg))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                AgentState.shared.set(.idle)
            }
            return
        }

        AgentState.shared.lastTranscript = transcript
        NotificationCenter.default.post(name: .transcriptReady, object: nil)
    }
}
