// OpenVision - GlassesSettingsView.swift
// Ray-Ban Meta: registration, the capture button routed to the app, photo quality, status.

import SwiftUI
import MWDATCore

struct GlassesSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var glassesManager: GlassesManager
    @EnvironmentObject var settingsManager: SettingsManager

    // MARK: - State

    @State private var isRegistering: Bool = false
    @State private var errorMessage: String?
    @State private var showingUnregisterConfirmation: Bool = false
    @State private var testPhotoResult: String?
    @State private var isTestingPhoto = false

    // MARK: - Body

    var body: some View {
        Form {
            registrationSection

            if glassesManager.isRegistered {
                captureButtonSection
                photoSection
                statusSection
                toolsSection
            }

            Section {
                Link(destination: URL(string: "https://wearables.developer.meta.com/docs/develop/")!) {
                    HStack {
                        Text("Документация Meta Wearables")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
                NavigationLink {
                    TroubleshootingView()
                } label: {
                    Text("Решение проблем")
                }
            } header: {
                Text("Справка")
            }
        }
        .navigationTitle("Очки Ray-Ban Meta")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settingsManager.settings.captureButtonEnabled) { _, _ in applyButtonLink() }
        .onChange(of: settingsManager.settings.captureButtonIncludeTouchpad) { _, _ in applyButtonLink() }
        .confirmationDialog(
            "Отменить регистрацию очков",
            isPresented: $showingUnregisterConfirmation,
            titleVisibility: .visible
        ) {
            Button("Отменить регистрацию", role: .destructive) {
                Task { await glassesManager.unregister() }
            }
            Button("Нет", role: .cancel) {}
        } message: {
            Text("OpenVision отключится от очков. Чтобы пользоваться дальше, нужно снова зарегистрироваться через Meta AI.")
        }
        .alert("Ошибка", isPresented: .constant(glassesManager.errorMessage != nil)) {
            Button("OK") { glassesManager.errorMessage = nil }
        } message: {
            if let error = glassesManager.errorMessage {
                Text(error)
            }
        }
    }

    // MARK: - Sections

    private var registrationSection: some View {
        Section {
            if glassesManager.isRegistered {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.success)
                    Text("Зарегистрировано")
                        .foregroundColor(Theme.success)
                    Spacer()
                    Button("Отменить регистрацию") {
                        showingUnregisterConfirmation = true
                    }
                    .foregroundColor(Theme.danger)
                    .font(.caption)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Зарегистрируй приложение в Meta AI, чтобы OpenVision мог работать с очками.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button {
                        register()
                    } label: {
                        HStack {
                            Spacer()
                            if isRegistering {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Открываю Meta AI…")
                            } else {
                                Image(systemName: "person.badge.plus")
                                Text("Зарегистрировать")
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRegistering)
                }
            }

            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Theme.warning)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(Theme.warning)
                }
            }
        } header: {
            Text("Регистрация")
        } footer: {
            Text("Сначала включи Developer Mode в приложении Meta AI: Настройки → App Info → нажми на номер версии 5 раз → включи Developer Mode.")
        }
    }

    private var captureButtonSection: some View {
        Section {
            Toggle(isOn: $settingsManager.settings.captureButtonEnabled) {
                Label("Кнопка съёмки управляет приложением", systemImage: "camera.shutter.button")
            }

            if settingsManager.settings.captureButtonEnabled {
                HStack {
                    Text("Статус")
                    Spacer()
                    Circle()
                        .fill(glassesManager.isButtonLinkActive ? Theme.success : Theme.inactive)
                        .frame(width: 8, height: 8)
                    Text(glassesManager.buttonLinkStatus)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                Picker("1 нажатие", selection: $settingsManager.settings.shortPressAction) {
                    ForEach(GlassesButtonAction.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Удержание", selection: $settingsManager.settings.holdAction) {
                    ForEach(GlassesButtonAction.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("2 нажатия", selection: $settingsManager.settings.doublePressAction) {
                    ForEach(GlassesButtonAction.allCases) { Text($0.displayName).tag($0) }
                }

                Toggle(isOn: $settingsManager.settings.captureButtonIncludeTouchpad) {
                    Text("Ловить и тачпад (если кнопка не отвечает)")
                }
            }
        } header: {
            Text("Кнопка съёмки на очках")
        } footer: {
            Text("Фото идёт с очков прямо в приложение и дальше в Gemini, без ожидания импорта в Фото. Это экспериментальная функция Meta (нужен Developer Mode). Если она не работает, приложение берёт последнее фото очков из галереи. При включённом \"тачпаде\" жесты на дужке не управляют музыкой.")
        }
    }

    private var photoSection: some View {
        Section {
            Toggle(isOn: $settingsManager.settings.fullResolutionPhotos) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Фото в полном разрешении")
                    Text(settingsManager.settings.fullResolutionPhotos ? "~12 Мп — виден самый мелкий текст, передаётся дольше" : "1080p — быстрее")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button {
                testPhoto()
            } label: {
                HStack {
                    Label("Пробный снимок", systemImage: "camera")
                    Spacer()
                    if isTestingPhoto {
                        ProgressView()
                    } else if let testPhotoResult {
                        Text(testPhotoResult)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .disabled(isTestingPhoto || glassesManager.isTakingPhoto || glassesManager.connectedDevice == nil)
        } header: {
            Text("Качество фото")
        } footer: {
            Text("Перед отправкой в Gemini фото уменьшается до 3072 px (максимум деталей, который использует Gemini), так что большое фото только дольше передаётся с очков.")
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Text("Очки подключены")
                Spacer()
                Text("\(glassesManager.connectedDeviceCount)")
                    .foregroundColor(.secondary)
            }
            if let device = glassesManager.connectedDevice {
                HStack {
                    Text("Устройство")
                    Spacer()
                    Text(device)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack {
                Text("Camera")
                Spacer()
                if glassesManager.isTakingPhoto {
                    Text("Снимаю…").foregroundColor(Theme.accent)
                } else if glassesManager.isStreaming {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.danger).frame(width: 8, height: 8)
                        Text("Включена").foregroundColor(Theme.danger)
                    }
                } else {
                    Text("Выкл.").foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Статус")
        }
    }

    private var toolsSection: some View {
        Section {
            // Stages/updates the on-glasses developer component via Meta AI. Sessions die with
            // "Device unavailable" when it is missing — this is the SDK's recovery path.
            Button {
                Task {
                    do {
                        try await Wearables.shared.openDATGlassesAppUpdate()
                    } catch {
                        glassesManager.errorMessage = "Не удалось открыть обновление: \(error.localizedDescription)"
                    }
                }
            } label: {
                Label("Установить/обновить компоненты на очках", systemImage: "arrow.down.circle")
            }

            if glassesManager.isStreaming {
                Button {
                    Task { await glassesManager.stopStreaming() }
                } label: {
                    Label("Выключить камеру очков", systemImage: "video.slash")
                }
            }
        } header: {
            Text("Инструменты")
        } footer: {
            Text("Используй, если очки пишут \"Device unavailable\" или сессия сразу обрывается.")
        }
    }

    // MARK: - Methods

    private func applyButtonLink() {
        let settings = settingsManager.settings
        Task { await glassesManager.applySettings(settings) }
    }

    private func testPhoto() {
        isTestingPhoto = true
        testPhotoResult = nil
        let full = settingsManager.settings.fullResolutionPhotos
        Task {
            let started = Date()
            if let data = await glassesManager.captureFullResolutionPhoto(fullResolution: full) {
                let size = UIImage(data: data).map { "\(Int($0.size.width * $0.scale))×\(Int($0.size.height * $0.scale))" } ?? "?"
                testPhotoResult = String(format: "%@ · %.1f s", size, Date().timeIntervalSince(started))
            } else {
                testPhotoResult = "Не удалось снять"
            }
            isTestingPhoto = false
        }
    }

    private func register() {
        isRegistering = true
        errorMessage = nil

        Task {
            do {
                try await glassesManager.register()
                isRegistering = false
            } catch {
                isRegistering = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Troubleshooting View

struct TroubleshootingView: View {
    var body: some View {
        List {
            Section("Регистрация") {
                TroubleshootingItem(
                    title: "Meta AI не открывается",
                    solution: "Установи приложение Meta AI и войди в аккаунт."
                )
                TroubleshootingItem(
                    title: "Регистрация не проходит",
                    solution: "Включи Developer Mode в приложении Meta AI и попробуй снова."
                )
            }

            Section("Кнопка съёмки") {
                TroubleshootingItem(
                    title: "Нажимаю кнопку, а приложение молчит",
                    solution: "Посмотри Статус в разделе кнопки. Если там \"Meta не разрешает\", включи Developer Mode. Если \"Работает\", но тишина — включи \"Ловить и тачпад\"."
                )
                TroubleshootingItem(
                    title: "Фото приходит долго",
                    solution: "Выключи \"Фото в полном разрешении\" — 1080p быстрее, а печатный текст всё равно читается."
                )
            }

            Section("Подключение") {
                TroubleshootingItem(
                    title: "Очки не видны",
                    solution: "Раскрой дужки, надень очки и проверь, что они подключены к iPhone по Bluetooth."
                )
                TroubleshootingItem(
                    title: "Камера не включается",
                    solution: "Закрой другие приложения, которые используют очки (с очками одновременно работает только одно)."
                )
            }
        }
        .navigationTitle("Решение проблем")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TroubleshootingItem: View {
    let title: String
    let solution: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(solution)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        GlassesSettingsView()
            .environmentObject(GlassesManager.shared)
            .environmentObject(SettingsManager.shared)
    }
}
