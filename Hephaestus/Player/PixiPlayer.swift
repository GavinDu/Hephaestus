import Combine
import Network
import SwiftUI
import UIKit
import WebKit

// MARK: - Player presentation
//
// The player is the PixiJS + Rapier Game IR runtime — the single runtime
// since the 2026-10-20 consolidation. The runtime is served by the backend
// at /player and embedded here in a bridgeless WKWebView: no
// WKScriptMessageHandler, no evaluateJavaScript control channel, no
// native API exposure (App Store Guideline 4.7 posture). Everything this
// shell does for resource control, performance, and telemetry respects
// that boundary:
//   - performance reaches the page only as a URL parameter (?quality=),
//     never as a script call;
//   - telemetry leaves the app as ordinary HTTPS POSTs from the app's
//     own networking (the same endpoint the page beacons to), never as
//     a message from the page;
//   - lifecycle signals come from WKNavigationDelegate, KVO on the web
//     view, and OS notifications — all native-side.

struct PixiPlayerRequest: Identifiable {
    let id = UUID()
    let gameID: String
    let title: String
}

// MARK: - Quality (performance control)

/// The family's quality preference for the player. `auto` resolves at
/// load time from device pressure: Low Power Mode or a serious/critical
/// thermal state drops the effective quality to low. The effective value
/// reaches the runtime as ?quality=, where low caps render resolution
/// at 1x, disables antialiasing, and shrinks particle pools.
enum PlayerQuality: String, CaseIterable {
    case auto, high, low

    static let defaultsKey = "hephaestus.playerQuality"

    static func effective(preference: PlayerQuality) -> String {
        switch preference {
        case .high:
            return "high"
        case .low:
            return "low"
        case .auto:
            let info = ProcessInfo.processInfo
            if info.isLowPowerModeEnabled { return "low" }
            switch info.thermalState {
            case .serious, .critical:
                return "low"
            default:
                return "high"
            }
        }
    }
}

// Social quick-exit events are emitted only when a loaded game is dismissed
// within five seconds. Longer sessions are not labeled as quick exits.
enum GameplayTelemetryPolicy {
    static let quickExitThresholdMS = 5_000

    static func shouldTrackQuickExit(durationMS: Int) -> Bool {
        durationMS >= 0 && durationMS < quickExitThresholdMS
    }
}

/// Keeps transient network state from covering a game that has already loaded.
enum PlayerLoadingPolicy {
    static func shouldShowOfflineOverlay(isOffline: Bool, isLoading: Bool, hasError: Bool) -> Bool {
        isOffline && isLoading && !hasError
    }
}
/// A foreground transition should only restart a failed load when connectivity
/// is available. Loaded gameplay is never reloaded just because the app resumed.
enum PlayerLifecyclePolicy {
    static func shouldRetryAfterForeground(wasBackgrounded: Bool, isOffline: Bool, hasError: Bool) -> Bool {
        wasBackgrounded && !isOffline && hasError
    }
}

// MARK: - Telemetry (monitoring)

/// Fire-and-forget reports to the backend's telemetry endpoint — the
/// same store the web runtime beacons its errors to, so one incidents
/// view covers web and native player health. Kinds: `perf` samples are
/// filed server-side but never counted as incidents; the `ios-*` kinds
/// are real failure signals and aggregate like web errors. Payloads
/// carry no account identifiers and no user content — game id, event
/// kind, a message, and the tail of the on-device dev log.
enum PlayerTelemetry {
    static func report(gameID: String?, kind: String, name: String, message: String) {
        let tail = DevLog.shared.exportText()
            .split(separator: "\n").suffix(20).map(String.init)
        let report = BackendAPI.PlayerTelemetryReport(
            gameId: gameID ?? "",
            runtimeVersion: "ios-player-1.1",
            kind: kind,
            name: name,
            message: message,
            logTail: tail
        )
        Task.detached {
            await BackendAPI.shared.postPlayerTelemetry(report)
        }
    }
}

