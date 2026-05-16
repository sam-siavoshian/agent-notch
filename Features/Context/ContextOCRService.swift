//
//  ContextOCRService.swift
//  Agent in the Notch
//
//  On-device text recognition for screenshot-driven UI memory. This gives the
//  agent visible labels/entities without waiting on a network VLM call.
//

import Foundation
import ImageIO
import Vision

public actor ContextOCRService {
    public static let shared = ContextOCRService()

    public init() {}

    public func recognizeText(in jpegData: Data, maxResults: Int = 80) async -> [ContextRecognizedText] {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("[ContextOCRService] OCR failed: \(error)")
            return []
        }

        return (request.results ?? [])
            .prefix(maxResults)
            .compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let box = observation.boundingBox
                return ContextRecognizedText(
                    text: text,
                    confidence: candidate.confidence,
                    x: box.origin.x,
                    y: box.origin.y,
                    width: box.width,
                    height: box.height
                )
            }
    }
}
