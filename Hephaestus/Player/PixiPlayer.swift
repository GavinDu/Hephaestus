import SwiftUI
import WebKit

// MARK: - Player presentation
//
// The player is the PixiJS + Rapier Game IR runtime — the single runtime
// since the 2026-10-20 consolidation (the native Swift IR interpreter in
// GameIRRuntime.swift was removed, along with Defold and Godot). The
// runtime is served by the backend at /player and embedded here in a
// bridgeless WKWebView: no WKScriptMessageHandler, no evaluateJavaScript
// control channel, no native API exposure (App Store Guideline 4.7
// posture). The web player loads its Game IR package over HTTPS from the
// backend exactly like any browser; this shell only hosts the page and
// surfaces load failures honestly.

struct PixiPlayerRequest: Identifiable {
    let id = UUID()
    let gameID: String
    let title: String
}

struct PixiPlayerSheet: View {
    let gameID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var attempt = 0

    private var playerURL: URL? {
        var components = URLComponents(url: BackendConfig.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/player"
        components?.queryItems = [URLQueryItem(name: "game", value: gameID)]
        return components?.url
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let url = playerURL {
                    PlayerWebView(
                        url: url,
                        onLoadFinish: {
                            isLoading = false
                            loadError = nil
                            DevLog.info(.player, "player loaded \(gameID)")
                        },
                        onLoadFail: { message in
                            isLoading = false
                            loadError = message
                            DevLog.error(.player, "player load failed for \(gameID): \(message)")
                        }
                    )
                    .id(attempt)
                    .ignoresSafeArea(edges: .bottom)
                }

                if isLoading && loadError == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading \(title)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let loadError {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Couldn't load the player")
                            .font(.headline)
                        Text(loadError)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Retry") {
                            self.loadError = nil
                            isLoading = true
                            attempt += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                DevLog.info(.player, "player opened for \(gameID) — loading /player in WebView")
            }
        }
    }
}

// MARK: - Bridgeless WKWebView host

private struct PlayerWebView: UIViewRepresentable {
    let url: URL
    let onLoadFinish: () -> Void
    let onLoadFail: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadFinish: onLoadFinish, onLoadFail: onLoadFail)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Deliberately no script message handlers and no user scripts:
        // the web runtime must not reach native code (bridgeless).
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reloads happen by recreating the view (see .id(attempt) in the
        // sheet), so there is nothing to update in place.
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoadFinish: () -> Void
        let onLoadFail: (String) -> Void

        init(onLoadFinish: @escaping () -> Void, onLoadFail: @escaping (String) -> Void) {
            self.onLoadFinish = onLoadFinish
            self.onLoadFail = onLoadFail
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadFinish()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadFail(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadFail(error.localizedDescription)
        }
    }
}
