// OpenVision - TTSService.swift
// Text-to-speech service using AVSpeechSynthesizer

import AVFoundation
import Foundation

/// Speaks Gemini's SPOKEN channel through the glasses: each sentence in its own language's voice
/// (Vietnamese or English), with leftover math symbols read as words.
@MainActor
final class TTSService: NSObject, ObservableObject {
    // MARK: - Singleton

    static let shared = TTSService()

    // MARK: - Published State

    @Published var isSpeaking: Bool = false

    // MARK: - Callbacks

    /// Called when speech starts
    var onSpeechStarted: (() -> Void)?

    /// Called when speech ends
    var onSpeechEnded: (() -> Void)?

    // MARK: - Speech Synthesizer

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Streaming state

    /// Utterances enqueued but not yet finished. `isSpeaking` only drops to false when this
    /// hits 0 AND no more chunks are coming — so it doesn't flap between queued sentences.
    var pendingUtterances: Int { activeUtterances.count }

    /// The utterances of the current reply. Tracked by identity, not a counter: `stop()` cancels
    /// the old ones, but their didCancel callbacks arrive later — with a counter they ate into the
    /// count of the NEXT reply and ended it early (barge-in unpaused while still speaking).
    private var activeUtterances = Set<ObjectIdentifier>()

    /// The language of the reply being spoken (nil until known). Sentences that carry no language
    /// of their own ("x = 2.", "B.") are read in it, so a Vietnamese answer isn't interrupted by
    /// a math line in the English voice.
    private var replyIsVietnamese: Bool?

    /// True while a streamed reply is still being fed sentence-by-sentence. Keeps `isSpeaking`
    /// latched even if the audio queue momentarily drains faster than the LLM produces text.
    private var streamingActive = false

    // MARK: - Voice Selection

    /// Auto-detect Vietnamese characters or math keywords in the text
    nonisolated static func containsVietnamese(_ text: String) -> Bool {
        // Russian build: the app's second-language slot (named "Vietnamese" in the code) is Russian.
        // Any Cyrillic letter means the sentence is read with the Russian voice.
        return text.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil
    }

    // MARK: - Spoken Audio Cleaning (Visor parity)

    /// Clean LaTeX formulas, markdown, and lingering tags before speech synthesis.
    /// `@inline(never)`: Blueprint checklist test 6 verifies this symbol is present in the
    /// Release Mach-O; with a single caller the optimizer would otherwise inline it away.
    @inline(never)
    static func cleanSpokenAudio(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"(?i)^\s*[-*•]?\s*(?:\[?(?:SPOKEN|DISPLAY)\]?)\s*:?\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\b(?:SPOKEN|DISPLAY)\b\s*:"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[:\s\-*#]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*{1,3}([^*]+)\*{1,3}"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`{1,3}[^`]*`{1,3}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"#{1,6}\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\[a-zA-Z]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[\$\{\}\[\]\\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a sentence says nothing about its language: no Vietnamese and fewer than two
    /// real words ("x = 2.", "B.", "3,5 cm."). Such sentences follow the reply's language.
    nonisolated static func isLanguageNeutral(_ text: String) -> Bool {
        guard !containsVietnamese(text) else { return false }
        let words = text.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 3 }
        return words.count < 2
    }

    /// The language a sentence is read in: its own when it has one, else the reply's.
    private func sentenceIsVietnamese(_ text: String) -> Bool {
        if Self.isLanguageNeutral(text) {
            return replyIsVietnamese ?? SolverIntent.speaksVietnamese
        }
        let vietnamese = Self.containsVietnamese(text)
        if replyIsVietnamese == nil { replyIsVietnamese = vietnamese }
        return vietnamese
    }

    /// Voice for one language — the chosen voice, else the best installed one.
    private func voice(vietnamese: Bool) -> AVSpeechSynthesisVoice? {
        let settings = SettingsManager.shared.settings
        if vietnamese {
            if let id = settings.selectedVietnameseVoiceIdentifier,
               let chosen = AVSpeechSynthesisVoice(identifier: id), chosen.language.hasPrefix("ru") { return chosen }
            if let best = Self.bestVoice(for: "ru-RU") { return best }
        }
        if let id = settings.selectedVoiceIdentifier,
           let chosen = AVSpeechSynthesisVoice(identifier: id), !chosen.language.hasPrefix("ru") { return chosen }
        return Self.bestVoice(for: "en-US")
    }

    /// The voice for one sentence: the chosen (or best installed) voice of the sentence's language.
    static func voice(forText text: String, vietnamese: AVSpeechSynthesisVoice? = nil,
                      english: AVSpeechSynthesisVoice? = nil) -> AVSpeechSynthesisVoice? {
        if containsVietnamese(text) {
            if let vietnamese, vietnamese.language.hasPrefix("ru") { return vietnamese }
            if let viVoice = bestVoice(for: "ru-RU") { return viVoice }
        }
        if let english, !english.language.hasPrefix("ru") { return english }
        return bestVoice(for: "en-US")
    }

    /// Highest-quality installed voice for a language (Premium > Enhanced > Default), so a
    /// downloaded enhanced Vietnamese/English voice is used automatically.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        if let cached = bestVoiceCache[language] { return cached }
        // Only upgraded (enhanced/premium), non-novelty voices compete; otherwise the system default.
        let upgraded = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language && $0.quality != .default && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        let voice = upgraded.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
        bestVoiceCache[language] = voice
        return voice
    }

