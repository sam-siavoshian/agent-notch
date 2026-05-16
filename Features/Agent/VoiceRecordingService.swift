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
        do {
            whisper = try await WhisperKit(model: "openai/whisper-tiny")
            NSLog("[VoiceRecordingService] WhisperKit ready (whisper-tiny)")
        } catch {
            NSLog("[VoiceRecordingService] WhisperKit init failed: \(error)")
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

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            NSLog("[VoiceRecordingService] Failed to create audio file: \(error)")
            AgentState.shared.set(.idle)
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.audioFile?.write(from: buffer)
        }

        do {
            try audioEngine.start()
        } catch {
            NSLog("[VoiceRecordingService] AVAudioEngine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            audioFile = nil
            recordingURL = nil
            AgentState.shared.set(.idle)
        }
    }

    private func stopAndTranscribe() async {
        let demoPrompt = ProcessInfo.processInfo.environment["ANTHROPIC_NOTCH_DEMO_PROMPT"] ?? ""

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
        if let whisper {
            do {
                let results = try await whisper.transcribe(audioPath: url.path)
                transcript = results.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                NSLog("[VoiceRecordingService] Transcription failed: \(error)")
            }
        }

        try? FileManager.default.removeItem(at: url)

        // Fall back to demo prompt if Whisper produced nothing
        if transcript.isEmpty { transcript = demoPrompt }

        guard !transcript.isEmpty else {
            NSLog("[VoiceRecordingService] No transcript — agent not fired.")
            AgentState.shared.set(.idle)
            return
        }

        AgentState.shared.lastTranscript = transcript
        NotificationCenter.default.post(name: .transcriptReady, object: nil)
    }
}
