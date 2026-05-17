import Foundation

// MARK: - Event base envelope + variants (§4 Event types)

/// Every event passing through PrivacyGate/EventIngester has this envelope.
public struct CEvent: Codable, Identifiable {
    public let id: UUID
    public let t: Date                    // ISO8601 UTC w/ ms
    public let seq: Int                   // monotonic per session
    public let kind: Kind
    public let sourceMonitor: String      // "KeystrokeMonitor", "AXObserver", ...
    public let app: String?
    public let bundleID: String?
    public let pid: Int?
    public let windowTitle: String?
    public let windowID: Int?
    public let displayID: Int?
    public var redacted: Bool
    public var redactionReason: RedactionReason?
    public let payload: Payload

    public enum Kind: String, Codable {
        case screen, input, click, copyPaste = "copy_paste", dwell, backtrack, search, appSwitch = "app_switch"
    }

    public enum RedactionReason: String, Codable {
        case secureInput = "secure_input"
        case passwordShape = "password_shape"
        case neverLogPaste = "never_log_paste"
        case browserPasswordContext = "browser_password_context"
        case urlCredentialStrip = "url_credential_strip"
    }

    public enum Payload: Codable {
        case screen(surface: String?)
        case input(element: String?, text: String, context: String?, submitKey: String?, modifiers: [String])
        case click(elementLabel: String?, axRole: String?, modifiers: [String])
        case copyPaste(from: CopyEndpoint, to: CopyEndpoint, changeCount: Int)
        case dwell(durationS: Double, signal: String?)
        case backtrack(fromApp: String, toApp: String, intervalS: Double, signal: String?)
        case search(query: String)
        case appSwitch(fromBundle: String?, toBundle: String)

        public struct CopyEndpoint: Codable {
            public let app: String
            public let element: String?
            public let selection: String?
            public init(app: String, element: String? = nil, selection: String? = nil) {
                self.app = app; self.element = element; self.selection = selection
            }
        }
    }

    public init(
        id: UUID = UUID(),
        t: Date = Date(),
        seq: Int,
        kind: Kind,
        sourceMonitor: String,
        app: String? = nil,
        bundleID: String? = nil,
        pid: Int? = nil,
        windowTitle: String? = nil,
        windowID: Int? = nil,
        displayID: Int? = nil,
        redacted: Bool = false,
        redactionReason: RedactionReason? = nil,
        payload: Payload
    ) {
        self.id = id; self.t = t; self.seq = seq; self.kind = kind
        self.sourceMonitor = sourceMonitor
        self.app = app; self.bundleID = bundleID; self.pid = pid
        self.windowTitle = windowTitle; self.windowID = windowID; self.displayID = displayID
        self.redacted = redacted; self.redactionReason = redactionReason
        self.payload = payload
    }
}

// MARK: - L1 Intent (per-request)

public struct CIntent: Codable {
    public let verb: String
    public let target: String?
    public let resolvedTarget: String?
    public let entities: [Entity]
    public let confidence: Double

    public struct Entity: Codable {
        public let label: String
        public let kind: String       // "person", "file", "url", "channel", "cwd", ...
        public let resolvedTo: String?

        public init(label: String, kind: String, resolvedTo: String? = nil) {
            self.label = label; self.kind = kind; self.resolvedTo = resolvedTo
        }
    }

    public init(verb: String, target: String? = nil, resolvedTarget: String? = nil, entities: [Entity] = [], confidence: Double = 0.5) {
        self.verb = verb; self.target = target; self.resolvedTarget = resolvedTarget
        self.entities = entities; self.confidence = confidence
    }
}

// MARK: - L2 Current screen (per-turn, never cached)

public struct CL2Snapshot: Codable {
    public let app: String
    public let bundleID: String
    public let pid: Int
    public let windowTitle: String?
    public let windowID: Int?
    public let displayID: Int
    public let displayBounds: [Double]
    public let capturedAt: Date
    public let ocrLines: [String]
    public let axElements: [AXElement]
    public let cursor: [Int]?            // [x, y]
    public let selection: String?
    public let clipboard: ClipboardSnapshot?
    public let appSpecific: [String: AnyCodable]?

    public struct AXElement: Codable {
        public let role: String
        public let label: String?
        public let axPath: String?       // richer identifier; not directly tool-callable
        public let bbox: [Int]?          // [x, y, w, h] valid for THIS TURN ONLY
        public let focused: Bool
    }

    public struct ClipboardSnapshot: Codable {
        public let kind: String           // "text" | "image" | ...
        public let preview: String?
        public let bytes: Int
        public let ageS: Double
        public let sourceApp: String?
        public let sourceBundleID: String?
    }
}

// MARK: - L3 Operational (durable, per-app)

public struct CRecipe: Codable {
    public let name: String
    public let triggerPattern: String     // "open DM | message <person> | DM <person>"
    public let steps: [Step]
    public var seenCount: Int
    public var lastSeen: Date
    public var confidence: Double

    public enum Step: Codable {
        case shortcut(keys: String)                      // "cmd+k"
        case type(value: String)                         // literal or "<person.name>"
        case key(keys: String)                           // "return"
        case menu(path: [String])                        // ["File", "New Tab"]
        case url(value: String)                          // "https://github.com/{org}/{repo}"
        case shellCmd(value: String, needsCwd: String?)  // "swift test"
        case openFile(value: String, app: String?)       // "Features/Context/Foo.swift"
        case appleScript(value: String)                  // last resort
    }
}

public struct CAppRecipes: Codable {
    public let appBundleID: String
    public var recipes: [CRecipe]
    public var candidates: [CRecipe]            // < 3 seen_count, not yet promoted
    public var shortcuts: [Shortcut]
    public var menuPaths: [MenuPath]

    public struct Shortcut: Codable {
        public let keys: String
        public let label: String?
        public var seenCount: Int
    }
    public struct MenuPath: Codable {
        public let path: [String]
        public var seenCount: Int
    }
}

// MARK: - L5 Narrative (multi-resolution)

public struct CActiveTask: Codable {
    public let id: String
    public let startedAt: Date
    public var label: String
    public var kind: String              // "design_iteration" | "coding" | ...
    public var narrative: String         // Mercury-maintained paragraph
    public var actionsTaken: [Action]
    public var resources: [String]       // URIs / paths
    public var entities: [CIntent.Entity]
    public var blockedOn: String?
    public var likelyNextSteps: [String]
    public var staleSince: Date?

    public struct Action: Codable {
        public let t: Date
        public let what: String
    }
}

public struct CArchivedTask: Codable {
    public let id: String
    public let label: String
    public let endedAt: Date
    public let outcome: String
    public let kind: String
}

public struct CResourceRef: Codable {
    public let kind: String              // "url" | "file" | "channel" | "cwd"
    public let uri: String
    public let label: String?
    public let app: String?
    public let lastSeen: Date
}

// MARK: - Helper: type-erased Codable for `appSpecific` blob

/// Lets `CL2Snapshot.appSpecific` carry arbitrary per-adapter JSON without forcing each
/// adapter to expose a typed Swift model up here. Re-encodes faithfully via JSONSerialization.
public struct AnyCodable: Codable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([AnyCodable].self) { value = v.map(\.value) }
        else if let v = try? c.decode([String: AnyCodable].self) {
            value = v.mapValues(\.value)
        }
        else if c.decodeNil() { value = NSNull() }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported AnyCodable value")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported"))
        }
    }
}
