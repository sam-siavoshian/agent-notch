//
//  VoiceRecordingService.swift
//  Agent in the Notch
//
//  Handles the full voice pipeline: record on longPressBegan, transcribe on
//  longPressEnded via OpenAI Whisper API, write result to AgentState.lastTranscript,
//  then post .transcriptReady for AgentSession to consume.
//
//  Demo mode: if ANTHROPIC_NOTCH_DEMO_PROMPT is set and no recording happened,
//  the env var is used as the transcript so the end-to-end loop works without
//  a microphone.
//

import AVFoundation
import Foundation

private let log = Log(category: "voice")

@MainActor
public final class VoiceRecordingService {
    public static let shared = VoiceRecordingService()

    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    private var beganObserver: NSObjectProtocol?
    private var endedObserver: NSObjectProtocol?

    private init() {}

    public func start() {
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
        log.info("voice.ready mic_authorized=\(micStatus == .authorized)")
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

    private func startRecording() async {
        guard !audioEngine.isRunning else { return }

        AgentState.shared.set(.listening, detail: "Listening…")
        AgentState.shared.lastTranscript = ""

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch_voice_\(Date().timeIntervalSince1970).wav")
        recordingURL = url

        let inputNode = audioEngine.inputNode
        // Bind to user-selected input device (nil = system default).
        let uid = AgentSettingsStore.shared.voiceInputDeviceUID
        AudioDeviceManager.setInputDevice(uid: uid, on: audioEngine)
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
        do {
            transcript = try await transcribeWithOpenAI(audioURL: url)
        } catch {
            log.error("transcription failed: \(error)")
            transcriptError = error
        }

        try? FileManager.default.removeItem(at: url)

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

    private func transcribeWithOpenAI(audioURL: URL) async throws -> String {
        guard let apiKey = Secrets.openAIAPIKey else {
            throw TranscriptionError.missingAPIKey
        }

        let audioData = try Data(contentsOf: audioURL)
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("en\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
        body.append("Computer command for a Mac agent. App names, URLs, system actions.\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            log.error("openai whisper status=\(http.statusCode) body=\(responseBody)")
            throw TranscriptionError.httpError(http.statusCode)
        }

        struct WhisperResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum TranscriptionError: Error {
        case missingAPIKey
        case invalidResponse
        case httpError(Int)
    }
}
