import Combine
import Network
import SwiftUI
import UIKit
import WebKit

// MARK: - Player presentation
//
// The player is the PixiJS + Rapier Game IR runtime — the single runtime
// since the 2026-10-20 consolidation. The runtime is served by the backend
// at /player and embedded here in a constrained WKWebView: the only native
// message is a verified-run notification; there is no evaluateJavaScript
// control channel and no arbitrary native API exposure (App Store Guideline
// 4.7 posture). Everything this
// shell does for resource control, performance, and telemetry respects
// that boundary:
//   - performance reaches the page only as a URL parameter (?quality=),
//     never as a script call;
//   - telemetry leaves the app as ordinary HTTPS POSTs from the app's
//     own networking (the same endpoint the page beacons to); the page may
//     only notify native of an opaque run ID after server submission;
//   - lifecycle signals come from WKNavigationDelegate, KVO on the web
//     view, OS notifications, and the validated run-result notification.

struct PixiPlayerRequest: Identifiable {
    let id = UUID()
    let gameID: String
    let title: String
    /// Tap time for the #58 tap-to-nav-ready measurement, and the
    /// poster URL for the hold frame. Nil for entry points that do
    /// not set them: those plays keep today's behavior.
    var tappedAt: Date? = nil
    var posterURL: String? = nil
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

/// Maps a WKWebView load failure to the player-facing error state
/// (Hephaestus #53). Two rules, both fail-closed:
///   - the UI shows only a fixed message per category, never the raw
///     localizedDescription: that string can carry URLs, hostnames, and
///     backend detail the player has no use for;
///   - the raw error still goes to DevLog and telemetry, so the detail
///     is not lost, it is just not shown.
/// Network failures get a retry-first message; anything else gets the
/// generic message. Both states offer Retry and Return to feed, so a
/// failed load never leaves a blank player with no next action.
enum PlayerLoadFailure {
    enum Category { case network, unknown }

