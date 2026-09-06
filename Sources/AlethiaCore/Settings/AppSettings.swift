import Foundation

/// How the dictation hotkey behaves.
public enum DictationActivation: String, Codable, Sendable, CaseIterable {
    /// Hold the key to talk; release to insert.
    case holdToTalk
    /// Press once to start, press again to stop.
    case toggle

    public var displayName: String {
        switch self {
        case .holdToTalk: return "Hold to talk"
        case .toggle: return "Press to start / stop"
        }
    }
}

/// Which key starts dictation.
public enum DictationHotkey: String, Codable, Sendable, CaseIterable {
    case fn
    case rightOption
    case rightCommand
    case leftControl
    case f5

    public var displayName: String {
        switch self {
        case .fn: return "Fn / Globe"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .leftControl: return "Left Control (⌃)"
        case .f5: return "F5"
        }
    }
}

/// Speech model variant. Parakeet TDT 0.6B v2 is English-only with the best recall;
/// v3 covers 25 European languages.
public enum SpeechModelVariant: String, Codable, Sendable, CaseIterable {
    case parakeetV2English
    case parakeetV3Multilingual

    public var displayName: String {
        switch self {
        case .parakeetV2English: return "Parakeet TDT 0.6B v2 (English)"
        case .parakeetV3Multilingual: return "Parakeet TDT 0.6B v3 (25 languages)"
        }
    }
}

/// Where optional language-model work (notes, dictation polish) runs.
public enum LanguageModelProviderKind: String, Codable, Sendable, CaseIterable {
    /// No model: rule-based dictation cleanup and heuristic notes only.
    case none
    /// Apple Intelligence via the Foundation Models framework (macOS 26+, on-device).
    case appleIntelligence
    /// Any OpenAI-compatible endpoint: Ollama / LM Studio locally, or a cloud API key.
    case openAICompatible

    public var displayName: String {
        switch self {
        case .none: return "Off (rules only)"
        case .appleIntelligence: return "Apple Intelligence (on-device)"
        case .openAICompatible: return "OpenAI-compatible server"
        }
    }
}

public struct LanguageModelSettings: Codable, Hashable, Sendable {
    public var provider: LanguageModelProviderKind
    /// Base URL for OpenAI-compatible servers, e.g. `http://localhost:11434/v1`.
    public var baseURL: String
    public var model: String
    /// Keychain account name holding the API key (the key itself is never stored here).
    public var apiKeyAccount: String
    /// Run the language model on every dictation (in addition to the rule engine).
    public var polishDictation: Bool
    /// Auto-generate enhanced notes when a meeting finishes processing.
    public var autoEnhanceNotes: Bool

    public init(
        provider: LanguageModelProviderKind = .none,
        baseURL: String = "http://localhost:11434/v1",
        model: String = "qwen3:4b",
        apiKeyAccount: String = "llm.apiKey",
        polishDictation: Bool = false,
        autoEnhanceNotes: Bool = true
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.apiKeyAccount = apiKeyAccount
        self.polishDictation = polishDictation
        self.autoEnhanceNotes = autoEnhanceNotes
    }
}

public struct DictationSettings: Codable, Hashable, Sendable {
    public var hotkey: DictationHotkey
    public var activation: DictationActivation
    public var removeFillers: Bool
    public var resolveSelfCorrections: Bool
    public var applyVoiceCommands: Bool
    public var smartFormatting: Bool
    /// Adapt style to the target app (casual in chat apps, no trailing period in search fields, …).
    public var appAwareStyle: Bool
    /// Show the result for a moment after inserting so it can be fixed.
    public var showCorrectionPopover: Bool
    public var correctionPopoverSeconds: Double
    /// Play a subtle sound when dictation starts / stops.
    public var playSounds: Bool
    /// Save dictations to history.
    public var keepHistory: Bool
    /// Language hint for the recognizer (BCP-47, or empty for auto with the multilingual model).
    public var language: String

