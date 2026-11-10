// OpenVision - GlassesManager.swift
// Singleton manager for Meta Ray-Ban glasses via the Meta Wearables DAT SDK 1.0.
//
// Three things ride on one DeviceSession:
//  • the capture-button link (MWDATInputs) — the glasses' own shutter reaches the app directly,
//    so a photo goes to Gemini without waiting for the Meta AI app to import it to Camera Roll;
//  • full-resolution stills (Camera.photo, up to the sensor's ~12 MP) — "Click & Go";
//  • the video stream (POV recording, and the 720p fallback still via stream.capturePhoto).
// Inputs and Camera.photo are experimental in DAT 1.0: they need the glasses in Developer Mode
// (MetaAppID 0) or Developer Center approval. Every path here falls back to the next one.

import Foundation
import SwiftUI
import CoreMedia
import OSLog
import MWDATCore
import MWDATCamera
import MWDATInputs

/// A press of the glasses' capture button.
enum GlassesButtonPress: String {
    case shortPress
    case hold
    case doublePress
}

/// Manages Meta Ray-Ban glasses registration, connection, camera and capture button.
@MainActor
final class GlassesManager: ObservableObject {
    // MARK: - Singleton

    static let shared = GlassesManager()

    // MARK: - Published Properties

    /// Whether the app is registered with Meta AI
    @Published var isRegistered: Bool = false

    /// Currently connected device identifier
    @Published var connectedDevice: DeviceIdentifier?

    /// Number of connected devices
    @Published var connectedDeviceCount: Int = 0

    /// Whether camera streaming is active
    @Published var isStreaming: Bool = false

    /// Last captured video frame
    @Published var lastFrame: UIImage?

    /// When `lastFrame` was received.
    private(set) var lastFrameTime: Date = .distantPast

    /// Last photo captured through the video stream (stream.capturePhoto)
    @Published var lastPhotoData: Data?

    /// Error message for UI display
    @Published var errorMessage: String?

    /// True while the capture button is routed to the app (Inputs capability active).
    @Published private(set) var isButtonLinkActive: Bool = false

    /// Human-readable state of the capture-button link, for Settings.
    @Published private(set) var buttonLinkStatus: String = "Выкл."

    /// True while a full-resolution photo is being taken / transferred from the glasses.
    @Published private(set) var isTakingPhoto: Bool = false

    // MARK: - Private Properties

    private let wearables = Wearables.shared

    // Session: one per link to the glasses. Camera and Inputs are its children.
    private var deviceSession: DeviceSession?
    private var sessionStarted = false
    private var sessionGeneration = 0
    private var sessionStartTask: Task<DeviceSession?, Never>?
    private var sessionMonitorTask: Task<Void, Never>?
    private var sessionErrorTask: Task<Void, Never>?

    // Camera: attached once per session; the stream and the still shutter compete for it.
    private var camera: Camera?
    private var photoTokens: [any AnyListenerToken] = []
    private var photoStarted = false
    private var pendingPhoto: CheckedContinuation<Data?, Never>?
    private var pendingPhotoID = UUID()
    /// Consecutive full-resolution failures; after two the app stops trying for this session
    /// (Camera.photo not approved / not supported) and goes straight to the stream still.
    private var fullPhotoFailures = 0

    // Capture-button link (MWDATInputs)
    private var wantsButtonLink = false
    private var linkIncludesTouchpad = false
    private var inputs: Inputs?
    private var inputsDrainTask: Task<Void, Never>?
    private var inputsStateToken: (any AnyListenerToken)?
    private var inputsErrorToken: (any AnyListenerToken)?
    private var inputsHasActivated = false
    private var inputsPermissionDenied = false
    private var inputsRevivalTask: Task<Void, Never>?
    private var linkRetryTask: Task<Void, Never>?
    private var linkRetryDelay: UInt64 = 5

    // Listener tokens (retained to keep subscriptions active)
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var stateListenerToken: (any AnyListenerToken)?
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var photoDataListenerToken: (any AnyListenerToken)?
    private var errorListenerToken: (any AnyListenerToken)?

    // MARK: - Callbacks

    /// Called when a video frame is received
    var onVideoFrame: ((UIImage) -> Void)?

    /// Raw sample buffer for every video frame — SessionRecorder muxes the POV video from it.
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Called when a photo arrives through the video stream (stream.capturePhoto)
    var onPhotoCaptured: ((Data) -> Void)?

