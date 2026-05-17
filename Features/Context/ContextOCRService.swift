//
//  ContextOCRService.swift
//  Agent in the Notch
//
//  On-device text recognition for screenshot-driven UI memory. This gives the
//  agent visible labels/entities without waiting on a network VLM call.
//

import Darwin
import Foundation
import ImageIO
import Vision

public actor ContextOCRService {
    public static let shared = ContextOCRService()

    public init() {}

    public func recognizeText(in jpegData: Data, maxResults: Int = 120) async -> [ContextRecognizedText] {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }
        return await recognizeText(in: image, maxResults: maxResults)
    }

    /// Preferred entrypoint when caller has the full-resolution CGImage. The
    /// JPEG path downsamples + compresses, which is what kills small UI text
    /// (menu bar, terminal prompts, etc). Always pass the raw CGImage when
    /// available.
    public func recognizeText(in cgImage: CGImage, maxResults: Int = 120) async -> [ContextRecognizedText] {
        let request = VNRecognizeTextRequest()
        // .accurate beats .fast by a wide margin on UI text. The latency
        // difference (~150ms vs ~30ms on a 3024×1964 screenshot) is negligible
        // for our use — we're already gated on a network Gemini call.
        request.recognitionLevel = .accurate
        // Enable Vision's spell-correction. Fixes the l↔I, 0↔O, ' ↔ ` confusions
        // that show up on small/AA-rendered text.
        request.usesLanguageCorrection = true
        // Min text size threshold ~12px (relative). Anything smaller is mostly
        // ChevronImage noise — costs cycles, produces garbage.
        request.minimumTextHeight = 0.008

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            fputs("[ERROR] [context.ocr] OCR failed: \(error)\n", Darwin.stderr)
            return []
        }

        return (request.results ?? [])
            .prefix(maxResults)
            .compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isMeaningfulText(text, confidence: candidate.confidence) else { return nil }
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

    /// Drop OCR fragments that almost certainly aren't useful text:
    ///   - <2 chars (artifacts, single punctuation)
    ///   - confidence < 0.4 (Vision's own quality signal)
    ///   - >40% non-alphanumeric (gibberish like "••O <APII")
    ///   - all-same character (e.g. "————")
    private static func isMeaningfulText(_ text: String, confidence: Float) -> Bool {
        guard text.count >= 2 else { return false }
        guard confidence >= 0.4 else { return false }

        let alnumSet = CharacterSet.alphanumerics
        let alphanumeric = text.unicodeScalars.filter { alnumSet.contains($0) }.count
        let total = text.unicodeScalars.count
        guard total > 0 else { return false }
        let alnumFraction = Double(alphanumeric) / Double(total)
        if alnumFraction < 0.6 { return false }

        // All-one-character runs (—————, ......, etc) are decoration.
        if let first = text.first, text.allSatisfy({ $0 == first }) { return false }
        return true
    }
}