    public init(
        hotkey: DictationHotkey = .fn,
        activation: DictationActivation = .holdToTalk,
        removeFillers: Bool = true,
        resolveSelfCorrections: Bool = true,
        applyVoiceCommands: Bool = true,
        smartFormatting: Bool = true,
        appAwareStyle: Bool = true,
        showCorrectionPopover: Bool = true,
        correctionPopoverSeconds: Double = 4,
        playSounds: Bool = true,
        keepHistory: Bool = true,
        language: String = "en"
    ) {
        self.hotkey = hotkey
        self.activation = activation
        self.removeFillers = removeFillers
        self.resolveSelfCorrections = resolveSelfCorrections
        self.applyVoiceCommands = applyVoiceCommands
        self.smartFormatting = smartFormatting
        self.appAwareStyle = appAwareStyle
        self.showCorrectionPopover = showCorrectionPopover
        self.correctionPopoverSeconds = correctionPopoverSeconds
        self.playSounds = playSounds
        self.keepHistory = keepHistory
        self.language = language
    }
}

public struct MeetingSettings: Codable, Hashable, Sendable {
    public var includeSystemAudio: Bool
    /// Offer to start a meeting when another app begins using the microphone.
    public var detectMeetings: Bool
    /// Show a live transcript while recording.
    public var liveTranscript: Bool
    /// Keep the audio recording after processing.
    public var keepAudio: Bool
    public var defaultTemplateID: String
    /// Read calendar events to pre-fill titles and attendees.
    public var useCalendar: Bool

    public init(
        includeSystemAudio: Bool = true,
        detectMeetings: Bool = true,
        liveTranscript: Bool = true,
        keepAudio: Bool = true,
        defaultTemplateID: String = NotesTemplate.general.id,
        useCalendar: Bool = false
    ) {
        self.includeSystemAudio = includeSystemAudio
        self.detectMeetings = detectMeetings
        self.liveTranscript = liveTranscript
        self.keepAudio = keepAudio
        self.defaultTemplateID = defaultTemplateID
        self.useCalendar = useCalendar
    }
}

/// All user preferences. Persisted as JSON in `UserDefaults` by `SettingsStore`.
public struct AppSettings: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var speechModel: SpeechModelVariant
    public var dictation: DictationSettings
    public var meetings: MeetingSettings
    public var languageModel: LanguageModelSettings
    public var didCompleteOnboarding: Bool
    public var launchAtLogin: Bool

    public init(
        schemaVersion: Int = 1,
        speechModel: SpeechModelVariant = .parakeetV3Multilingual,
        dictation: DictationSettings = DictationSettings(),
        meetings: MeetingSettings = MeetingSettings(),
        languageModel: LanguageModelSettings = LanguageModelSettings(),
        didCompleteOnboarding: Bool = false,
        launchAtLogin: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.speechModel = speechModel
        self.dictation = dictation
        self.meetings = meetings
        self.languageModel = languageModel
        self.didCompleteOnboarding = didCompleteOnboarding
        self.launchAtLogin = launchAtLogin
    }

    public static let `default` = AppSettings()
}

// MARK: - Tolerant decoding
//
// Every settings struct decodes missing keys as defaults so adding a preference never
// resets existing installs.

extension DictationSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DictationSettings()
        hotkey = try c.decodeIfPresent(DictationHotkey.self, forKey: .hotkey) ?? d.hotkey
        activation = try c.decodeIfPresent(DictationActivation.self, forKey: .activation) ?? d.activation
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? d.removeFillers
        resolveSelfCorrections = try c.decodeIfPresent(Bool.self, forKey: .resolveSelfCorrections) ?? d.resolveSelfCorrections
        applyVoiceCommands = try c.decodeIfPresent(Bool.self, forKey: .applyVoiceCommands) ?? d.applyVoiceCommands
        smartFormatting = try c.decodeIfPresent(Bool.self, forKey: .smartFormatting) ?? d.smartFormatting
        appAwareStyle = try c.decodeIfPresent(Bool.self, forKey: .appAwareStyle) ?? d.appAwareStyle
        showCorrectionPopover = try c.decodeIfPresent(Bool.self, forKey: .showCorrectionPopover) ?? d.showCorrectionPopover
        correctionPopoverSeconds = try c.decodeIfPresent(Double.self, forKey: .correctionPopoverSeconds) ?? d.correctionPopoverSeconds
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        keepHistory = try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? d.keepHistory
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
    }
}

