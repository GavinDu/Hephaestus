import Combine
import CoreFoundation
import CryptoKit
import Network
import SwiftUI
import UIKit
import WebKit

// MARK: - Player presentation
//
// The player is the PixiJS + Rapier Game IR runtime — the single runtime
// since the 2026-10-20 consolidation. The runtime is served by the backend
// at /player and embedded here in a constrained WKWebView: the sole narrow
// message name carries validated runtime metrics and opaque run-result
// notifications, never arbitrary native control. There is no evaluateJavaScript
// control channel or general native API (App Store Guideline 4.7). Everything this
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

/// Validated v1 telemetry payload decoded *before* consuming a metric sequence.
/// A malformed high-sequence message must never hide a later legitimate
/// first-render, first-input, or performance-window milestone. The shipping
/// trusted Pixi producer sends exactly the common keys and one typed payload.
enum PlayerNativeMetricPayload {
    case firstSceneRenderSubmit(milliseconds: Int)
    case firstInput(milliseconds: Int)
    case perfWindow(p95: Int, average: Int, count: Int)

    // WKScriptMessage numeric fields are bridged via NSNumber. Foundation
    // can cast the special CFBoolean singleton to Int(1)/Int(0); an event
    // with schema=true or ms=true must not be admitted as a valid number.
    static func strictInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        return value as? Int
    }

    var metric: String {
        switch self {
        case .firstSceneRenderSubmit: return "first_scene_render_submit"
        case .firstInput: return "first_input"
        case .perfWindow: return "perf_window"
        }
    }

    static func parse(_ body: [String: Any]) -> Self? {
        guard let schema = Self.strictInt(body["schema"]),
              schema == 1 || schema == 2 else { return nil }
        var common: Set<String> = ["schema", "type", "sessionId", "gameId", "metric", "sequence"]
        if schema == 2 {
            guard PlayerNativeDocumentEpochGate.isWellFormed(body["documentNonce"] as? String)
            else { return nil }
            common.insert("documentNonce")
        }
        guard body["type"] as? String == "player_metric",
              body["sessionId"] as? String != nil,
              body["gameId"] as? String != nil,
              Self.strictInt(body["sequence"]) != nil,
              let kind = body["metric"] as? String else { return nil }
        switch kind {
        case "first_scene_render_submit":
            guard Set(body.keys) == common.union(["ms"]),
                  let ms = Self.strictInt(body["ms"]),
                  PlayerRuntimeMetricPolicy.firstSceneRenderSubmitMS(ms) != nil
            else { return nil }
            return .firstSceneRenderSubmit(milliseconds: ms)
        case "first_input":
            guard Set(body.keys) == common.union(["ms"]),
                  let ms = Self.strictInt(body["ms"]), (0...86_400_000).contains(ms)
            else { return nil }
            return .firstInput(milliseconds: ms)
        case "perf_window":
            guard Set(body.keys) == common.union(["frameTimeP95Ms", "frameTimeAvgMs", "frameCount"]),
                  let p95 = Self.strictInt(body["frameTimeP95Ms"]),
                  let average = Self.strictInt(body["frameTimeAvgMs"]),
                  let count = Self.strictInt(body["frameCount"]),
                  (0...60_000).contains(p95), (0...60_000).contains(average),
                  (1...10_000).contains(count)
            else { return nil }
            return .perfWindow(p95: p95, average: average, count: count)
        default:
            return nil
        }
    }
}

/// Strict, pure prewarm first-scene callback admission for a *future*
/// pool-owned WKScriptMessageHandler installed before speculative navigation.
/// This helper is intentionally not a handler or a score/result bridge.
/// Trust flags MUST be supplied from native WebKit frame/origin/navigation
/// provenance rather than from any JavaScript message dictionary.
struct PlayerPrewarmV2SceneMetricGate {
    private(set) var firstMilliseconds: Int?
    private(set) var firstSequence: Int?
    private(set) var firstSessionID: String?

    mutating func record(
        _ body: [String: Any],
        expectedGameID: String,
        currentDocumentNonce: String?,
        isTrustedMainFrame: Bool,
        isSameOrigin: Bool,
        navigationStarted: Bool,
        credentialScopeCurrent: Bool
    ) -> Bool {
        // Reject *before* recording a sequence. An invalid high-sequence
        // message must not consume the single valid scene-ready milestone.
        guard firstMilliseconds == nil,
              isTrustedMainFrame, isSameOrigin,
              navigationStarted, credentialScopeCurrent,
              !expectedGameID.isEmpty, expectedGameID.utf8.count <= 128,
              let currentDocumentNonce,
              PlayerNativeDocumentEpochGate.isWellFormed(currentDocumentNonce),
              PlayerNativeMetricPayload.strictInt(body["schema"]) == 2,
              body["documentNonce"] as? String == currentDocumentNonce,
              body["gameId"] as? String == expectedGameID,
              let session = body["sessionId"] as? String,
              PlayerNativeRuntimeIdentifierPolicy.validSessionID(session),
              let sequence = PlayerNativeMetricPayload.strictInt(body["sequence"]),
              (0...100_000).contains(sequence),
              let payload = PlayerNativeMetricPayload.parse(body)
        else { return false }
        guard case let .firstSceneRenderSubmit(milliseconds) = payload
        else { return false }
        firstMilliseconds = milliseconds
        firstSequence = sequence
        firstSessionID = session
        return true
    }

    mutating func reset() {
        firstMilliseconds = nil
        firstSequence = nil
        firstSessionID = nil
    }
}

