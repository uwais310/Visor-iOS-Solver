// OpenVision - VoiceSettingsView.swift
// Voice: wake word, microphone, listening language, answer voices (one per language), speed.

import SwiftUI
import AVFoundation

struct VoiceSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager

    // MARK: - Helpers

    private func voiceName(_ identifier: String?, language: String) -> String {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice.name
        }
        return TTSService.bestVoice(for: language).map { "Авто · \($0.name)" } ?? "Авто"
    }

    // MARK: - Body

    var body: some View {
        Form {
            // Wake word
            Section {
                Toggle(isOn: $settingsManager.settings.wakeWordEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Слово-обращение")
                        Text("Слушает вопрос только после этого слова")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if settingsManager.settings.wakeWordEnabled {
                    TextField("Клод", text: $settingsManager.settings.wakeWord)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Как позвать")
            } footer: {
                Text("Скажи \"\(settingsManager.settings.wakeWord)\" и спрашивай свободно, по-русски или по-английски. Варианты вроде \"Эй, Клод\" тоже подходят.")
            }

            // Listening
            Section {
                Toggle(isOn: $settingsManager.settings.preferGlassesMic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Микрофон очков")
                        Text("Полностью без рук, пока очки на тебе")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Picker("Язык распознавания", selection: $settingsManager.settings.recognitionLanguage) {
                    Text("Авто (как на iPhone)").tag("auto")
                    Text("Русский").tag("ru-RU")
                    Text("English").tag("en-US")
                }

                Picker("Завершать при тишине", selection: $settingsManager.settings.conversationTimeout) {
                    Text("15 сек").tag(TimeInterval(15))
                    Text("30 сек").tag(TimeInterval(30))
                    Text("1 мин").tag(TimeInterval(60))
                    Text("2 мин").tag(TimeInterval(120))
                }
            } header: {
                Text("Микрофон")
            } footer: {
                Text("iOS распознаёт один язык за раз: выбери тот, на котором спрашиваешь чаще. Ответ всегда на языке вопроса. Смена языка действует со следующего обращения.")
            }

            // Answer voices
            Section {
                NavigationLink {
                    VoiceSelectionView(languagePrefix: "ru", title: "Русский голос",
                                       sample: "Привет, ответ в этом задании: икс равно двум.",
                                       selection: $settingsManager.settings.selectedVietnameseVoiceIdentifier)
                } label: {
                    HStack {
                        Text("Русский голос")
                        Spacer()
                        Text(voiceName(settingsManager.settings.selectedVietnameseVoiceIdentifier, language: "ru-RU"))
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink {
                    VoiceSelectionView(languagePrefix: "en", title: "English voice",
                                       sample: "Hello! The answer to this question is x equals 2.",
                                       selection: $settingsManager.settings.selectedVoiceIdentifier)
                } label: {
                    HStack {
                        Text("Английский голос")
                        Spacer()
                        Text(voiceName(settingsManager.settings.selectedVoiceIdentifier, language: "en-US"))
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Скорость речи")
                        Spacer()
                        Text(String(format: "%.0f%%", settingsManager.settings.speechRate / 0.5 * 100))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settingsManager.settings.speechRate, in: 0.35...0.6, step: 0.025)
                        .tint(Theme.accent)
                }
            } header: {
                Text("Голос ответа")
            } footer: {
                Text("Каждое предложение читается голосом своего языка. Формулы читаются словами (\"икс в квадрате\", \"равно\", \"плюс\").")
            }

            // Feedback
            Section {
                Toggle(isOn: $settingsManager.settings.playActivationSound) {
                    Text("Звук при обращении")
                }
            } header: {
                Text("Отклик")
            }
        }
        .navigationTitle("Голос")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        VoiceSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
