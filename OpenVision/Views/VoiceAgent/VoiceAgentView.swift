// OpenVision - VoiceAgentView.swift
// Beautiful main voice conversation UI with glassmorphism design.
//
// MVVM: this view only renders state and forwards interactions — every piece of orchestration
// (session lifecycle, command routing, live video, TTS streaming) lives in VoiceAgentViewModel.

import SwiftUI

struct VoiceAgentView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager

    // MARK: - ViewModel

    @StateObject private var viewModel = VoiceAgentViewModel()

    // MARK: - Observed services
    // Only the services whose @Published state the body reacts to directly. They are the same
    // singletons the ViewModel drives — observed here purely so onChange fires.

    @StateObject private var voiceCommandService = VoiceCommandService.shared
    @StateObject private var ttsService = TTSService.shared
    @StateObject private var photoScanner = RecentPhotoScanner.shared

    /// The solution open in the sheet — frozen when opened, so a new question doesn't blank it.
    @State private var openSolution: SolutionItem?

    /// Typed prompt input for keyboard composer ("nhập prompt")
    @State private var typedPrompt: String = ""
    @FocusState private var isPromptFocused: Bool

    // MARK: - Body

    var body: some View {
        ZStack {
            // Beautiful animated background
            AnimatedBackground()

            // Particle effects
            ParticleEffect(particleCount: 30)
                .opacity(0.5)

            // Main content — the orb stays vertically centered and STABLE.
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 8)
                Spacer()
                centerContent
                Spacer()

                // Bottom prompt composer bar ("nhập prompt")
                promptComposerBar
                    .padding(.bottom, 8)
            }

            // Transcript floats above composer; appears immediately when a photo is attached or text flows.
            if settingsManager.settings.showTranscripts
                && (!viewModel.userTranscript.isEmpty || !viewModel.aiTranscript.isEmpty || viewModel.currentTranscriptPhotoData != nil || viewModel.agentState == .thinking) {
                VStack(spacing: 8) {
                    Spacer()

                    // Visor parity: Status indicator while waiting for high-resolution photo transfer
                    if let status = viewModel.statusMessage {
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: Theme.accent))
                                .scaleEffect(0.8)
                            Text(status)
                                .font(.caption.bold())
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.75))
                                .overlay(Capsule().stroke(Theme.accent.opacity(0.6), lineWidth: 1))
                        )
                        .transition(.scale.combined(with: .opacity))
                    }

                    transcriptArea
                        .padding(.bottom, 68)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Error overlay
            if let error = viewModel.errorMessage {
                errorOverlay(error)
            }
        }
        // Animate the state text and the transcript's appear/disappear only — NOT every streamed
        // token (the old .spring on userTranscript/aiTranscript sprang the whole view and jostled
        // the orb on every word).
        .animation(.easeInOut(duration: 0.3), value: viewModel.agentState)
        .animation(.easeInOut(duration: 0.35), value: viewModel.userTranscript.isEmpty)
        .animation(.easeInOut(duration: 0.35), value: viewModel.aiTranscript.isEmpty)
        // Attached to the root (not the transcript, which comes and goes) so the solution stays
        // open after the session ends.
        .sheet(item: $openSolution) { item in
            SolutionSheet(markdown: item.markdown)
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .task {
            await viewModel.requestSpeechAuthorization()
        }
        // Observe TTS state changes
        .onChange(of: ttsService.isSpeaking) { _, isSpeaking in
            viewModel.ttsSpeakingChanged(isSpeaking)
        }
        // Control thinking sound based on agent state
        .onChange(of: viewModel.agentState) { _, newState in
            viewModel.agentStateChanged(newState)
        }
        // Observe VoiceCommandService state changes
        .onChange(of: voiceCommandService.state) { _, newState in
            viewModel.voiceStateChanged(newState)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            StatusPill(
                status: settingsManager.settings.backendDisplayName,
                color: viewModel.agentState == .idle ? Theme.inactive : Theme.success,
                isConnected: viewModel.agentState != .idle && viewModel.agentState != .connecting
            )

            Spacer()

            // Transient "Saved to Photos" / failure status after a recording finishes.
            if let status = viewModel.recordingStatus {
                Text(status)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .transition(.opacity)
            }

            // POV recording toggle (glasses video + as-heard audio → Photos).
            if glassesManager.isRegistered {
                Button {
                    viewModel.toggleRecording()
                } label: {
                    Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.title2)
                        .foregroundColor(viewModel.isRecording ? Theme.danger : Theme.textPrimary)
                        .padding(.horizontal, 4)
                }
                .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Record point of view")
            }

            // Photo readiness: the glasses photo the next question will use (temple shutter →
            // Camera Roll, or the SDK camera). Tap to take one with the glasses camera.
            Button {
                Task { await viewModel.snapPhotoFromGlasses() }
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    photoBadge(now: timeline.date)
                }
            }
            .accessibilityLabel("Снять фото очками")

            // Glasses status
            HStack(spacing: 8) {
                Image(systemName: "eyeglasses")
                    .foregroundColor(glassesManager.isRegistered ? Theme.success : Theme.inactive)

                if glassesManager.isStreaming {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Center Content

    /// Map the agent state to the orb's visual mode.
    private var orbMode: SwirlOrb.Mode {
        switch viewModel.agentState {
        case .listening: return .listening
        case .speaking: return .speaking
        case .thinking, .connecting: return .thinking
        case .idle: return .idle
        }
    }

    private var centerContent: some View {
        VStack(spacing: 28) {
            // Heading / status prompt
            Group {
                if viewModel.agentState == .idle && settingsManager.settings.wakeWordEnabled {
                    VStack(spacing: 8) {
                        Text("Спрашивай что угодно")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.heading)
                        if viewModel.isVoiceReady {
                            Text("Скажи \"\(settingsManager.settings.wakeWord)\" и вопрос — или нажми кнопку на очках")
                                .font(.subheadline)
                                .foregroundColor(Theme.textSecondary)
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().tint(Theme.accent).scaleEffect(0.8)
                                Text("Запускаю голос…")
                                    .font(.subheadline)
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            .transition(.opacity)

            // The assistant identity: swirling emerald orb (tap to start/stop a session)
            SwirlOrb(mode: orbMode, size: 250)
                .onTapGesture { viewModel.toggleSession() }

            // Status text
            Text(viewModel.agentState.displayText)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(Theme.textPrimary)
        }
    }

    // MARK: - Transcript Area

    // Bubbles float directly over the background (no outer card box — the old GlassCard wrapper
    // was a mostly-empty gray slab).
    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranscriptView(
                userText: viewModel.userTranscript,
                aiText: viewModel.aiTranscript,
                isAIStreaming: viewModel.agentState == .speaking,
                userPhotoData: viewModel.currentTranscriptPhotoData,
                onDetachPhoto: { viewModel.detachPhoto() }
            )
            if let solution = viewModel.latestSolution {
                SolutionButton { openSolution = SolutionItem(markdown: solution) }
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.25), value: viewModel.latestSolution == nil)
    }

    // MARK: - Prompt Composer Bar

    private var promptComposerBar: some View {
        HStack(spacing: 10) {
            // Camera snap button
            Button {
                Task { await viewModel.snapPhotoFromGlasses() }
            } label: {
                Image(systemName: viewModel.currentTranscriptPhotoData != nil ? "camera.fill" : "camera")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(viewModel.currentTranscriptPhotoData != nil ? Theme.accent : Theme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().stroke(Theme.accent.opacity(viewModel.currentTranscriptPhotoData != nil ? 0.8 : 0.2), lineWidth: 1))
            }
            .accessibilityLabel("Снять фото очками")

            // Text input field for typing prompt
            TextField("Напиши вопрос или скажи его…", text: $typedPrompt)
                .font(.subheadline)
                .foregroundColor(Theme.textPrimary)
                .focused($isPromptFocused)
                .submitLabel(.send)
                .onSubmit {
                    submitPrompt()
                }

            // Send button or mic listening indicator
            if !typedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    submitPrompt()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(Theme.accent)
                }
                .transition(.scale.combined(with: .opacity))
            } else if viewModel.agentState == .listening {
                Image(systemName: "waveform")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        )
        .padding(.horizontal, 16)
    }

    private func submitPrompt() {
        let text = typedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedPrompt = ""
        isPromptFocused = false
        viewModel.sendTypedCommand(text)
    }

    // MARK: - Photo badge

    /// The photo the next question will use: a thumbnail and how long ago it was taken, or a plain
    /// camera when there is none. Green while it is still within the 120 s window.
    @ViewBuilder
    private func photoBadge(now: Date) -> some View {
        let contextAge = viewModel.activePhotoContext.map { now.timeIntervalSince($0.timestamp) }
        let libraryAge = photoScanner.latestPhotoDate.map { now.timeIntervalSince($0) }
        let age = [contextAge, libraryAge].compactMap { $0 }.filter { $0 >= 0 }.min()
        let ready = (age ?? .infinity) < SolverIntent.recentPhotoWindow
            && (viewModel.activePhotoContext?.isFresh(at: now) ?? true)
        HStack(spacing: 6) {
            if ready, let thumbnail = photoScanner.latestThumbnail, libraryAge == age {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: ready ? "camera.fill" : "camera")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(ready ? Theme.success : Theme.textPrimary)
            }
            if ready, let age {
                Text("\(Int(age))s")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundColor(Theme.success)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(ready ? Theme.success.opacity(0.6) : Theme.bgElevatedStroke, lineWidth: 1))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ready ? "Есть фото с очков, снято \(Int(age ?? 0)) сек. назад" : "Фото нет")
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ message: String) -> some View {
        VStack {
            Spacer()

            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Theme.warning)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white)

                Spacer()

                Button {
                    viewModel.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.danger.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
            .padding(.bottom, 150)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    VoiceAgentView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
        .preferredColorScheme(.dark)
}
