// OpenVision - GeminiLiveService.swift
// REST-based Gemini solver: streaming, resilient, agentic (asks for a photo when it needs one).
//
// Design notes (see docs/architecture/ADR-001-solver-pipeline.md):
// - API keys come ONLY from Settings (Keychain); several keys may be entered. Rate limits are per
//   Google Cloud PROJECT and per MODEL, so keys should come from different projects, and the model
//   chain gives a second quota when the first model is exhausted.
// - Gemini 3 gives every image a fixed token budget (HIGH ~1120, ULTRA_HIGH ~2240 tokens), so the
//   photo is sent upright at <= 3072 px and the detail is requested with media resolution instead
//   of uploading 12 MP of bytes that would be downscaled anyway.

import Foundation
import UIKit
import AVFoundation

@MainActor
final class GeminiLiveService: ObservableObject {
    // MARK: - Singleton

    static let shared = GeminiLiveService()

    // MARK: - Published State

    @Published var connectionState: AIConnectionState = .disconnected
    @Published var isProcessing: Bool = false
    @Published var isModelSpeaking: Bool = false
    @Published var lastError: String?

    // MARK: - Endpoint & models

    static let apiHost = "generativelanguage.googleapis.com"
    /// Tried in order. Quota is per model, so the second model is a real fallback when the
    /// first one is exhausted or unavailable (404) for every key.
    static let modelChain = ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite"]
    /// The primary model (diagnostics, settings UI).
    static var modelName: String { modelChain[0] }

    // MARK: - Multi-turn Conversation History

    /// Entries kept for follow-up questions: 3 user/model exchanges (Blueprint lesson 7).
    static let maxHistoryEntries = 6

    private var conversationHistory: [[String: Any]] = []

    /// Number of stored history entries (user + model turns) — read-only view for diagnostics/tests.
    var conversationHistoryCount: Int { conversationHistory.count }

    public func clearConversationHistory() {
        conversationHistory.removeAll()
        imageFingerprintInHistory = nil
    }

    /// Continue a past conversation from History: its last exchanges (text only — photos are not
    /// kept in History) become the model's context for the next question.
    func seedHistory(from messages: [(isUser: Bool, text: String)]) {
        clearConversationHistory()
        var turns: [[String: Any]] = messages.suffix(Self.maxHistoryEntries).map { message in
            message.isUser ? Self.userTurn(text: message.text, imageData: nil)
                           : Self.modelTurn(text: Self.dualChannelFromHistory(message.text), signature: nil)
        }
        // The history must open with a user turn.
        while let first = turns.first, (first["role"] as? String) != "user" { turns.removeFirst() }
        conversationHistory = turns
    }

