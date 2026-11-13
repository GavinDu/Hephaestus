import Combine
import CryptoKit
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

/// Navigation completion means HTML loaded, not gameplay started. Accept one
/// bounded, validated first-input milestone from the trusted runtime, even
/// if a later event uses a new telemetry sequence number.
struct PlayerFirstInputGate {
    private(set) var accepted = false

    mutating func accept(milliseconds: Int?) -> Bool {
        guard !accepted, let milliseconds, (0...86_400_000).contains(milliseconds) else {
            return false
        }
        accepted = true
        return true
    }
}

/// Accept only trusted runtime metric kinds and their newer sequence values.
/// The trusted JS runtime increments a global native sequence counter, so
/// three per-kind high-water marks reject repeats without growing memory.
/// The Coordinator separately binds sessionId and gameId before this gate.
struct PlayerRuntimeMetricSequenceGate {
    private(set) var highestSequenceByMetric: [String: Int] = [:]

    mutating func accept(metric: String, sequence: Int) -> Bool {
        guard (0...100_000).contains(sequence),
              ["first_scene_render_submit", "first_input", "perf_window"].contains(metric),
              sequence > (highestSequenceByMetric[metric] ?? -1) else { return false }
        highestSequenceByMetric[metric] = sequence
        return true
    }

    mutating func reset() { highestSequenceByMetric.removeAll() }
}

/// First scene submission is a one-time, validated milestone, not proof
/// of GPU composition or the first interactive frame.
struct PlayerFirstSceneRenderSubmissionGate {
    private(set) var accepted = false

