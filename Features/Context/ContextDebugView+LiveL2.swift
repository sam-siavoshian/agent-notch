import SwiftUI
import AppKit

/// Live preview of what L2Snapshotter is extracting from the current frontmost
/// window. Polls every 2s. Useful for verifying "is the system actually
/// surfacing useful actionable info from the screen?" without long-pressing.
public struct ContextDebugLiveL2View: View {

    @State private var snapshot: CL2Snapshot?
    @State private var screenshotJPEG: Data?
    @State private var lastCaptureAt: Date?
    @State private var captureLatencyMS: Int = 0
    @State private var timer: Timer?
    @State private var isCapturing = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerRow
                Divider()
                if let snap = snapshot {
                    screenSection(snap)
                    Divider()
                    clickableSection(snap)
                    Divider()
                    passiveSection(snap)
                    Divider()
                    ocrSection(snap)
                    Divider()
                    selectionAndClipboardSection(snap)
                    Divider()
                    appSpecificSection(snap)
                } else {
                    Text("Capturing first snapshot…")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .padding(16)
            .font(.system(size: 12, design: .monospaced))
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("Live L2 Preview").font(.system(size: 14, weight: .semibold))
            Spacer()
            if let t = lastCaptureAt {
                Text("captured \(t.formatted(.dateTime.hour().minute().second())) · \(captureLatencyMS)ms")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Button("Capture now") { Task { await captureNow() } }
                .disabled(isCapturing)
        }
    }

    private func screenSection(_ snap: CL2Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Frontmost").font(.system(size: 12, weight: .semibold))
            Text("\(snap.app) — \(snap.windowTitle ?? "(no window title)")").font(.system(size: 11))
            Text("bundle: \(snap.bundleID) · pid: \(snap.pid) · display: \(snap.displayID)").font(.system(size: 10)).foregroundColor(.secondary)
            if let jpeg = screenshotJPEG, let nsImage = NSImage(data: jpeg) {
                Image(nsImage: nsImage)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .cornerRadius(4)
            }
        }
    }

    private func clickableSection(_ snap: CL2Snapshot) -> some View {
        let clickableRoles: Set<String> = ["AXButton", "AXMenuItem", "AXMenuButton", "AXLink", "AXRadioButton", "AXCheckBox", "AXTab", "AXPopUpButton", "AXComboBox", "AXTextField", "AXTextArea", "AXSearchField"]
        let clickables = snap.axElements.filter { clickableRoles.contains($0.role) }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Clickable elements (\(clickables.count))").font(.system(size: 12, weight: .semibold))
            if clickables.isEmpty {
                Text("<none — extraction may not be finding any actionable controls>").foregroundColor(.orange).font(.system(size: 11))
            } else {
                ForEach(0..<clickables.count, id: \.self) { i in
                    let el = clickables[i]
                    HStack(spacing: 8) {
                        Text(el.role).foregroundColor(.blue).frame(width: 100, alignment: .leading)
                        Text(el.label ?? "<no label>").lineLimit(1)
                        Spacer()
                        if el.focused { Text("⌖ focused").foregroundColor(.green).font(.system(size: 10)) }
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    private func passiveSection(_ snap: CL2Snapshot) -> some View {
        let clickableRoles: Set<String> = ["AXButton", "AXMenuItem", "AXMenuButton", "AXLink", "AXRadioButton", "AXCheckBox", "AXTab", "AXPopUpButton", "AXComboBox", "AXTextField", "AXTextArea", "AXSearchField"]
        let passive = snap.axElements.filter { !clickableRoles.contains($0.role) }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Passive elements (\(passive.count))").font(.system(size: 12, weight: .semibold))
            ForEach(0..<min(passive.count, 15), id: \.self) { i in
                let el = passive[i]
                HStack(spacing: 8) {
                    Text(el.role).foregroundColor(.gray).frame(width: 100, alignment: .leading)
                    Text(el.label ?? "?").lineLimit(1).foregroundColor(.secondary)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            if passive.count > 15 {
                Text("… +\(passive.count - 15) more").foregroundColor(.secondary).font(.system(size: 10))
            }
        }
    }

    private func ocrSection(_ snap: CL2Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OCR text lines (\(snap.ocrLines.count))").font(.system(size: 12, weight: .semibold))
            if snap.ocrLines.isEmpty {
                Text("<no OCR yet — first capture is slow>").foregroundColor(.orange).font(.system(size: 11))
            } else {
                ForEach(0..<min(snap.ocrLines.count, 20), id: \.self) { i in
                    Text("• \(snap.ocrLines[i])").font(.system(size: 11)).lineLimit(1)
                }
                if snap.ocrLines.count > 20 {
                    Text("… +\(snap.ocrLines.count - 20) more").foregroundColor(.secondary).font(.system(size: 10))
                }
            }
        }
    }

    private func selectionAndClipboardSection(_ snap: CL2Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Selection + Clipboard").font(.system(size: 12, weight: .semibold))
            if let sel = snap.selection, !sel.isEmpty {
                Text("selection: \(sel.prefix(160))").font(.system(size: 11))
            } else {
                Text("selection: <none>").foregroundColor(.secondary).font(.system(size: 11))
            }
            if let cb = snap.clipboard {
                Text("clipboard \(cb.kind) (\(cb.bytes)B, age \(Int(cb.ageS))s\(cb.sourceApp.map { ", from \($0)" } ?? "")):")
                    .font(.system(size: 11))
                Text((cb.preview ?? "<no preview>").prefix(200))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            } else {
                Text("clipboard: <empty>").foregroundColor(.secondary).font(.system(size: 11))
            }
        }
    }

    private func appSpecificSection(_ snap: CL2Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("App-specific (from registered adapter)").font(.system(size: 12, weight: .semibold))
            if let blob = snap.appSpecific, !blob.isEmpty {
                ForEach(blob.keys.sorted(), id: \.self) { k in
                    Text("\(k): \(String(describing: blob[k]?.value).prefix(160))")
                        .font(.system(size: 11))
                }
            } else {
                Text("<no adapter for \(snap.bundleID) — or adapter returned empty>")
                    .foregroundColor(.orange).font(.system(size: 11))
            }
        }
    }

    private func start() {
        Task { await captureNow() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { await captureNow() }
        }
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func captureNow() async {
        guard !isCapturing else { return }
        isCapturing = true
        let start = Date()
        let result = await L2Snapshotter.snapshot(overallDeadline: 0.5)
        let latency = Int((Date().timeIntervalSince(start)) * 1000)
        await MainActor.run {
            snapshot = result.l2
            screenshotJPEG = result.screenshotJPEG
            lastCaptureAt = Date()
            captureLatencyMS = latency
            isCapturing = false
        }
    }
}