    /// History stores a reply's DISPLAY text only. Fed back as-is, the model sees its own past
    /// turns without SPOKEN/DISPLAY and starts answering the same way — so rebuild the shape, with
    /// the first sentence as the spoken part.
    nonisolated static func dualChannelFromHistory(_ text: String) -> String {
        if text.range(of: #"(?im)^\s*\**\s*SPOKEN"#, options: .regularExpression) != nil { return text }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let spoken = TextChunking.sentences(firstLine).first ?? firstLine
        return "SPOKEN:\n\(spoken)\n\nDISPLAY:\n\(text)"
    }

    // MARK: - Callbacks

    var onTextReceived: ((String) -> Void)?
    var onAudioReceived: ((Data) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?
    var onDisconnected: (() -> Void)?

    // Callbacks backing AIBackend conformance
    var agentMessageCallback: ((String) -> Void)?
    var processingChangedCallback: ((Bool) -> Void)?

    /// Streamed SPOKEN-channel text so far (cumulative, cleaned exactly like the final parse), so
    /// the glasses can start speaking at the first finished sentence. Main actor.
    var onPartialSpoken: ((String) -> Void)?

    /// The model asked to SEE (it replied with `captureToken`) and no photo was attached: take one
    /// (glasses camera, or a photo just synced to Camera Roll) and return it, or nil if none.
    var onCaptureRequested: ((_ question: String) async -> Data?)?

    // MARK: - Active Request Tracking

    private var activeTask: Task<Void, Error>?

    // MARK: - Initialization

    private init() {}

    // MARK: - Connection Lifecycle

    /// Connect to Gemini Service: validates key availability and enters connected state
    func connect() async throws {
        let keys = getAvailableKeyList()
        guard !keys.isEmpty else {
            throw AIBackendError.notConfigured
        }

        connectionState = .connected
        onConnectionStateChanged?(connectionState)
        NSLog("[GeminiLive] Connected to REST solver endpoint with %d API key(s)", keys.count)
    }

    /// Disconnect from Gemini Service
    func disconnect() async {
        guard connectionState != .disconnected else { return }

        NSLog("[GeminiLive] Disconnecting")
        activeTask?.cancel()
        activeTask = nil
        isProcessing = false
        isModelSpeaking = false

        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        processingChangedCallback?(false)
        onDisconnected?()
    }

    /// Interrupt ongoing request
    func interrupt() async {
        NSLog("[GeminiLive] Interrupted")
        requestGeneration += 1   // an in-flight stream drops its result and stops feeding speech
        activeTask?.cancel()
        activeTask = nil
        isProcessing = false
        isModelSpeaking = false
        processingChangedCallback?(false)
    }

    // MARK: - Messaging

    /// Send plain text turn
    func sendText(_ text: String) async throws {
        try await sendRESTMessage(text, imageData: nil)
    }

    /// Primary solver entrypoint: send the wearer's words (+ optional glasses photo) to Gemini.
    ///
    /// An agent loop: if the model needs to see something and no photo is in the conversation, it
    /// answers with `captureToken`; the app then takes a photo (`onCaptureRequested`) and asks the
    /// same question again with it. Every request streams, retries by failure type, and is bounded
    /// by one overall deadline, so the wearer is never left on "thinking".
    func sendRESTMessage(_ text: String, imageData: Data?) async throws {
        requestGeneration += 1
        let generation = requestGeneration
        isProcessing = true
        processingChangedCallback?(true)
        lastError = nil

        defer {
            // A newer request (or interrupt) owns the processing state now — don't clobber it.
            if generation == requestGeneration {
                isProcessing = false
                processingChangedCallback?(false)
            }
        }

        guard !getAvailableKeyList().isEmpty else {
            lastError = "No Gemini API key — add one in Settings → Gemini"
            throw AIBackendError.notConfigured
        }

        let question = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (imageData != nil ? "Посмотри на фото. Если там задача или вопрос — реши и дай ответ. Если нет — скажи, что это." : "Привет")
            : text

        var image = imageData
        var turn = try await performTurn(question: question, imageData: image, generation: generation)

        if Self.isCaptureRequest(turn.rawText), image == nil, let capture = onCaptureRequested {
            NSLog("[GeminiLive] Model asked to see — capturing a photo")
            if let photo = await capture(question) {
                guard generation == requestGeneration else { throw CancellationError() }
                image = photo
                turn = try await performTurn(question: question, imageData: photo, generation: generation)
            } else {
                let message = SolverIntent.missingPhotoMessage(for: question)
                turn = TurnResult(rawText: "SPOKEN:\n\(message)\n\nDISPLAY:\n\(message)", sentImage: nil, historyCopyTask: nil)
            }
        }
        if Self.isCaptureRequest(turn.rawText) {
            // Asked again despite a photo: never speak the protocol token.
            let message = SolverIntent.missingPhotoMessage(for: question)
            turn.rawText = "SPOKEN:\n\(message)\n\nDISPLAY:\n\(message)"
        }

        deliver(turn.rawText)
        await recordTurn(userText: question, sentImage: turn.sentImage, historyCopyTask: turn.historyCopyTask,
                         rawText: turn.rawText, signature: turn.signature)
    }

    private struct TurnResult {
        var rawText: String
        var sentImage: Data?
        var historyCopyTask: Task<Data, Never>?
        var signature: String? = nil
    }

    /// One question → one answer, with every retry the failure calls for.
    private func performTurn(question: String, imageData: Data?, generation: Int) async throws -> TurnResult {
        let allKeys = getAvailableKeyList()

        // Upright JPEG, long edge <= 3072 px (off the main actor). Detail comes from media
        // resolution; bigger uploads only cost latency.
        var prepared: Data?
        if let imageData {
            prepared = await Task.detached(priority: .userInitiated) { PhotoPayload.uploadJPEG(from: imageData) ?? imageData }.value
        }
        let fullUpload = prepared

        // When imageData is explicitly provided, always attach it to ensure model sees the latest captured context
        if let data = prepared {
            NSLog("[GeminiLive] Attached image payload: %ld bytes (%@)", data.count, PhotoPayload.mimeType(for: data))
        }
        // The lighter history copy is made while the request runs.
        var historyCopyTask: Task<Data, Never>? = prepared.map { data in
            Task.detached(priority: .utility) { PhotoPayload.historyCopy(of: data) }
        }

        let started = Date()
        let maxAttempts = allKeys.count * Self.modelChain.count + 3
        var attempt = 0
        var networkFailures = 0
        var healedSignatures = false
        var lastErrorMessage = "No response from Gemini API"

        retryLoop: while attempt < maxAttempts && Date().timeIntervalSince(started) < Self.overallDeadline {
            guard generation == requestGeneration, !Task.isCancelled else {
                historyCopyTask?.cancel()
                throw CancellationError()
            }
            attempt += 1
            let (model, key) = nextCandidate(keys: allKeys)
            let contents = conversationHistory + [Self.userTurn(text: question, imageData: prepared,
                                                                  perPartMediaResolution: mediaResolutionMode == .perPartUltraHigh)]
            let body = try makeRequestBody(contents: contents)
            NSLog("[GeminiLive] Sending request (attempt %ld/%ld, %ld KB) to %@ with key %@…",
                  attempt, maxAttempts, body.count / 1024, model, String(key.prefix(6)))

            let outcome = await performStreamingRequest(body: body, model: model, key: key, generation: generation)
            switch outcome {
            case .success(let rawText, let signature):
                NSLog("[GeminiLive] %@ answered (%ld chars) in %.1fs", model, rawText.count, Date().timeIntervalSince(started))
                return TurnResult(rawText: rawText, sentImage: prepared, historyCopyTask: historyCopyTask, signature: signature)

            case .cancelled:
                historyCopyTask?.cancel()
                throw CancellationError()

            case .rateLimited(let retryAfter):
                NSLog("[GeminiLive] %@ quota exhausted for key %@… — rotating", model, String(key.prefix(6)))
                coolDown(model: model, key: key, for: retryAfter ?? 60)
                lastErrorMessage = "Gemini quota exhausted (429)"

            case .badKey(let message):
                NSLog("[GeminiLive] Key %@… rejected (%@) — dropping it for an hour", String(key.prefix(6)), message)
                coolDown(model: nil, key: key, for: 3600)
                lastErrorMessage = message

            case .modelUnavailable(let message):
                NSLog("[GeminiLive] %@ unavailable (%@) — falling back to the next model", model, message)
                coolDown(model: model, key: nil, for: 3600)
                lastErrorMessage = message

            case .unsupportedField(let capability, let message):
                guard downgrade(capability) else {
                    lastErrorMessage = message
                    break retryLoop
                }
                NSLog("[GeminiLive] Model rejected %@ — retrying without it", String(describing: capability))
                attempt -= 1   // not the key's fault

            case .staleSignature(let message):
                // History carries a thought signature the API no longer accepts: start the
                // conversation afresh once instead of failing every follow-up.
                guard !healedSignatures else {
                    lastErrorMessage = message
                    break retryLoop
                }
                healedSignatures = true
                NSLog("[GeminiLive] History rejected (%@) — clearing it and retrying", message)
                clearConversationHistory()
                // The photo may have been left out because history already had it: history is
                // gone now, so it has to travel with this question again.
                if prepared == nil, let fullUpload {
                    prepared = fullUpload
                    historyCopyTask = Task.detached(priority: .utility) { PhotoPayload.historyCopy(of: fullUpload) }
                }
                attempt -= 1

            case .serverError(let message):
                lastErrorMessage = message
                await backoff(attempt: attempt)

            case .network(let message, let partial, let signature):
                if !Self.parseDualChannel(partial).spoken.isEmpty {
                    // The connection dropped mid-answer: keep what arrived rather than make the
                    // wearer wait for a full retry (the spoken part streams first anyway).
                    NSLog("[GeminiLive] Stream dropped after %ld chars (%@) — using partial answer", partial.count, message)
                    return TurnResult(rawText: partial, sentImage: prepared, historyCopyTask: historyCopyTask, signature: signature)
                }
                lastErrorMessage = message
                networkFailures += 1
                if networkFailures > Self.maxNetworkRetries { break retryLoop }
                await backoff(attempt: networkFailures)

            case .fatal(let message):
                lastErrorMessage = message
                break retryLoop
            }
        }

        historyCopyTask?.cancel()
        NSLog("[GeminiLive] Giving up after %ld attempt(s), %.1fs: %@", attempt, Date().timeIntervalSince(started), lastErrorMessage)
        self.lastError = lastErrorMessage
        throw AIBackendError.requestFailed(lastErrorMessage)
    }

    // MARK: - Agent protocol

    /// What the model answers when it must see something and has no image (see system prompt).
    static let captureToken = "[[CAPTURE]]"

    /// Appended by the model when the wearer is ending the conversation ("cảm ơn", "bye"):
    /// the app speaks the goodbye and closes the session instead of waiting for the timeout.
    static let endToken = "[[END]]"

    static func endsConversation(_ raw: String) -> Bool {
        raw.uppercased().contains(endToken)
    }

    static func isCaptureRequest(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix(captureToken)
    }

    // MARK: - Request plumbing

    /// Hard cap on one model call, all retries included.
    nonisolated static let overallDeadline: TimeInterval = 120
    /// Longest silence tolerated between bytes (covers the model "thinking" before its first token).
    nonisolated static let idleTimeout: TimeInterval = 75
    nonisolated static let maxNetworkRetries = 2

    /// Extra URLProtocol classes for the session (tests stub the network with these).
    var urlProtocolClasses: [AnyClass] = [] {
        didSet { session = Self.makeSession(protocolClasses: urlProtocolClasses) }
    }

    /// Keys to use instead of Settings (tests).
    var apiKeysOverride: [String]?

    /// How photo detail is requested. Gemini 3 accepts ULTRA_HIGH only on an image part; older or
    /// smaller models may reject either form — each rejection steps down one level, remembered
    /// for the rest of the run.
    enum MediaResolutionMode: Equatable {
        case perPartUltraHigh, configHigh, none
    }

    /// Request features a model may not support.
    enum Capability: Equatable {
        case mediaResolution, thinking
    }

    private(set) var mediaResolutionMode: MediaResolutionMode = .perPartUltraHigh
    private(set) var thinkingSupported = true

    private var session: URLSession = GeminiLiveService.makeSession(protocolClasses: [])
    private var requestGeneration = 0
    private var imageFingerprintInHistory: Int?

    private nonisolated static func makeSession(protocolClasses: [AnyClass]) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = overallDeadline + 30
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !protocolClasses.isEmpty {
            config.protocolClasses = protocolClasses + (config.protocolClasses ?? [])
        }
        return URLSession(configuration: config)
    }

    /// Step a capability down after the model rejected it. False when there is nothing left to drop.
    private func downgrade(_ capability: Capability) -> Bool {
        switch capability {
        case .mediaResolution:
            switch mediaResolutionMode {
            case .perPartUltraHigh: mediaResolutionMode = .configHigh
            case .configHigh: mediaResolutionMode = .none
            case .none: return false
            }
        case .thinking:
            guard thinkingSupported else { return false }
            thinkingSupported = false
        }
        return true
    }

    /// Outcome of one HTTP attempt, classified for the retry policy.
    enum AttemptOutcome: Equatable {
        case success(String, signature: String?)
        case cancelled
        case rateLimited(retryAfter: TimeInterval?)
        case badKey(String)
        case modelUnavailable(String)
        case unsupportedField(Capability, String)
        case staleSignature(String)
        case serverError(String)
        case network(String, partial: String, signature: String?)
        case fatal(String)
    }

    var historyContainsImage: Bool {
        conversationHistory.contains { turn in
            (turn["parts"] as? [[String: Any]])?.contains { $0["inlineData"] != nil } ?? false
        }
    }

    static func userTurn(text: String, imageData: Data?, perPartMediaResolution: Bool = false) -> [String: Any] {
        var parts: [[String: Any]] = []
        if let imageData {
            var part: [String: Any] = [
                "inlineData": [
                    "mimeType": PhotoPayload.mimeType(for: imageData),
                    "data": imageData.base64EncodedString()
                ]
            ]
            if perPartMediaResolution {
                part["mediaResolution"] = ["level": "MEDIA_RESOLUTION_ULTRA_HIGH"]
            }
            parts.append(part)
        }
        parts.append(["text": text])
        return ["role": "user", "parts": parts]
    }

    /// The model's turn as history: its text, plus the thought signature it ended with (Gemini 3
    /// expects signatures back in multi-turn conversations), mirroring how the stream sent them.
    static func modelTurn(text: String, signature: String?) -> [String: Any] {
        var parts: [[String: Any]] = [["text": text]]
        if let signature, !signature.isEmpty {
            parts.append(["text": "", "thoughtSignature": signature])
        }
        return ["role": "model", "parts": parts]
    }

    private func makeRequestBody(contents: [[String: Any]]) throws -> Data {
        var generationConfig: [String: Any] = [
            "temperature": 0.2,
            // Thinking tokens may count against this budget; 2048 could leave a hard problem with
            // an empty, truncated answer.
            "maxOutputTokens": 8192
        ]
        if mediaResolutionMode == .configHigh {
            generationConfig["mediaResolution"] = "MEDIA_RESOLUTION_HIGH"
        }
        if thinkingSupported {
            // Flash-Lite defaults to MINIMAL; LOW buys a self-check on math (manifesto model 4)
            // for a small latency cost — the spoken answer still streams first.
            generationConfig["thinkingConfig"] = ["thinkingLevel": "LOW"]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": buildSystemPrompt()]]],
            "contents": contents,
            "generationConfig": generationConfig
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private func performStreamingRequest(body: Data, model: String, key: String, generation: Int) async -> AttemptOutcome {
        let endpoint = "https://\(Self.apiHost)/v1beta/models/\(model):streamGenerateContent?alt=sse"
        guard let url = URL(string: endpoint) else { return .fatal("Invalid Gemini URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Header, not URL: query strings end up in logs and proxies.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = body
        request.timeoutInterval = Self.idleTimeout

        var accumulated = ""
        var signature: String?
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .network("No HTTP response", partial: "", signature: nil)
            }
            guard (200...299).contains(http.statusCode) else {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line
                    if errorBody.count > 4000 { break }
                }
                NSLog("[GeminiLive] HTTP error %ld: %@", http.statusCode, errorBody)
                return Self.classifyHTTPError(status: http.statusCode, body: errorBody,
                                              retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            }
            for try await line in bytes.lines {
                guard generation == requestGeneration else { return .cancelled }
                guard let chunk = Self.parseSSELine(line) else { continue }
                if let reason = chunk.blockReason {
                    return .fatal("Gemini blocked the request (\(reason))")
                }
                if let sig = chunk.thoughtSignature { signature = sig }
                guard !chunk.text.isEmpty else { continue }
                accumulated += chunk.text
                if let spoken = Self.streamingSpokenPrefix(from: accumulated), !spoken.isEmpty {
                    onPartialSpoken?(spoken)
                }
            }
            if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .serverError("Empty response from Gemini")
            }
            return .success(accumulated, signature: signature)
        } catch is CancellationError {
            return .cancelled
        } catch {
            if (error as? URLError)?.code == .cancelled { return .cancelled }
            NSLog("[GeminiLive] Request error: %@", error.localizedDescription)
            return .network(error.localizedDescription, partial: accumulated, signature: signature)
        }
    }

    /// Hand a finished reply to the view model (dual-channel parsing happens there).
    private func deliver(_ rawText: String) {
        if let agentMessage = agentMessageCallback {
            agentMessage(rawText)
        } else {
            onOutputTranscription?(Self.parseDualChannel(rawText).spoken)
        }
        onTextReceived?(rawText)
        // Note: For REST calls, turn completion does NOT occur here; it occurs after TTS playback completes.
    }

    /// Append the finished exchange to history (photo as its lighter copy), keeping the last
    /// `maxHistoryEntries` entries.
    private func recordTurn(userText: String, sentImage: Data?, historyCopyTask: Task<Data, Never>?,
                            rawText: String, signature: String?) async {
        var historyImage: Data?
        if let historyCopyTask {
            historyImage = await historyCopyTask.value
        }
        conversationHistory.append(Self.userTurn(text: userText, imageData: historyImage))
        conversationHistory.append(Self.modelTurn(text: rawText, signature: signature))
        if conversationHistory.count > Self.maxHistoryEntries {
            conversationHistory.removeFirst(conversationHistory.count - Self.maxHistoryEntries)
        }
        if let sentImage {
            imageFingerprintInHistory = PhotoPayload.fingerprint(sentImage)
        }
        if !historyContainsImage {
            imageFingerprintInHistory = nil
        }
    }

    private func backoff(attempt: Int) async {
        // Google's guidance: exponential 1, 2, 4 s… with jitter.
        let base = min(8.0, pow(2.0, Double(max(0, attempt - 1))))
        let delay = base + Double.random(in: 0...0.4)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    // MARK: - Response parsing (pure, unit-testable)

    struct StreamChunk: Equatable {
        var text: String
        var finishReason: String?
        var blockReason: String?
        var thoughtSignature: String? = nil
    }

    /// One SSE line (`data: {json}`) → its text delta. Thought parts are skipped; every text part
    /// is joined (models that "think" can put a non-text part first); a thought signature (often
    /// on a final empty-text part) is kept for the history.
    static func parseSSELine(_ line: String) -> StreamChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseResponseObject(json)
    }

    static func parseResponseObject(_ json: [String: Any]) -> StreamChunk {
        var text = ""
        var finishReason: String?
        var signature: String?
        if let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first {
            finishReason = first["finishReason"] as? String
            if let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let sig = part["thoughtSignature"] as? String, !sig.isEmpty { signature = sig }
                    guard (part["thought"] as? Bool) != true else { continue }
                    if let t = part["text"] as? String { text += t }
                }
            }
        }
        let blockReason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String
        return StreamChunk(text: text, finishReason: finishReason, blockReason: blockReason, thoughtSignature: signature)
    }