// MARK: - Reachability

/// Minimal path monitor for the player sheet: an offline device should
/// get an honest offline state, not an endless spinner.
final class PlayerPathMonitor: ObservableObject {
    @Published var isOffline = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "hephaestus.player.path")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOffline = path.status != .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

// MARK: - Sheet

struct PixiPlayerSheet: View {
    let gameID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var attempt = 0
    @State private var progress: Double = 0
    @State private var showSlowHint = false
    @State private var loadStartedAt = Date()
    @State private var activeQuality: String?
    @State private var autoReloads = 0
    @State private var reportedThermal = false
    @State private var reportedMemoryWarning = false
    @State private var gameplayStartedAt: Date?
    @State private var didTrackGameplayStart = false
    @AppStorage(PlayerQuality.defaultsKey) private var qualityRaw = PlayerQuality.auto.rawValue
    @StateObject private var pathMonitor = PlayerPathMonitor()

    private var qualityPreference: PlayerQuality {
        PlayerQuality(rawValue: qualityRaw) ?? .auto
    }

    private var effectiveQuality: String {
        PlayerQuality.effective(preference: qualityPreference)
    }

    private var playerURL: URL? {
        var components = URLComponents(url: BackendConfig.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/player"
        components?.queryItems = [
            URLQueryItem(name: "game", value: gameID),
            URLQueryItem(name: "quality", value: activeQuality ?? effectiveQuality),
        ]
        return components?.url
    }

    private var shareURL: URL {
        var components = URLComponents(url: BackendConfig.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/player"
        components?.queryItems = [URLQueryItem(name: "game", value: gameID)]
        return components?.url ?? BackendConfig.baseURL
    }


    var body: some View {
        NavigationStack {
            ZStack {
                if let url = playerURL {
                    PlayerWebView(
                        url: url,
                        onProgress: { progress = $0 },
                        onLoadFinish: {
                            isLoading = false
                            loadError = nil
                            showSlowHint = false
                            let ms = Int(Date().timeIntervalSince(loadStartedAt) * 1000)
                            DevLog.info(.player, "player loaded \(gameID) in \(ms)ms (quality \(effectiveQuality))")
                            PlayerTelemetry.report(gameID: gameID, kind: "perf", name: "PlayerLoad",
                                                   message: "loaded in \(ms)ms quality=\(effectiveQuality)")
                            // The backend derives play_start/replay/completion from
                            // runtime session_start/run_end events. Only track the
                            // sheet lifecycle here to avoid double-counting starts.
                            if !didTrackGameplayStart {
                                gameplayStartedAt = Date()
                                didTrackGameplayStart = true
                            }
                        },
                        onLoadFail: { message in
                            isLoading = false
                            loadError = message
                            DevLog.error(.player, "player load failed for \(gameID): \(message)")
                            PlayerTelemetry.report(gameID: gameID, kind: "ios-load-failed",
                                                   name: "LoadFailed", message: message)
                        },
                        onTerminate: {
                            // The web content process died (usually
                            // memory pressure): the page is a white
                            // void unless we reload it ourselves.
                            if autoReloads < 2 {
                                autoReloads += 1
                                DevLog.warn(.player, "web content process terminated for \(gameID); auto-reload \(autoReloads)/2")
                                PlayerTelemetry.report(gameID: gameID, kind: "ios-webview-terminated",
                                                       name: "WebContentProcessTerminated",
                                                       message: "auto-reload \(autoReloads) of 2")
                                loadError = nil
                                isLoading = true
                                progress = 0
                                showSlowHint = false
                                loadStartedAt = Date()
                                attempt += 1
                            } else {
                                isLoading = false
                                loadError = "The player kept stopping — its web process ended repeatedly. Close and reopen the game."
                                DevLog.error(.player, "web content process terminated repeatedly for \(gameID)")
                                PlayerTelemetry.report(gameID: gameID, kind: "ios-webview-terminated",
                                                       name: "WebContentProcessTerminated",
                                                       message: "gave up after 2 auto-reloads")
                            }
                        }
                    )
                    .id(attempt)
                    .ignoresSafeArea(edges: .bottom)
                }

                if isLoading && loadError == nil {
                    VStack(spacing: 12) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 180)
                        Text("Loading \(title)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if showSlowHint {
                            Text("Still loading — the connection may be slow.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .background(HephaestusDesign.cardBackground, in: RoundedRectangle(cornerRadius: HephaestusDesign.sectionRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HephaestusDesign.sectionRadius, style: .continuous).strokeBorder(HephaestusDesign.subtleBorder, lineWidth: 1))
                }

                if PlayerLoadingPolicy.shouldShowOfflineOverlay(
                    isOffline: pathMonitor.isOffline,
                    isLoading: isLoading,
                    hasError: loadError != nil
                ) {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("You're offline")
                            .font(.headline)
                        Text("Games load from the internet. Reconnect and the player will retry on its own.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: 360)
                    .background(HephaestusDesign.cardBackground, in: RoundedRectangle(cornerRadius: HephaestusDesign.sectionRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HephaestusDesign.sectionRadius, style: .continuous).strokeBorder(HephaestusDesign.subtleBorder, lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
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
                            self.autoReloads = 0
                            isLoading = true
                            progress = 0
                            showSlowHint = false
                            loadStartedAt = Date()
                            attempt += 1
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: HephaestusDesign.minimumActionHeight)
                    }
                    .padding(24)
                    .frame(maxWidth: 360)
                    .background(HephaestusDesign.cardBackground, in: RoundedRectangle(cornerRadius: HephaestusDesign.sectionRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HephaestusDesign.sectionRadius, style: .continuous).strokeBorder(HephaestusDesign.subtleBorder, lineWidth: 1))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .frame(minHeight: HephaestusDesign.minimumActionHeight)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share game")
                    .simultaneousGesture(TapGesture().onEnded {
                        Task { await BackendAPI.shared.trackSocialEvent(gameID: gameID, kind: "share") }
                    })

                    Menu {
                        Picker("Player quality", selection: $qualityRaw) {
                            ForEach(PlayerQuality.allCases, id: \.rawValue) { q in
                                Text(q == .auto ? "Auto · recommended" : (q == .high ? "High quality" : "Low power"))
                                    .tag(q.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .frame(minWidth: HephaestusDesign.minimumActionHeight, minHeight: HephaestusDesign.minimumActionHeight)
                    }
                    .accessibilityLabel("Player quality settings")
                    .accessibilityHint("Changing quality reloads the game.")
                }
            }
            .onChange(of: qualityRaw) { _, _ in
                // Apply the saved quality on the next game launch, not during
                // an active session: reloading would discard progress.
                DevLog.info(.player, "quality preference saved for next game -> \(qualityRaw) (effective \(effectiveQuality))")
            }
            .onChange(of: pathMonitor.isOffline) { _, offline in
                if !offline, loadError != nil {
                    // Back online after a failed load: one quiet retry.
                    loadError = nil
                    isLoading = true
                    progress = 0
                    showSlowHint = false
                    loadStartedAt = Date()
                    attempt += 1
                }
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background:
                    guard !wasBackgrounded else { return }
                    wasBackgrounded = true
                    DevLog.info(.player, "app backgrounded while player sheet is open for \(gameID)")
                    PlayerTelemetry.report(gameID: gameID, kind: "perf", name: "PlayerBackground",
                                           message: "app entered background; player lifecycle suspended")
                case .active:
                    guard wasBackgrounded else { return }
                    wasBackgrounded = false
                    DevLog.info(.player, "app foregrounded with player sheet open for \(gameID)")
                    PlayerTelemetry.report(gameID: gameID, kind: "perf", name: "PlayerForeground",
                                           message: "app returned to foreground; player lifecycle resumed")
                    // Retry only a failed load, and only when connectivity is back.
                    // A successfully loaded game stays on screen; foregrounding does
                    // not trigger a disruptive reload or reset current gameplay.
                    if PlayerLifecyclePolicy.shouldRetryAfterForeground(
                        wasBackgrounded: true, isOffline: pathMonitor.isOffline, hasError: loadError != nil
                    ) {
                        loadError = nil
                        isLoading = true
                        progress = 0
                        showSlowHint = false
                        loadStartedAt = Date()
                        attempt += 1
                    }
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                if !reportedMemoryWarning {
                    reportedMemoryWarning = true
                    DevLog.warn(.player, "memory warning while player open for \(gameID)")
                    PlayerTelemetry.report(gameID: gameID, kind: "ios-memory-warning",
                                           name: "MemoryWarning", message: "UIApplication memory warning during play")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                let state = ProcessInfo.processInfo.thermalState
                if (state == .serious || state == .critical), !reportedThermal {
                    reportedThermal = true
                    DevLog.warn(.player, "thermal state \(state.rawValue) while player open for \(gameID)")
                    PlayerTelemetry.report(gameID: gameID, kind: "ios-thermal",
                                           name: "ThermalState", message: "thermal state serious/critical during play")
                }
            }
            .task {
                // Slow-load hint: still loading after 8s deserves an
                // explanation, not just a longer stare at the spinner.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if isLoading { showSlowHint = true }
            }
            .onAppear {
                loadStartedAt = Date()
                activeQuality = effectiveQuality
                DevLog.info(.player, "player opened for \(gameID) — loading /player in WebView (quality \(activeQuality ?? effectiveQuality))")
            }
            .onDisappear {
                guard let startedAt = gameplayStartedAt, didTrackGameplayStart else { return }
                let durationMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                if GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: durationMS) {
                    Task {
                        await BackendAPI.shared.trackSocialEvent(
                            gameID: gameID,
                            kind: "quick_exit",
                            durationMS: durationMS
                        )
                    }
                }
                gameplayStartedAt = nil
            }
        }
    }
}

// MARK: - Bridgeless WKWebView host

private struct PlayerWebView: UIViewRepresentable {
    let url: URL
    let onProgress: (Double) -> Void
    let onLoadFinish: () -> Void
    let onLoadFail: (String) -> Void
    let onTerminate: () -> Void

    /// One process pool for every player web view: the web content
    /// process (and its JIT/engine state) is reused across games
    /// instead of being spun up cold on every open.
    private static let processPool = WKProcessPool()

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onLoadFinish: onLoadFinish,
                    onLoadFail: onLoadFail, onTerminate: onTerminate)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Deliberately no script message handlers and no user scripts:
        // the web runtime must not reach native code (bridgeless).
        configuration.processPool = Self.processPool
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "HephaestusPlayer/1.1"

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.observeProgress(of: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reloads happen by recreating the view (see .id(attempt) in the
        // sheet), so there is nothing to update in place.
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onProgress: (Double) -> Void
        let onLoadFinish: () -> Void
        let onLoadFail: (String) -> Void
        let onTerminate: () -> Void
        private var progressObservation: NSKeyValueObservation?

        init(onProgress: @escaping (Double) -> Void,
             onLoadFinish: @escaping () -> Void,
             onLoadFail: @escaping (String) -> Void,
             onTerminate: @escaping () -> Void) {
            self.onProgress = onProgress
            self.onLoadFinish = onLoadFinish
            self.onLoadFail = onLoadFail
            self.onTerminate = onTerminate
        }

        func observeProgress(of webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                self?.onProgress(view.estimatedProgress)
            }
        }

        func stopObserving() {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onProgress(0)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onProgress(1)
            onLoadFinish()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadFail(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadFail(error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onTerminate()
        }
    }
}
