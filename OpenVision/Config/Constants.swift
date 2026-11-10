// OpenVision - Constants.swift
// App-wide constants

import Foundation

enum Constants {
    // MARK: - Voice

    enum Voice {
        /// Default wake word
        static let defaultWakeWord = "Клод"

        /// Wake word cooldown to prevent double-detection (seconds)
        static let wakeWordCooldown: TimeInterval = 0.8

        /// Command capture timeout (seconds)
        static let commandTimeout: TimeInterval = 10.0

        /// Silence timeout to end command capture (seconds).
        ///
        /// FALLBACK ONLY — used when acoustic VAD is unavailable. It measures "no new transcript
        /// for N seconds", not silence, and SFSpeechRecognizer emits partials in bursts with ~1s
        /// gaps mid-sentence, so it has to stay long or it cuts the user off. With VAD the turn is
        /// committed from real end-of-speech plus `vadCommitGrace` instead.
        static let silenceTimeout: TimeInterval = 4.0

        /// Extra wait after VAD reports end-of-speech before committing the turn (seconds).
        ///
        /// Short on purpose: Silero has already absorbed ~0.75s of silence hysteresis before it
        /// fires, and speech resuming inside this window cancels the commit. This buys a little
        /// room for the recognizer's final partial to land, which trails the audio slightly.
        static let vadCommitGrace: TimeInterval = 0.35

        /// Default conversation timeout (seconds) — the user's choice in Settings → Voice wins.
        static let conversationTimeout: TimeInterval = 30.0
    }

    // MARK: - Storage

    enum Storage {
        /// Settings file name
        static let settingsFileName = "settings.json"

        /// Conversations file name
        static let conversationsFileName = "conversations.json"

        /// Maximum conversations to keep
        static let maxConversations = 100

        /// Conversation inactivity timeout before starting new (seconds)
        static let conversationInactivityTimeout: TimeInterval = 300 // 5 minutes
    }
}