    static func classifyHTTPError(status: Int, body: String, retryAfter: String?) -> AttemptOutcome {
        let lower = body.lowercased()
        let summary = "HTTP \(status): \(body.prefix(300))"
        switch status {
        case 429:
            return .rateLimited(retryAfter: retryAfter.flatMap { TimeInterval($0) })
        case 401, 403:
            return .badKey(summary)
        case 404:
            return .modelUnavailable(summary)
        case 400:
            if lower.contains("api key") || lower.contains("api_key") {
                return .badKey(summary)
            }
            if lower.contains("mediaresolution") || lower.contains("media_resolution") || lower.contains("media resolution") {
                return .unsupportedField(.mediaResolution, summary)
            }
            if lower.contains("thinking") {
                return .unsupportedField(.thinking, summary)
            }
            if lower.contains("signature") {
                return .staleSignature(summary)
            }
            return .fatal(summary)
        case 408, 500...599:
            return .serverError(summary)
        default:
            return .fatal(summary)
        }
    }

    private static let spokenTagRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:^|\n)\s*[-*•]?\s*(?:\[SPOKEN\]|\*{0,2}SPOKEN(?:\s*:|\*{0,2}\s*:?)|#+\s*SPOKEN)"#)
    private static let displayTagRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:^|\n)\s*[-*•]?\s*(?:\[DISPLAY\]|\*{0,2}DISPLAY(?:\s*:|\*{0,2}\s*:?)|#+\s*DISPLAY)"#)

    /// The SPOKEN channel of a reply that is still streaming in: nil until the SPOKEN tag has
    /// arrived, cut at the DISPLAY tag. Cleaned with the same rules as `parseDualChannel`, so it
    /// is always a prefix of the final spoken text (the sentence streamer relies on that).
    static func streamingSpokenPrefix(from raw: String) -> String? {
        guard let spokenRegex = spokenTagRegex else { return nil }
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let tag = spokenRegex.firstMatch(in: raw, range: full) else { return nil }
        let start = tag.range.location + tag.range.length
        var end = ns.length
        if let displayRegex = displayTagRegex,
           let display = displayRegex.firstMatch(in: raw, range: NSRange(location: start, length: ns.length - start)) {
            end = display.range.location
        }
        guard end > start else { return "" }
        var body = ns.substring(with: NSRange(location: start, length: end - start))
        // A DISPLAY tag that has only half arrived ("\n**DISP") must not leak into speech:
        // hold back a trailing line that could still become the tag.
        if let newline = body.range(of: "\n", options: .backwards) {
            let lastLine = body[newline.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            let core = lastLine.trimmingCharacters(in: CharacterSet(charactersIn: "-*•#[ "))
            if !lastLine.isEmpty && "display".hasPrefix(core) {
                body = String(body[..<newline.lowerBound])
            }
        }
        return cleanChannelText(body)
    }

    // MARK: - Keys, models, rotation & cooldown

    /// Keys from Settings: one or several, separated by commas, semicolons, spaces or new lines.
    /// Never compiled into the app — the repository is public.
    nonisolated static func parseKeys(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.components(separatedBy: CharacterSet(charactersIn: ",; \n\r\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func getAvailableKeyList() -> [String] {
        if let apiKeysOverride { return apiKeysOverride }
        return Self.parseKeys(SettingsManager.shared.settings.geminiAPIKey)
    }

    private var currentKeyIndex = 0
    /// Cooldowns keyed "model|key"; "*" stands for every model (dead key) or every key (missing model).
    private var cooldowns: [String: Date] = [:]

    private func isCoolingDown(model: String, key: String, now: Date) -> Bool {
        [cooldownKey(model, key), cooldownKey(nil, key), cooldownKey(model, nil)].contains { (cooldowns[$0] ?? .distantPast) > now }
    }

    private func cooldownKey(_ model: String?, _ key: String?) -> String {
        "\(model ?? "*")|\(key ?? "*")"
    }

    /// First (model, key) pair that is not cooling down: the primary model with every key before
    /// the fallback model. If everything is cooling down, the pair whose cooldown ends first.
    private func nextCandidate(keys: [String]) -> (model: String, key: String) {
        let now = Date()
        let total = keys.count
        for model in Self.modelChain {
            for i in 0..<total {
                let idx = (currentKeyIndex + i) % total
                if !isCoolingDown(model: model, key: keys[idx], now: now) {
                    currentKeyIndex = (idx + 1) % total
                    return (model, keys[idx])
                }
            }
        }
        var best = (model: Self.modelChain[0], key: keys[0])
        var bestEnd = Date.distantFuture
        for model in Self.modelChain {
            for key in keys {
                let end = [cooldownKey(model, key), cooldownKey(nil, key), cooldownKey(model, nil)]
                    .compactMap { cooldowns[$0] }.max() ?? .distantPast
                if end < bestEnd {
                    bestEnd = end
                    best = (model, key)
                }
            }
        }
        return best
    }

    private func coolDown(model: String?, key: String?, for seconds: TimeInterval) {
        cooldowns[cooldownKey(model, key)] = Date().addingTimeInterval(max(1, seconds))
    }

    /// Forget rotation position, cooldowns and learned model capabilities (tests, fresh start).
    func resetNetworkState() {
        currentKeyIndex = 0
        cooldowns.removeAll()
        mediaResolutionMode = .perPartUltraHigh
        thinkingSupported = true
    }

    // MARK: - Dual Channel Response Parser (Visor line-anchored regex)

    static func parseDualChannel(_ text: String) -> (spoken: String, display: String) {
        let trimmed = text.replacingOccurrences(of: endToken, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenPattern = #"(?i)(?:^|\n)\s*[-*•]?\s*(?:\[SPOKEN\]|\*{0,2}SPOKEN(?:\s*:|\*{0,2}\s*:?)|\#\#+\s*SPOKEN)\s*([\s\S]*?)(?=(?:(?:^|\n)\s*[-*•]?\s*(?:\[DISPLAY\]|\*{0,2}DISPLAY(?:\s*:|\*{0,2}\s*:?)|\#\#+\s*DISPLAY))|$)"#
        let displayPattern = #"(?i)(?:^|\n)\s*[-*•]?\s*(?:\[DISPLAY\]|\*{0,2}DISPLAY(?:\s*:|\*{0,2}\s*:?)|\#\#+\s*DISPLAY)\s*([\s\S]*?)(?=(?:(?:^|\n)\s*[-*•]?\s*(?:\[SPOKEN\]|\*{0,2}SPOKEN(?:\s*:|\*{0,2}\s*:?)|\#\#+\s*SPOKEN))|$)"#

        let spokenRegex = try? NSRegularExpression(pattern: spokenPattern)
        let displayRegex = try? NSRegularExpression(pattern: displayPattern)

        let nsString = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        var spokenPart: String?
        var displayPart: String?

        if let sm = spokenRegex?.firstMatch(in: trimmed, range: fullRange), sm.numberOfRanges > 1 {
            let r = sm.range(at: 1)
            if r.location != NSNotFound {
                spokenPart = nsString.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let dm = displayRegex?.firstMatch(in: trimmed, range: fullRange), dm.numberOfRanges > 1 {
            let r = dm.range(at: 1)
            if r.location != NSNotFound {
                displayPart = nsString.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let s = spokenPart, let d = displayPart {
            let cleanS = cleanChannelText(s)
            let cleanD = cleanChannelText(d)
            return (cleanS.isEmpty ? cleanD : cleanS, cleanD.isEmpty ? cleanS : cleanD)
        } else if let s = spokenPart {
            let cleanS = cleanChannelText(s)
            return (cleanS, cleanS)
        } else if let d = displayPart {
            let cleanD = cleanChannelText(d)
            return (generateSpokenSummary(from: cleanD), cleanD)
        }

        return (trimmed, trimmed)
    }

    private static func generateSpokenSummary(from display: String) -> String {
        let lines = display.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var resultLine: String?
        for line in lines.reversed() {
            let lower = line.lowercased()
            if lower.hasPrefix("kết quả") || lower.hasPrefix("đáp án") || lower.hasPrefix("đáp số") ||
                lower.hasPrefix("nghiệm") || lower.hasPrefix("vậy") || lower.hasPrefix("chọn") ||
                lower.hasPrefix("result") || lower.hasPrefix("answer") || lower.hasPrefix("therefore") ||
                lower.hasPrefix("ответ") || lower.hasPrefix("итог") || lower.hasPrefix("значит") {
                resultLine = line
                break
            }
        }
        let prefix = resultLine ?? lines.first ?? ""
        let cleanPrefix = cleanChannelText(prefix)
        let note = TTSService.containsVietnamese(display)
            ? "Подробное решение — на экране телефона."
            : "The full working is on your phone screen."
        return "\(cleanPrefix). \(note)"
    }

    static func cleanChannelText(_ text: String) -> String {
        var s = text.replacingOccurrences(of: endToken, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"(?i)^\s*[-*•]?\s*(?:\[?(?:SPOKEN|DISPLAY)\]?)\s*:?\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\b(?:SPOKEN|DISPLAY)\b\s*:"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[:\s\-*#]+"#, with: "", options: .regularExpression)
        while let last = s.last, "*# \t\r\n".contains(last) {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    // MARK: - System Prompt (answer-first dual channel, bilingual, agentic photo capture)

    func buildSystemPrompt() -> String {
        let now = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        var prompt = """
        You are a multimodal AI assistant built into Ray-Ban Meta smart glasses and an iPhone. You see the world through the user's first-person glasses camera: real-world scenes, streets, objects, signs, menus, textbooks, math, physics and chemistry problems, computer screens, code, and documents.

        HOW THE USER TALKS TO YOU:
        The user speaks freely, in Russian or in English (sometimes mixed), with no fixed commands. Their words come from speech recognition, so expect misheard words, stray punctuation and small typos — infer what they mean.
        ALWAYS answer in the language the user used in their latest message: Russian question -> Russian answer (грамотный, естественный русский язык); English question -> English answer. If the message has no clear language, answer in Russian.

        PHOTOS:
        Usually the user presses the capture button on the glasses frame, or simply asks. An attached image is the photo from the glasses. Use it whenever the question could be about it (e.g. «что это», «реши это», «что тут написано», "what does this say").
        If the question is clearly unrelated to the photo (general knowledge, chit-chat, time, advice...), ignore the photo and answer normally.
        Follow-up questions may refer to a photo earlier in this conversation; keep using it.
        If the user is asking about something they are looking at but there is NO image anywhere in this conversation, do not guess and do not describe anything: reply with exactly [[CAPTURE]] and nothing else. The app will take a photo with the glasses and ask you again with it attached.

        MODES (decide from the user's words, any language):
        - Visual recognition / places / scene understanding («что это», «где я», «что передо мной»): describe the object, place or scene accurately and add useful, context-aware information.
        - Solve (default): give the answer and the method.
        - Tutor («подскажи», «объясни по шагам», «научи», "explain step by step", "teach me"): do NOT reveal the final answer; give the next step or a hint and ask the user to try, then check what they say.
        - Whole page («вся страница», «все вопросы», "all questions"): answer every question, SPOKEN lists them briefly («первый — А, второй — В»), DISPLAY gives a table with a short reason per question.
        - Read / translate / explain code or text: do exactly that, in the user's language.
        - Ending («спасибо», «пока», «всё, хватит», "thanks", "bye", "that's all"): reply with one short friendly sentence (SPOKEN and DISPLAY the same) and put [[END]] alone on the very last line. Only when the user is clearly finishing, never after a real question.
        Before answering math, physics or chemistry, silently re-check the result (conditions, signs, units); never state an answer you have not verified.

        When solving problems or answering questions, you MUST strictly follow the DUAL-CHANNEL RESPONSE FORMAT:

        SPOKEN:
        Provide a natural spoken explanation in 2 to 4 complete sentences for the glasses speaker, in the user's language. In Solve mode the FIRST sentence states the final answer (it is spoken while the rest is still being generated); the following sentences give the core method and key steps. For a problem with a worked solution, briefly mention that the full solution is on the phone screen.
        NEVER use raw LaTeX, backslashes, or math symbols in SPOKEN (no dollar signs, frac, sqrt, superscripts, subscripts). Spell everything out as words.
        In Russian answers, write every formula, variable, unit and chemical formula in SPOKEN in Russian words exactly the way a Russian teacher reads it aloud, never in Latin letters or symbols: «икс равно двум», «икс в квадрате плюс три икс равно десять», «корень из шестнадцати равен четырём», «аш два о», «аш два эс о четыре», «цэ о два», «натрий хлор», «девять и восемь метра в секунду в квадрате», «ответ — А». In English answers: 'x equals 2', 'the answer is A'.
        For multiple choice questions, explicitly state the question number and the selected option with brief reasoning.

        DISPLAY:
        Complete step-by-step solution for the iPhone screen, in the user's language. Use standard LaTeX ($...$ inline, $$...$$ block display) for all formulas. Provide clear derivations, explanations, and final answer. If multiple choice, clearly state the selected option and rationale. For a simple non-math question, DISPLAY can just repeat the answer with any useful detail.

        The current date and time is \(now) in the user's local time zone. Base any time on this.
        """

        let userPrompt = SettingsManager.shared.settings.userPrompt
        if !userPrompt.isEmpty {
            prompt += "\n\nAdditional instructions from user:\n\(userPrompt)"
        }

        let memories = SettingsManager.shared.settings.memories
        if !memories.isEmpty {
            prompt += "\n\nThings to remember about the user:"
            for (key, value) in memories {
                prompt += "\n- \(key): \(value)"
            }
        }

        return prompt
    }
}