/// Pure native-side provenance policy for speculative WebKit callbacks.
/// The caller supplies identity/frame/origin from WKScriptMessage itself, not
/// from browser JSON. URL equality includes the exact game and quality query.
enum PlayerPrewarmMessageOriginPolicy {
    static func allows(
        isCurrentPooledView: Bool,
        isAttached: Bool,
        expectedURL: URL?,
        actualURL: URL?,
        isMainFrame: Bool,
        originScheme: String,
        originHost: String,
        originPort: Int,
        backendURL: URL
    ) -> Bool {
        guard isCurrentPooledView, !isAttached, isMainFrame,
              let expectedURL, actualURL == expectedURL,
              let scheme = backendURL.scheme, let host = backendURL.host
        else { return false }
        // WebKit normalizes omitted/default ports to 0 in
        // WKSecurityOrigin.port. Only normalize 0 to the scheme's known
        // default: an explicit nondefault backend port must still match
        // exactly, never admit a foreign origin as a default-port alias.
        guard scheme == "https" || scheme == "http" else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        let expectedPort = backendURL.port ?? defaultPort
        let normalizedOriginPort = originPort == 0 ? defaultPort : originPort
        return originScheme == scheme && originHost == host &&
            normalizedOriginPort == expectedPort
    }
}

/// Pure native-only routing decision for one pooled WKScriptMessage handler.
/// Native WebView/credential/lease facts must be supplied by the pool. This
/// policy alone does NOT authenticate a page, frame, nonce or run result.
enum PlayerPrewarmMessageOwnershipPolicy {
    enum Recipient: Equatable {
        case speculative
        case attached
        case drop
    }

    static func recipient(
        isAttached: Bool, transferringLease: UInt64?,
        currentLease: UInt64, hasAttachedReceiver: Bool,
        credentialScopeCurrent: Bool
    ) -> Recipient {
        guard credentialScopeCurrent else { return .drop }
        if !isAttached {
            // A retired attachment must not retain a stale receiver/lease.
            return transferringLease == nil && !hasAttachedReceiver
                ? .speculative : .drop
        }
        guard currentLease != 0 else { return .drop }
        if let transferringLease {
            // During take()->Coordinator install, the pool collector owns
            // the callback only for the exact current nonzero lease.
            return transferringLease != 0 && transferringLease == currentLease
                ? .speculative : .drop
        }
        return hasAttachedReceiver ? .attached : .drop
    }
}

/// A rejected old Coordinator must never stop or blank a WKWebView that
/// a successor already retook under a newer native attachment lease.
/// Only a truly retired, no-longer-pooled view can be neutralized.
enum PlayerRejectedHandoffCleanupPolicy {
    static func mayBlank(isCurrentPooledView: Bool) -> Bool {
        !isCurrentPooledView
    }
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

/// One live, cryptographically unpredictable challenge per attempted main-frame
/// WK document. The pool (not a JS session ID or SwiftUI Coordinator) owns it.
/// No historical-ID list is needed: late messages must match this exact nonce.
struct PlayerNativeDocumentEpochGate {
    private(set) var currentNonce: String?
    private(set) var navigationStarted = false
    private var expectingNavigationStart = false

    static func isWellFormed(_ nonce: String?) -> Bool {
        guard let nonce, nonce.utf8.count == 32 else { return false }
        return nonce.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    mutating func prepareNavigation() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
        let alphabet = Array("0123456789abcdef")
        var result = String()
        result.reserveCapacity(32)
        for byte in bytes {
            result.append(alphabet[Int(byte >> 4)])
            result.append(alphabet[Int(byte & 0x0f)])
        }
        currentNonce = result
        navigationStarted = false
        expectingNavigationStart = true
        return result
    }

    /// True only for the explicitly prepared navigation; an unannounced
    /// script-initiated reload invalidates the old challenge immediately.
    mutating func didStartNavigation() -> Bool {
        guard expectingNavigationStart else {
            invalidate()
            return false
        }
        expectingNavigationStart = false
        navigationStarted = true
        return true
    }

    func acceptsV2(_ claimedNonce: String?) -> Bool {
        guard navigationStarted, Self.isWellFormed(claimedNonce),
              let currentNonce else { return false }
        return claimedNonce == currentNonce
    }

    mutating func invalidate() {
        currentNonce = nil
        navigationStarted = false
        expectingNavigationStart = false
    }
}

/// Version negotiation is one-way within a *single* document. This is
/// compatibility only: a future strict-v2 release must reject v1 from the
/// very first callback once generator v2 rollout is confirmed.
struct PlayerNativeBridgeVersionGate {
    /// The native app must choose its policy BEFORE any JS callback arrives.
    /// A v1 callback cannot be used to negotiate whether v1 is acceptable.
    enum AdmissionPolicy {
        case legacyCompatible
        case requireV2
    }

    let policy: AdmissionPolicy
    private(set) var acceptedV2 = false

    init(policy: AdmissionPolicy = .legacyCompatible) {
        self.policy = policy
    }

    func allows(_ schema: Int) -> Bool {
        switch policy {
        case .requireV2:
            return schema == 2
        case .legacyCompatible:
            return schema == 2 || (schema == 1 && !acceptedV2)
        }
    }

    mutating func didAccept(_ schema: Int) {
        guard allows(schema) else { return }
        if schema == 2 { acceptedV2 = true }
    }

    mutating func reset() {
        acceptedV2 = false
    }
}

/// Reject delayed messages from recently retired documents when the same
/// WebView navigates to a fresh runtime session. An unbound replacement
/// document must not accept a retired session's first queued message.
/// Keep only a fixed number of IDs regardless of game duration.
/// This is defense-in-depth; a per-navigation runtime nonce would prove
/// provenance across arbitrarily many document reloads.
/// Browser-owned runtime identifiers are *candidates*, never credentials.
/// The Go replay identity boundary caps ASCII identifiers by UTF-8 bytes.
/// A Swift String.count grapheme cap would accept oversized emoji IDs.
enum PlayerNativeRuntimeIdentifierPolicy {
    static let maximumBytes = 128

