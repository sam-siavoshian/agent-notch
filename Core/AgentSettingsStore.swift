//
//  AgentSettingsStore.swift
//  Agent in the Notch
//
//  Single source of truth for agent settings. Persists to a local JSON file
//  under Application Support. Read by both the Notch UI (for editing) and the
//  Agent wiring (for inference inputs).
//

import AppKit
import Combine
import Foundation

public enum TTSVoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case alloy, echo, fable, nova, onyx, shimmer
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public struct KillSwitchShortcut: Codable, Equatable, Sendable {
    /// `NSEvent.keyCode` of the trigger key — used for matching.
    public var keyCode: UInt16
    /// Glyph captured at record time (e.g. "K", "ESC") — display only.
    public var keyLabel: String
    /// `NSEvent.ModifierFlags.deviceIndependentFlagsMask` intersection, raw value.
    public var modifiers: UInt

    public init(keyCode: UInt16, keyLabel: String, modifiers: UInt) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.modifiers = modifiers
    }

    public static let `default` = KillSwitchShortcut(
        keyCode: 0x28,                                              // kVK_ANSI_K
        keyLabel: "K",
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )

    public var displayString: String {
        let mods = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.shift)   { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s + keyLabel.uppercased()
    }
}

public struct AgentSettings: Equatable, Sendable {
    public var reasoningEffort: AgentReasoningEffort
    public var preferences: String
    public var systemPrompt: String
    public var cursorColor: CursorColor
    public var ttsVoice: TTSVoice
    public var collectionPaused: Bool
    public var neverLogApps: [String]
    public var mercuryEnabled: Bool
    /// Continuous, throttled (>=8s) background Gemini observer that watches the
    /// screen after major-change captures and accumulates per-surface UI/UX
    /// memory. Defaults on; no-ops without `GEMINI_API_KEY`.
    public var geminiObserverEnabled: Bool
    /// Global panic-button shortcut. First press soft-stops the harness;
    /// a second press within 2s SIGKILLs the app.
    public var killSwitchShortcut: KillSwitchShortcut

    public static let defaultNeverLogApps: [String] = [
        "com.1password.1password7",
        "com.1password.1password8",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.agentnotch.app",
    ]

    public static let `default` = AgentSettings(
        reasoningEffort: .medium,
        preferences: "",
        systemPrompt: "",
        cursorColor: .blue,
        ttsVoice: .nova,
        collectionPaused: false,
        neverLogApps: AgentSettings.defaultNeverLogApps,
        mercuryEnabled: true,
        geminiObserverEnabled: true,
        killSwitchShortcut: .default
    )
}

// Custom Codable so old JSON without newer fields still loads with safe defaults.
extension AgentSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case reasoningEffort, preferences, systemPrompt, cursorColor, ttsVoice
        case collectionPaused, neverLogApps, mercuryEnabled
        case geminiObserverEnabled
        case killSwitchShortcut
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reasoningEffort      = (try? c.decode(AgentReasoningEffort.self, forKey: .reasoningEffort))      ?? .medium
        preferences          = (try? c.decode(String.self,               forKey: .preferences))          ?? ""
        systemPrompt         = (try? c.decode(String.self,               forKey: .systemPrompt))         ?? ""
        cursorColor          = (try? c.decode(CursorColor.self,          forKey: .cursorColor))          ?? .blue
        ttsVoice             = (try? c.decode(TTSVoice.self,             forKey: .ttsVoice))             ?? .nova
        collectionPaused     = (try? c.decode(Bool.self,                 forKey: .collectionPaused))     ?? false
        neverLogApps         = (try? c.decode([String].self,             forKey: .neverLogApps))         ?? AgentSettings.defaultNeverLogApps
        mercuryEnabled       = (try? c.decode(Bool.self,                 forKey: .mercuryEnabled))       ?? true
        geminiObserverEnabled = (try? c.decode(Bool.self,                forKey: .geminiObserverEnabled)) ?? true
        killSwitchShortcut   = (try? c.decode(KillSwitchShortcut.self,   forKey: .killSwitchShortcut))   ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reasoningEffort,      forKey: .reasoningEffort)
        try c.encode(preferences,          forKey: .preferences)
        try c.encode(systemPrompt,         forKey: .systemPrompt)
        try c.encode(cursorColor,          forKey: .cursorColor)
        try c.encode(ttsVoice,             forKey: .ttsVoice)
        try c.encode(collectionPaused,     forKey: .collectionPaused)
        try c.encode(neverLogApps,         forKey: .neverLogApps)
        try c.encode(mercuryEnabled,       forKey: .mercuryEnabled)
        try c.encode(geminiObserverEnabled, forKey: .geminiObserverEnabled)
        try c.encode(killSwitchShortcut,   forKey: .killSwitchShortcut)
    }
}

@MainActor
public final class AgentSettingsStore: ObservableObject {
    public static let shared = AgentSettingsStore()

    @Published public private(set) var settings: AgentSettings = .default

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("AgentNotch", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("agent_settings.json")
        load()
        // Seed PrivacyGate so a fresh launch reflects persisted preferences
        // before any monitor fires its first event.
        PrivacyGate.shared.collectionPaused = settings.collectionPaused
        PrivacyGate.shared.neverLogApps = Set(settings.neverLogApps)
    }

    public var reasoningEffort: AgentReasoningEffort {
        get { settings.reasoningEffort }
        set { update { $0.reasoningEffort = newValue } }
    }

    public var preferences: String {
        get { settings.preferences }
        set { update { $0.preferences = newValue } }
    }

    public var systemPrompt: String {
        get { settings.systemPrompt }
        set { update { $0.systemPrompt = newValue } }
    }

    public var cursorColor: CursorColor {
        get { settings.cursorColor }
        set { update { $0.cursorColor = newValue } }
    }

    public var ttsVoice: TTSVoice {
        get { settings.ttsVoice }
        set { update { $0.ttsVoice = newValue } }
    }

    public var collectionPaused: Bool {
        get { settings.collectionPaused }
        set {
            update { $0.collectionPaused = newValue }
            PrivacyGate.shared.collectionPaused = newValue
        }
    }

    public var neverLogApps: [String] {
        get { settings.neverLogApps }
        set {
            update { $0.neverLogApps = newValue }
            PrivacyGate.shared.neverLogApps = Set(newValue)
        }
    }

    public var mercuryEnabled: Bool {
        get { settings.mercuryEnabled }
        // mercuryEnabled has no runtime consumer yet — Phase 4 will honor it.
        set { update { $0.mercuryEnabled = newValue } }
    }

    /// Toggle for the continuous background screen observer. When off,
    /// `GeminiObserver.observe(...)` no-ops and no per-surface memory is
    /// accumulated.
    public var geminiObserverEnabled: Bool {
        get { settings.geminiObserverEnabled }
        set { update { $0.geminiObserverEnabled = newValue } }
    }

    public var killSwitchShortcut: KillSwitchShortcut {
        get { settings.killSwitchShortcut }
        set { update { $0.killSwitchShortcut = newValue } }
    }

    public func update(_ mutate: (inout AgentSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        guard copy != settings else { return }
        settings = copy
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode(AgentSettings.self, from: data) else { return }
        settings = decoded
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = settings
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }
}
