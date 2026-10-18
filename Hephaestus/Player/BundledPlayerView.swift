import Combine
import Foundation
import SwiftUI
import WebKit

/// The player runtime version bundled in this app (see
/// Player/Resources/bundled-player.html, `HephaestusBoot.SHIM_VERSION`).
/// The container refuses to boot a game whose package requires anything else.
let bundledRuntimeVersion = "gameshim/v1"

// MARK: - Package models (mirror GET /v1/games/{id}/package)

struct RuntimeRequirement: Codable {
    var required: String
    var kind: String
    var version: String
}

struct PackageAsset: Codable {
    var id: String
    var kind: String
    var url: String
    var mime: String?
    var source: String?
    var label: String?
}

struct PackageData: Codable {
    var entry: PackageAsset
    var sprites: [PackageAsset]
    var music: PackageAsset?
}

struct GamePackageResponse: Codable {
    var packageVersion: String
    var gameId: String
    var runtime: RuntimeRequirement
    var data: PackageData
}

// MARK: - Load + handshake state machine

/// Fetches the data-package descriptor and checks the runtime handshake
/// before the WebView boots. The handshake lives in Swift — never in JS —
/// so the WebView itself stays bridgeless (no script message handlers).
@MainActor
final class BundledPlayerState: ObservableObject {
    enum Phase {
        case loading
        case ready(GamePackageResponse)
        case mismatch(required: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading

    func load(gameID: String) async {
        phase = .loading
        let url = BackendConfig.baseURL
            .appendingPathComponent("v1/games/\(gameID)/package")
        do {
            var req = URLRequest(url: url)
            req.setValue(BackendConfig.userID, forHTTPHeaderField: "X-User-ID")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                phase = .failed("Couldn't load this game (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)).")
                return
            }
            let pkg = try JSONDecoder().decode(GamePackageResponse.self, from: data)
            if pkg.runtime.required == bundledRuntimeVersion {
                phase = .ready(pkg)
            } else if pkg.runtime.required.isEmpty {
                phase = .mismatch(required: "unknown — this game predates runtime versioning")
            } else {
                phase = .mismatch(required: pkg.runtime.required)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Bridgeless WKWebView container

/// WKWebView that runs the bundled player runtime. The runtime HTML ships in
/// the app binary; only game *data* (the package descriptor + assets) comes
/// from the network. Swift talks to JS one-way via evaluateJavaScript —
/// deliberately no WKScriptMessageHandlers, so game code can never call into
/// native code (App Store guideline 4.7.2 posture: no native API exposure).
struct BundledPlayerView: UIViewRepresentable {
    let package: GamePackageResponse
    let baseURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Load the bundled shell once; the coordinator boots the game on finish.
        if webView.url == nil {
            guard let shellURL = Bundle.main.url(forResource: "bundled-player", withExtension: "html") else {
                print("[Hephaestus] bundled-player.html missing from app bundle — add it to the Xcode target")
                return
            }
            webView.loadFileURL(shellURL, allowingReadAccessTo: shellURL.deletingLastPathComponent())
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(package: package, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let package: GamePackageResponse
        let baseURL: URL

        init(package: GamePackageResponse, baseURL: URL) {
            self.package = package
            self.baseURL = baseURL
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // One-way injection: base64 keeps arbitrary game data out of
            // JS string-quoting hazards. The shell decodes and boots.
            guard let json = try? JSONEncoder().encode(package) else { return }
            let b64 = json.base64EncodedString()
            let base = baseURL.absoluteString
            let js = "window.HephaestusBoot && window.HephaestusBoot.bootGame('\(b64)', '\(base)')"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    print("[Hephaestus] boot injection failed: \(error.localizedDescription)")
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            print("[Hephaestus] bundled shell failed to load: \(error.localizedDescription)")
        }
    }
}

// MARK: - Full-screen sheet

/// Request type for presenting the bundled player (game-ID based).
struct BundledPlayerRequest: Identifiable {
    let id = UUID()
    let gameID: String
    let title: String
}

struct BundledPlayerSheet: View {
    let gameID: String
    let title: String

    @StateObject private var state = BundledPlayerState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch state.phase {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading game…").foregroundStyle(.secondary)
                    }
                case .ready(let pkg):
                    BundledPlayerView(package: pkg, baseURL: BackendConfig.baseURL)
                        .ignoresSafeArea(edges: .bottom)
                case .mismatch(let required):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.yellow)
                        Text("Update required").font(.headline)
                        Text("This game needs player runtime \(required), but this app bundles \(bundledRuntimeVersion). Update Hephaestus to play it.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("Couldn't load the game").font(.headline)
                        Text(message).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await state.load(gameID: gameID) }
    }
}