    mutating func accept(milliseconds: Int?) -> Bool {
        guard !accepted, let milliseconds, (0...3_600_000).contains(milliseconds) else { return false }
        accepted = true
        return true
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
/// Recover only a live, unfinished in-flight warmup whose delegate
/// handoff lost the terminal navigation callback.
enum PlayerPrewarmHandoffPolicy {
    static func shouldRecoverUnobservedFinish(
        isActive: Bool, stillLoading: Bool, hasObservedTerminalNavigation: Bool,
        recoveryArmed: Bool
    ) -> Bool {
        recoveryArmed && isActive && !stillLoading && !hasObservedTerminalNavigation
    }
}

/// A game may not navigate the main frame to another document.
enum PlayerMainFrameNavigationPolicy {
    static func shouldAllow(
        requestURL: URL?, expectedURL: URL?,
        isMainFrame: Bool, isDisposing: Bool
    ) -> Bool {
        if !isMainFrame { return true }
        guard let requestURL else { return false }
        if isDisposing { return requestURL.absoluteString == "about:blank" }
        guard let expectedURL else { return false }
        return requestURL == expectedURL
    }
}

enum PlayerPrewarmResponsePolicy {
    /// A prewarmed page is reusable only when the main document did not
    /// return an HTTP error. Otherwise the attached player must retry and
    /// surface the normal actionable load-failure state.
    static func shouldCacheResponse(statusCode: Int) -> Bool {
        statusCode < 400
    }
}

/// A single failed main-frame navigation can surface through both
/// decidePolicyFor(response) and didFailProvisionalNavigation (the latter
/// commonly reports NSURLErrorCancelled after an HTTP error response is
/// rejected). Emit one UI/telemetry failure per navigation attempt.
final class PlayerNavigationFailureGate {
    private(set) var hasReportedFailure = false

    func beginNavigation() {
        hasReportedFailure = false
    }

    func shouldReportFailure() -> Bool {
        guard !hasReportedFailure else { return false }
        hasReportedFailure = true
        return true
    }
}

enum PlayerLoadFailure {
    enum Category { case network, unavailable, invalidPackage, incompatible, accessDenied, unknown }

    static let httpErrorDomain = "Hephaestus.PlayerHTTP"

    static func httpError(statusCode: Int) -> NSError {
        NSError(domain: httpErrorDomain, code: statusCode)
    }

    static func category(for error: Error) -> Category {
        let ns = error as NSError
        if ns.domain == httpErrorDomain {
            switch ns.code {
            case 401, 403: return .accessDenied
            case 404, 410: return .unavailable
            case 400, 409, 413, 422: return .invalidPackage
            case 408, 425, 429, 500, 502, 503, 504: return .network
            case 426: return .incompatible
            default: return .unknown
            }
        }
        guard ns.domain == NSURLErrorDomain else { return .unknown }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             // TLS handshake failures are transient transport failures from
             // the player's perspective; use the retry-first recovery path.
             NSURLErrorSecureConnectionFailed:
            return .network
        default:
            return .unknown
        }
    }

    static func userMessage(for error: Error) -> String {
        switch category(for: error) {
        case .network:
            return "Check your connection and try again."
        case .unavailable:
            return "This game is no longer available. Return to the feed to try another game."
        case .invalidPackage:
            return "This game package is invalid or exceeds its resource limits. Return to the feed to try another game."
        case .incompatible:
            return "This game needs a newer version of the app. Update the app and try again."
        case .accessDenied:
            return "You don't have access to this game. Return to the feed or sign in again."
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

/// Bounds automatic WKWebView recovery so a repeatedly crashing game cannot
/// create an unbounded reload loop. Explicit user retry resets the counter.
enum PlayerWebContentTerminationPolicy {
    static let maximumAutomaticReloads = 2
    static let repeatedTerminationMessage = "The player kept stopping — its web process ended repeatedly. Close and reopen the game."

    static func shouldAutomaticallyReload(completedReloads: Int) -> Bool {
        completedReloads >= 0 && completedReloads < maximumAutomaticReloads
    }
}

// The runtime's initial explicit Pixi render can be measured independently
// of WKNavigationDelegate.didFinish. This is renderer submission, not proof
// that the GPU/compositor displayed a frame, nor that input is accepted.
// Strict limits also prevent an untrusted or malformed page metric from
// feeding unbounded values into native telemetry.
enum PlayerRuntimeMetricPolicy {
    static func firstSceneRenderSubmitMS(_ value: Any?) -> Int? {
        guard let ms = value as? Int, (0...3_600_000).contains(ms) else { return nil }
        return ms
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

// A warm page is a speculative resource, not a durable entitlement or a
// verified package cache. If the Play sheet never attaches, expire it before
// an abandoned request can retain a whole WebKit scene indefinitely.
enum PlayerPrewarmBudgetPolicy {
    static let expiryNanoseconds: UInt64 = 15_000_000_000

    static func shouldExpire(
        isAttached: Bool,
        scheduledEpoch: UInt64,
        currentEpoch: UInt64
    ) -> Bool {
        !isAttached && scheduledEpoch == currentEpoch
    }
}

/// iOS can request memory reclamation while a speculative player is warming.
/// Only an unattached page may be evicted; a live game owns its WebView until
/// its matching presentation lease ends. Evaluation happens on MainActor at
/// notification delivery, not when an async callback was scheduled.
enum PlayerPrewarmMemoryPressurePolicy {
    static func shouldDiscard(isAttached: Bool, hasPooledView: Bool) -> Bool {
        !isAttached && hasPooledView
    }
}

/// Only an authoritative pooled WebView may mark a game URL as loaded.
/// A detached warmup or an old view from before a credential change may
/// complete navigation after a replacement; it must never poison the new
/// pool's loadedURL fast path. Prewarm and attached completions share this
/// pure predicate because either can legitimately finish an owned load.
enum PlayerPrewarmCompletionPolicy {
    static func shouldRecordLoaded(
        isCurrentPooledView: Bool, expectedURL: URL?, actualURL: URL?
    ) -> Bool {
        guard isCurrentPooledView, let expectedURL, let actualURL else { return false }
        return expectedURL == actualURL
    }
}

/// An attached player lease belongs to one SwiftUI Coordinator, even
/// when the next retry reuses the same WKWebView instance. Dismantling an
/// obsolete Coordinator must not remove the successor's script handler,
/// invalidate its navigation or blank its canvas.
enum PlayerAttachmentLeasePolicy {
    static func mayRecycle(
        isCurrentPooledView: Bool,
        isAttached: Bool,
        expectedLease: UInt64,
        currentLease: UInt64
    ) -> Bool {
        isCurrentPooledView && isAttached &&
            expectedLease != 0 && expectedLease == currentLease
    }
}

/// Credential changes are security boundaries. An old speculative
/// WebKit page cannot be reused after the Keychain bearer session rotates.
enum PlayerSessionCachePolicy {
    static func shouldPurge(cachedFingerprint: String?, currentFingerprint: String) -> Bool {
        guard let cachedFingerprint else { return false }
        return cachedFingerprint != currentFingerprint
    }
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
    private static var attachmentLease: UInt64 = 0
    private static var sessionFingerprint: String?
    private static let sessionObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: .hephaestusBackendSessionDidChange, object: nil, queue: .main
    ) { _ in
        Task { @MainActor in PlayerWebViewPool.invalidateForSessionChange() }
    }
    private static let memoryWarningObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { _ in
        Task { @MainActor in
            guard PlayerPrewarmMemoryPressurePolicy.shouldDiscard(
                isAttached: PlayerWebViewPool.isAttached,
                hasPooledView: PlayerWebViewPool.pooledView != nil
            ) else { return }
            PlayerWebViewPool.discardUnattachedPrewarm()
            DevLog.info(.player, "unattached speculative WebView prewarm evicted after memory warning")
        }
    }
    private static var prewarmEpoch: UInt64 = 0
    private static var prewarmExpiryTask: Task<Void, Never>?
    private static let warmupDelegate = WarmupDelegate()

    static func playerURL(gameID: String, quality: String? = nil) -> URL? {
        // Do not construct a player URL for an empty identifier, and never
        // forward arbitrary quality values into the runtime query contract.
        let normalizedGameID = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGameID.isEmpty else { return nil }

        var components = URLComponents(url: BackendConfig.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/player"
        let preference = PlayerQuality(rawValue:
            UserDefaults.standard.string(forKey: PlayerQuality.defaultsKey) ?? PlayerQuality.auto.rawValue
        ) ?? .auto
        let requestedQuality = quality.flatMap { value in
            ["low", "high"].contains(value) ? value : nil
        }
        components?.queryItems = [
            URLQueryItem(name: "game", value: normalizedGameID),
            URLQueryItem(name: "quality", value: requestedQuality ?? PlayerQuality.effective(preference: preference)),
            URLQueryItem(name: "presentation", value: "play")
        ]
        return components?.url
    }

    static func prewarm(gameID: String) {
        ensureCurrentCredentialScope()
        guard !isAttached, let url = playerURL(gameID: gameID) else { return }
        let view = pooledView ?? makeWebView()
        pooledView = view
        if currentURL == url && (view.isLoading || loadedURL == url) { return }

        view.stopLoading()
        currentURL = url
        loadedURL = nil
        view.navigationDelegate = warmupDelegate
        view.load(URLRequest(url: url))
        // A prewarm that is never attached must not hold a loaded game,
        // authenticated resources, or an entire WebContent process forever.
        prewarmExpiryTask?.cancel()
        prewarmEpoch &+= 1
        let epoch = prewarmEpoch
        prewarmExpiryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: PlayerPrewarmBudgetPolicy.expiryNanoseconds)
            guard !Task.isCancelled,
                  PlayerPrewarmBudgetPolicy.shouldExpire(
                    isAttached: isAttached,
                    scheduledEpoch: epoch,
                    currentEpoch: prewarmEpoch
                  ), pooledView === view else { return }
            discardUnattachedPrewarm()
            DevLog.info(.player, "abandoned speculative player prewarm expired")
        }
        DevLog.info(.player, "prewarming player page for \(gameID)")
    }

    static func take(url: URL) -> (webView: WKWebView, shouldLoad: Bool, didFinish: Bool, lease: UInt64) {
        ensureCurrentCredentialScope()
        // Ownership moves to a real interactive sheet. An expiry task must
        // never stop or blank the WebView after that handoff.
        prewarmExpiryTask?.cancel()
        prewarmExpiryTask = nil
        prewarmEpoch &+= 1
        let view = pooledView ?? makeWebView()
        pooledView = view
        let didFinish = currentURL == url && loadedURL == url && view.url == url
        let alreadyLoading = currentURL == url && view.isLoading
        let shouldLoad = !didFinish && !alreadyLoading
        isAttached = true
        // Every distinct interactive SwiftUI Coordinator owns a new lease,
        // even if it reuses the same prewarmed WKWebView after a retry.
        attachmentLease &+= 1
        currentURL = url
        if shouldLoad { loadedURL = nil }
        view.navigationDelegate = nil
        return (view, shouldLoad, didFinish, attachmentLease)
    }

    /// Only the currently attached navigation may be recovered. A previously
    /// dismissed sheet must never reload a WebView now owned by another game.
    static func ownsAttachedNavigation(_ webView: WKWebView, url: URL, lease: UInt64) -> Bool {
        // A prewarm-recovery KVO callback from an old Coordinator may run
        // after a new retry takes the same pooled WebView and game URL.
        // URL/instance equality alone cannot authorize an old lease to reload.
        ownsActiveAttachment(webView, lease: lease) && currentURL == url
    }

    /// A detached/stale WebView cannot navigate on the pooled game's behalf.
    static func allowsMainFrameNavigation(_ webView: WKWebView, requestURL: URL?, isMainFrame: Bool) -> Bool {
        if !isMainFrame { return true }
        guard pooledView === webView else { return false }
        return PlayerMainFrameNavigationPolicy.shouldAllow(
            requestURL: requestURL, expectedURL: currentURL,
            isMainFrame: isMainFrame, isDisposing: !isAttached && currentURL == nil
        )
    }

    static func markLoaded(_ webView: WKWebView) {
        // Credential changes can arrive before the notification observer
        // runs. Recheck the keychain scope before accepting an async finish.
        ensureCurrentCredentialScope()
        guard PlayerPrewarmCompletionPolicy.shouldRecordLoaded(
            isCurrentPooledView: pooledView === webView,
            expectedURL: currentURL, actualURL: webView.url
        ), let currentURL else { return }
        loadedURL = currentURL
    }

    static func markFailed(_ webView: WKWebView) {
        guard let currentURL, webView.url == currentURL else { return }
        markFailed(webView, responseURL: currentURL)
    }

    static func markFailed(_ webView: WKWebView, responseURL: URL?) {
        guard pooledView === webView, let currentURL,
              responseURL == currentURL else { return }
        loadedURL = nil
        self.currentURL = nil
    }

    static func ownsActiveAttachment(_ webView: WKWebView, lease: UInt64) -> Bool {
        PlayerAttachmentLeasePolicy.mayRecycle(
            isCurrentPooledView: pooledView === webView,
            isAttached: isAttached,
            expectedLease: lease,
            currentLease: attachmentLease
        )
    }

    static func recycle(_ webView: WKWebView, lease: UInt64) {
        guard ownsActiveAttachment(webView, lease: lease) else { return }
        prewarmExpiryTask?.cancel()
        prewarmExpiryTask = nil
        prewarmEpoch &+= 1
        isAttached = false
        currentURL = nil
        loadedURL = nil
        webView.navigationDelegate = warmupDelegate
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Only a SHA-256 fingerprint is kept in memory, never raw bearer
    /// tokens. Checking at take/prewarm also closes the race between a
    /// synchronous Keychain update and asynchronous notification delivery.
    private static func credentialFingerprint() -> String {
        let scope = BackendConfig.loadSessionToken().map { "bearer:" + $0 } ?? "anonymous"
        return Data(SHA256.hash(data: Data(scope.utf8))).base64EncodedString()
    }

    private static func ensureCurrentCredentialScope() {
        _ = sessionObserver
        _ = memoryWarningObserver
        let current = credentialFingerprint()
        if PlayerSessionCachePolicy.shouldPurge(
            cachedFingerprint: sessionFingerprint, currentFingerprint: current
        ) {
            invalidateForSessionChange()
        }
        sessionFingerprint = current
    }

    /// Fail closed after login, logout, replacement or account deletion.
    /// This also tears down an attached runtime. The player sheet observes
    /// the same event and displays an actionable session-changed message.
    static func invalidateForSessionChange() {
        prewarmExpiryTask?.cancel()
        prewarmExpiryTask = nil
        prewarmEpoch &+= 1
        let stale = pooledView
        pooledView = nil
        currentURL = nil
        loadedURL = nil
        isAttached = false
        sessionFingerprint = credentialFingerprint()
        stale?.navigationDelegate = nil
        stale?.stopLoading()
        stale?.loadHTMLString("", baseURL: nil)
    }

    /// Only speculative, *unattached* prewarms are discarded. Never
    /// invalidate an interactive player or its verified-run session.
    private static func discardUnattachedPrewarm() {
        guard !isAttached else { return }
        prewarmExpiryTask?.cancel()
        prewarmExpiryTask = nil
        prewarmEpoch &+= 1
        let stale = pooledView
        pooledView = nil
        currentURL = nil
        loadedURL = nil
        stale?.stopLoading()
        stale?.navigationDelegate = nil
        stale?.loadHTMLString("", baseURL: nil)
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
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let allow = PlayerWebViewPool.allowsMainFrameNavigation(
                webView, requestURL: navigationAction.request.url, isMainFrame: isMainFrame
            )
            decisionHandler(allow ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            // A redirect response must not bypass the action-level allowlist.
            if navigationResponse.isForMainFrame &&
               !PlayerWebViewPool.allowsMainFrameNavigation(
                   webView, requestURL: navigationResponse.response.url, isMainFrame: true
               ) {
                decisionHandler(.cancel)
                return
            }
            guard navigationResponse.isForMainFrame,
                  let response = navigationResponse.response as? HTTPURLResponse,
                  !PlayerPrewarmResponsePolicy.shouldCacheResponse(statusCode: response.statusCode) else {
                decisionHandler(.allow)
                return
            }
            // A 4xx/5xx HTML error page is not a successfully prewarmed
            // game. Clear the pool entry before cancelling so take(url:)
            // starts a fresh attached navigation and can show its error UI.
            PlayerWebViewPool.markFailed(webView, responseURL: response.url)
            decisionHandler(.cancel)
        }

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

/// Keeps gameplay portrait-shaped on regular-width devices while allowing
/// compact iPhone layouts to use the entire available width.
enum PlayerStageLayout {
    static func width(containerWidth: CGFloat, containerHeight: CGFloat, isRegular: Bool) -> CGFloat {
        guard isRegular else { return containerWidth }
        return min(containerWidth, min(containerHeight * 9 / 16, 560))
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
            .background(ArcadePulseTheme.surface, in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius, style: .continuous).strokeBorder(ArcadePulseTheme.subtleBorder, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ArcadePulseTheme.canvas)
    }
}

// MARK: - Sheet

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
    @State private var sessionRevoked = false
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
                .accessibilityIdentifier("player.loading")
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
        // Navigation completion is NOT proof that the game has rendered or
        // can accept input. Only the trusted runtime reports player_ready;
        // this native callback records PlayerLoad/TapToNavReady separately.
        // The runtime's first accepted input owns the gameplay-start
        // clock. Navigation finish may still precede the start card or
        // rendering; starting a quick-exit timer here mislabels latency.
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
                    // A retry/account swap can occur during the 300 ms fade.
                    // The old sheet must never mutate its successor's poster.
                    let fadeEpoch = attempt
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled,
                              PlayerTransientPresentationPolicy.mayFinishPosterFade(
                                expectedEpoch: fadeEpoch, currentEpoch: attempt,
                                sessionRevoked: sessionRevoked,
                                isLoading: isLoading, hasLoadError: loadError != nil
                              ) else { return }
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
        // Value captured when .id(attempt) creates the WebView. Callbacks from
        // a retired/retried sheet cannot mutate the current presentation.
        let callbackEpoch = attempt
        return ZStack {
                if let url = playerURL {
                    PlayerWebView(
                        url: url,
                        gameID: gameID,
                        onProgress: { value in
                            guard PlayerLaunchCallbackGate.accepts(expectedEpoch: callbackEpoch,
                                                         currentEpoch: attempt,
                                                         sessionRevoked: sessionRevoked) else { return }
                            progress = value
                        },
                        onLoadFinish: {
                            guard PlayerLaunchCallbackGate.accepts(expectedEpoch: callbackEpoch,
                                                         currentEpoch: attempt,
                                                         sessionRevoked: sessionRevoked) else { return }
                            handleLoadFinish()
                        },
                        onLoadFail: { error in
                            guard PlayerLaunchCallbackGate.accepts(expectedEpoch: callbackEpoch,
                                                         currentEpoch: attempt,
                                                         sessionRevoked: sessionRevoked) else { return }
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
                            guard PlayerLaunchCallbackGate.accepts(expectedEpoch: callbackEpoch,
                                                         currentEpoch: attempt,
                                                         sessionRevoked: sessionRevoked) else { return }
                            // The web content process died (usually
                            // memory pressure): the page is a white
                            // void unless we reload it ourselves.
                            if PlayerWebContentTerminationPolicy.shouldAutomaticallyReload(completedReloads: autoReloads) {
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
                                loadError = PlayerWebContentTerminationPolicy.repeatedTerminationMessage
                                DevLog.error(.player, "web content process terminated repeatedly for \(gameID)")
                                PlayerTelemetry.report(gameID: gameID, kind: "ios-webview-terminated",
                                                       name: "WebContentProcessTerminated",
                                                       message: "gave up after 2 auto-reloads")
                            }
                        },
                        onPrewarmHit: {
                            guard PlayerLaunchCallbackGate.accepts(expectedEpoch: callbackEpoch,
                                                         currentEpoch: attempt,
                                                         sessionRevoked: sessionRevoked) else { return }
                            prewarmHit = true
                        },
                        onFirstInput: {
                            guard PlayerLaunchCallbackGate.accepts(expectedEpoch: callbackEpoch,
                                                         currentEpoch: attempt,
                                                         sessionRevoked: sessionRevoked) else { return }
                            if !didTrackGameplayStart {
                                gameplayStartedAt = Date()
                                didTrackGameplayStart = true
                            }
                        },
                        onVerifiedRun: { result in
                            guard PlayerLaunchCallbackGate.accepts(expectedEpoch: callbackEpoch,
                                                         currentEpoch: attempt,
                                                         sessionRevoked: sessionRevoked) else { return }
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
                                .accessibilityIdentifier("player.loading")
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
                            .accessibilityIdentifier("player.retry")
                            .disabled(sessionRevoked)
                            Button("Return to feed") {
                                finishToFeed()
                            }
                            .frame(minHeight: HephaestusDesign.minimumActionHeight)
                            .accessibilityIdentifier("player.returnToFeed")
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
                    .accessibilityIdentifier("player.done")
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
        // A server-verified outcome is authoritative even when an auto-play
        // game finishes without a first touch. Do not couple score handoff
        // to the native quick-exit timer (which starts on first input).
        if let verifiedResult, verifiedResult.isVerified {
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
                .background(
                    LinearGradient(
                        colors: [
                            ArcadePulseTheme.canvas,
                            ArcadePulseTheme.electricViolet.opacity(0.19),
                            ArcadePulseTheme.canvas
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
            .navigationTitle(title)
            .preferredColorScheme(.dark)
            .tint(ArcadePulseTheme.electricViolet)
            .toolbarBackground(ArcadePulseTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                playerToolbar
            }
            .onChange(of: qualityRaw) { _, _ in
                // Apply the saved quality on the next game launch, not during
                // an active session: reloading would discard progress.
                DevLog.info(.player, "quality preference saved for next game -> \(qualityRaw) (effective \(effectiveQuality))")
            }
            .onChange(of: attempt) { _, _ in
                // Each recreated player WebView has its own runtime session.
                // A prior quick-exit start and completed prewarm must not
                // leak into retry, connectivity recovery or crash reload.
                prewarmHit = false
                gameplayStartedAt = nil
                didTrackGameplayStart = false
                verifiedResult = nil
            }
            .onChange(of: pathMonitor.isOffline) { _, offline in
                if !offline, loadError != nil, !sessionRevoked {
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
                    if !sessionRevoked && PlayerLifecyclePolicy.shouldRetryAfterForeground(
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
            .onReceive(NotificationCenter.default.publisher(for: .hephaestusBackendSessionDidChange)) { _ in
                sessionRevoked = true
                // Changing the Keychain identity invalidates all prewarmed
                // or attached pages, pending callbacks and prior results.
                PlayerWebViewPool.invalidateForSessionChange()
                verifiedResult = nil
                gameplayStartedAt = nil
                didTrackGameplayStart = false
                isLoading = false
                showSlowHint = false
                holdVisible = false
                loadError = "Your account session changed. Return to the feed and reopen this game."
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
            .task(id: attempt) {
                // Start an independent 8s timer per actual WebView attempt.
                // Retired timers are canceled by SwiftUI when attempt changes
                // and may not surface premature hints in the new session.
                let hintEpoch = attempt
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled,
                      PlayerTransientPresentationPolicy.mayShowSlowLoadHint(
                        expectedEpoch: hintEpoch, currentEpoch: attempt,
                        sessionRevoked: sessionRevoked,
                        isLoading: isLoading, hasLoadError: loadError != nil
                      ) else { return }
                showSlowHint = true
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
                    .foregroundStyle(ArcadePulseTheme.neonMagenta)
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
                    .tint(ArcadePulseTheme.playOrangeDeep)
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
            .background(ArcadePulseTheme.canvas)
            .foregroundStyle(ArcadePulseTheme.textPrimary)
            .preferredColorScheme(.dark)
            .tint(ArcadePulseTheme.electricViolet)
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
    let onFirstInput: () -> Void
    let onVerifiedRun: (VerifiedRunResult) -> Void

    private static let messageName = "hephaestusRunResult"

    func makeCoordinator() -> Coordinator {
        Coordinator(gameID: gameID, expectedURL: url, onProgress: onProgress,
                    onLoadFinish: onLoadFinish, onLoadFail: onLoadFail,
                    onTerminate: onTerminate, onFirstInput: onFirstInput,
                    onVerifiedRun: onVerifiedRun)
    }

    func makeUIView(context: Context) -> WKWebView {
        let handoff = PlayerWebViewPool.take(url: url)
        let webView = handoff.webView
        context.coordinator.attachmentLease = handoff.lease
        // A newer .id(attempt) may mount before the old coordinator's
        // dismantle callback. Replace its script handler explicitly:
        // registering a duplicate WebKit handler name otherwise throws.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
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
                context.coordinator.reportPrewarmedFinishIfActive()
            }
        } else {
            // Completion can race the warmup delegate swap. Recover only if
            // the navigation is no longer in flight and neither delegate
            // has observed a terminal callback; never infer readiness.
            context.coordinator.observePrewarmHandoff(of: webView, expectedURL: url)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reloads happen by recreating the view (see .id(attempt) in the
        // sheet), so there is nothing to update in place.
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
        // Old sheet teardown may run after a new retry has already taken
        // ownership of the *same* view. Never remove its new handler or
        // recycle its live navigation on behalf of the retired coordinator.
        guard PlayerWebViewPool.ownsActiveAttachment(
            webView, lease: coordinator.attachmentLease
        ) else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: messageName)
        PlayerWebViewPool.recycle(webView, lease: coordinator.attachmentLease)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var attachmentLease: UInt64 = 0
        let expectedGameID: String
        let expectedURL: URL
        let onProgress: (Double) -> Void
        let onLoadFinish: () -> Void
        let onLoadFail: (Error) -> Void
        let onTerminate: () -> Void
        let onFirstInput: () -> Void
        let onVerifiedRun: (VerifiedRunResult) -> Void
        private var progressObservation: NSKeyValueObservation?
        private var prewarmLoadingObservation: NSKeyValueObservation?
        private var prewarmRecoveryArmed = false
        private var acceptedRunIDs = Set<String>()
        private var navigationFailureGate = PlayerNavigationFailureGate()
        private var metricSequenceGate = PlayerRuntimeMetricSequenceGate()
        private var firstSceneRenderSubmissionGate = PlayerFirstSceneRenderSubmissionGate()
        private var firstInputGate = PlayerFirstInputGate()
        private var runtimeSessionID: String?
        private var isActive = true
        private var hasObservedTerminalNavigation = false
        lazy var messageProxy = WeakScriptMessageHandler(delegate: self)

        init(gameID: String, expectedURL: URL,
             onProgress: @escaping (Double) -> Void,
             onLoadFinish: @escaping () -> Void,
             onLoadFail: @escaping (Error) -> Void,
             onTerminate: @escaping () -> Void,
             onFirstInput: @escaping () -> Void,
             onVerifiedRun: @escaping (VerifiedRunResult) -> Void) {
            self.expectedGameID = gameID
            self.expectedURL = expectedURL
            self.onProgress = onProgress
            self.onLoadFinish = onLoadFinish
            self.onLoadFail = onLoadFail
            self.onTerminate = onTerminate
            self.onFirstInput = onFirstInput
            self.onVerifiedRun = onVerifiedRun
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard isActive, message.name == PlayerWebView.messageName,
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
                  metricSequenceGate.accept(metric: metric, sequence: sequence) else { return }
            let metricID = "\(runtimeSessionID):\(metric):\(sequence)"
            switch metric {
            case "first_scene_render_submit":
                guard let ms = PlayerRuntimeMetricPolicy.firstSceneRenderSubmitMS(body["ms"]),
                      firstSceneRenderSubmissionGate.accept(milliseconds: ms) else { return }
                // This metric may be lost when a pooled WebView was already
                // warmed before the Coordinator attached. The backend also
                // captures the milestone independently for that case.
                PlayerTelemetry.report(
                    gameID: expectedGameID, kind: "perf",
                    name: "FirstSceneRenderSubmitted",
                    message: "renderer-submitted-ms=\(ms); not display-presented or interactive"
                )
            case "first_input":
                guard let ms = body["ms"] as? Int,
                      firstInputGate.accept(milliseconds: ms) else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isActive,
                          self.runtimeSessionID == runtimeSessionID else { return }
                    self.onFirstInput()
                }
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
                guard let self, self.isActive else { return }
                self.onProgress(view.estimatedProgress)
            }
        }

        func stopObserving() {
            isActive = false
            prewarmRecoveryArmed = false
            prewarmLoadingObservation?.invalidate()
            prewarmLoadingObservation = nil
            progressObservation?.invalidate()
            progressObservation = nil
            acceptedRunIDs.removeAll()
            metricSequenceGate.reset()
            firstSceneRenderSubmissionGate = PlayerFirstSceneRenderSubmissionGate()
            firstInputGate = PlayerFirstInputGate()
            runtimeSessionID = nil
        }

        @MainActor
        func observePrewarmHandoff(of webView: WKWebView, expectedURL: URL) {
            // The warmup delegate can win the completion callback after take()
            // switched delegates. A single next-loop check misses a later
            // isLoading=true -> false transition; KVO observes that edge.
            prewarmRecoveryArmed = true
            prewarmLoadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.recoverUnobservedWarmupIfNeeded(view, expectedURL: expectedURL)
                }
            }
            // Also cover completion before the KVO observation was installed.
            DispatchQueue.main.async { [weak self] in
                self?.recoverUnobservedWarmupIfNeeded(webView, expectedURL: expectedURL)
            }
        }

        private func disarmPrewarmRecovery() {
            prewarmRecoveryArmed = false
            prewarmLoadingObservation?.invalidate()
            prewarmLoadingObservation = nil
        }

        func reportPrewarmedFinishIfActive() {
            guard isActive, !hasObservedTerminalNavigation else { return }
            hasObservedTerminalNavigation = true
            disarmPrewarmRecovery()
            onProgress(1)
            onLoadFinish()
        }

        @MainActor
        func recoverUnobservedWarmupIfNeeded(_ webView: WKWebView, expectedURL: URL) {
            guard PlayerWebViewPool.ownsAttachedNavigation(
                    webView, url: expectedURL, lease: attachmentLease
                  ),
                  PlayerPrewarmHandoffPolicy.shouldRecoverUnobservedFinish(
                    isActive: isActive, stillLoading: webView.isLoading,
                    hasObservedTerminalNavigation: hasObservedTerminalNavigation,
                    recoveryArmed: prewarmRecoveryArmed
                  ) else { return }
            // One-shot recovery; disarm before reload so KVO cannot trigger a
            // second reload and no terminal callback is fabricated.
            disarmPrewarmRecovery()
            webView.load(URLRequest(url: expectedURL))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard isActive else { return }
            hasObservedTerminalNavigation = false
            navigationFailureGate.beginNavigation()
            onProgress(0)
        }

        private func reportNavigationFailure(_ error: Error) {
            guard isActive, navigationFailureGate.shouldReportFailure() else { return }
            hasObservedTerminalNavigation = true
            disarmPrewarmRecovery()
            onLoadFail(error)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let allow = isActive && PlayerWebViewPool.allowsMainFrameNavigation(
                webView, requestURL: navigationAction.request.url, isMainFrame: isMainFrame
            ) && PlayerMainFrameNavigationPolicy.shouldAllow(
                requestURL: navigationAction.request.url, expectedURL: expectedURL,
                isMainFrame: isMainFrame, isDisposing: false
            )
            if !allow && isMainFrame && !hasObservedTerminalNavigation {
                // A redirect during launch is an actionable security failure.
                // A blocked link after didFinish leaves existing play intact.
                reportNavigationFailure(PlayerLoadFailure.httpError(statusCode: 403))
            }
            decisionHandler(allow ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            // Recheck the final main-document URL even if a redirect did not
            // generate a separate navigation-action policy callback.
            if navigationResponse.isForMainFrame &&
               !PlayerMainFrameNavigationPolicy.shouldAllow(
                   requestURL: navigationResponse.response.url, expectedURL: expectedURL,
                   isMainFrame: true, isDisposing: false
               ) {
                reportNavigationFailure(PlayerLoadFailure.httpError(statusCode: 403))
                decisionHandler(.cancel)
                return
            }
            guard navigationResponse.isForMainFrame,
                  let response = navigationResponse.response as? HTTPURLResponse,
                  response.statusCode >= 400 else {
                decisionHandler(.allow)
                return
            }
            reportNavigationFailure(PlayerLoadFailure.httpError(statusCode: response.statusCode))
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            reportPrewarmedFinishIfActive()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportNavigationFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportNavigationFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard isActive else { return }
            hasObservedTerminalNavigation = true
            disarmPrewarmRecovery()
            onTerminate()
        }
    }
}
