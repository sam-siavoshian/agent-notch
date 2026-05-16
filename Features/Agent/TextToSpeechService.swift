//
//  TextToSpeechService.swift
//  Agent in the Notch
//

import AVFoundation

@MainActor
final class TextToSpeechService {
    static let shared = TextToSpeechService()
    private let synthesizer = AVSpeechSynthesizer()
    private init() {}

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
