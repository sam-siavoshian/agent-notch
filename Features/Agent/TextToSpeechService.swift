//
//  TextToSpeechService.swift
//  Agent in the Notch
//
//  Streams raw PCM16 from OpenAI TTS via chunked HTTP transfer, feeding
//  AVAudioPlayerNode as bytes arrive. First audio plays in ~100ms instead
//  of waiting for the full file to download.
//
//  Endpoint: POST /v1/audio/speech with response_format=pcm
//  Output:   24 kHz · mono · PCM16 little-endian → converted to Float32 for AVAudioEngine.
//

import AVFoundation
import Foundation

@MainActor
final class TextToSpeechService {
    static let shared = TextToSpeechService()

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    // PCM16 24 kHz mono — matches OpenAI TTS raw PCM output
    private let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000, channels: 1, interleaved: false
    )!
    private var currentTask: Task<Void, Never>?

    private init() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: pcmFormat)
        try? audioEngine.start()
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentTask?.cancel()
        playerNode.stop()
        currentTask = Task { [weak self] in
            await self?.stream(trimmed)
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        playerNode.stop()
    }

    // MARK: - Streaming

    private func stream(_ text: String) async {
        guard let apiKey = Secrets.openAIAPIKey else { return }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let voice = AgentSettingsStore.shared.settings.ttsVoice.rawValue
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "tts-1",
            "input": text,
            "voice": voice,
            "response_format": "pcm"   // raw PCM16 — no container, directly streamable
        ])

        do {
            if !audioEngine.isRunning { try audioEngine.start() }
            let (byteStream, response) = try await URLSession.shared.bytes(for: request)

            // Bail on non-2xx so we don't try to decode an error JSON as audio.
            if let http = response as? HTTPURLResponse, http.statusCode >= 300 { return }
            guard !Task.isCancelled else { return }

            playerNode.play()

            // 100 ms of PCM16 at 24 kHz = 2400 samples × 2 bytes = 4800 bytes.
            // Smaller → lower latency to first sound. Larger → fewer schedule calls.
            let chunkBytes = 4_800
            var accumulator = Data()
            accumulator.reserveCapacity(chunkBytes)

            for try await byte in byteStream {
                if Task.isCancelled { return }
                accumulator.append(byte)
                if accumulator.count >= chunkBytes {
                    scheduleChunk(accumulator)
                    accumulator.removeAll(keepingCapacity: true)
                }
            }
            if !accumulator.isEmpty { scheduleChunk(accumulator) }
        } catch {
            // TTS failure is non-fatal — agent continues without voice.
        }
    }

    // Convert a block of raw PCM16 LE bytes → Float32 AVAudioPCMBuffer and
    // hand it to the player node. Buffers are gaplessly concatenated by AVAudioEngine.
    private func scheduleChunk(_ data: Data) {
        let sampleCount = data.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(sampleCount))
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
}
