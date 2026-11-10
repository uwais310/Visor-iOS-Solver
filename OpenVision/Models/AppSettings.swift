// OpenVision - AppSettings.swift
// Settings data model with Codable support for JSON persistence.
//
// One brain (Gemini), one glasses workflow — so only the settings that workflow uses live here.
// Older settings.json files with extra fields (other backends, Kokoro, telemetry…) still load:
// unknown keys are ignored and missing ones fall back to the defaults (see SettingsManager).

import Foundation

/// What a press of the glasses' capture button does (Meta DAT Inputs, experimental).
enum GlassesButtonAction: String, Codable, CaseIterable, Identifiable {
    /// Take a full-resolution photo; it becomes the context for the next question.
    case capture
    /// Take a photo and solve it right away — no need to speak.
    case captureAndSolve
    /// Read the last answer again.
    case repeatAnswer
    /// Do nothing.
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .capture: return "Фото (жду вопрос)"
        case .captureAndSolve: return "Фото и сразу ответ"
        case .repeatAnswer: return "Повторить ответ"
        case .none: return "Ничего"
        }
    }
}

/// App settings persisted to Documents/settings.json (the API key goes to the Keychain; see SettingsSecrets)
struct AppSettings: Codable, Equatable {
    // MARK: - Gemini

    /// Google Gemini API key(s) — several may be entered, comma-separated (GeminiLiveService.parseKeys).
    var geminiAPIKey: String = ""

    // MARK: - Voice input

    /// Wake word phrase (default: "Ok Vision")
    var wakeWord: String = "Клод"

    /// Whether wake word detection is enabled
    var wakeWordEnabled: Bool = true

    /// Play activation chime on wake word detection
    var playActivationSound: Bool = true

    /// Conversation timeout in seconds (auto-end after silence)
    var conversationTimeout: TimeInterval = 30

    /// Language the speech recognizer listens for: "auto" (the iPhone's language), "vi-VN" or
    /// "en-US". iOS recognizes one language at a time; answers always follow the question's language.
    var recognitionLanguage: String = "ru-RU"

    /// Prefer the glasses' Bluetooth microphone for voice input when they're the connected audio
    /// device — true hands-free. Falls back to the phone mic automatically when the glasses aren't
    /// the audio route. Turn off to always use the phone. (Glasses mic uses more battery.)
    var preferGlassesMic: Bool = true

    // MARK: - Glasses (Meta DAT 1.0)

    /// Receive the glasses' capture-button presses in the app (photos go straight to Gemini at full
    /// resolution, no Camera Roll import). Experimental in the Meta SDK: needs the glasses in
    /// Developer Mode; falls back to the Camera Roll workflow when unavailable.
    var captureButtonEnabled: Bool = true
    var shortPressAction: GlassesButtonAction = .capture
    var holdAction: GlassesButtonAction = .repeatAnswer
    var doublePressAction: GlassesButtonAction = .captureAndSolve
    /// Also route the touchpad to the app — only if button presses never arrive (a known SDK
    /// quirk); while on, the temple touchpad no longer controls music/volume.
    var captureButtonIncludeTouchpad: Bool = false
    /// Photos taken through the SDK: full sensor resolution (~12 MP, slower to transfer) or 1080p.
    var fullResolutionPhotos: Bool = true

    // MARK: - Voice output (Apple system voices, one per language)

    /// English voice identifier (nil = best installed en-US voice)
    var selectedVoiceIdentifier: String? = nil

    /// Vietnamese voice identifier (nil = best installed vi-VN voice)
    var selectedVietnameseVoiceIdentifier: String? = nil

    /// Speaking rate, 0.3 (slow) … 0.6 (fast). Apple's default is 0.5.
    var speechRate: Float = 0.425

    // MARK: - AI Customization

    /// Custom instructions appended to AI system prompt
    var userPrompt: String = ""

    /// Key-value memories the AI can read and manage
    var memories: [String: String] = [:]

    // MARK: - Display

    /// Show live transcripts in UI
    var showTranscripts: Bool = true

    // MARK: - Computed Properties

    /// Whether at least one Gemini key is set (keys are never compiled into the app).
    var isGeminiConfigured: Bool {
        !GeminiLiveService.parseKeys(geminiAPIKey).isEmpty
    }

    /// Label for the status pill.
    var backendDisplayName: String { "Gemini" }
}