extension MeetingSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MeetingSettings()
        includeSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .includeSystemAudio) ?? d.includeSystemAudio
        detectMeetings = try c.decodeIfPresent(Bool.self, forKey: .detectMeetings) ?? d.detectMeetings
        liveTranscript = try c.decodeIfPresent(Bool.self, forKey: .liveTranscript) ?? d.liveTranscript
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? d.keepAudio
        defaultTemplateID = try c.decodeIfPresent(String.self, forKey: .defaultTemplateID) ?? d.defaultTemplateID
        useCalendar = try c.decodeIfPresent(Bool.self, forKey: .useCalendar) ?? d.useCalendar
    }
}

extension LanguageModelSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LanguageModelSettings()
        provider = try c.decodeIfPresent(LanguageModelProviderKind.self, forKey: .provider) ?? d.provider
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        apiKeyAccount = try c.decodeIfPresent(String.self, forKey: .apiKeyAccount) ?? d.apiKeyAccount
        polishDictation = try c.decodeIfPresent(Bool.self, forKey: .polishDictation) ?? d.polishDictation
        autoEnhanceNotes = try c.decodeIfPresent(Bool.self, forKey: .autoEnhanceNotes) ?? d.autoEnhanceNotes
    }
}

extension AppSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        speechModel = try c.decodeIfPresent(SpeechModelVariant.self, forKey: .speechModel) ?? d.speechModel
        dictation = try c.decodeIfPresent(DictationSettings.self, forKey: .dictation) ?? d.dictation
        meetings = try c.decodeIfPresent(MeetingSettings.self, forKey: .meetings) ?? d.meetings
        languageModel = try c.decodeIfPresent(LanguageModelSettings.self, forKey: .languageModel) ?? d.languageModel
        didCompleteOnboarding = try c.decodeIfPresent(Bool.self, forKey: .didCompleteOnboarding) ?? d.didCompleteOnboarding
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }
}

/// Loads and saves `AppSettings`. Tolerates missing keys so older installs keep working
/// when new settings are added.
public final class SettingsStore: @unchecked Sendable {
    public static let defaultsKey = "app.alethia.settings.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: AppSettings?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            cached = .default
            return .default
        }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(AppSettings.self, from: data) {
            cached = decoded
            return decoded
        }
        // Partial decode: keep whatever top-level sections still parse.
        var settings = AppSettings.default
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func section<T: Decodable>(_ key: String, as type: T.Type) -> T? {
                guard let raw = object[key],
                      let sub = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
                return try? decoder.decode(T.self, from: sub)
            }
            if let d = section("dictation", as: DictationSettings.self) { settings.dictation = d }
            if let m = section("meetings", as: MeetingSettings.self) { settings.meetings = m }
            if let l = section("languageModel", as: LanguageModelSettings.self) { settings.languageModel = l }
            if let onboarded = object["didCompleteOnboarding"] as? Bool { settings.didCompleteOnboarding = onboarded }
            if let raw = object["speechModel"] as? String, let v = SpeechModelVariant(rawValue: raw) { settings.speechModel = v }
        }
        cached = settings
        return settings
    }

    public func save(_ settings: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        cached = settings
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) -> AppSettings {
        var settings = load()
        mutate(&settings)
        save(settings)
        return settings
    }
}