    /// Called when the wearer presses the glasses' capture button (button link active).
    var onCaptureButton: ((GlassesButtonPress) -> Void)?

    // MARK: - Initialization

    private init() {
        print("[GlassesManager] Initializing")
        setupRegistrationListener()
        setupDevicesListener()
    }

    // MARK: - Registration

    /// Register app with Meta AI
    func register() async throws {
        print("[GlassesManager] Starting registration")

        for await state in wearables.registrationStateStream() {
            if case .registered = state {
                print("[GlassesManager] Already registered")
                isRegistered = true
                return
            }
            break
        }

        try await wearables.startRegistration()
        print("[GlassesManager] Registration initiated, waiting for Meta AI callback")
    }

    /// Unregister app from Meta AI
    func unregister() async {
        print("[GlassesManager] Starting unregistration")
        wantsButtonLink = false
        linkRetryTask?.cancel()
        endSession()

        do {
            try await wearables.startUnregistration()
            isRegistered = false
            connectedDevice = nil
            connectedDeviceCount = 0
            errorMessage = nil
            print("[GlassesManager] Unregistration successful")
        } catch {
            errorMessage = "Не удалось отменить регистрацию: \(error.localizedDescription)"
            print("[GlassesManager] Unregistration error: \(error)")
        }
    }

    // MARK: - Session

    /// The started session for the connected glasses — reused when one is up, otherwise created
    /// and started (≤ 15 s). Concurrent callers share one start attempt.
    /// `reportErrors: false` for background work (the button link's retries): failures go to the
    /// log and the link status, not to an alert the wearer didn't ask for.
    private func ensureSession(reportErrors: Bool = true) async -> DeviceSession? {
        if let session = deviceSession, sessionStarted { return session }
        if let task = sessionStartTask { return await task.value }
        let task = Task { @MainActor [weak self] () -> DeviceSession? in
            guard let self else { return nil }
            return await self.startSession(reportErrors: reportErrors)
        }
        sessionStartTask = task
        let session = await task.value
        sessionStartTask = nil
        return session
    }

    private func startSession(reportErrors: Bool) async -> DeviceSession? {
        func report(_ message: String) {
            print("[GlassesManager] \(message)")
            if reportErrors { errorMessage = message }
        }
        guard isRegistered else {
            report("Нет регистрации в Meta AI")
            return nil
        }
        guard let deviceId = connectedDevice else {
            report("Очки не подключены")
            return nil
        }

        // The SDK's own verdict on whether it can drive this hardware — surfaces firmware/SDK
        // mismatches that otherwise fail as an opaque "Device unavailable" at session start.
        if let device = wearables.deviceForIdentifier(deviceId) {
            print("[GlassesManager] Device \(device.nameOrId()): type=\(device.deviceType()) link=\(device.linkState) compatibility=\(device.compatibility())")
            if device.compatibility() == .deviceUpdateRequired {
                report("Очкам нужно обновление — обнови в приложении Meta AI")
            } else if device.compatibility() == .sdkUpdateRequired {
                report("Очки новее, чем SDK приложения")
            }
        }

        // Tear down whatever is left of an old session first.
        endSession()

        do {
            // SpecificDeviceSelector stays the more reliable choice over AutoDeviceSelector
            let session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: deviceId))
            sessionGeneration += 1
            let generation = sessionGeneration
            deviceSession = session
            sessionStarted = false

            // Subscribe before start() so the .started transition can't be missed.
            let stateStream = session.stateStream()
            sessionMonitorTask = Task { @MainActor [weak self] in
                for await state in stateStream {
                    print("[GlassesManager] Device session state: \(state)")
                    guard let self, generation == self.sessionGeneration else { return }
                    if state == .started {
                        self.sessionStarted = true
                    } else if state == .stopped {
                        self.sessionDidStop(generation: generation)
                        return
                    }
                }
            }
            // The session can abort during startup with the reason only on its error stream.
            let errorStream = session.errorStream()
            sessionErrorTask = Task { @MainActor [weak self] in
                for await error in errorStream {
                    print("[GlassesManager] Device session error: \(error) — \(error.description)")
                    if reportErrors, UIApplication.shared.applicationState == .active {
                        self?.errorMessage = "Ошибка сессии очков: \(error.description)"
                    }
                }
            }