    /// Per-language pick, so streaming sentence-by-sentence doesn't rescan the voice list.
    private static var bestVoiceCache: [String: AVSpeechSynthesisVoice] = [:]

    /// Get all available voices for a language
    static func availableVoices(for languageCode: String = "en") -> [AVSpeechSynthesisVoice] {
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languageCode) }
            .sorted { v1, v2 in
                // Sort by quality (premium first), then by name
                if v1.quality != v2.quality {
                    return v1.quality.rawValue > v2.quality.rawValue
                }
                return v1.name < v2.name
            }
    }

    /// Get display name for a voice quality
    static func qualityDisplayName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Initialization

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speak

    /// Speak text (single-shot: replaces anything currently playing). Queued sentence by
    /// sentence, so a reply mixing Vietnamese and English is read with the right voice for each.
    func speak(_ text: String) {
        stop()
        let cleaned = Self.cleanSpokenAudio(text)
        if !Self.isLanguageNeutral(cleaned) { replyIsVietnamese = Self.containsVietnamese(cleaned) }
        let sentences = TextChunking.sentences(text)
        for sentence in sentences.isEmpty ? [text] : sentences {
            enqueue(sentence)
        }
    }

    // MARK: - Streaming (sentence-by-sentence)

    /// Begin a streamed reply. Clears the queue and latches `isSpeaking` true so the recognizer
    /// stays paused across the gaps between sentences while the LLM is still generating.
    func beginStreaming() {
        stop()
        streamingActive = true
        isSpeaking = true
        onSpeechStarted?()
    }

    /// Enqueue one sentence without interrupting what's already queued. AVSpeechSynthesizer plays
    /// queued utterances back-to-back, so this pipelines speech behind the LLM as it streams.
    func speakChunk(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueue(trimmed)
    }

    /// Signal that no more sentences are coming. Releases the latch once the queue drains.
    func endStreaming() {
        streamingActive = false
        if pendingUtterances == 0 {
            isSpeaking = false
            onSpeechEnded?()
        }
    }

    /// Lead-in silence before the first sentence of a reply: Bluetooth speakers drop the first
    /// few hundred milliseconds of audio after silence, which clipped the start of answers.
    static let bluetoothLeadIn: TimeInterval = 0.3

    /// Build an utterance with the right voice and hand it to the synthesizer's queue.
    private func enqueue(_ text: String) {
        let cleaned = Self.cleanSpokenAudio(text)
        guard !cleaned.isEmpty else { return }
        let vietnamese = sentenceIsVietnamese(cleaned)
        let spoken = SpokenMath.normalize(cleaned, vietnamese: vietnamese)
        guard !spoken.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = voice(vietnamese: vietnamese)
        utterance.rate = min(max(SettingsManager.shared.settings.speechRate, AVSpeechUtteranceMinimumSpeechRate),
                             AVSpeechUtteranceMaximumSpeechRate)
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        if activeUtterances.isEmpty {
            utterance.preUtteranceDelay = Self.bluetoothLeadIn
        }
        activeUtterances.insert(ObjectIdentifier(utterance))
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Stop speaking and clear the queue.
    func stop() {
        let wasSpeaking = isSpeaking || !activeUtterances.isEmpty
        // Forget the old utterances first: their didCancel callbacks then find nothing to end.
        activeUtterances.removeAll()
        replyIsVietnamese = nil
        streamingActive = false
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        if wasSpeaking { onSpeechEnded?() }
    }

    /// Pause speaking
    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    /// Continue speaking
    func continueSpeaking() {
        synthesizer.continueSpeaking()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // The moment audio actually begins — the honest end of the wearer's wait. Marked here,
            // not where the view model hands text over: hand-off-time marking excluded synthesis
            // entirely, which made TTS TTFB structurally zero and perceived latency optimistic.
            // First-wins per turn, and gated inside the collector on the turn having requested
            // TTS, so later sentences and unrelated system utterances can't misattribute.
            MetricsCollector.shared.markFirstAudio()
            if !self.isSpeaking {
                self.isSpeaking = true
                self.onSpeechStarted?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            // An utterance of a reply that was already stopped: nothing of the current one ended.
            guard self.activeUtterances.remove(id) != nil else { return }
            // Only truly "done" when the queue is empty AND no more sentences are coming.
            if self.activeUtterances.isEmpty && !self.streamingActive {
                self.isSpeaking = false
                self.onSpeechEnded?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            // stop() already forgot the utterances it cancelled (and reported the end).
            guard self.activeUtterances.remove(id) != nil else { return }
            if self.activeUtterances.isEmpty {
                self.streamingActive = false
                self.isSpeaking = false
                self.onSpeechEnded?()
            }
        }
    }
}

// MARK: - Spoken math (pure, unit-testable)

/// Reads math symbols that slipped into the SPOKEN channel as words in the answer's language, so
/// the voice says "x bình phương bằng 4" instead of "x caret 2 equals sign 4". The system prompt
/// already asks Gemini to spell math out; this is the safety net. Deliberately conservative:
/// "1-5" (a range), "Ray-Ban" and plain prose dashes are left alone.
enum SpokenMath {
    private struct Words {
        let squared, cubed, power, root, over, times, divided, notEqual, lessEqual, greaterEqual,
            approx, less, greater, equals, plus, minus, negative, percent: String
    }

    private static let vietnamese = Words(
        squared: "в квадрате", cubed: "в кубе", power: "в степени", root: "корень из", over: "разделить на",
        times: "умножить на", divided: "разделить на", notEqual: "не равно", lessEqual: "меньше или равно",
        greaterEqual: "больше или равно", approx: "примерно равно", less: "меньше", greater: "больше",
        equals: "равно", plus: "плюс", minus: "минус", negative: "минус", percent: "процентов")

    private static let english = Words(
        squared: "squared", cubed: "cubed", power: "to the power of", root: "the square root of",
        over: "over", times: "times", divided: "divided by", notEqual: "is not equal to",
        lessEqual: "is less than or equal to", greaterEqual: "is greater than or equal to",
        approx: "is approximately", less: "is less than", greater: "is greater than",
        equals: "equals", plus: "plus", minus: "minus", negative: "negative", percent: "percent")

    static func normalize(_ text: String, vietnamese isVietnamese: Bool) -> String {
        let w = isVietnamese ? vietnamese : english
        var s = text
        func replace(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        replace(#"\^\s*2(?![0-9])"#, " \(w.squared)")
        replace(#"\^\s*3(?![0-9])"#, " \(w.cubed)")
        replace(#"\^\s*\(([^()]*)\)"#, " \(w.power) $1")
        replace(#"\^\s*(-?[0-9A-Za-z]+)"#, " \(w.power) $1")
        replace(#"²"#, " \(w.squared)")
        replace(#"³"#, " \(w.cubed)")
        replace(#"√\s*"#, "\(w.root) ")
        replace(#"([0-9])\s*/\s*([0-9])"#, "$1 \(w.over) $2")
        replace(#"\s*[×·∗]\s*"#, " \(w.times) ")
        replace(#"\s*÷\s*"#, " \(w.divided) ")
        replace(#"\s*≠\s*"#, " \(w.notEqual) ")
        replace(#"\s*≤\s*"#, " \(w.lessEqual) ")
        replace(#"\s*≥\s*"#, " \(w.greaterEqual) ")
        replace(#"\s*≈\s*"#, " \(w.approx) ")
        replace(#"\s+<\s+"#, " \(w.less) ")
        replace(#"\s+>\s+"#, " \(w.greater) ")
        replace(#"\s*=\s*"#, " \(w.equals) ")
        replace(#"\s+\+\s+|(?<=[0-9A-Za-z)])\+(?=[0-9A-Za-z(])"#, " \(w.plus) ")
        replace(#"([0-9)])\s+[-−]\s+([0-9(])"#, "$1 \(w.minus) $2")
        replace(#"(^|[\s(])[-−]([0-9])"#, "$1\(w.negative) $2")
        replace(#"([0-9])\s*%"#, "$1 \(w.percent)")
        replace(#"π"#, isVietnamese ? " пи " : " pi ")
        if isVietnamese {
            replace(#"(?<![A-Za-z])[xX](?![A-Za-z])"#, " икс ")
            replace(#"(?<![A-Za-z])[yY](?![A-Za-z])"#, " игрек ")
        }
        replace(#"[_^]"#, " ")
        replace(#"\s+"#, " ")
        return s.trimmingCharacters(in: .whitespaces)
    }
}
