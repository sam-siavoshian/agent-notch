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
    /// Local Piper TTS using the user-supplied `jarvis-high.onnx` model.
    /// Routes through `PiperTTSEngine` instead of OpenAI; no API key, no
    /// network. Needs the `piper` CLI installed and the ONNX file present
    /// at `~/jarvis-voice/voices/jarvis-high.onnx`.
    case jarvis

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .jarvis: return "JARVIS (local)"
        default:      return rawValue.capitalized
        }
    }

    /// True when the voice is generated locally rather than via OpenAI's
    /// hosted TTS endpoint. The TextToSpeechService dispatches accordingly.
    public var isLocal: Bool { self == .jarvis }
}

/// Visual mode for the cursor surface. `.companion` floats a soft-pill dot
/// alongside the real cursor at all times (current behavior). `.glow` hides
/// the dot at rest and renders a soft radial glow directly under the cursor
/// only while the agent is active (long-press + run). Mutually exclusive.
public enum CursorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case companion
    case glow
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .companion: return "Companion"
        case .glow:      return "Glow"
        }
    }
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
        s.reserveCapacity(8)
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.shift)   { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        s += keyLabel.uppercased()
        return s
    }
}

public struct AgentSettings: Equatable, Sendable {
    public var agentModel: AgentModel
    public var reasoningEffort: AgentReasoningEffort
    public var preferences: String
    public var systemPrompt: String
    public var cursorColor: CursorColor
    public var cursorMode: CursorMode
    public var ttsVoice: TTSVoice
    /// Persistent CoreAudio device UID for voice input. nil = system default.
    public var voiceInputDeviceUID: String?
    /// Persistent CoreAudio device UID for TTS output. nil = system default.
    public var voiceOutputDeviceUID: String?
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
    /// Master switch for the private SkyLight SPI used as Tier-3 dispatch
    /// (clicks on Chromium web content). Default on. Disable to force the
    /// agent driver onto the all-public-API path (postToPid + AX only).
    public var allowPrivateSkyLight: Bool
    /// Backend that runs the computer-use loop. `.anthropicAPI` (default) hits
    /// Anthropic directly with our API key; `.claudeCodeCLI` spawns the user's
    /// locally-installed `claude` binary and surfaces our tools via the MCP
    /// bridge — zero AgentNotch API spend, billed against the user's CC auth.
    public var provider: AgentProvider
    /// Optional override for the `claude` binary location. nil = resolve via
    /// `which claude` + standard fallbacks at spawn time.
    public var claudeCodePath: String?

    public static let defaultNeverLogApps: [String] = [
        "com.1password.1password7",
        "com.1password.1password8",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.agentnotch.app",
    ]

    public static let `default` = AgentSettings(
        agentModel: .haiku,
        reasoningEffort: .medium,
        preferences: "",
        systemPrompt: "",
        cursorColor: .blue,
        cursorMode: .companion,
        ttsVoice: .nova,
        voiceInputDeviceUID: nil,
        voiceOutputDeviceUID: nil,
        collectionPaused: false,
        neverLogApps: AgentSettings.defaultNeverLogApps,
        mercuryEnabled: true,
        geminiObserverEnabled: true,
        killSwitchShortcut: .default,
        allowPrivateSkyLight: true,
        provider: .anthropicAPI,
        claudeCodePath: nil
    )
}

