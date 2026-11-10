// OpenVision - GeminiSettingsView.swift
// Gemini Live API key configuration

import SwiftUI

struct GeminiSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var apiKey: String = ""

    // MARK: - Body

    var body: some View {
        Form {
            // API Key
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("AQ.… или AIza…  (несколько ключей — через запятую)", text: $apiKey)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Ключ")
            } footer: {
                let count = GeminiLiveService.parseKeys(apiKey).count
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: count > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(count > 0 ? Theme.success : Theme.warning)
                        Text(count > 0 ? "\(count) шт. — ключи хранятся в Keychain телефона, не в коде" : "Ключа нет: приложение не может обращаться к Gemini")
                            .foregroundColor(count > 0 ? Theme.success : Theme.warning)
                    }
                    Text("Лимит считается по ПРОЕКТУ и по модели, а не по ключу: больше лимита дают только ключи из разных проектов Google Cloud. Когда у основной модели лимит кончается, приложение само переходит на \(GeminiLiveService.modelChain.dropFirst().joined(separator: ", ")).")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }

            // Help
            Section {
                Link(destination: URL(string: "https://aistudio.google.com/app/apikey")!) {
                    HStack {
                        Text("Получить API-ключ (Google AI Studio)")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }

            } header: {
                Text("Справка")
            } footer: {
                Text("Модели: \(GeminiLiveService.modelChain.joined(separator: " → ")). Ответ приходит потоком: очки читают первое предложение сразу.")
            }

        }
        .navigationTitle("Gemini")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = settingsManager.settings.geminiAPIKey
        }
        .onDisappear {
            saveSettings()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveSettings()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Methods

    private func saveSettings() {
        // Normalised to "key1, key2" — GeminiLiveService.parseKeys reads any separator.
        settingsManager.settings.geminiAPIKey = GeminiLiveService.parseKeys(apiKey).joined(separator: ", ")
        settingsManager.saveNow()
    }
}

#Preview {
    NavigationStack {
        GeminiSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
