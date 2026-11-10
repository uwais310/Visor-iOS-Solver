// OpenVision - SettingsView.swift
// Settings: one brain (Gemini), the glasses, and the voice — nothing else.

import SwiftUI

struct SettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // AI
                Section {
                    NavigationLink {
                        GeminiSettingsView()
                    } label: {
                        HStack {
                            Label("Gemini", systemImage: "sparkles")
                            Spacer()
                            if settingsManager.settings.isGeminiConfigured {
                                Text("\(GeminiLiveService.parseKeys(settingsManager.settings.geminiAPIKey).count) key")
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Нет ключа")
                                    .foregroundColor(Theme.warning)
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(Theme.warning)
                            }
                        }
                    }

                    NavigationLink {
                        AdditionalInstructionsView()
                    } label: {
                        Label("Свои инструкции", systemImage: "text.quote")
                    }

                    NavigationLink {
                        MemoriesView()
                    } label: {
                        HStack {
                            Label("Память", systemImage: "brain")
                            Spacer()
                            Text("\(settingsManager.settings.memories.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("AI")
                }

                // Glasses
                Section {
                    NavigationLink {
                        GlassesSettingsView()
                    } label: {
                        HStack {
                            Label("Очки Ray-Ban Meta", systemImage: "eyeglasses")
                            Spacer()
                            Image(systemName: glassesManager.isRegistered ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundColor(glassesManager.isRegistered ? Theme.success : Theme.warning)
                        }
                    }
                } header: {
                    Text("Устройство")
                }

                // Voice
                Section {
                    NavigationLink {
                        VoiceSettingsView()
                    } label: {
                        HStack {
                            Label("Голос", systemImage: "mic.fill")
                            Spacer()
                            Text(settingsManager.settings.wakeWordEnabled ? settingsManager.settings.wakeWord : "Выкл.")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Голос")
                }

                // Display
                Section {
                    Toggle(isOn: $settingsManager.settings.showTranscripts) {
                        Label("Показывать диалог на экране", systemImage: "text.bubble")
                    }
                } header: {
                    Text("Экран")
                }

                // About
                Section {
                    HStack {
                        Label("Версия", systemImage: "info.circle")
                        Spacer()
                        Text("\(Config.appVersion) (\(Config.buildNumber))")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/darwnlinz1/OpenVision")!) {
                        Label("Исходный код на GitHub", systemImage: "link")
                    }
                } header: {
                    Text("О приложении")
                } footer: {
                    Text("OpenVision — открытое ПО (MIT). Русская сборка.")
                }
            }
            .navigationTitle("Настройки")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
}
