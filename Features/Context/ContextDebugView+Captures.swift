import SwiftUI
import AppKit

extension ContextDebugView {
    var capturesPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent captures · \(snapshots.count)")
                    .font(.headline)

                if snapshots.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No captures yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ForEach(Array(snapshots.reversed()), id: \.id) { snapshot in
                        captureCard(snapshot)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func captureCard(_ snapshot: ContextSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            snapshotThumbnail(snapshot, maxWidth: 320, maxHeight: 200)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot.appName.isEmpty ? "Unknown app" : snapshot.appName)
                        .font(.system(size: 13, weight: .semibold))
                    triggerBadge(snapshot.trigger)
                }
                Text(snapshot.windowTitle.isEmpty ? "Untitled window" : snapshot.windowTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(ContextDebugFormat.relativeTimestamp(snapshot.capturedAt)) · \(ContextDebugFormat.absoluteTimestamp(snapshot.capturedAt))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("\(snapshot.width)×\(snapshot.height) · \(snapshot.recognizedText.count) OCR items")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if let cursor = snapshot.cursorLocation {
                    Text("Cursor: x=\(Int(cursor.x)), y=\(Int(cursor.y))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if !snapshot.recognizedText.isEmpty {
                    Text(Self.ocrPreview(snapshot.recognizedText))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func triggerBadge(_ trigger: ContextCaptureTrigger) -> some View {
        Text(trigger.rawValue)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Self.triggerColor(trigger).opacity(0.18))
            )
            .foregroundStyle(Self.triggerColor(trigger))
    }

    private static func triggerColor(_ trigger: ContextCaptureTrigger) -> Color {
        switch trigger {
        case .startup:   return .blue
        case .click:     return .purple
        case .activation:return .green
        case .manual:    return .orange
        case .appSwitch: return .pink
        }
    }

    private static func ocrPreview(_ items: [ContextRecognizedText]) -> String {
        let joined = items.map { $0.text }.joined(separator: " | ")
        if joined.count <= 200 { return joined }
        let idx = joined.index(joined.startIndex, offsetBy: 200)
        return String(joined[..<idx]) + "…"
    }

    private func snapshotThumbnail(_ snapshot: ContextSnapshot, maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        Group {
            if let image = NSImage(data: snapshot.jpegData) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .overlay(Text("No image").font(.caption).foregroundStyle(.secondary))
            }
        }
    }
}