    static func validSessionID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...maximumBytes).contains(bytes.count) else { return false }
        // Match the server's printable ASCII identifier baseline.
        return bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }

    /// A genuine response must identify the exact run that was requested;
    /// same-game/verified-looking data from another run is never sufficient.
    static func matchesRequestedRunID(_ requested: String, response: String) -> Bool {
        validRunID(requested) && validRunID(response) && requested == response
    }

    static func validRunID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...maximumBytes).contains(bytes.count),
              value != ".", value != ".." else { return false }
        // The run ID becomes exactly one percent-encoded REST path segment.
        // Do not allow embedded slashes, percent escapes or dot segments.
        return bytes.allSatisfy { byte in
            (0x41...0x5a).contains(byte) ||
            (0x61...0x7a).contains(byte) ||
            (0x30...0x39).contains(byte) ||
            byte == 0x2d || byte == 0x2e ||
            byte == 0x5f || byte == 0x7e
        }
    }
}

struct PlayerRuntimeSessionBindingGate {
    static let maximumRetiredSessions = 8
    private(set) var activeSessionID: String?
    private var retiredSessionIDs: [String] = []
    var retiredCount: Int { retiredSessionIDs.count }

    mutating func bind(_ sessionID: String) -> Bool {
        guard PlayerNativeRuntimeIdentifierPolicy.validSessionID(sessionID),
              !retiredSessionIDs.contains(sessionID) else { return false }
        if let activeSessionID { return activeSessionID == sessionID }
        activeSessionID = sessionID
        return true
    }

    mutating func beginNavigation() {
        if let old = activeSessionID, !retiredSessionIDs.contains(old) {
            retiredSessionIDs.append(old)
            if retiredSessionIDs.count > Self.maximumRetiredSessions {
                retiredSessionIDs.removeFirst(retiredSessionIDs.count - Self.maximumRetiredSessions)
            }
        }
        activeSessionID = nil
    }

    mutating func clear() {
        activeSessionID = nil
        retiredSessionIDs.removeAll(keepingCapacity: false)
    }
}

/// Shipping WKWebView coordinator's pure launch transition gate (#202/#203).
/// It is NOT a second gameplay engine and never downloads/executes Game IR.
/// Navigation, render-submission and input can arrive out of order due to
/// WebKit prewarm handoff; their accepted milestones must remain monotonic.
/// A navigation finish never proves renderer/GPU readiness or interaction.
struct PlayerHostLaunchReducer {
    enum Phase: Equatable {
        case navigating
        case documentLoaded
        case sceneSubmitted
        case interactive
        case navigationFailed
        case webProcessTerminated
        case detached
    }

    private(set) var phase: Phase = .navigating
    private(set) var observedTerminalNavigation = false
    private var hasSceneSubmission = false
    private var firstInputGate = PlayerFirstInputGate()

    var isAttached: Bool { phase != .detached }
    var permitsRuntimeEvents: Bool {
        switch phase {
        case .navigationFailed, .webProcessTerminated, .detached: return false
        default: return true
        }
    }

    mutating func navigationStarted() {
        // Fatal load failures and WebContent death require a new Coordinator;
        // stale callbacks may not revive the same failed attachment.
        guard permitsRuntimeEvents else { return }
        phase = .navigating
        observedTerminalNavigation = false
        hasSceneSubmission = false
        firstInputGate = PlayerFirstInputGate()
    }

    mutating func navigationFinished() -> Bool {
        guard permitsRuntimeEvents, !observedTerminalNavigation else { return false }
        observedTerminalNavigation = true
        if phase == .navigating { phase = .documentLoaded }
        return true
    }

    mutating func sceneSubmitted() -> Bool {
        guard permitsRuntimeEvents, !hasSceneSubmission else { return false }
        hasSceneSubmission = true
        // A callback may arrive after first input due to WebKit delivery
        // order. Record the milestone but never regress the higher phase.
        if phase == .navigating || phase == .documentLoaded {
            phase = .sceneSubmitted
        }
        return true
    }

    mutating func firstInput(milliseconds: Int?) -> Bool {
        guard permitsRuntimeEvents,
              firstInputGate.accept(milliseconds: milliseconds) else { return false }
        phase = .interactive
        return true
    }

    mutating func navigationFailed() -> Bool {
        guard isAttached, !observedTerminalNavigation, phase != .webProcessTerminated else { return false }
        observedTerminalNavigation = true
        phase = .navigationFailed
        return true
    }

    mutating func webProcessTerminated() -> Bool {
        guard permitsRuntimeEvents else { return false }
        observedTerminalNavigation = true
        phase = .webProcessTerminated
        return true
    }

    mutating func detach() {
        phase = .detached
        observedTerminalNavigation = true
    }
}

/// A trusted player may restart repeatedly inside the same WK document.
/// Only the newest notified result may reach the sheet, even if older network
/// requests finish later. Recent dedup and in-flight/queued work remain bounded.
/// This gate never authorizes a result; the backend and native verification
/// checks must still validate every completed request.
struct PlayerVerifiedRunNotificationGate {
    static let maximumRecentRunIDs = 32
    static let maximumConcurrentFetches = 2
    private var recentRunIDs: [String] = []
    private var pendingRunIDs = Set<String>()
    private var deferredRunID: String?
    private var latestRunID: String?

    var recentCount: Int { recentRunIDs.count }
    var pendingCount: Int { pendingRunIDs.count }
    var deferredCount: Int { deferredRunID == nil ? 0 : 1 }