    static func category(for error: Error) -> Category {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .unknown }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed:
            return .network
        default:
            return .unknown
        }
    }

    static func userMessage(for error: Error) -> String {
        switch category(for: error) {
        case .network:
            return "Check your connection and try again."
        case .unknown:
            return "The player couldn't load this game."
        }
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
            logTail: tail,
            runId: DevLog.shared.runID
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

// MARK: - Single pooled player web view
//
// Prewarming starts only after an explicit Play press begins. The same
// WKWebView is handed to the full-screen sheet, so its in-flight navigation
// continues instead of starting a second cold page. On dismissal we navigate
// to an empty document to stop the game runtime while retaining the WebView.
@MainActor
enum PlayerWebViewPool {
    static let processPool = WKProcessPool()
    private static var pooledView: WKWebView?
    private static var currentURL: URL?
    private static var loadedURL: URL?
    private static var isAttached = false
    private static let warmupDelegate = WarmupDelegate()

    static func playerURL(gameID: String, quality: String? = nil) -> URL? {
        var components = URLComponents(url: BackendConfig.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/player"
        let preference = PlayerQuality(rawValue:
            UserDefaults.standard.string(forKey: PlayerQuality.defaultsKey) ?? PlayerQuality.auto.rawValue
        ) ?? .auto
        components?.queryItems = [
            URLQueryItem(name: "game", value: gameID),
            URLQueryItem(name: "quality", value: quality ?? PlayerQuality.effective(preference: preference)),
            URLQueryItem(name: "presentation", value: "play")
        ]
        return components?.url
    }

    static func prewarm(gameID: String) {
        guard !isAttached, let url = playerURL(gameID: gameID) else { return }
        let view = pooledView ?? makeWebView()
        pooledView = view
        if currentURL == url && (view.isLoading || loadedURL == url) { return }

        view.stopLoading()
        currentURL = url
        loadedURL = nil
        view.navigationDelegate = warmupDelegate
        view.load(URLRequest(url: url))
        DevLog.info(.player, "prewarming player page for \(gameID)")
    }

    static func take(url: URL) -> (webView: WKWebView, shouldLoad: Bool, didFinish: Bool) {
        let view = pooledView ?? makeWebView()
        pooledView = view
        let didFinish = currentURL == url && loadedURL == url && view.url == url
        let alreadyLoading = currentURL == url && view.isLoading
        let shouldLoad = !didFinish && !alreadyLoading
        isAttached = true
        currentURL = url
        if shouldLoad { loadedURL = nil }
        view.navigationDelegate = nil
        return (view, shouldLoad, didFinish)
    }

    static func markLoaded(_ webView: WKWebView) {
        guard let currentURL, webView.url == currentURL else { return }
        loadedURL = currentURL
    }

    static func markFailed(_ webView: WKWebView) {
        guard let currentURL, webView.url == currentURL else { return }
        loadedURL = nil
        self.currentURL = nil
    }

    static func recycle(_ webView: WKWebView) {
        guard pooledView === webView else { return }
        isAttached = false
        currentURL = nil
        loadedURL = nil
        webView.navigationDelegate = warmupDelegate
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The only handler is attached per presentation and accepts one
        // validated run-result notification; there is no script control API.
        configuration.processPool = processPool
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "HephaestusPlayer/1.1"
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    private final class WarmupDelegate: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            PlayerWebViewPool.markLoaded(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            PlayerWebViewPool.markFailed(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            PlayerWebViewPool.markFailed(webView)
        }
    }
}

/// Shared chrome for the player sheet's state cards (loading, offline,
/// error). One place owns the padding, width cap, background, and border
/// so the three states cannot drift apart again — the loading card used
/// to miss the max-width and full-screen frame the other two had.
/// Content keeps its own spacing; this only owns the card itself.
private struct PlayerStateCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(HephaestusDesign.cardPadding)
            .frame(maxWidth: HephaestusDesign.stateCardMaxWidth)
            .background(HephaestusDesign.cardBackground, in: RoundedRectangle(cornerRadius: HephaestusDesign.sectionRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HephaestusDesign.sectionRadius, style: .continuous).strokeBorder(HephaestusDesign.subtleBorder, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
    }
}

// MARK: - Sheet

/// Portrait gameplay stage sizing for regular-width devices.
enum PlayerStageLayout {
    static func width(containerWidth: CGFloat, containerHeight: CGFloat, isRegular: Bool) -> CGFloat {
        guard isRegular else { return containerWidth }
        return min(containerWidth, min(containerHeight * 9 / 16, 560))
    }
}

struct PixiPlayerSheet: View {
    let gameID: String
    let title: String
    /// Hold frame for the #58 handoff: the feed poster's URL. While
    /// set and not yet faded, the poster covers the web view so Play
    /// never flashes a blank sheet. Nil keeps today's loading card.
    /// A video clip frame is deliberately NOT snapshotted: video
    /// layers render black into image contexts, so the poster is the
    /// honest hold frame the shell can offer today.
    /// Declared before onFinish on purpose: Swift call-site
    /// arguments must follow declaration order, and the cover site
    /// passes holdPosterURL/tappedAt before the trailing onFinish.
    var holdPosterURL: String? = nil
    /// Tap time for the tap-to-nav-ready measurement. Nil skips it.
    var tappedAt: Date? = nil
    var onFinish: (VerifiedRunResult) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Handoff state (#58): the hold fades out once, on the first
    /// navigation finish. Reloads and retries never re-show it.
    @State private var holdOpacity = 1.0
    @State private var holdVisible = true
    @State private var prewarmHit = false
    @State private var didReportHandoff = false
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
    @State private var didReportInteractive = false
    @State private var verifiedResult: VerifiedRunResult?
    @AppStorage(PlayerQuality.defaultsKey) private var qualityRaw = PlayerQuality.auto.rawValue
    @StateObject private var pathMonitor = PlayerPathMonitor()

    private var qualityPreference: PlayerQuality {
        PlayerQuality(rawValue: qualityRaw) ?? .auto
    }

    private var effectiveQuality: String {
        PlayerQuality.effective(preference: qualityPreference)
    }

    private var playerURL: URL? {
        PlayerWebViewPool.playerURL(gameID: gameID, quality: activeQuality ?? effectiveQuality)
    }

    private var shareURL: URL {
        var components = URLComponents(url: BackendConfig.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/player"
        components?.queryItems = [URLQueryItem(name: "game", value: gameID)]
        return components?.url ?? BackendConfig.baseURL
    }

    /// #58 hold backdrop, extracted so the body expression stays
    /// small enough to type-check. A failed poster load falls back
    /// to black, never to a white flash.
    private var holdBackdrop: some View {
        Group {
            if let holdPosterURL, let holdURL = URL(string: holdPosterURL) {
                AsyncImage(url: holdURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.black
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(holdOpacity)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }
        }
    }

    /// #58 compact progress overlay drawn ON the hold poster.
    /// PlayerStateCard paints its own full-screen background, which
    /// would hide the hold, so it cannot be reused here.
    private var holdLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 180)
            Text("Loading \(title)…")
                .font(.subheadline)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
            if showSlowHint {
                Text("Still loading — the connection may be slow.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Navigation-finish handler, extracted from the PlayerWebView
    /// call site so that expression stays type-checkable: the inline
    /// version (with the #58 handoff block) timed out the compiler.
    /// @State assignment needs no `mutating` here: the wrappers'
    /// setters forward to external storage.
    private func handleLoadFinish() {
        isLoading = false
        loadError = nil
        showSlowHint = false
        let ms = Int(Date().timeIntervalSince(loadStartedAt) * 1000)
        DevLog.info(.player, "player loaded \(gameID) in \(ms)ms (quality \(effectiveQuality))")
        PlayerTelemetry.report(gameID: gameID, kind: "perf", name: "PlayerLoad",
                               message: "loaded in \(ms)ms quality=\(effectiveQuality)")
        if !didReportInteractive {
            didReportInteractive = true
            let eventID = "ios-tti:\(gameID):\(loadStartedAt.timeIntervalSince1970)"
            Task {
                await BackendAPI.shared.trackSocialEvent(
                    gameID: gameID,
                    kind: "player_ready",
                    timeToInteractiveMS: max(0, ms),
                    eventID: eventID
                )
            }
        }
        // The backend derives play_start/replay/completion from
        // runtime session_start/run_end events. Only track the
        // sheet lifecycle here to avoid double-counting starts.
        if !didTrackGameplayStart {
            gameplayStartedAt = Date()
            didTrackGameplayStart = true
        }
        // #58 handoff, once: tap-to-nav-ready is tap time
        // to navigation finish (the shell definition
        // Gavin confirmed), and the hold poster fades
        // out over the live web view. Reloads skip
        // both: the hold is already gone by then.
        if !didReportHandoff {
            didReportHandoff = true
            if let tappedAt {
                let ms = max(0, Int(Date().timeIntervalSince(tappedAt) * 1000))
                PlayerTelemetry.report(gameID: gameID, kind: "perf", name: "TapToNavReady",
                                       message: "tap-to-nav-ready in \(ms)ms prewarmHit=\(prewarmHit) quality=\(effectiveQuality)")
            }
            if holdPosterURL != nil, holdVisible {
                if reduceMotion {
                    holdOpacity = 0
                    holdVisible = false
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { holdOpacity = 0 }
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        holdVisible = false
                    }
                }
            }
        }
    }

    /// The player stack, extracted from `body` so the body
    /// expression stays type-checkable: the full body (stack +
    /// overlays + toolbar + lifecycle modifiers) timed out the
    /// compiler after the #58 additions.
    private var playerContent: some View {
        ZStack {
                if let url = playerURL {
                    PlayerWebView(
                        url: url,
                        gameID: gameID,
                        onProgress: { progress = $0 },
                        onLoadFinish: { handleLoadFinish() },
                        onLoadFail: { error in
                            isLoading = false
                            holdOpacity = 0
                            holdVisible = false
                            // Raw detail goes to DevLog/telemetry;
                            // the card shows only the mapped message.
                            loadError = PlayerLoadFailure.userMessage(for: error)
                            let message = error.localizedDescription
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
                        },
                        onPrewarmHit: { prewarmHit = true },
                        onVerifiedRun: { result in
                            verifiedResult = result
                        }
                    )
                    .id(attempt)
                    .ignoresSafeArea(edges: .bottom)
                }

                // #58 hold frame: the poster covers the web view until
                // the first navigation finish fades it out. A missing
                // poster URL means no hold at all.
                if holdPosterURL != nil, holdVisible {
                    holdBackdrop
                }

                if isLoading && loadError == nil, !prewarmHit {
                    if holdPosterURL != nil, holdVisible {
                        holdLoadingOverlay
                    } else {
                    PlayerStateCard {
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
                    }
                    }
                }

                if PlayerLoadingPolicy.shouldShowOfflineOverlay(
                    isOffline: pathMonitor.isOffline,
                    isLoading: isLoading,
                    hasError: loadError != nil
                ) {
                    PlayerStateCard {
                        VStack(spacing: 14) {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: HephaestusDesign.stateIconSize))
                                .foregroundStyle(.secondary)
                            Text("You're offline")
                                .font(.headline)
                            Text("Games load from the internet. Reconnect and the player will retry on its own.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }

                if let loadError {
                    PlayerStateCard {
                        VStack(spacing: 14) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: HephaestusDesign.stateIconSize))
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
                    Button("Return to feed") {
                        finishToFeed()
                    }
                                .frame(minHeight: HephaestusDesign.minimumActionHeight)
                        }
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private var playerToolbar: some ToolbarContent {

                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        finishToFeed()
                    }
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

    private func finishToFeed() {
        if didTrackGameplayStart, let verifiedResult, verifiedResult.isVerified {
            onFinish(verifiedResult)
        }
        dismiss()
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                Group {
                    if horizontalSizeClass == .regular {
                        playerContent
                            .frame(
                                width: PlayerStageLayout.width(
                                    containerWidth: proxy.size.width,
                                    containerHeight: proxy.size.height,
                                    isRegular: true
                                ),
                                height: proxy.size.height
                            )
                    } else {
                        playerContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HephaestusDesign.pageBackground)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                playerToolbar
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

/// Native post-run handoff. The result is fetched from BackendAPI after the
/// WebView reports an opaque run ID; JavaScript never supplies display data.
struct PlayerResultSheet: View {
    let game: FeedGame
    let result: VerifiedRunResult
    let isLiked: Bool
    let onPlayAgain: () -> Void
    let onNextGame: () -> Void
    let onToggleLike: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.purple)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(result.result?.won == true ? "You did it!" : "Run complete")
                        .font(.title2.weight(.bold))
                    Text(game.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    if let outcome = result.result {
                        Text("Score: \(outcome.score)")
                            .font(.title3.weight(.semibold))
                        if let rank = result.rank {
                            Text("Weekly rank: #\(rank.position)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Choose what you want to do next.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)

                VStack(spacing: 12) {
                    Button {
                        dismiss()
                        onPlayAgain()
                    } label: {
                        Label("Play Again", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: HephaestusDesign.minimumActionHeight)

                    Button {
                        dismiss()
                        onNextGame()
                    } label: {
                        Label("Next Game", systemImage: "chevron.up.2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: HephaestusDesign.minimumActionHeight)

                    Button {
                        onToggleLike()
                    } label: {
                        Label(isLiked ? "Liked" : "Like", systemImage: isLiked ? "heart.fill" : "heart")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(isLiked ? .pink : nil)
                    .frame(minHeight: HephaestusDesign.minimumActionHeight)
                    .accessibilityLabel(isLiked ? "Unlike \(game.title)" : "Like \(game.title)")
                }
                .frame(maxWidth: 420)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HephaestusDesign.pageBackground)
            .navigationTitle("Run complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Verified-result WKWebView host

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

private struct PlayerWebView: UIViewRepresentable {
    let url: URL
    let gameID: String
    let onProgress: (Double) -> Void
    let onLoadFinish: () -> Void
    let onLoadFail: (Error) -> Void
    let onTerminate: () -> Void
    /// Fires when take() returned an already-finished prewarmed
    /// navigation, before onLoadFinish is delivered after mount.
    /// Declared between onTerminate and onVerifiedRun to match the
    /// call-site argument order (Swift requires the same order).
    var onPrewarmHit: () -> Void = {}
    let onVerifiedRun: (VerifiedRunResult) -> Void

    private static let messageName = "hephaestusRunResult"

    func makeCoordinator() -> Coordinator {
        Coordinator(gameID: gameID, onProgress: onProgress,
                    onLoadFinish: onLoadFinish, onLoadFail: onLoadFail,
                    onTerminate: onTerminate, onVerifiedRun: onVerifiedRun)
    }

    func makeUIView(context: Context) -> WKWebView {
        let handoff = PlayerWebViewPool.take(url: url)
        let webView = handoff.webView
        webView.configuration.userContentController.add(context.coordinator.messageProxy, name: Self.messageName)
        webView.navigationDelegate = context.coordinator
        context.coordinator.observeProgress(of: webView)
        if handoff.shouldLoad {
            webView.load(URLRequest(url: url))
        } else if handoff.didFinish {
            // A prewarmed navigation may have finished before the sheet
            // attached its delegate. Deliver readiness after the view mounts.
            onPrewarmHit()
            DispatchQueue.main.async {
                context.coordinator.onProgress(1)
                context.coordinator.onLoadFinish()
            }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reloads happen by recreating the view (see .id(attempt) in the
        // sheet), so there is nothing to update in place.
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: messageName)
        PlayerWebViewPool.recycle(webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let expectedGameID: String
        let onProgress: (Double) -> Void
        let onLoadFinish: () -> Void
        let onLoadFail: (Error) -> Void
        let onTerminate: () -> Void
    let onVerifiedRun: (VerifiedRunResult) -> Void
        private var progressObservation: NSKeyValueObservation?
        private var acceptedRunIDs = Set<String>()
        private var acceptedMetricIDs = Set<String>()
        private var runtimeSessionID: String?
        private var isActive = true
        lazy var messageProxy = WeakScriptMessageHandler(delegate: self)

        init(gameID: String,
             onProgress: @escaping (Double) -> Void,
             onLoadFinish: @escaping () -> Void,
             onLoadFail: @escaping (Error) -> Void,
             onTerminate: @escaping () -> Void,
             onVerifiedRun: @escaping (VerifiedRunResult) -> Void) {
            self.expectedGameID = gameID
            self.onProgress = onProgress
            self.onLoadFinish = onLoadFinish
            self.onLoadFail = onLoadFail
            self.onTerminate = onTerminate
            self.onVerifiedRun = onVerifiedRun
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == PlayerWebView.messageName,
                  message.frameInfo.isMainFrame,
                  sameOrigin(message.frameInfo.securityOrigin),
                  let body = message.body as? [String: Any],
                  body["schema"] as? Int == 1,
                  let runtimeSessionID = body["sessionId"] as? String,
                  !runtimeSessionID.isEmpty, runtimeSessionID.count <= 128,
                  body["gameId"] as? String == expectedGameID,
                  let type = body["type"] as? String else { return }
            if let boundSessionID = self.runtimeSessionID, boundSessionID != runtimeSessionID { return }
            self.runtimeSessionID = runtimeSessionID
            if type == "player_metric" {
                handleMetric(body, runtimeSessionID: runtimeSessionID)
                return
            }
            guard type == "verified_run_available",
                  Set(body.keys).isSubset(of: ["schema", "type", "sessionId", "gameId", "runId"]),
                  let runID = body["runId"] as? String,
                  !runID.isEmpty, runID.count <= 128,
                  acceptedRunIDs.insert(runID).inserted else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await BackendAPI.shared.fetchVerifiedRunResult(runID: runID)
                    guard self.isActive, self.runtimeSessionID == runtimeSessionID,
                          result.gameID == expectedGameID, result.isVerified else { return }
                    onVerifiedRun(result)
                } catch {
                    PlayerTelemetry.report(gameID: expectedGameID, kind: "ios-run-result-failed",
                                           name: "VerifiedRunResultFetchFailed",
                                           message: "verified result unavailable")
                }
            }
        }

        private func handleMetric(_ body: [String: Any], runtimeSessionID: String) {
            guard Set(body.keys).isSubset(of: ["schema", "type", "sessionId", "gameId", "metric", "sequence", "ms", "frameTimeP95Ms", "frameTimeAvgMs", "frameCount"]),
                  let metric = body["metric"] as? String,
                  let sequence = body["sequence"] as? Int,
                  sequence >= 0, sequence <= 100_000 else { return }
            let metricID = "\(runtimeSessionID):\(metric):\(sequence)"
            guard acceptedMetricIDs.insert(metricID).inserted else { return }
            switch metric {
            case "first_input":
                guard let ms = body["ms"] as? Int, (0...86_400_000).contains(ms) else { return }
                Task { await BackendAPI.shared.trackSocialEvent(
                    gameID: expectedGameID, kind: "player_first_input",
                    timeToFirstInputMS: ms, eventID: "ios-metric:\(metricID)"
                ) }
            case "perf_window":
                guard let p95 = body["frameTimeP95Ms"] as? Int,
                      let avg = body["frameTimeAvgMs"] as? Int,
                      let count = body["frameCount"] as? Int,
                      (0...60_000).contains(p95), (0...60_000).contains(avg),
                      (1...10_000).contains(count) else { return }
                Task { await BackendAPI.shared.trackSocialEvent(
                    gameID: expectedGameID, kind: "player_perf_window",
                    frameTimeP95MS: p95, frameTimeAvgMS: avg,
                    frameCount: count, eventID: "ios-metric:\(metricID)"
                ) }
            default:
                return
            }
        }

        private func sameOrigin(_ origin: WKSecurityOrigin) -> Bool {
            guard let expectedScheme = BackendConfig.baseURL.scheme,
                  let expectedHost = BackendConfig.baseURL.host else { return false }
            let expectedPort = BackendConfig.baseURL.port ?? (expectedScheme == "https" ? 443 : 80)
            return origin.protocol == expectedScheme && origin.host == expectedHost && origin.port == expectedPort
        }

        func observeProgress(of webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                self?.onProgress(view.estimatedProgress)
            }
        }

        func stopObserving() {
            isActive = false
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
            onLoadFail(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadFail(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onTerminate()
        }
    }
}