            print("[GlassesManager] Starting device session...")
            try session.start()

            let deadline = Date().addingTimeInterval(15)
            while !sessionStarted, Date() < deadline, deviceSession != nil, generation == sessionGeneration {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard sessionStarted, generation == sessionGeneration else {
                report("Не удалось открыть сессию с очками (таймаут)")
                dumpSDKLogs(since: 30)
                if generation == sessionGeneration { endSession() }
                return nil
            }
            print("[GlassesManager] Device session started")
            return session
        } catch {
            report("Не удалось открыть сессию с очками: \(error.localizedDescription)")
            endSession()
            return nil
        }
    }

    /// The glasses ended the session (folded, out of range, another app took them…).
    private func sessionDidStop(generation: Int) {
        guard generation == sessionGeneration else { return }
        print("[GlassesManager] Device session stopped by the device")
        endSession()
        scheduleLinkRetry()
    }

    /// Stop the session and forget every child (camera, photo, inputs, stream listeners).
    private func endSession() {
        sessionGeneration += 1
        resolvePendingPhoto(nil)
        teardownInputs(removeFromSession: false)
        camera?.stop()
        deviceSession?.stop()
        sessionMonitorTask?.cancel()
        sessionErrorTask?.cancel()
        sessionMonitorTask = nil
        sessionErrorTask = nil
        cleanupStreamListeners()
        photoTokens = []
        photoStarted = false
        camera = nil
        deviceSession = nil
        sessionStarted = false
        isStreaming = false
        lastFrame = nil
        lastFrameTime = .distantPast
    }

    private func ensureCameraPermission() async -> Bool {
        do {
            var status = try await wearables.checkPermissionStatus(.camera)
            if status != .granted {
                print("[GlassesManager] Requesting camera permission...")
                status = try await wearables.requestPermission(.camera)
            }
            guard status == .granted else {
                errorMessage = "Нет разрешения на камеру очков"
                return false
            }
            return true
        } catch {
            errorMessage = "Ошибка разрешения камеры очков: \(error.localizedDescription)"
            print("[GlassesManager] Permission error: \(error)")
            return false
        }
    }

    /// The session's camera, attached once per session (the stream configuration is fixed at
    /// attach time: 720p raw, which the POV recording and the fallback still both use).
    private func cameraForSession(_ session: DeviceSession) -> Camera? {
        if let camera { return camera }
        do {
            let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 30)
            // Order matters: the session must be STARTED before addCamera, else nil.
            guard let cam = try session.addCamera(config: config) else {
                errorMessage = "Не удалось подключить камеру к сессии очков"
                print("[GlassesManager] addCamera returned nil")
                return nil
            }
            camera = cam
            observePhoto(cam)
            return cam
        } catch {
            errorMessage = "Не удалось подключить камеру: \(error.localizedDescription)"
            print("[GlassesManager] addCamera error: \(error)")
            return nil
        }
    }

    // MARK: - Streaming

    /// Start camera streaming from glasses
    func startStreaming() async {
        guard !isStreaming else {
            print("[GlassesManager] Already streaming")
            return
        }
        // A still is crossing: starting the stream now would take the sensor from it.
        guard !isTakingPhoto else {
            print("[GlassesManager] Not starting the stream — a photo is being taken")
            return
        }
        guard isRegistered else {
            errorMessage = "Нет регистрации в Meta AI"
            return
        }
        guard await ensureCameraPermission() else { return }
        print("[GlassesManager] Starting camera stream")
        isStreaming = await wakeCamera() != nil
        reviveInputsIfNeeded()
    }

    /// Start the camera's video stream and wait until frames flow. A camera switched off after
    /// an earlier capture is started again through its stream; if it will not come back, the
    /// session is rebuilt once with a fresh camera.
    private func wakeCamera() async -> Camera? {
        for attempt in 1...2 {
            guard let session = await ensureSession(), let cam = cameraForSession(session) else { return nil }
            setupStreamListeners(stream: cam.stream)
            cam.stream.start()
            if await waitUntil(seconds: 8, { cam.stream.state == .streaming }) { return cam }
            print("[GlassesManager] Camera stream did not start (attempt \(attempt)) — rebuilding the session")
            endSession()
        }
        errorMessage = "Камера очков не запустилась"
        return nil
    }

    /// Stop camera streaming. The session stays up while the capture button is linked (the
    /// button needs it); otherwise it is closed too.
    func stopStreaming() async {
        guard isStreaming || camera != nil || deviceSession != nil else { return }
        print("[GlassesManager] Stopping camera stream")
        guard !isTakingPhoto else { return }   // the photo path stops the camera itself

        if wantsButtonLink, deviceSession != nil {
            stopCameraKeepingSession()
        } else {
            endSession()
        }
        print("[GlassesManager] Streaming stopped")
    }

    /// Camera off (LED off, battery), session and button link kept.
    private func stopCameraKeepingSession() {
        if photoStarted {
            camera?.photo.stop()
            // Cleared now, not on the async .stopped event: a capture right after must start
            // the shutter again instead of firing on one that is going down (PhotoError.notReady).
            photoStarted = false
        }
        camera?.stream.stop()
        camera?.stop()
        cleanupStreamListeners()
        isStreaming = false
        lastFrame = nil
        lastFrameTime = .distantPast
    }

    /// Capture a 720p still from the running video stream (fallback path).
    func capturePhoto() async {
        guard isStreaming, let stream = camera?.stream else {
            errorMessage = "Чтобы снять, камера очков должна быть включена"
            return
        }
        print("[GlassesManager] Capturing photo from stream")
        // Failures surface as StreamError.photoCaptureFailed on the error publisher.
        if !stream.capturePhoto(format: .jpeg) {
            errorMessage = "Не удалось сделать фото"
            print("[GlassesManager] capturePhoto returned false")
        }
    }

    // MARK: - Full-resolution photo (Camera.photo, DAT 1.0, experimental)

    /// Take a standalone still at full sensor resolution (or 1080p) and return its JPEG bytes,
    /// or nil so the caller can fall back to the stream still / Camera Roll.
    ///
    /// The SDK's camera does not power itself: the video stream is started only to wake the
    /// sensor, the still shutter is started once frames prove it is awake, the stream is then
    /// stopped (a running stream makes the still fail), and the capture is fired. The camera
    /// is switched off again afterwards — "Click & Go" — and the button link, which a still
    /// takes down (it crosses on the file-transfer channel), is attached again.
    func resetPhotoFailures() {
        fullPhotoFailures = 0
    }

    func captureFullResolutionPhoto(fullResolution: Bool, timeout: TimeInterval = 25) async -> Data? {
        guard !isTakingPhoto else { return nil }
        guard isRegistered, connectedDevice != nil else { return nil }
        // A recording owns the stream; the stream still is the right tool then.
        guard !isStreaming else { return nil }

        // Reset lockout on explicit capture requests
        fullPhotoFailures = 0

        isTakingPhoto = true
        let startedAt = Date()
        defer {
            isTakingPhoto = false
            reviveInputsIfNeeded()
        }

        guard await ensureCameraPermission() else { return nil }

        // 1. Wake the sensor with the stream (official DAT stream method).
        guard let cam = await wakeCamera() else {
            print("[GlassesManager] Direct photo: the camera never woke")
            noteFullPhotoFailure()
            stopCameraAfterPhoto()
            return nil
        }

        // 2. Official Stable DAT Stream Capture: trigger still without stopping the stream!
        // Video streaming briefly pauses, delivers the full JPEG to photoDataPublisher, and resumes.
        lastPhotoData = nil
        if cam.stream.capturePhoto(format: .jpeg) {
            let streamDeadline = Date().addingTimeInterval(min(timeout, 4.0))
            while Date() < streamDeadline {
                if let photo = lastPhotoData, !photo.isEmpty {
                    stopCameraAfterPhoto()
                    let seconds = String(format: "%.1f", Date().timeIntervalSince(startedAt))
                    print("[GlassesManager] Direct stream still captured: \(photo.count) bytes in \(seconds) s")
                    return photo
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        // 3. Fallback: freshest live video frame from the active sensor
        if let liveFrame = lastFrame?.jpegData(compressionQuality: 0.95) {
            stopCameraAfterPhoto()
            let seconds = String(format: "%.1f", Date().timeIntervalSince(startedAt))
            print("[GlassesManager] Live stream frame captured: \(liveFrame.count) bytes in \(seconds) s")
            return liveFrame
        }

        // 4. Secondary fallback: Camera.photo if supported by developer firmware
        if fullPhotoFailures < 2 {
            if !photoStarted { cam.photo.start() }
            if await waitUntil(seconds: 1.5, { [weak self] in self?.photoStarted == true }) {
                cam.stream.stop()
                _ = await waitUntil(seconds: 1.0, { cam.stream.state == .stopped })
                let captureID = UUID()
                pendingPhotoID = captureID
                let data: Data? = await withCheckedContinuation { continuation in
                    pendingPhoto = continuation
                    cam.photo.capturePhoto(resolution: fullResolution ? .full : .large, quality: .high)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard let self, self.pendingPhotoID == captureID else { return }
                        self.resolvePendingPhoto(nil)
                    }
                }
                if let data, !data.isEmpty {
                    stopCameraAfterPhoto()
                    return data
                }
            }
        }

        stopCameraAfterPhoto()
        noteFullPhotoFailure()
        return nil
    }

    private func noteFullPhotoFailure() {
        fullPhotoFailures += 1
        if fullPhotoFailures >= 2 {
            print("[GlassesManager] Full photo disabled for this session after repeated failures")
        }
    }

    /// Shutter and camera off after a still (the session and button link stay).
    private func stopCameraAfterPhoto() {
        if photoStarted {
            camera?.photo.stop()
            // Cleared now, not on the async .stopped event: a capture right after must start
            // the shutter again instead of firing on one that is going down (PhotoError.notReady).
            photoStarted = false
        }
        camera?.stream.stop()
        camera?.stop()
        isStreaming = false
        if !wantsButtonLink { endSession() }
    }

    private func resolvePendingPhoto(_ data: Data?) {
        guard let continuation = pendingPhoto else { return }
        pendingPhoto = nil
        pendingPhotoID = UUID()
        continuation.resume(returning: data)
    }

    /// Subscribe to the still shutter once per camera: photoDataPublisher replays nothing, so a
    /// listener registered per capture could miss the arrival.
    private func observePhoto(_ cam: Camera) {
        let photo = cam.photo
        photoTokens = []
        photoStarted = false

        photoTokens.append(photo.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                print("[GlassesManager] Photo state: \(state)")
                if case .started = state {
                    self.photoStarted = true
                } else if case .stopped = state {
                    self.photoStarted = false
                    self.resolvePendingPhoto(nil)   // a still cannot outlive its shutter
                }
            }
        })
        photoTokens.append(photo.photoDataPublisher.listen { [weak self] capture in
            let data = capture.imageData
            Task { @MainActor in
                self?.resolvePendingPhoto(data)
            }
        })
        photoTokens.append(photo.errorPublisher.listen { [weak self] error in
            let detail = String(describing: error)
            Task { @MainActor in
                print("[GlassesManager] Photo error: \(detail)")
                self?.resolvePendingPhoto(nil)
            }
        })
        photoTokens.append(photo.transferProgressPublisher.listen { progress in
            print("[GlassesManager] Photo transfer: \(progress.bytesReceived)/\(progress.totalBytes) bytes")
        })
    }

    private func waitUntil(seconds: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: - Capture-button link (MWDATInputs, experimental)

    /// Apply the capture-button settings (Settings screen and app start share this).
    func applySettings(_ settings: AppSettings) async {
        await configureButtonLink(enabled: settings.captureButtonEnabled,
                                  includeTouchpad: settings.captureButtonIncludeTouchpad)
    }

    /// Route the glasses' capture button to the app (or give it back to the glasses).
    /// `includeTouchpad` widens the request to the temple touchpad — only for glasses whose
    /// button presses never arrive otherwise; the touchpad then stops controlling media.
    func configureButtonLink(enabled: Bool, includeTouchpad: Bool) async {
        let changed = includeTouchpad != linkIncludesTouchpad
        wantsButtonLink = enabled
        linkIncludesTouchpad = includeTouchpad
        linkRetryTask?.cancel()
        linkRetryDelay = 5

        guard enabled else {
            teardownInputs(removeFromSession: true)
            buttonLinkStatus = "Выкл."
            if !isStreaming && !isTakingPhoto { endSession() }
            return
        }
        if changed { teardownInputs(removeFromSession: true) }
        await startButtonLink()
    }

    private func startButtonLink() async {
        guard wantsButtonLink, inputs == nil, !inputsPermissionDenied else { return }
        guard isRegistered else { buttonLinkStatus = "Очки не зарегистрированы"; return }
        guard connectedDevice != nil else { buttonLinkStatus = "Жду подключения очков…"; return }

        buttonLinkStatus = "Подключение…"
        guard let session = await ensureSession(reportErrors: false) else {
            buttonLinkStatus = "Не удалось открыть сессию очков"
            scheduleLinkRetry()
            return
        }
        // Attached straight after .started, Inputs can fail once with deviceDisconnected:
        // give the link a beat to settle (Meta's BirdSpotter sample hit this on hardware).
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard wantsButtonLink, inputs == nil, deviceSession != nil else { return }
        attachInputs(to: session)
    }

    private func attachInputs(to session: DeviceSession) {
        // `sources` is a request to the glasses (they route those surfaces to the app instead
        // of their own handler), not a filter. Without the touchpad, back keeps its system role.
        let configuration = linkIncludesTouchpad
            ? InputsConfiguration(sources: [.captouch, .captureButton, .actionButton], consumeBack: true)
            : InputsConfiguration(sources: [.captureButton], consumeBack: false)

        let attached: Inputs?
        do {
            attached = try session.addInputs(configuration: configuration)
        } catch {
            print("[GlassesManager] addInputs failed: \(error)")
            buttonLinkStatus = "Кнопка съёмки не подключилась — пробую ещё…"
            scheduleLinkRetry()
            return
        }
        guard let attached else {
            print("[GlassesManager] addInputs returned nil")
            buttonLinkStatus = "Эти очки не передают кнопку съёмки приложению"
            return
        }

        inputs = attached
        inputsHasActivated = false
        buttonLinkStatus = "Включаю…"

        // The event stream has room for exactly one reader.
        let events = attached.events
        inputsDrainTask = Task { @MainActor [weak self] in
            for await event in events {
                self?.receive(event)
            }
            print("[GlassesManager] Inputs event stream ended")
        }

        inputsStateToken = attached.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                print("[GlassesManager] Inputs state: \(state)")
                if case .active = state {
                    self.inputsHasActivated = true
                    self.isButtonLinkActive = true
                    self.buttonLinkStatus = "Работает"
                    self.linkRetryDelay = 5
                } else if case .inactive = state {
                    // `inactive` is also the state Inputs is born in: only a link that was
                    // active and went quiet (a still crossed, the link blinked) is revived.
                    guard self.inputsHasActivated else { return }
                    self.isButtonLinkActive = false
                    self.buttonLinkStatus = "Переподключение…"
                    self.reviveInputsIfNeeded()
                }
            }
        }
        inputsErrorToken = attached.errorPublisher.listen { [weak self] error in
            let detail = String(describing: error)
            Task { @MainActor in
                guard let self else { return }
                print("[GlassesManager] Inputs error: \(detail)")
                if detail.localizedCaseInsensitiveContains("permissionDenied") {
                    // Not fixable with requestPermission: the capability isn't enabled for the app.
                    self.inputsPermissionDenied = true
                    self.isButtonLinkActive = false
                    self.buttonLinkStatus = "Meta не разрешает приложению кнопку съёмки — включи Developer Mode в Meta AI"
                }
            }
        }
    }

    private func receive(_ event: InputEvent) {
        switch event {
        case let .capture(pressType, source, _):
            let press: GlassesButtonPress
            switch pressType {
            case .shortPress: press = .shortPress
            case .hold: press = .hold
            case .doublePress: press = .doublePress
            @unknown default:
                print("[GlassesManager] Ignored capture press \(pressType)")
                return
            }
            print("[GlassesManager] Capture button: \(press.rawValue) from \(source)")
            onCaptureButton?(press)
        default:
            print("[GlassesManager] Ignored input \(event)")
        }
    }

    /// Remove a dead Inputs and attach a fresh one (it has no start() of its own). Waits until
    /// no still is crossing — a still is what takes the button down in the first place.
    private func reviveInputsIfNeeded() {
        guard wantsButtonLink, !inputsPermissionDenied, inputsRevivalTask == nil else { return }
        guard inputs == nil || !isButtonLinkActive else { return }
        inputsRevivalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inputsRevivalTask = nil }
            while self.isTakingPhoto {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard self.wantsButtonLink, !self.isButtonLinkActive else { return }
            self.teardownInputs(removeFromSession: true)
            if let session = self.deviceSession, self.sessionStarted {
                self.attachInputs(to: session)
            } else {
                await self.startButtonLink()
            }
        }
    }

    private func teardownInputs(removeFromSession: Bool) {
        inputsDrainTask?.cancel()
        inputsDrainTask = nil
        inputsStateToken = nil
        inputsErrorToken = nil
        if removeFromSession, inputs != nil {
            try? deviceSession?.removeInputs()
        }
        inputs = nil
        inputsHasActivated = false
        isButtonLinkActive = false
    }

    /// Try the link again later (glasses folded, out of range, session refused). Backs off to 60 s.
    private func scheduleLinkRetry() {
        guard wantsButtonLink, !inputsPermissionDenied else { return }
        linkRetryTask?.cancel()
        let delay = linkRetryDelay
        linkRetryDelay = min(linkRetryDelay * 2, 60)
        linkRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled, self.wantsButtonLink, self.inputs == nil else { return }
            await self.startButtonLink()
        }
    }

    // MARK: - Private Methods

    private func setupRegistrationListener() {
        registrationTask = Task {
            for await state in wearables.registrationStateStream() {
                await MainActor.run {
                    if case .registered = state {
                        self.isRegistered = true
                        print("[GlassesManager] Registration state: registered")
                    } else {
                        self.isRegistered = false
                        print("[GlassesManager] Registration state: \(state)")
                    }
                }
            }
        }
    }

    private func setupDevicesListener() {
        devicesTask = Task {
            for await devices in wearables.devicesStream() {
                await MainActor.run {
                    let hadDevice = self.connectedDevice != nil
                    self.connectedDeviceCount = devices.count
                    self.connectedDevice = devices.first
                    print("[GlassesManager] Devices updated: \(devices.count) connected")
                    // Glasses came (back) into range: bring the capture button back.
                    if !hadDevice, self.connectedDevice != nil, self.wantsButtonLink, self.inputs == nil {
                        self.linkRetryDelay = 5
                        Task { await self.startButtonLink() }
                    }
                }
            }
        }
    }

    private func setupStreamListeners(stream: MWDATCamera.Stream) {
        stateListenerToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self, !self.isTakingPhoto else { return }   // the photo path drives the stream itself
                switch state {
                case .streaming:
                    self.isStreaming = true
                case .stopped:
                    self.isStreaming = false
                default:
                    break
                }
            }
        }

        videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                self?.onVideoSampleBuffer?(frame.sampleBuffer)
                if let image = frame.makeUIImage() {
                    self?.lastFrame = image
                    self?.lastFrameTime = Date()
                    self?.onVideoFrame?(image)
                }
            }
        }

        photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                let data = photoData.data
                self?.lastPhotoData = data
                self?.onPhotoCaptured?(data)
                print("[GlassesManager] Stream photo captured: \(data.count) bytes")
            }
        }

        errorListenerToken = stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                // The raw codec pauses by design when the app leaves the foreground and the SDK
                // reports that as a scary error — only surface errors seen in the foreground.
                if UIApplication.shared.applicationState == .active {
                    self?.errorMessage = error.localizedDescription
                }
                print("[GlassesManager] Stream error: \(error)")
            }
        }
    }

    /// The DAT SDK logs its teardown reasons via OSLog; on session failure dump every
    /// non-Apple subsystem line from the last `seconds` to stdout.
    private func dumpSDKLogs(since seconds: TimeInterval) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-seconds))
            let entries = try store.getEntries(at: position)
            print("[GlassesManager] ===== SDK log dump (last \(Int(seconds))s) =====")
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                let sub = log.subsystem
                guard !sub.isEmpty, !sub.hasPrefix("com.apple") else { continue }
                print("[SDKLOG] \(sub)/\(log.category) [\(log.level.rawValue)] \(log.composedMessage)")
            }
            print("[GlassesManager] ===== end SDK log dump =====")
        } catch {
            print("[GlassesManager] OSLogStore dump failed: \(error)")
        }
    }

    private func cleanupStreamListeners() {
        stateListenerToken = nil
        videoFrameListenerToken = nil
        photoDataListenerToken = nil
        errorListenerToken = nil
    }
}