    /// Accept a distinct candidate, returning the ID to fetch immediately,
    /// or nil when the newest candidate is deferred behind two active fetches.
    /// One deferred slot supersedes older waiting outcomes, not newer ones.
    mutating func offer(_ runID: String) -> String? {
        guard PlayerNativeRuntimeIdentifierPolicy.validRunID(runID),
              !recentRunIDs.contains(runID),
              !pendingRunIDs.contains(runID),
              deferredRunID != runID else { return nil }
        recentRunIDs.append(runID)
        if recentRunIDs.count > Self.maximumRecentRunIDs {
            recentRunIDs.removeFirst(recentRunIDs.count - Self.maximumRecentRunIDs)
        }
        latestRunID = runID
        if pendingRunIDs.count < Self.maximumConcurrentFetches {
            pendingRunIDs.insert(runID)
            return runID
        }
        deferredRunID = runID
        return nil
    }

    func isLatest(_ runID: String) -> Bool {
        latestRunID == runID
    }

    /// Release a completed request and, if still attached, promote the latest
    /// deferred run. Never promote twice or resurrect after reset/detach.
    mutating func complete(_ runID: String) -> String? {
        guard pendingRunIDs.remove(runID) != nil else { return nil }
        guard let next = deferredRunID else { return nil }
        deferredRunID = nil
        pendingRunIDs.insert(next)
        return next
    }