// Custom Codable so old JSON without newer fields still loads with safe defaults.
extension AgentSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case agentModel
        case reasoningEffort, preferences, systemPrompt, cursorColor, cursorMode, ttsVoice
        case voiceInputDeviceUID, voiceOutputDeviceUID
        case collectionPaused, neverLogApps, mercuryEnabled
        case geminiObserverEnabled
        case killSwitchShortcut
        case allowPrivateSkyLight
        case provider, claudeCodePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentModel           = (try? c.decode(AgentModel.self,           forKey: .agentModel))           ?? .haiku
        reasoningEffort      = (try? c.decode(AgentReasoningEffort.self, forKey: .reasoningEffort))      ?? .medium
        preferences          = (try? c.decode(String.self,               forKey: .preferences))          ?? ""
        systemPrompt         = (try? c.decode(String.self,               forKey: .systemPrompt))         ?? ""
        cursorColor          = (try? c.decode(CursorColor.self,          forKey: .cursorColor))          ?? .blue
        cursorMode           = (try? c.decode(CursorMode.self,           forKey: .cursorMode))           ?? .companion
        ttsVoice             = (try? c.decode(TTSVoice.self,             forKey: .ttsVoice))             ?? .nova
        voiceInputDeviceUID  = try? c.decode(String.self,                forKey: .voiceInputDeviceUID)
        voiceOutputDeviceUID = try? c.decode(String.self,                forKey: .voiceOutputDeviceUID)
        collectionPaused     = (try? c.decode(Bool.self,                 forKey: .collectionPaused))     ?? false
        neverLogApps         = (try? c.decode([String].self,             forKey: .neverLogApps))         ?? AgentSettings.defaultNeverLogApps
        mercuryEnabled       = (try? c.decode(Bool.self,                 forKey: .mercuryEnabled))       ?? true
        geminiObserverEnabled = (try? c.decode(Bool.self,                forKey: .geminiObserverEnabled)) ?? true
        killSwitchShortcut   = (try? c.decode(KillSwitchShortcut.self,   forKey: .killSwitchShortcut))   ?? .default
        allowPrivateSkyLight = (try? c.decode(Bool.self,                 forKey: .allowPrivateSkyLight)) ?? true
        provider             = (try? c.decode(AgentProvider.self,        forKey: .provider))             ?? .anthropicAPI
        claudeCodePath       = try? c.decode(String.self,                forKey: .claudeCodePath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentModel,           forKey: .agentModel)
        try c.encode(reasoningEffort,      forKey: .reasoningEffort)
        try c.encode(preferences,          forKey: .preferences)
        try c.encode(systemPrompt,         forKey: .systemPrompt)
        try c.encode(cursorColor,          forKey: .cursorColor)
        try c.encode(cursorMode,           forKey: .cursorMode)
        try c.encode(ttsVoice,             forKey: .ttsVoice)
        try c.encodeIfPresent(voiceInputDeviceUID,  forKey: .voiceInputDeviceUID)
        try c.encodeIfPresent(voiceOutputDeviceUID, forKey: .voiceOutputDeviceUID)
        try c.encode(collectionPaused,     forKey: .collectionPaused)
        try c.encode(neverLogApps,         forKey: .neverLogApps)
        try c.encode(mercuryEnabled,       forKey: .mercuryEnabled)
        try c.encode(geminiObserverEnabled, forKey: .geminiObserverEnabled)
        try c.encode(killSwitchShortcut,   forKey: .killSwitchShortcut)
        try c.encode(allowPrivateSkyLight, forKey: .allowPrivateSkyLight)
        try c.encode(provider,             forKey: .provider)
        try c.encodeIfPresent(claudeCodePath, forKey: .claudeCodePath)
    }
}

@MainActor
public final class AgentSettingsStore: ObservableObject {
    public static let shared = AgentSettingsStore()

    @Published public private(set) var settings: AgentSettings = .default

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private static let sharedDecoder = JSONDecoder()
    private static let sharedEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

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

    public var agentModel: AgentModel {
        get { settings.agentModel }
        set { update { $0.agentModel = newValue } }
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

    public var cursorMode: CursorMode {
        get { settings.cursorMode }
        set { update { $0.cursorMode = newValue } }
    }

    public var ttsVoice: TTSVoice {
        get { settings.ttsVoice }
        set { update { $0.ttsVoice = newValue } }
    }

    public var voiceInputDeviceUID: String? {
        get { settings.voiceInputDeviceUID }
        set { update { $0.voiceInputDeviceUID = newValue } }
    }

    public var voiceOutputDeviceUID: String? {
        get { settings.voiceOutputDeviceUID }
        set { update { $0.voiceOutputDeviceUID = newValue } }
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

    public var allowPrivateSkyLight: Bool {
        get { settings.allowPrivateSkyLight }
        set { update { $0.allowPrivateSkyLight = newValue } }
    }

    public var provider: AgentProvider {
        get { settings.provider }
        set { update { $0.provider = newValue } }
    }

    public var claudeCodePath: String? {
        get { settings.claudeCodePath }
        set { update { $0.claudeCodePath = newValue } }
    }

    public func update(_ mutate: (inout AgentSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        guard copy != settings else { return }
        settings = copy
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.sharedDecoder.decode(AgentSettings.self, from: data) else { return }
        settings = decoded
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = settings
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard let data = try? Self.sharedEncoder.encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }
}
