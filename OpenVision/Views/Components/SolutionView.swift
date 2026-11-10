// OpenVision - SolutionView.swift
// The phone half of the dual channel: renders the DISPLAY answer (Markdown + LaTeX) offline with
// the bundled KaTeX + marked in Resources/SolutionRenderer. The glasses speak SPOKEN; this is the
// "bảng phụ đạo" the wearer glances at for the step-by-step derivation.

import SwiftUI
import WebKit

/// Offline Markdown + LaTeX renderer (WKWebView over Resources/SolutionRenderer/index.html).
struct SolutionWebView: UIViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.dataDetectorTypes = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        if let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "SolutionRenderer") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        context.coordinator.show(markdown)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(markdown)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var loaded = false
        private var pending: String?
        private var shown: String?

        func show(_ markdown: String) {
            guard markdown != shown else { return }
            pending = markdown
            flush()
        }

        private func flush() {
            guard loaded, let markdown = pending, let webView else { return }
            pending = nil
            shown = markdown
            // JSON-encode the text so any quote/backslash/newline reaches JavaScript intact.
            guard let data = try? JSONSerialization.data(withJSONObject: [markdown]),
                  let array = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("render(\(array)[0])", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            flush()
        }

        /// Only the bundled page may load; links in an answer open in Safari instead.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if url.isFileURL { return .allow }
            if navigationAction.navigationType == .linkActivated {
                _ = await UIApplication.shared.open(url)
            }
            return .cancel
        }
    }
}

/// Full-screen sheet with the rendered step-by-step solution.
struct SolutionSheet: View {
    let markdown: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                SolutionWebView(markdown: markdown)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("Решение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                        .foregroundColor(Theme.accent)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = markdown
                        copied = true
                        HapticFeedback.success()
                    } label: {
                        Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .foregroundColor(Theme.accent)
                    .accessibilityLabel("Копировать решение")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Compact entry point under the spoken answer: "Xem lời giải".
struct SolutionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "function")
                Text("Открыть подробное решение")
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(.black.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.buttonGradient))
        }
        .accessibilityHint("Открывает решение по шагам с формулами")
    }
}

/// A solution opened in a sheet.
struct SolutionItem: Identifiable {
    let id = UUID()
    let markdown: String
}