    mutating func reset() {
        recentRunIDs.removeAll(keepingCapacity: false)
        pendingRunIDs.removeAll(keepingCapacity: false)
        deferredRunID = nil
        latestRunID = nil
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
    enum Category: Equatable { case network, unavailable, invalidPackage, incompatible, accessDenied, unknown }

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

/// Permanent Game Package and authorization failures must never trigger a
/// navigation reload loop. Recoverable transport errors may retry automatically
/// only after the existing foreground/connectivity checks have succeeded.
enum PlayerLoadRetryPolicy {
    static func shouldOfferManualRetry(category: PlayerLoadFailure.Category?) -> Bool {
        switch category {
        case .network, .unknown, nil: return true
        case .unavailable, .invalidPackage, .incompatible, .accessDenied: return false
        }
    }

    static func shouldRetryOnForeground(category: PlayerLoadFailure.Category?) -> Bool {
        category == .network
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

/// User-visible WebView callbacks belong to the currently attached sheet,
/// not simply to whichever Coordinator still has a valid runtime session.
/// A newer retry may take the pooled WebView before the old Coordinator ends.
enum PlayerHostCallbackDeliveryPolicy {
    static func mayDeliver(ownsCurrentAttachment: Bool, acceptsRuntimeEvents: Bool) -> Bool {
        ownsCurrentAttachment && acceptsRuntimeEvents
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

/// Player-only WebKit isolation boundary. Native Keychain credentials do
/// not imply WebKit's default persistent cookies/asset cache are safe across
/// user changes. Warm and interactive player reuse one in-memory store only
/// within their current native credential epoch.
@MainActor
enum PlayerWebKitSessionStoragePolicy {
    static func newSessionStore() -> WKWebsiteDataStore {
        WKWebsiteDataStore.nonPersistent()
    }

    static func configuration(processPool: WKProcessPool,
                              dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.websiteDataStore = dataStore
        return configuration
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
    private static var processPool = WKProcessPool()
    private static var playerWebsiteDataStore = PlayerWebKitSessionStoragePolicy.newSessionStore()
    private static var pooledView: WKWebView?
    private static var currentURL: URL?
    private static var loadedURL: URL?
    private static var isAttached = false
    private static var attachmentLease: UInt64 = 0
    // The single pool-owned WebKit handler never changes identity.
    // Transfer holds one exact native lease until the Coordinator mounts.
    private static var transferringLease: UInt64?
    private static var attachedReceiverLease: UInt64?
    private static weak var attachedMessageReceiver: (any WKScriptMessageHandler)?
    private static var documentEpochGate = PlayerNativeDocumentEpochGate()
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
    // Only a *currently unattached* speculative WKWebView is evictable on
    // background. Evaluate at MainActor callback delivery, not when the
    // notification was posted: a real Play may have attached in between.
    private static let backgroundObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { _ in
        Task { @MainActor in
            guard PlayerPrewarmMemoryPressurePolicy.shouldDiscard(
                isAttached: PlayerWebViewPool.isAttached,
                hasPooledView: PlayerWebViewPool.pooledView != nil
            ) else { return }
            PlayerWebViewPool.discardUnattachedPrewarm()
            DevLog.info(.player, "unattached speculative WebView prewarm evicted after background")
        }
    }
    private static var prewarmEpoch: UInt64 = 0
    private static var prewarmExpiryTask: Task<Void, Never>?
    private static let warmupDelegate = WarmupDelegate()
    // Owned independently of SwiftUI sheet presentation so a genuine
    // schema-v2 first-scene submission can be captured *before* attach.
    // WKUserContentController retains the handler; this handler never
    // retains a WKWebView or any game content.
    private static let prewarmMetricName = "hephaestusRunResult"
    private static let prewarmMetricHandler = PoolMetricRouter()
    private static var prewarmSceneGate = PlayerPrewarmV2SceneMetricGate()

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

    static func prepareDocumentNavigation(_ webView: WKWebView) {
        guard pooledView === webView else { return }
        prewarmSceneGate.reset()
        transferringLease = nil
        let nonce = documentEpochGate.prepareNavigation()
        // Only installed native code can issue a fresh current-document
        // challenge. Page code cannot derive future navigation epochs.
        // This app has no other WKUserScripts in this private pooled player.
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let source = """
        Object.defineProperty(window, '__hephaestusNativeBridge', {
          value: Object.freeze({schema: 2, documentNonce: '\(nonce)'}),
          writable: false, configurable: false
        });
        """
        controller.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    static func didStartDocumentNavigation(_ webView: WKWebView) {
        guard pooledView === webView else { return }
        prewarmSceneGate.reset()
        transferringLease = nil
        _ = documentEpochGate.didStartNavigation()
    }

    static func acceptsCurrentDocumentNonce(_ webView: WKWebView, nonce: String?) -> Bool {
        pooledView === webView && isAttached && documentEpochGate.acceptsV2(nonce)
    }

    static func hasCurrentDocumentNonce(_ webView: WKWebView) -> Bool {
        pooledView === webView && isAttached &&
            documentEpochGate.navigationStarted && documentEpochGate.currentNonce != nil
    }

    static func revokeDocumentNonce(_ webView: WKWebView) {
        guard pooledView === webView else { return }
        documentEpochGate.invalidate()
        prewarmSceneGate.reset()
        transferringLease = nil
    }

    static func prewarm(gameID: String) {
        ensureCurrentCredentialScope()
        guard !isAttached, let url = playerURL(gameID: gameID) else { return }
        let view = pooledView ?? makeWebView()
        pooledView = view
        // An existing prewarm already has its listener; do not briefly
        // unregister it while a first-scene message may be in flight.
        if currentURL == url && (view.isLoading || loadedURL == url) { return }
        // The single pool handler is installed when the WKWebView is created.
        // Never unregister it while a previous document might still post.

        view.stopLoading()
        currentURL = url
        loadedURL = nil
        view.navigationDelegate = warmupDelegate
        prepareDocumentNavigation(view)
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
        attachedMessageReceiver = nil
        attachedReceiverLease = nil
        // The pool owns callbacks from a still-loading or already-warm page
        // until the new Coordinator acknowledges this exact lease.
        transferringLease = shouldLoad ? nil : attachmentLease
        currentURL = url
        if shouldLoad {
            loadedURL = nil
            prepareDocumentNavigation(view)
        }
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
        transferringLease = nil
        documentEpochGate.invalidate()
        prewarmSceneGate.reset()
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
        transferringLease = nil
        attachedMessageReceiver = nil
        attachedReceiverLease = nil
        currentURL = nil
        loadedURL = nil
        documentEpochGate.invalidate()
        prewarmSceneGate.reset()
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
        _ = backgroundObserver
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
        transferringLease = nil
        attachedMessageReceiver = nil
        attachedReceiverLease = nil
        currentURL = nil
        loadedURL = nil
        isAttached = false
        documentEpochGate.invalidate()
        prewarmSceneGate.reset()
        sessionFingerprint = credentialFingerprint()
        // Never let a newly created player WebView share persistent data or
        // a WebContent process pool with the retired Keychain identity.
        processPool = WKProcessPool()
        playerWebsiteDataStore = PlayerWebKitSessionStoragePolicy.newSessionStore()
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
        transferringLease = nil
        attachedMessageReceiver = nil
        attachedReceiverLease = nil
        currentURL = nil
        loadedURL = nil
        documentEpochGate.invalidate()
        prewarmSceneGate.reset()
        stale?.stopLoading()
        stale?.navigationDelegate = nil
        stale?.loadHTMLString("", baseURL: nil)
    }

    static func mayNeutralizeRejectedHandoff(_ webView: WKWebView) -> Bool {
        PlayerRejectedHandoffCleanupPolicy.mayBlank(
            isCurrentPooledView: pooledView === webView
        )
    }

    /// Once mounted, the new Coordinator owns the current attachment lease.
    /// The pool's WKScriptMessageHandler itself remains installed throughout.
    @discardableResult
    static func attachMessageReceiver(
        _ receiver: WKScriptMessageHandler, webView: WKWebView,
        url: URL, lease: UInt64
    ) -> Bool {
        ensureCurrentCredentialScope()
        guard lease != 0,
              ownsAttachedNavigation(webView, url: url, lease: lease)
        else { return false }
        attachedMessageReceiver = receiver
        attachedReceiverLease = lease
        transferringLease = nil
        return true
    }

    /// Reject all callbacks from retired views/credential epochs. Untrusted
    /// attached messages still run through the original Coordinator's full
    /// native main-frame/origin/nonce/session/game/typed-metric admission.
    private static func routeWebKitMessage(
        _ controller: WKUserContentController, message: WKScriptMessage
    ) {
        ensureCurrentCredentialScope()
        guard let view = pooledView, message.webView === view else { return }
        let scopeIsCurrent = sessionFingerprint == credentialFingerprint()
        let hasCurrentReceiver = attachedMessageReceiver != nil &&
            attachedReceiverLease == attachmentLease
        switch PlayerPrewarmMessageOwnershipPolicy.recipient(
            isAttached: isAttached, transferringLease: transferringLease,
            currentLease: attachmentLease,
            hasAttachedReceiver: hasCurrentReceiver,
            credentialScopeCurrent: scopeIsCurrent
        ) {
        case .speculative:
            collectPrewarmMetric(message)
        case .attached:
            guard let lease = attachedReceiverLease,
                  ownsActiveAttachment(view, lease: lease) else { return }
            attachedMessageReceiver?.userContentController(
                controller, didReceive: message
            )
        case .drop:
            return
        }
    }

    // A pool-owned listener cannot receive a run result or other privileges.
    // Require WKScriptMessage.webView identity, current immutable player URL,
    // native frame/origin and credential fingerprint, and the one current
    // nonce-bound schema-v2 metric before storing a bounded observation.
    private static func collectPrewarmMetric(_ message: WKScriptMessage) {
        guard message.name == prewarmMetricName,
              let view = pooledView, let url = currentURL,
              let expectedGameID = URLComponents(
                  url: url, resolvingAgainstBaseURL: false
              )?.queryItems?.first(where: { $0.name == "game" })?.value,
              let body = message.body as? [String: Any] else { return }
        let source = message.frameInfo.securityOrigin
        let trustedProvenance = PlayerPrewarmMessageOriginPolicy.allows(
            isCurrentPooledView: message.webView === view,
            // During take()->attach the current pool owns the transfer
            // lease; do not treat it as a completed attached receiver yet.
            isAttached: isAttached && transferringLease == nil,
            expectedURL: currentURL, actualURL: view.url,
            isMainFrame: message.frameInfo.isMainFrame,
            originScheme: source.protocol, originHost: source.host,
            originPort: source.port, backendURL: BackendConfig.baseURL
        )
        guard trustedProvenance else { return }
        _ = prewarmSceneGate.record(
            body, expectedGameID: expectedGameID,
            currentDocumentNonce: documentEpochGate.currentNonce,
            isTrustedMainFrame: message.frameInfo.isMainFrame,
            isSameOrigin: trustedProvenance,
            navigationStarted: documentEpochGate.navigationStarted,
            credentialScopeCurrent: sessionFingerprint == credentialFingerprint()
        )
    }

    // This pool-owned handler is stable across take/recycle. It holds no
    // WKWebView or Coordinator and cannot retain a retired game session.
    private final class PoolMetricRouter: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            PlayerWebViewPool.routeWebKitMessage(userContentController, message: message)
        }
    }

    private static func makeWebView() -> WKWebView {
        let configuration = PlayerWebKitSessionStoragePolicy.configuration(
            processPool: processPool, dataStore: playerWebsiteDataStore
        )
        // Prewarm must register before view.load; the pool listener accepts
        // only schema-v2 scene *metrics*, never a run or native control.
        configuration.userContentController.add(
            prewarmMetricHandler, name: prewarmMetricName
        )
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "HephaestusPlayer/1.1"
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    private final class WarmupDelegate: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            PlayerWebViewPool.didStartDocumentNavigation(webView)
        }

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

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            PlayerWebViewPool.markFailed(webView)
            PlayerWebViewPool.revokeDocumentNonce(webView)
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
    @State private var loadFailureCategory: PlayerLoadFailure.Category?
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
        loadFailureCategory = nil
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
                            loadFailureCategory = PlayerLoadFailure.category(for: error)
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
                            // A terminated document must not turn a known permanent
                            // package/entitlement error into another recoverable error.
                            // Keep its original failure and Return to feed available.
                            guard PlayerLoadRetryPolicy.shouldOfferManualRetry(category: loadFailureCategory) else {
                                isLoading = false
                                return
                            }
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
                                loadFailureCategory = nil
                                isLoading = true
                                progress = 0
                                showSlowHint = false
                                loadStartedAt = Date()
                                attempt += 1
                            } else {
                                isLoading = false
                                loadFailureCategory = .unknown
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
                            if PlayerLoadRetryPolicy.shouldOfferManualRetry(category: loadFailureCategory) {
                                Button("Retry") {
                                    self.loadError = nil
                                    self.loadFailureCategory = nil
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
                            }
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

                // iOS UINavigationBar still clamps a ToolbarItem's real
                // accessibility button to 36pt, even with a 44pt label.
                // The single exit lives in the player-owned safe-area row.
                ToolbarItemGroup(placement: .primaryAction) {
                    // The real system ShareLink is in the same native
                    // safe-area row as Done. iPhone AND iPad CI measured a
                    // navigation-toolbar ShareLink AX height of only 36pt.
                    // Keep quality selection in the navigation toolbar.
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
            // The platform toolbar measured a real 36pt Done hitbox on iPhone
            // despite a 44pt inner label (#460). Reserve an app-owned safe
            // area row so the one native exit remains fully hittable while
            // WKWebView receives no touches under the control.
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button {
                        finishToFeed()
                    } label: {
                        Text("Done")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(ArcadePulseTheme.textPrimary)
                            .frame(minWidth: 72, minHeight: 48)
                            .background(
                                ArcadePulseTheme.surface,
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.done")
                    .accessibilityHint("Close this game and return to the feed")
                    Spacer(minLength: 0)
                    // One interactive host for both native player actions.
                    // Avoid the UINavigationBar's measured 36pt ShareLink
                    // hitbox without inventing a custom share controller.
                    ShareLink(item: shareURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(ArcadePulseTheme.textPrimary)
                            .frame(minWidth: 88, minHeight: 48)
                            .background(
                                ArcadePulseTheme.surface,
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share game")
                    .accessibilityIdentifier("player.share")
                    .simultaneousGesture(TapGesture().onEnded {
                        Task { await BackendAPI.shared.trackSocialEvent(gameID: gameID, kind: "share") }
                    })
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 56)
                .background(ArcadePulseTheme.canvas)
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
                    if !sessionRevoked &&
                       PlayerLoadRetryPolicy.shouldRetryOnForeground(category: loadFailureCategory) &&
                       PlayerLifecyclePolicy.shouldRetryAfterForeground(
                           wasBackgrounded: true, isOffline: pathMonitor.isOffline, hasError: loadError != nil
                       ) {
                        loadError = nil
                        loadFailureCategory = nil
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
                loadFailureCategory = .accessDenied
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

    // Also used by Coordinator during strict message-name admission;
    // the pool owns handler registration but not the trusted name policy.
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
        context.coordinator.attachedWebView = webView
        // No remove/add gap: the pool keeps exactly one WebKit handler.
        // An old Coordinator can never displace this lease's receiver.
        guard PlayerWebViewPool.attachMessageReceiver(
            context.coordinator.messageProxy, webView: webView,
            url: url, lease: handoff.lease
        ) else {
            // A credential rotation may have retired this exact WKWebView,
            // but a newer sheet may also have RETAKEN the same pooled view
            // under a successor lease. Only blank it when it is no longer
            // the pool's live view; never stop the successor's navigation.
            if PlayerWebViewPool.mayNeutralizeRejectedHandoff(webView) {
                webView.stopLoading()
                webView.loadHTMLString("", baseURL: nil)
            }
            return webView
        }
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
        // Recycle invalidates the lease; the pool's sole WebKit handler stays.
        PlayerWebViewPool.recycle(webView, lease: coordinator.attachmentLease)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var attachmentLease: UInt64 = 0
        // Only weakly reference the pooled host; never retain a retired view
        // merely because an asynchronous verified-result lookup is pending.
        weak var attachedWebView: WKWebView?
        private var ownsLiveAttachment: Bool {
            guard let view = attachedWebView else { return false }
            return PlayerWebViewPool.ownsActiveAttachment(view, lease: attachmentLease)
        }
        private var acceptsCurrentHostCallbacks: Bool {
            PlayerHostCallbackDeliveryPolicy.mayDeliver(
                ownsCurrentAttachment: ownsLiveAttachment,
                acceptsRuntimeEvents: launchLifecycle.permitsRuntimeEvents
            )
        }
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
        private var verifiedRunGate = PlayerVerifiedRunNotificationGate()
        // At most two concurrent result lookups; deferred work stays latest-only.
        private var verifiedRunFetchTasks: [String: Task<Void, Never>] = [:]
        private var navigationFailureGate = PlayerNavigationFailureGate()
        private var metricSequenceGate = PlayerRuntimeMetricSequenceGate()
        private var firstSceneRenderSubmissionGate = PlayerFirstSceneRenderSubmissionGate()
        private var launchLifecycle = PlayerHostLaunchReducer()
        private var runtimeSessionGate = PlayerRuntimeSessionBindingGate()
        // Compatibility remains explicitly enabled until the trusted generator's
        // schema-v2 producer is deployed and validated. Flip to .requireV2
        // as one reviewed release change; never auto-negotiate from the
        // first untrusted JS callback.
        private var nativeBridgeVersionGate = PlayerNativeBridgeVersionGate(
            policy: .legacyCompatible
        )
        private var runtimeSessionID: String? { runtimeSessionGate.activeSessionID }
        private var isActive: Bool { launchLifecycle.isAttached }
        private var hasObservedTerminalNavigation: Bool { launchLifecycle.observedTerminalNavigation }
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
            // Reject retired attachments, wrong frame/origin, stale navigation
            // epochs and malformed schemas before binding the first session.
            guard acceptsCurrentHostCallbacks,
                  message.name == PlayerWebView.messageName,
                  message.frameInfo.isMainFrame,
                  sameOrigin(message.frameInfo.securityOrigin),
                  let body = message.body as? [String: Any],
                  let schema = PlayerNativeMetricPayload.strictInt(body["schema"]),
                  (schema == 1 || schema == 2),
                  let view = attachedWebView,
                  PlayerWebViewPool.hasCurrentDocumentNonce(view),
                  nativeBridgeVersionGate.allows(schema),
                  (schema != 2 || PlayerWebViewPool.acceptsCurrentDocumentNonce(
                      view, nonce: body["documentNonce"] as? String
                  )),
                  let runtimeSessionID = body["sessionId"] as? String,
                  PlayerNativeRuntimeIdentifierPolicy.validSessionID(runtimeSessionID),
                  body["gameId"] as? String == expectedGameID,
                  let type = body["type"] as? String,
                  (type == "player_metric" || type == "verified_run_available") else { return }
            let permittedResultFields: Set<String> = schema == 2
                ? ["schema", "type", "sessionId", "gameId", "runId", "documentNonce"]
                : ["schema", "type", "sessionId", "gameId", "runId"]
            // A malformed high-sequence metric or forged result must not
            // claim the new runtime-session binding slot.
            let validMetric = type == "player_metric" &&
                PlayerNativeMetricPayload.parse(body) != nil
            let validRun = type == "verified_run_available" &&
                Set(body.keys) == permittedResultFields &&
                (body["runId"] as? String).map(
                    PlayerNativeRuntimeIdentifierPolicy.validRunID
                ) == true
            guard (validMetric || validRun),
                  runtimeSessionGate.bind(runtimeSessionID) else { return }
            nativeBridgeVersionGate.didAccept(schema)
            if type == "player_metric" {
                handleMetric(body, runtimeSessionID: runtimeSessionID)
                return
            }
            guard let runID = body["runId"] as? String,
                  let toFetch = verifiedRunGate.offer(runID) else { return }
            requestVerifiedRunResult(toFetch, runtimeSessionID: runtimeSessionID)
        }

        private func requestVerifiedRunResult(_ runID: String, runtimeSessionID: String) {
            // The host owns the backend lookup tasks, not the lifetime of a
            // reused WKWebView document. Cancellation on dismantle prevents
            // stale lookups keeping a retired coordinator alive unnecessarily.
            verifiedRunFetchTasks[runID] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.verifiedRunFetchTasks.removeValue(forKey: runID)
                    if let next = self.verifiedRunGate.complete(runID),
                       self.isActive, self.ownsLiveAttachment,
                       self.runtimeSessionID == runtimeSessionID {
                        self.requestVerifiedRunResult(next, runtimeSessionID: runtimeSessionID)
                    }
                }
                do {
                    let result = try await BackendAPI.shared.fetchVerifiedRunResult(runID: runID)
                    // In-page Play Again can post a newer run ID before this
                    // older backend fetch completes. Never overwrite its result.
                    // The request may have completed while the coordinator was
                    // being dismantled; cancellation must also block delivery.
                    guard !Task<Never, Never>.isCancelled,
                          self.isActive, self.ownsLiveAttachment,
                          self.launchLifecycle.permitsRuntimeEvents,
                          self.runtimeSessionID == runtimeSessionID,
                          self.verifiedRunGate.isLatest(runID),
                          PlayerNativeRuntimeIdentifierPolicy.matchesRequestedRunID(
                              runID, response: result.runID
                          ),
                          result.gameID == self.expectedGameID, result.isVerified else { return }
                    self.onVerifiedRun(result)
                } catch {
                    // Dismissal, retry or sign-out cancels session-owned work;
                    // expected cancellation is not a user-facing fetch error.
                    guard !Task<Never, Never>.isCancelled,
                          self.isActive, self.ownsLiveAttachment,
                          self.launchLifecycle.permitsRuntimeEvents,
                          self.runtimeSessionID == runtimeSessionID else { return }
                    PlayerTelemetry.report(gameID: self.expectedGameID, kind: "ios-run-result-failed",
                                           name: "VerifiedRunResultFetchFailed",
                                           message: "verified result unavailable")
                }
            }
        }

        private func handleMetric(_ body: [String: Any], runtimeSessionID: String) {
            // Reject malformed/extra fields *before* advancing the per-kind
            // high-water mark. Otherwise a bad sequence=100000 can suppress
            // a later valid scene/input message with a smaller sequence.
            guard let payload = PlayerNativeMetricPayload.parse(body),
                  let sequence = body["sequence"] as? Int,
                  metricSequenceGate.accept(metric: payload.metric, sequence: sequence) else { return }
            let metricID = "\(runtimeSessionID):\(payload.metric):\(sequence)"
            switch payload {
            case .firstSceneRenderSubmit(let ms):
                guard firstSceneRenderSubmissionGate.accept(milliseconds: ms),
                      launchLifecycle.sceneSubmitted() else { return }
                // This metric may be lost when a pooled WebView was already
                // warmed before the Coordinator attached. The backend also
                // captures the milestone independently for that case.
                PlayerTelemetry.report(
                    gameID: expectedGameID, kind: "perf",
                    name: "FirstSceneRenderSubmitted",
                    message: "renderer-submitted-ms=\(ms); not display-presented or interactive"
                )
            case .firstInput(let ms):
                guard launchLifecycle.firstInput(milliseconds: ms) else { return }
                Task { @MainActor [weak self] in
                    // After a retry, session equality alone cannot authorize
                    // the retired Coordinator to update the old player sheet.
                    guard let self, self.acceptsCurrentHostCallbacks,
                          self.runtimeSessionID == runtimeSessionID else { return }
                    self.onFirstInput()
                }
                Task { await BackendAPI.shared.trackSocialEvent(
                    gameID: expectedGameID, kind: "player_first_input",
                    timeToFirstInputMS: ms, eventID: "ios-metric:\(metricID)"
                ) }
            case .perfWindow(let p95, let avg, let count):
                Task { await BackendAPI.shared.trackSocialEvent(
                    gameID: expectedGameID, kind: "player_perf_window",
                    frameTimeP95MS: p95, frameTimeAvgMS: avg,
                    frameCount: count, eventID: "ios-metric:\(metricID)"
                ) }
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
                guard let self, self.acceptsCurrentHostCallbacks else { return }
                self.onProgress(view.estimatedProgress)
            }
        }

        func stopObserving() {
            launchLifecycle.detach()
            prewarmRecoveryArmed = false
            prewarmLoadingObservation?.invalidate()
            prewarmLoadingObservation = nil
            progressObservation?.invalidate()
            progressObservation = nil
            for task in verifiedRunFetchTasks.values { task.cancel() }
            verifiedRunFetchTasks.removeAll(keepingCapacity: false)
            verifiedRunGate.reset()
            attachedWebView = nil
            metricSequenceGate.reset()
            firstSceneRenderSubmissionGate = PlayerFirstSceneRenderSubmissionGate()
            runtimeSessionGate.clear()
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
            guard acceptsCurrentHostCallbacks,
                  launchLifecycle.navigationFinished() else { return }
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
            PlayerWebViewPool.prepareDocumentNavigation(webView)
            webView.load(URLRequest(url: expectedURL))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard acceptsCurrentHostCallbacks else { return }
            PlayerWebViewPool.didStartDocumentNavigation(webView)
            nativeBridgeVersionGate.reset()
            launchLifecycle.navigationStarted()
            // A real reload has a new web runtime session. Stale metrics,
            // run IDs, and in-flight verified-result lookups from the old
            // document must not be associated with the replacement page.
            runtimeSessionGate.beginNavigation()
            // Revoke older document result requests before accepting a new
            // metric and verified-run session; canceled results cannot win.
            for task in verifiedRunFetchTasks.values { task.cancel() }
            verifiedRunFetchTasks.removeAll(keepingCapacity: false)
            verifiedRunGate.reset()
            // New trusted document restarts metric sequence and first render.
            metricSequenceGate.reset()
            firstSceneRenderSubmissionGate = PlayerFirstSceneRenderSubmissionGate()
            navigationFailureGate.beginNavigation()
            onProgress(0)
        }

        private func reportNavigationFailure(_ error: Error) {
            guard acceptsCurrentHostCallbacks,
                  launchLifecycle.navigationFailed(),
                  navigationFailureGate.shouldReportFailure() else { return }
            disarmPrewarmRecovery()
            if let view = attachedWebView { PlayerWebViewPool.revokeDocumentNonce(view) }
            onLoadFail(error)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let allow = acceptsCurrentHostCallbacks && PlayerWebViewPool.allowsMainFrameNavigation(
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
            guard acceptsCurrentHostCallbacks else {
                decisionHandler(.cancel)
                return
            }
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
            guard acceptsCurrentHostCallbacks,
                  launchLifecycle.webProcessTerminated() else { return }
            disarmPrewarmRecovery()
            PlayerWebViewPool.revokeDocumentNonce(webView)
            onTerminate()
        }
    }
}
