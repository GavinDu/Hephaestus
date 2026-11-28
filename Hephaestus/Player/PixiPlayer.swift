import Combine
import CoreFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
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

/// Canonical immutable public GamePackage identity from the backend wire contract.
/// Never trim or rewrite IDs: altered identity can reopen a different game
/// or poison a pooled scene/credential lease. The query encoder is not a validator.
/// Source-compatible native launch/pool policy. The common ASCII/byte
/// contract is shared with BackendAPI's verified-only leaderboard request.
enum PlayerPublishedGameIDPolicy {
    static func valid(_ gameID: String) -> Bool {
        PublishedGameIDPolicy.valid(gameID)
    }
}

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

/// Host-side admission for feed-provided hold-poster URLs, before AsyncImage.
/// This is transport/scheme safety, not proof that an image's content,
/// moderation verdict, origin redirect or decoded-pixel budget is trusted.
enum PlayerHoldPosterURLPolicy {
    static func admittedURL(_ raw: String?, backendOrigin: URL) -> URL? {
        guard let raw, (1...2048).contains(raw.utf8.prefix(2049).count) else {
            return nil
        }
        for scalar in raw.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) ||
               CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return nil
            }
        }
        guard let components = URLComponents(string: raw),
              components.fragment == nil,
              components.user == nil, components.password == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        if scheme == "https" { return url }
        // Local/development HTTP is permitted only for the configured
        // backend origin. Never load unrelated cleartext remote posters.
        guard scheme == "http",
              backendOrigin.scheme?.lowercased() == "http",
              host.lowercased() == backendOrigin.host?.lowercased(),
              (components.port ?? 80) == (backendOrigin.port ?? 80) else {
            return nil
        }
        return url
    }
}

/// Pure policy for a future URLSession-backed hold-poster loader.
/// WARNING: SwiftUI AsyncImage does not invoke this policy. #715 must wire it
/// to a cancellable transport delegate before redirect enforcement ships.
enum PlayerPosterRedirectHopPolicy {
    static let maximumRedirects = 3

    /// alreadyFollowed is the number of hops previously accepted (0, 1, 2).
    /// All trust anchors are native caller-owned; never take an original
    /// origin from a redirected HTTP response or creator-authored metadata.
    static func admittedHop(
        original: URL,
        from previous: URL,
        to proposed: URL,
        alreadyFollowed: Int,
        backendOrigin: URL
    ) -> URL? {
        guard (0..<maximumRedirects).contains(alreadyFollowed),
              let start = admittedUnambiguousURL(original, backendOrigin: backendOrigin),
              let prior = admittedUnambiguousURL(previous, backendOrigin: backendOrigin),
              let next = admittedUnambiguousURL(proposed, backendOrigin: backendOrigin),
              let pinnedOrigin = originKey(start),
              originKey(prior) == pinnedOrigin,
              originKey(next) == pinnedOrigin else { return nil }
        return next
    }

    private static func admittedUnambiguousURL(_ url: URL, backendOrigin: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedHost = components.percentEncodedHost, !encodedHost.isEmpty,
              // Conservative until real publisher/CDN inventory proves additional
              // host forms safe. Reject encoded host, IPv6 and unicode ambiguity.
              encodedHost.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0)
              }) else { return nil }
        return PlayerHoldPosterURLPolicy.admittedURL(
            url.absoluteString, backendOrigin: backendOrigin
        )
    }

    private static func originKey(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { return nil }
        return "\(scheme)|\(host)|\(port)"
    }
}

/// Pure admission for a future lease-owned hold-poster transport (#715).
/// Mirrors Generator preview.go's PNG/JPEG, 2 MiB and 4096 dimension
/// limits. No image decode or network request occurs in this policy.
/// The shipping AsyncImage does not yet invoke it.
struct PlayerHoldPosterResponseBudget {
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumDimension = 4096
    static let maximumPixels = 16_777_216

    enum Format: String {
        case png = "image/png"
        case jpeg = "image/jpeg"

        var typeIdentifier: String {
            switch self {
            case .png: UTType.png.identifier
            case .jpeg: UTType.jpeg.identifier
            }
        }
    }

    let format: Format
    let declaredLength: Int?
    private(set) var receivedBytes = 0
    private(set) var rejected = false
    private var finished = false

    init?(statusCode: Int, mimeType: String?, expectedLength: Int64,
          contentEncoding: String?) {
        guard statusCode == 200,
              let mimeType, let format = Format(rawValue: mimeType.lowercased()),
              expectedLength == -1 || (1...Int64(Self.maximumBytes)).contains(expectedLength),
              contentEncoding == nil || contentEncoding?.lowercased() == "identity"
        else { return nil }
        self.format = format
        self.declaredLength = expectedLength == -1 ? nil : Int(expectedLength)
    }

    /// Call BEFORE appending a received chunk to the bounded data buffer.
    /// A rejected response is terminal, even if a later chunk is small.
    mutating func admitChunk(byteCount: Int) -> Bool {
        let limit = declaredLength ?? Self.maximumBytes
        guard !rejected, !finished, byteCount >= 0, byteCount <= limit - receivedBytes else {
            rejected = true
            return false
        }
        receivedBytes += byteCount
        return true
    }

    /// Call exactly once from the transport's terminal completion callback.
    /// Reaching a byte count alone never authorizes header inspection/decode.
    /// Failed, empty, truncated or duplicate completion is terminally rejected.
    mutating func finish(transportSucceeded: Bool) -> Bool {
        guard !rejected, !finished, transportSucceeded, receivedBytes > 0,
              declaredLength == nil || receivedBytes == declaredLength else {
            rejected = true
            return false
        }
        finished = true
        return true
    }

    var complete: Bool {
        finished && !rejected
    }

    static func dimensionsAllowed(width: Int, height: Int) -> Bool {
        guard (1...maximumDimension).contains(width),
              (1...maximumDimension).contains(height) else { return false }
        return width <= maximumPixels / height
    }

    /// Inspect encoded type and header metadata before any raster decode.
    /// This does not certify complete bitstream validity or image moderation.
    func admitsEncodedHeader(_ data: Data) -> Bool {
        guard complete, data.count == receivedBytes else { return false }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let identifier = CGImageSourceGetType(source),
              (identifier as String) == format.typeIdentifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return Self.dimensionsAllowed(width: width, height: height)
    }
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

/// Re-evaluate native ownership when an asynchronously enqueued, non-score
/// social metric is about to begin. Trusted flags come from the *current*
/// Coordinator/pool, never the untrusted message body's fields. Once a real
/// network request begins, its completion is a separate cancellation concern.
enum PlayerRuntimeMetricDispatchPolicy {
    static func mayStart(
        ownsCurrentAttachment: Bool,
        permitsRuntimeEvents: Bool,
        taskCancelled: Bool,
        expectedSessionID: String,
        currentSessionID: String?
    ) -> Bool {
        ownsCurrentAttachment && permitsRuntimeEvents && !taskCancelled &&
        PlayerNativeRuntimeIdentifierPolicy.validSessionID(expectedSessionID) &&
        currentSessionID == expectedSessionID
    }
}

/// Main-actor native telemetry owner. One bounded set of URLSession-backed
/// Swift Tasks per attached document; no queue or second runtime executor.
/// A revoked Task may have ALREADY reached the server before cancellation.
/// The epoch prevents late task completion from changing a later document.
@MainActor
final class PlayerNativeMetricTaskRegistry {
    static let maximumInFlight = 2

    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var nextID: UInt64 = 0
    private(set) var epoch: UInt64 = 0
    var inFlightCount: Int { tasks.count }

    @discardableResult
    func submit(_ makeTask: (_ taskID: UInt64, _ epoch: UInt64) -> Task<Void, Never>) -> Bool {
        guard tasks.count < Self.maximumInFlight,
              nextID < UInt64.max, epoch < UInt64.max else { return false }
        nextID += 1
        let id = nextID
        tasks[id] = makeTask(id, epoch)
        return true
    }

    func complete(taskID: UInt64, epoch taskEpoch: UInt64) {
        guard taskEpoch == epoch else { return }
        tasks.removeValue(forKey: taskID)
    }

    func revoke() {
        if epoch < UInt64.max { epoch += 1 }
        let priorTasks = Array(tasks.values)
        tasks.removeAll(keepingCapacity: false)
        for task in priorTasks { task.cancel() }
    }
}

/// The pool weakly observes only its current attached document's task
/// registry. Retire before replacing ownership, not on eventual SwiftUI
/// dismantle. This never retracts a server-committed event.
@MainActor
final class PlayerNativeMetricAttachmentRevocation {
    private weak var registry: PlayerNativeMetricTaskRegistry?

    func bind(_ next: PlayerNativeMetricTaskRegistry) {
        if registry === next { return }
        retire()
        registry = next
    }

    func retire() {
        let prior = registry
        registry = nil
        prior?.revoke()
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

/// Fail-closed WebKit origin equality shared by speculative and attached players.
/// WKSecurityOrigin.port can be 0 for an implicit *standard* HTTP(S) port.
/// This helper does not authenticate a frame, navigation, document, or session.
enum PlayerWebKitOriginPolicy {
    static func matches(
        backendURL: URL,
        originScheme: String,
        originHost: String,
        originPort: Int
    ) -> Bool {
        guard let scheme = backendURL.scheme,
              scheme == "https" || scheme == "http",
              let host = backendURL.host, !host.isEmpty,
              backendURL.user == nil, backendURL.password == nil,
              (0...65535).contains(originPort)
        else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        let expectedPort = backendURL.port ?? defaultPort
        guard (1...65535).contains(expectedPort) else { return false }
        let observedPort = originPort == 0 ? defaultPort : originPort
        return originScheme == scheme && originHost == host &&
            observedPort == expectedPort
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
              let expectedURL, actualURL == expectedURL else { return false }
        return PlayerWebKitOriginPolicy.matches(
            backendURL: backendURL,
            originScheme: originScheme, originHost: originHost,
            originPort: originPort
        )
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

/// Only a current native-admitted scene submission can release a hold poster.
/// Navigation finish is not a first composited pixel nor gameplay start.
enum PlayerScenePosterHandoffPolicy {
    static let noSceneTimeoutMilliseconds: Int64 = 12_000

    static func mayFade(
        expectedAttempt: Int, acceptedSceneAttempt: Int?,
        hasHoldPoster: Bool, holdVisible: Bool, holdOpacity: Double,
        navigationFinished: Bool, hasLoadError: Bool, sessionRevoked: Bool
    ) -> Bool {
        acceptedSceneAttempt == expectedAttempt &&
        hasHoldPoster && holdVisible && holdOpacity > 0 &&
        navigationFinished && !hasLoadError && !sessionRevoked
    }

    static func shouldOfferNoSceneRecovery(
        expectedAttempt: Int, acceptedSceneAttempt: Int?,
        hasHoldPoster: Bool, holdVisible: Bool,
        navigationFinished: Bool, hasLoadError: Bool, sessionRevoked: Bool,
        isForeground: Bool
    ) -> Bool {
        acceptedSceneAttempt != expectedAttempt &&
        hasHoldPoster && holdVisible && navigationFinished &&
        !hasLoadError && !sessionRevoked && isForeground
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

/// At most one candidate scene-submit milestone per current speculative
/// WK document. Its identity is immutable; neither URL equality alone nor a
/// JS session ID alone is sufficient to transfer ownership after a retry.
/// The permanent pool-owned schema-v2 WebKit listener records a candidate
/// under current native document identity (#561); attached consume is #562/#352.
struct PlayerPrewarmSceneMilestoneLedger {
    struct Identity: Equatable {
        let gameID: String
        let playerURL: URL
        let documentNonce: String
        let credentialFingerprint: String
        let runtimeSessionID: String

        var isValid: Bool {
            guard PlayerPublishedGameIDPolicy.valid(gameID),
                  playerURL.scheme?.lowercased() == "https",
                  let host = playerURL.host, !host.isEmpty,
                  playerURL.user == nil, playerURL.password == nil,
                  playerURL.fragment == nil,
                  let components = URLComponents(
                      url: playerURL, resolvingAgainstBaseURL: false
                  ),
                  components.path == "/player",
                  let gameItems = components.queryItems?.filter({ $0.name == "game" }),
                  gameItems.count == 1, gameItems[0].value == gameID,
                  PlayerNativeDocumentEpochGate.isWellFormed(documentNonce),
                  !credentialFingerprint.isEmpty,
                  credentialFingerprint.utf8.count <= 256,
                  (1...128).contains(runtimeSessionID.utf8.count) else { return false }
            // Mirror the protocol byte contract instead of String.count,
            // which counts grapheme clusters, not the UTF-8 session bytes.
            return runtimeSessionID.utf8.allSatisfy { (0x21...0x7e).contains($0) }
        }
    }

    struct Submission: Equatable {
        let identity: Identity
        let sequence: Int
        let milliseconds: Int
    }

    private(set) var candidate: Submission?
    private(set) var hasTransferred = false

    mutating func record(
        identity: Identity,
        expected: Identity,
        sequence: Int,
        milliseconds: Int,
        isMainFrame: Bool,
        isSpeculative: Bool,
        navigationStarted: Bool
    ) -> Bool {
        guard candidate == nil, !hasTransferred,
              identity.isValid, expected.isValid, identity == expected,
              isMainFrame, isSpeculative, navigationStarted,
              (0...100_000).contains(sequence),
              (0...3_600_000).contains(milliseconds) else { return false }
        candidate = Submission(
            identity: identity, sequence: sequence, milliseconds: milliseconds
        )
        return true
    }

    /// A retired SwiftUI Coordinator must not steal a successor's pending
    /// milestone. Mismatched identities do not consume a current candidate;
    /// navigation/session invalidation separately clears all stale state.
    mutating func consume(
        expected: Identity,
        offeredLease: UInt64,
        currentLease: UInt64,
        isCurrentPooledView: Bool,
        isAttached: Bool
    ) -> Submission? {
        guard !hasTransferred, let candidate,
              candidate.identity == expected, expected.isValid,
              offeredLease != 0, offeredLease == currentLease,
              isCurrentPooledView, isAttached else { return nil }
        hasTransferred = true
        self.candidate = nil
        return candidate
    }

    mutating func invalidate() {
        candidate = nil
        hasTransferred = false
    }
}

/// The speculative WK callback is not an attached player callback.
/// Commit both pure gates together: a forged or malformed document metric
/// cannot poison one state while leaving the other unconsumed.
enum PlayerPrewarmSceneLedgerCapturePolicy {
    static func capture(
        _ body: [String: Any],
        identity: PlayerPrewarmSceneMilestoneLedger.Identity,
        currentDocumentNonce: String?,
        isTrustedMainFrame: Bool,
        isSameOrigin: Bool,
        navigationStarted: Bool,
        credentialScopeCurrent: Bool,
        isSpeculative: Bool,
        gate: inout PlayerPrewarmV2SceneMetricGate,
        ledger: inout PlayerPrewarmSceneMilestoneLedger
    ) -> Bool {
        guard identity.isValid,
              identity.documentNonce == currentDocumentNonce,
              // Pin the stored candidate to the *exact* admitted session,
              // not a different valid-but-attacker-selected message session.
              body["sessionId"] as? String == identity.runtimeSessionID,
              let sequence = PlayerNativeMetricPayload.strictInt(body["sequence"]),
              let payload = PlayerNativeMetricPayload.parse(body),
              case let .firstSceneRenderSubmit(milliseconds) = payload
        else { return false }

        var nextGate = gate
        var nextLedger = ledger
        guard nextGate.record(
            body, expectedGameID: identity.gameID,
            currentDocumentNonce: currentDocumentNonce,
            isTrustedMainFrame: isTrustedMainFrame,
            isSameOrigin: isSameOrigin,
            navigationStarted: navigationStarted,
            credentialScopeCurrent: credentialScopeCurrent
        ), nextLedger.record(
            identity: identity, expected: identity,
            sequence: sequence, milliseconds: milliseconds,
            isMainFrame: isTrustedMainFrame, isSpeculative: isSpeculative,
            navigationStarted: navigationStarted
        ) else { return false }
        gate = nextGate
        ledger = nextLedger
        return true
    }
}

/// Native-only prewarm-to-attached identity gate. An old Coordinator
/// cannot consume a successor's candidate by guessing the URL or run ID;
/// every field is compared with current pool, nonce and credential facts.
enum PlayerPrewarmAttachedSceneIdentityPolicy {
    static func matches(
        _ submission: PlayerPrewarmSceneMilestoneLedger.Submission,
        currentURL: URL?,
        currentDocumentNonce: String?,
        currentCredentialFingerprint: String?,
        expectedGameID: String,
        offeredLease: UInt64,
        currentLease: UInt64,
        isCurrentPooledView: Bool,
        isAttached: Bool
    ) -> Bool {
        let identity = submission.identity
        return identity.isValid &&
            currentURL == identity.playerURL &&
            currentDocumentNonce == identity.documentNonce &&
            currentCredentialFingerprint == identity.credentialFingerprint &&
            expectedGameID == identity.gameID &&
            PlayerNativeRuntimeIdentifierPolicy.validSessionID(identity.runtimeSessionID) &&
            (0...100_000).contains(submission.sequence) &&
            (0...3_600_000).contains(submission.milliseconds) &&
            PlayerAttachmentLeasePolicy.mayRecycle(
                isCurrentPooledView: isCurrentPooledView,
                isAttached: isAttached,
                expectedLease: offeredLease, currentLease: currentLease
            )
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
        // The WebKit message body is untrusted. Reject the 129th byte before
        // allocating a full UTF-8 copy of a potentially enormous string.
        // Keep #451's exact server-compatible printable ASCII grammar.
        var byteCount = 0
        for byte in value.utf8 {
            byteCount += 1
            guard byteCount <= maximumBytes, (0x21...0x7e).contains(byte) else {
                return false
            }
        }
        return byteCount > 0
    }

    /// A genuine response must identify the exact run that was requested;
    /// same-game/verified-looking data from another run is never sufficient.
    static func matchesRequestedRunID(_ requested: String, response: String) -> Bool {
        validRunID(requested) && validRunID(response) && requested == response
    }

    static func validRunID(_ value: String) -> Bool {
        guard value != ".", value != ".." else { return false }
        // Validate the path segment in a streaming bounded pass: don't
        // materialize its entire UTF-8 representation before the length gate.
        // Existing #451 unreserved grammar and dot-segment rules are unchanged.
        var byteCount = 0
        for byte in value.utf8 {
            byteCount += 1
            guard byteCount <= maximumBytes,
                  (0x41...0x5a).contains(byte) ||
                  (0x61...0x7a).contains(byte) ||
                  (0x30...0x39).contains(byte) ||
                  byte == 0x2d || byte == 0x2e ||
                  byte == 0x5f || byte == 0x7e
            else { return false }
        }
        return byteCount > 0
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

/// Read-only projection of the one shipping WKWebView host (#731/#642).
/// It does not instantiate GamePlayerCore.PlayerLaunchCoordinator or fetch,
/// validate or decode packages/assets a second time. "rendererSubmitted"
/// means a vetted Pixi render submission, never a GPU-composited frame.
struct PlayerCurrentHostMilestone: Equatable {
    enum Stage: Equatable {
        case navigating
        case documentLoaded
        case rendererSubmitted
        case firstInputAdmitted
        case failed
        case stopped
    }

    let stage: Stage
    let gameID: String
    let attachmentLease: UInt64
    let nativeDocumentNonce: String?
    let validatedRuntimeSessionID: String?
}

enum PlayerCurrentHostMilestoneProjection {
    // Aligned to the Go GamePackage envelope's installed major format.
    // This is a static native compatibility assertion, not a request to fetch
    // or interpret new code, nor a JS-supplied capability negotiation.
    static let gamePackageFormatVersion = "2.0"

    /// Admit a current metric before it mutates either the sequence gate
    /// or the launch reducer. Failed/stopped owners and a missing native
    /// document nonce must not consume the next valid event slot.
    static func permitsMetricAdmission(
        _ milestone: PlayerCurrentHostMilestone?, forSession sessionID: String
    ) -> Bool {
        guard let milestone,
              milestone.nativeDocumentNonce != nil,
              milestone.validatedRuntimeSessionID == sessionID else { return false }
        switch milestone.stage {
        case .failed, .stopped: return false
        case .navigating, .documentLoaded, .rendererSubmitted,
             .firstInputAdmitted: return true
        }
    }

    static func project(
        phase: PlayerHostLaunchReducer.Phase,
        gameID: String,
        playerURL: URL,
        attachmentLease: UInt64,
        nativeDocumentNonce: String?,
        validatedRuntimeSessionID: String?,
        ownsCurrentAttachment: Bool
    ) -> PlayerCurrentHostMilestone? {
        guard ownsCurrentAttachment, attachmentLease > 0,
              PlayerPublishedGameIDPolicy.valid(gameID),
              let parts = URLComponents(url: playerURL, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              parts.host != nil, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.path == "/player",
              parts.queryItems?.filter({ $0.name == "game" }).map(\.value) == [gameID]
        else { return nil }
        // The nonce is generated by the native pool, never read from the
        // page. No raw WebKit callback is admitted into this projector.
        if let nonce = nativeDocumentNonce {
            guard nonce.utf8.count == 32,
                  nonce.utf8.allSatisfy({
                      (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
                  }) else { return nil }
        }
        if let sessionID = validatedRuntimeSessionID {
            guard PlayerNativeRuntimeIdentifierPolicy.validSessionID(sessionID) else { return nil }
        }
        let stage: PlayerCurrentHostMilestone.Stage
        switch phase {
        case .navigating: stage = .navigating
        case .documentLoaded: stage = .documentLoaded
        case .sceneSubmitted:
            guard nativeDocumentNonce != nil, validatedRuntimeSessionID != nil else { return nil }
            stage = .rendererSubmitted
        case .interactive:
            guard nativeDocumentNonce != nil, validatedRuntimeSessionID != nil else { return nil }
            stage = .firstInputAdmitted
        case .navigationFailed, .webProcessTerminated: stage = .failed
        case .detached: stage = .stopped
        }
        return PlayerCurrentHostMilestone(
            stage: stage, gameID: gameID, attachmentLease: attachmentLease,
            nativeDocumentNonce: nativeDocumentNonce,
            validatedRuntimeSessionID: validatedRuntimeSessionID
        )
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
///   - diagnostics must also be allowlisted before DevLog/telemetry:
///     NSError descriptions and userInfo may contain credentials or URLs.
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

/// Private game identity does not belong in free-form lifecycle DevLog text.
/// Typed PlayerTelemetry retains separately governed identity and is not
/// modified by this local diagnostic policy.
enum PlayerLocalLifecycleLog {
    static let prewarm = "prewarming player page"
    static let terminatedRepeatedly = "web content process terminated repeatedly"
    static let backgrounded = "app backgrounded while player sheet is open"
    static let foregrounded = "app foregrounded with player sheet open"
    static let memoryWarning = "memory warning while player open"
    static let opened = "player opened; loading /player in WebView"

    static func navigationFinished(milliseconds: Int) -> String {
        "player navigation finished in \(min(3_600_000, max(0, milliseconds)))ms"
    }

    static func autoReload(completedReloads: Int) -> String {
        "web content process terminated; auto-reload \(min(2, max(0, completedReloads)))/2"
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .serious: return "thermal state serious while player open"
        case .critical: return "thermal state critical while player open"
        default: return "thermal state changed while player open"
        }
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

/// One production status gate for BOTH prewarmed and attached main-frame
/// documents. A URL-matched 302 login, 1xx or nonfinal 3xx is never a game.
/// 304 remains a *legacy cache-compatibility exception*, not independently
/// authenticated cached bytes, scene readiness, or a compositor present.
enum PlayerMainDocumentHTTPPolicy {
    static func permitsMainDocument(statusCode: Int) -> Bool {
        (200...299).contains(statusCode) || statusCode == 304
    }
}

/// Fixed diagnostic categories only. At most four observations per native
/// prepared navigation, shared across speculative and attached owners.
/// A WKNavigationResponse has no nonce receipt; this is NOT authorization.
struct PlayerMainDocumentResponseObservations {
    private enum Kind: Hashable {
        case prewarm200, prewarm304, attached200, attached304
    }
    private var observed: Set<Kind> = []

    mutating func record(statusCode: Int, isAttached: Bool) -> String? {
        let kind: Kind
        switch (isAttached, statusCode) {
        case (false, 200): kind = .prewarm200
        case (false, 304): kind = .prewarm304
        case (true, 200): kind = .attached200
        case (true, 304): kind = .attached304
        default: return nil
        }
        guard observed.insert(kind).inserted else { return nil }
        switch kind {
        case .prewarm200: return "player HTTP observation: prewarm 200"
        case .prewarm304: return "player HTTP observation: prewarm 304"
        case .attached200: return "player HTTP observation: attached 200"
        case .attached304: return "player HTTP observation: attached 304"
        }
    }

    mutating func reset() {
        observed.removeAll(keepingCapacity: true)
    }
}

/// Compatibility façade for existing prewarm policy callers and tests.
enum PlayerPrewarmResponsePolicy {
    static func shouldCacheResponse(statusCode: Int) -> Bool {
        PlayerMainDocumentHTTPPolicy.permitsMainDocument(statusCode: statusCode)
    }
}

/// Pure, native-owned cache provenance contract staged for #726.
/// This helper does not alter the still-shipping WKNavigationResponse policies.
/// WebKit must prove the real cached representation and current native owner
/// before those delegates may consume any receipt or admit a HTTP 304.
enum PlayerAuthorizedDocumentRevalidationPolicy {
    struct Authorized200Receipt: Equatable {
        let gameID: String
        let immutablePlayerURL: URL
        let credentialEpoch: UInt64
        let attachmentLease: UInt64
        let nativeDocumentNonce: String
        let etag: String?
    }

    private static func validNonce(_ value: String?) -> Bool {
        guard let value else { return false }
        var count = 0
        for byte in value.utf8 {
            count += 1
            guard count <= 32,
                  (0x30...0x39).contains(byte) ||
                  (0x61...0x66).contains(byte) else { return false }
        }
        return count == 32
    }

    private static func validETag(_ value: String?) -> Bool {
        guard let value else { return true }
        var count = 0
        for byte in value.utf8 {
            count += 1
            // Opaque HTTP entity-tag; never log or interpolate caller text.
            guard count <= 128, (0x20...0x7e).contains(byte) else { return false }
        }
        return count > 0
    }

    private static func validPlayerURL(
        _ url: URL, gameID: String, backendOrigin: URL
    ) -> Bool {
        guard let p = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let origin = URLComponents(url: backendOrigin, resolvingAgainstBaseURL: false),
              let scheme = p.scheme?.lowercased(), let host = p.host?.lowercased(),
              let originScheme = origin.scheme?.lowercased(),
              let originHost = origin.host?.lowercased(),
              scheme == originScheme, host == originHost,
              (p.port ?? (scheme == "https" ? 443 : 80)) ==
                (origin.port ?? (originScheme == "https" ? 443 : 80)),
              (scheme == "https" || scheme == "http"),
              p.user == nil, p.password == nil, p.fragment == nil,
              p.path == "/player",
              p.queryItems?.filter({ $0.name == "game" }).map(\.value) == [gameID]
        else { return false }
        return true
    }

    /// Receipt construction is only permitted for a genuinely native-verified
    /// current-owner main-frame 200, *not* a page-supplied JavaScript claim.
    static func authorized200(
        gameID: String, expectedPlayerURL: URL, responseURL: URL?,
        backendOrigin: URL, statusCode: Int,
        credentialEpoch: UInt64, attachmentLease: UInt64,
        nativeDocumentNonce: String?, etag: String?,
        ownsCurrentAttachment: Bool, isTrustedMainFrame: Bool,
        hasAuthorizedCachedRepresentation: Bool
    ) -> Authorized200Receipt? {
        guard statusCode == 200, ownsCurrentAttachment, isTrustedMainFrame,
              hasAuthorizedCachedRepresentation,
              credentialEpoch > 0, attachmentLease > 0,
              PlayerPublishedGameIDPolicy.valid(gameID),
              validPlayerURL(expectedPlayerURL, gameID: gameID, backendOrigin: backendOrigin),
              responseURL == expectedPlayerURL,
              validNonce(nativeDocumentNonce), validETag(etag),
              let nativeDocumentNonce else { return nil }
        return Authorized200Receipt(
            gameID: gameID, immutablePlayerURL: expectedPlayerURL,
            credentialEpoch: credentialEpoch, attachmentLease: attachmentLease,
            nativeDocumentNonce: nativeDocumentNonce, etag: etag
        )
    }

    /// Status-only 304 can NEVER establish a document or render milestone.
    /// Caller must independently prove WebKit's current cached representation
    /// and native lease/credential/document provenance at the exact decision.
    static func admits304(
        receipt: Authorized200Receipt?,
        gameID: String, expectedPlayerURL: URL, responseURL: URL?,
        backendOrigin: URL, statusCode: Int,
        credentialEpoch: UInt64, attachmentLease: UInt64,
        nativeDocumentNonce: String?, responseETag: String?,
        ownsCurrentAttachment: Bool, isTrustedMainFrame: Bool,
        hasAuthorizedCachedRepresentation: Bool
    ) -> Bool {
        guard statusCode == 304, let receipt,
              ownsCurrentAttachment, isTrustedMainFrame,
              hasAuthorizedCachedRepresentation,
              credentialEpoch > 0, attachmentLease > 0,
              PlayerPublishedGameIDPolicy.valid(gameID),
              validPlayerURL(expectedPlayerURL, gameID: gameID, backendOrigin: backendOrigin),
              responseURL == expectedPlayerURL,
              validNonce(nativeDocumentNonce), validETag(responseETag),
              receipt.gameID == gameID,
              receipt.immutablePlayerURL == expectedPlayerURL,
              receipt.credentialEpoch == credentialEpoch,
              receipt.attachmentLease == attachmentLease,
              receipt.nativeDocumentNonce == nativeDocumentNonce
        else { return false }
        // A 304 may omit ETag. If present it must match the validated prior
        // 200 representation; a new/different tag never authorizes cache use.
        if let responseETag { return receipt.etag == responseETag }
        return true
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

    /// Privacy-safe transport diagnostics. Never serialize NSError.userInfo,
    /// localizedDescription, custom domains, URLs or response bodies into
    /// persisted telemetry or developer logs. Numeric codes keep operational
    /// grouping useful without leaking request/creator identity.
    static func safeDiagnostic(for error: Error) -> String {
        let ns = error as NSError
        let reason: String
        if ns.domain == httpErrorDomain && (100...599).contains(ns.code) {
            reason = "http_status=\(ns.code)"
        } else if ns.domain == NSURLErrorDomain && (-9999...9999).contains(ns.code) {
            reason = "url_error_code=\(ns.code)"
        } else {
            reason = "other_error"
        }
        return "\(reason) category=\(category(for: error))"
    }

    /// Only a bounded, allowlisted error category may enter local free-form logs.
    /// Never pass the game ID, URL, NSError metadata, or arbitrary strings.
    /// Typed telemetry game identity is governed by a separate privacy policy.
    static func safeLocalLogMessage(for error: Error) -> String {
        "player load failed: \(safeDiagnostic(for: error))"
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

    /// Reconnect must not turn an actionable permanent Game Package or
    /// entitlement failure into another navigation. A nil/unknown category
    /// is deliberately not sufficient authorization for an automatic retry.
    static func shouldRetryOnConnectivityRestored(
        wasOffline: Bool,
        isOffline: Bool,
        category: PlayerLoadFailure.Category?,
        hasError: Bool,
        sessionRevoked: Bool
    ) -> Bool {
        wasOffline && !isOffline && hasError && !sessionRevoked &&
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

    /// Do not allocate a replacement WebView while backgrounded or offline.
    /// This decision never consumes the bounded crash budget itself.
    static func shouldAutoRestartNow(
        completedReloads: Int,
        isActiveAndForeground: Bool,
        isOffline: Bool
    ) -> Bool {
        shouldAutomaticallyReload(completedReloads: completedReloads) &&
            isActiveAndForeground && !isOffline
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
/// are real failure signals and aggregate like web errors.
/// Upload only explicitly structured event fields, never arbitrary on-device
/// DevLog text. Other caller-supplied event messages require separate audit.
enum PlayerTelemetryLogUploadPolicy {
    /// Reject arbitrary log text; generic regex scrubbing cannot prove safety.
    static func remoteTail(from localEntries: [String]) -> [String] {
        []
    }
}

enum PlayerTelemetry {
    static func report(gameID: String?, kind: String, name: String, message: String) {
        // The DevLog remains on-device for authorized diagnosis. Report
        // only the typed event fields, never historical free-form log lines.
        let tail = PlayerTelemetryLogUploadPolicy.remoteTail(from: [])
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
    private static let metricAttachment = PlayerNativeMetricAttachmentRevocation()
    private static weak var attachedMessageReceiver: (any WKScriptMessageHandler)?
    private static var documentEpochGate = PlayerNativeDocumentEpochGate()
    private static var mainDocumentResponseObservations = PlayerMainDocumentResponseObservations()
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
    private static var sceneMilestoneLedger = PlayerPrewarmSceneMilestoneLedger()

    static func playerURL(gameID: String, quality: String? = nil) -> URL? {
        // Do not construct a player URL for an empty identifier, and never
        // forward arbitrary quality values into the runtime query contract.
        guard PlayerPublishedGameIDPolicy.valid(gameID) else { return nil }

        var components = URLComponents(url: BackendConfig.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/player"
        let preference = PlayerQuality(rawValue:
            UserDefaults.standard.string(forKey: PlayerQuality.defaultsKey) ?? PlayerQuality.auto.rawValue
        ) ?? .auto
        let requestedQuality = quality.flatMap { value in
            ["low", "high"].contains(value) ? value : nil
        }
        components?.queryItems = [
            URLQueryItem(name: "game", value: gameID),
            URLQueryItem(name: "quality", value: requestedQuality ?? PlayerQuality.effective(preference: preference)),
            URLQueryItem(name: "presentation", value: "play")
        ]
        return components?.url
    }

    static func prepareDocumentNavigation(_ webView: WKWebView) {
        guard pooledView === webView else { return }
        prewarmSceneGate.reset()
        sceneMilestoneLedger.invalidate()
        transferringLease = nil
        let nonce = documentEpochGate.prepareNavigation()
        mainDocumentResponseObservations.reset()
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
        sceneMilestoneLedger.invalidate()
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

    /// A current native epoch can be exposed to the attached Coordinator
    /// without trusting a JS echo of the nonce or accepting a retired lease.
    static func currentNativeDocumentNonce(_ webView: WKWebView, lease: UInt64) -> String? {
        guard ownsActiveAttachment(webView, lease: lease),
              documentEpochGate.navigationStarted else { return nil }
        return documentEpochGate.currentNonce
    }

    /// Diagnostic only: the current native navigation context is not a
    /// cryptographic association of the response with its cached body.
    static func observeMainDocumentResponse(
        _ webView: WKWebView, response: HTTPURLResponse, lease: UInt64?
    ) {
        guard pooledView === webView, let currentURL,
              response.url == currentURL, documentEpochGate.navigationStarted,
              documentEpochGate.currentNonce != nil else { return }
        if let lease {
            guard ownsActiveAttachment(webView, lease: lease) else { return }
        } else {
            guard !isAttached else { return }
        }
        if let message = mainDocumentResponseObservations.record(
            statusCode: response.statusCode, isAttached: lease != nil
        ) {
            DevLog.info(.player, message)
        }
    }

    static func revokeDocumentNonce(_ webView: WKWebView) {
        guard pooledView === webView else { return }
        documentEpochGate.invalidate()
        prewarmSceneGate.reset()
        sceneMilestoneLedger.invalidate()
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
        DevLog.info(.player, PlayerLocalLifecycleLog.prewarm)
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
        metricAttachment.retire()
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
        sceneMilestoneLedger.invalidate()
    }

    static func ownsActiveAttachment(_ webView: WKWebView, lease: UInt64) -> Bool {
        PlayerAttachmentLeasePolicy.mayRecycle(
            isCurrentPooledView: pooledView === webView,
            isAttached: isAttached,
            expectedLease: lease,
            currentLease: attachmentLease
        )
    }

    /// Native metric admission must also close the Keychain-notification gap.
    /// Rechecking can retire the current registry, including the calling task.
    static func ownsCurrentMetricAttachment(_ webView: WKWebView, lease: UInt64) -> Bool {
        ensureCurrentCredentialScope()
        return ownsActiveAttachment(webView, lease: lease)
    }

    static func recycle(_ webView: WKWebView, lease: UInt64) {
        guard ownsActiveAttachment(webView, lease: lease) else { return }
        metricAttachment.retire()
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
        sceneMilestoneLedger.invalidate()
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
        metricAttachment.retire()
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
        sceneMilestoneLedger.invalidate()
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
        sceneMilestoneLedger.invalidate()
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
        url: URL, lease: UInt64, metricRegistry: PlayerNativeMetricTaskRegistry
    ) -> Bool {
        ensureCurrentCredentialScope()
        guard lease != 0,
              ownsAttachedNavigation(webView, url: url, lease: lease)
        else { return false }
        metricAttachment.bind(metricRegistry)
        attachedMessageReceiver = receiver
        attachedReceiverLease = lease
        transferringLease = nil
        return true
    }

    /// First OFFER the native-authenticated candidate without burning it.
    /// The Coordinator must accept its strict local reducer gates before it
    /// requests one committed transfer under the very same current lease.
    /// Missing/stale candidates never synthesize a first frame.
    static func offerAttachedPrewarmScene(
        webView: WKWebView, url: URL, gameID: String, lease: UInt64
    ) -> PlayerPrewarmSceneMilestoneLedger.Submission? {
        ensureCurrentCredentialScope()
        guard attachedReceiverLease == lease,
              ownsAttachedNavigation(webView, url: url, lease: lease),
              let candidate = sceneMilestoneLedger.candidate,
              PlayerPrewarmAttachedSceneIdentityPolicy.matches(
                  candidate, currentURL: currentURL,
                  currentDocumentNonce: documentEpochGate.currentNonce,
                  currentCredentialFingerprint: sessionFingerprint,
                  expectedGameID: gameID, offeredLease: lease,
                  currentLease: attachmentLease,
                  isCurrentPooledView: pooledView === webView,
                  isAttached: isAttached
              ) else { return nil }
        return candidate
    }

    /// Called synchronously after the Coordinator has staged all reducer
    /// checks. Revalidate the live pool and exact offered candidate before
    /// burning the one-slot ledger; never consume a newer document's scene.
    static func commitAttachedPrewarmScene(
        _ offered: PlayerPrewarmSceneMilestoneLedger.Submission,
        webView: WKWebView, url: URL, gameID: String, lease: UInt64
    ) -> Bool {
        guard let current = offerAttachedPrewarmScene(
            webView: webView, url: url, gameID: gameID, lease: lease
        ), current == offered else { return false }
        return sceneMilestoneLedger.consume(
            expected: offered.identity,
            offeredLease: lease, currentLease: attachmentLease,
            isCurrentPooledView: pooledView === webView, isAttached: isAttached
        ) == offered
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
        guard trustedProvenance,
              let nonce = documentEpochGate.currentNonce,
              let fingerprint = sessionFingerprint,
              let runtimeSessionID = body["sessionId"] as? String else { return }
        let identity = PlayerPrewarmSceneMilestoneLedger.Identity(
            gameID: expectedGameID, playerURL: url, documentNonce: nonce,
            credentialFingerprint: fingerprint, runtimeSessionID: runtimeSessionID
        )
        // WebKit frame/origin/URL and native document nonce were checked
        // before staging. Neither a JS run result nor a navigation finish
        // may become a scene milestone. A failed validation commits nothing.
        _ = PlayerPrewarmSceneLedgerCapturePolicy.capture(
            body, identity: identity, currentDocumentNonce: nonce,
            isTrustedMainFrame: message.frameInfo.isMainFrame,
            isSameOrigin: trustedProvenance,
            navigationStarted: documentEpochGate.navigationStarted,
            credentialScopeCurrent: fingerprint == credentialFingerprint(),
            isSpeculative: !isAttached ||
                (transferringLease != nil && transferringLease == attachmentLease),
            gate: &prewarmSceneGate, ledger: &sceneMilestoneLedger
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
            guard navigationResponse.isForMainFrame else {
                // Keep existing subresource policy; only the main document
                // may authorize a successful game page handoff.
                decisionHandler(.allow)
                return
            }
            guard let response = navigationResponse.response as? HTTPURLResponse,
                  PlayerMainDocumentHTTPPolicy.permitsMainDocument(
                    statusCode: response.statusCode
                  ) else {
                // Reject 1xx, nonfinal redirect/login, 4xx/5xx and non-HTTP
                // main documents. Do not cache a stalled/no-body page as warm.
                // This invalidates only the same expected pooled URL.
                PlayerWebViewPool.markFailed(
                    webView, responseURL: navigationResponse.response.url
                )
                decisionHandler(.cancel)
                return
            }
            PlayerWebViewPool.observeMainDocumentResponse(
                webView, response: response, lease: nil
            )
            decisionHandler(.allow)
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
    /// Handoff state (#58/#765): navigation finish never fades the hold.
    /// The admitted current scene submits first; a bounded timeout exposes Retry.
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
    // Current attached runtime's renderer *submission*, not GPU-present.
    // Any retry/sheet epoch revokes the diagnostic immediately.
    @State private var firstSceneSubmittedForAttempt: (epoch: Int, milliseconds: Int)?
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

    // Cancel stale recovery tasks on all terminal/ownership transitions.
    private var noSceneWatchdogIdentity: String {
        "\(attempt):\(isLoading):\(scenePhase):\(firstSceneSubmittedForAttempt?.epoch ?? -1):\(sessionRevoked):\(loadError != nil):\(holdVisible)"
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

    private var admittedHoldPosterURL: URL? {
        PlayerHoldPosterURLPolicy.admittedURL(
            holdPosterURL, backendOrigin: BackendConfig.baseURL
        )
    }

    /// #58 hold backdrop, extracted so the body expression stays
    /// small enough to type-check. A failed poster load falls back
    /// to black, never to a white flash.
    private var holdBackdrop: some View {
        Group {
            if let holdURL = admittedHoldPosterURL {
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
        DevLog.info(.player, PlayerLocalLifecycleLog.navigationFinished(milliseconds: ms))
        PlayerTelemetry.report(gameID: gameID, kind: "perf", name: "PlayerLoad",
                               message: "loaded in \(ms)ms quality=\(effectiveQuality)")
        // Navigation completion is NOT proof that the game has rendered or
        // can accept input. Only the trusted runtime reports player_ready;
        // this native callback records PlayerLoad/TapToNavReady separately.
        // The runtime's first accepted input owns the gameplay-start
        // clock. Navigation finish may still precede the start card or
        // rendering; starting a quick-exit timer here mislabels latency.
        // TapToNavReady still means *only* navigation finish. The hold
        // does not fade until a current admitted renderer scene is submitted.
        // If prewarm reports scene before didFinish, both gates are now ready.
        if !didReportHandoff {
            didReportHandoff = true
            if let tappedAt {
                let ms = max(0, Int(Date().timeIntervalSince(tappedAt) * 1000))
                PlayerTelemetry.report(gameID: gameID, kind: "perf", name: "TapToNavReady",
                                       message: "tap-to-nav-ready in \(ms)ms prewarmHit=\(prewarmHit) quality=\(effectiveQuality)")
            }
        }
        fadeHoldPosterAfterCurrentScene()
    }

    /// Scene submission is a validated current native callback, not an
    /// observation of a GPU-composited pixel or independent score proof.
    private func fadeHoldPosterAfterCurrentScene() {
        guard PlayerScenePosterHandoffPolicy.mayFade(
            expectedAttempt: attempt,
            acceptedSceneAttempt: firstSceneSubmittedForAttempt?.epoch,
            hasHoldPoster: admittedHoldPosterURL != nil,
            holdVisible: holdVisible, holdOpacity: holdOpacity,
            navigationFinished: !isLoading,
            hasLoadError: loadError != nil, sessionRevoked: sessionRevoked
        ) else { return }

        if reduceMotion {
            holdOpacity = 0
            holdVisible = false
        } else {
            withAnimation(.easeOut(duration: 0.25)) { holdOpacity = 0 }
            let fadeEpoch = attempt
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled,
                      firstSceneSubmittedForAttempt?.epoch == fadeEpoch,
                      PlayerTransientPresentationPolicy.mayFinishPosterFade(
                        expectedEpoch: fadeEpoch, currentEpoch: attempt,
                        sessionRevoked: sessionRevoked,
                        isLoading: isLoading, hasLoadError: loadError != nil
                      ) else { return }
                holdVisible = false
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
                            // Keep raw NSError metadata and game identity out
                            // of free-form local logs and the visible player UI.
                            loadFailureCategory = PlayerLoadFailure.category(for: error)
                            loadError = PlayerLoadFailure.userMessage(for: error)
                            let diagnostic = PlayerLoadFailure.safeDiagnostic(for: error)
                            DevLog.error(.player, PlayerLoadFailure.safeLocalLogMessage(for: error))
                            PlayerTelemetry.report(gameID: gameID, kind: "ios-load-failed",
                                                   name: "LoadFailed", message: diagnostic)
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
                            if PlayerWebContentTerminationPolicy.shouldAutoRestartNow(
                                completedReloads: autoReloads,
                                isActiveAndForeground: scenePhase == .active && !wasBackgrounded,
                                isOffline: pathMonitor.isOffline
                            ) {
                                autoReloads += 1
                                DevLog.warn(.player, PlayerLocalLifecycleLog.autoReload(completedReloads: autoReloads))
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
                                let exhausted = !PlayerWebContentTerminationPolicy.shouldAutomaticallyReload(
                                    completedReloads: autoReloads
                                )
                                loadError = exhausted
                                    ? PlayerWebContentTerminationPolicy.repeatedTerminationMessage
                                    : "The player stopped while inactive or offline. Return to the app and tap Retry."
                                // Neither path claims a live scene or spends a reload attempt.
                                DevLog.warn(.player, exhausted
                                    ? PlayerLocalLifecycleLog.terminatedRepeatedly
                                    : "web content terminated; foreground manual recovery required")
                                PlayerTelemetry.report(gameID: gameID, kind: "ios-webview-terminated",
                                                       name: "WebContentProcessTerminated",
                                                       message: exhausted ? "auto-reload budget exhausted" : "deferred: background or offline")
                            }
                        },
                        onPrewarmHit: {
                            guard PlayerLaunchCallbackGate.accepts(expectedEpoch: callbackEpoch,
                                                         currentEpoch: attempt,
                                                         sessionRevoked: sessionRevoked) else { return }
                            prewarmHit = true
                        },
                        onFirstSceneRenderSubmit: { ms in
                            guard PlayerLaunchCallbackGate.accepts(
                                expectedEpoch: callbackEpoch, currentEpoch: attempt,
                                sessionRevoked: sessionRevoked
                            ) else { return }
                            firstSceneSubmittedForAttempt = (
                                epoch: callbackEpoch, milliseconds: ms
                            )
                            fadeHoldPosterAfterCurrentScene()
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
                if admittedHoldPosterURL != nil, holdVisible {
                    holdBackdrop
                }

                if isLoading && loadError == nil, !prewarmHit {
                    if admittedHoldPosterURL != nil, holdVisible {
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
                                .accessibilityIdentifier("player.error.message")
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
                    if PlayerPublishedGameIDPolicy.valid(gameID) {
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
                firstSceneSubmittedForAttempt = nil
                gameplayStartedAt = nil
                didTrackGameplayStart = false
                verifiedResult = nil
            }
            .onChange(of: pathMonitor.isOffline) { wasOffline, offline in
                if PlayerLoadRetryPolicy.shouldRetryOnConnectivityRestored(
                    wasOffline: wasOffline,
                    isOffline: offline,
                    category: loadFailureCategory,
                    hasError: loadError != nil,
                    sessionRevoked: sessionRevoked
                ) {
                    // Only a real offline-to-online transition after a
                    // transient transport error may start one quiet retry.
                    // Permanent/unknown failures remain actionable and intact.
                    loadError = nil
                    loadFailureCategory = nil
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
                    DevLog.info(.player, PlayerLocalLifecycleLog.backgrounded)
                    PlayerTelemetry.report(gameID: gameID, kind: "perf", name: "PlayerBackground",
                                           message: "app entered background; player lifecycle suspended")
                case .active:
                    guard wasBackgrounded else { return }
                    wasBackgrounded = false
                    DevLog.info(.player, PlayerLocalLifecycleLog.foregrounded)
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
                firstSceneSubmittedForAttempt = nil
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
                    DevLog.warn(.player, PlayerLocalLifecycleLog.memoryWarning)
                    PlayerTelemetry.report(gameID: gameID, kind: "ios-memory-warning",
                                           name: "MemoryWarning", message: "UIApplication memory warning during play")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                let state = ProcessInfo.processInfo.thermalState
                if (state == .serious || state == .critical), !reportedThermal {
                    reportedThermal = true
                    DevLog.warn(.player, PlayerLocalLifecycleLog.thermal(state))
                    PlayerTelemetry.report(gameID: gameID, kind: "ios-thermal",
                                           name: "ThermalState", message: "thermal state serious/critical during play")
                }
            }
            .task(id: noSceneWatchdogIdentity) {
                // Navigation-finish is not a scene. This attempt-scoped
                // Task cancels on retry, phase change, scene, revocation,
                // terminal error, poster fade and dismissal.
                let watchdogAttempt = attempt
                guard scenePhase == .active, !isLoading, loadError == nil,
                      admittedHoldPosterURL != nil, holdVisible else { return }
                try? await Task.sleep(for: .milliseconds(
                    PlayerScenePosterHandoffPolicy.noSceneTimeoutMilliseconds
                ))
                guard !Task.isCancelled, watchdogAttempt == attempt,
                      scenePhase == .active,
                      PlayerScenePosterHandoffPolicy.shouldOfferNoSceneRecovery(
                        expectedAttempt: watchdogAttempt,
                        acceptedSceneAttempt: firstSceneSubmittedForAttempt?.epoch,
                        hasHoldPoster: admittedHoldPosterURL != nil,
                        holdVisible: holdVisible,
                        navigationFinished: !isLoading,
                        hasLoadError: loadError != nil,
                        sessionRevoked: sessionRevoked,
                        isForeground: scenePhase == .active
                      ) else { return }
                // No compositor or rendered-scene claims from didFinish.
                // This is a stalled scene, NOT evidence of failed transport.
                // Keep manual Retry and safe exit without auto-retrying on
                // connectivity/foreground changes as though HTTP failed.
                holdOpacity = 0
                holdVisible = false
                loadFailureCategory = .unknown
                loadError = "The game has not drawn its first scene. Tap Retry or return to the feed."
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
                guard PlayerPublishedGameIDPolicy.valid(gameID) else {
                    // Invalid canonical identity never starts a game lease.
                    // Present a terminal, recoverable UI without logging an ID.
                    isLoading = false
                    loadFailureCategory = .invalidPackage
                    loadError = "This game has an invalid identifier. Return to the feed."
                    holdOpacity = 0
                    holdVisible = false
                    return
                }
                DevLog.info(.player, PlayerLocalLifecycleLog.opened)
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
    // The Discover presenter owns asynchronous Next Game dismissal. Keep
    // the original synchronous behavior for any other callers.
    var dismissesOnNextGame = true
    var isAdvancingToNextGame = false
    var nextGameFeedback: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
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
                        if dismissesOnNextGame { dismiss() }
                        onNextGame()
                    } label: {
                        HStack {
                            if isAdvancingToNextGame {
                                ProgressView().accessibilityHidden(true)
                                Text("Finding next game…")
                            } else {
                                Label("Next Game", systemImage: "chevron.up.2")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: HephaestusDesign.minimumActionHeight)
                    .disabled(isAdvancingToNextGame)
                    .accessibilityLabel(isAdvancingToNextGame ? "Finding next game" : "Next Game")

                    if let nextGameFeedback, !isAdvancingToNextGame {
                        Text(nextGameFeedback)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("player.result.nextFeedback")
                    }

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
            .frame(maxWidth: .infinity)
            }
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
    let onFirstSceneRenderSubmit: (Int) -> Void
    let onFirstInput: () -> Void
    let onVerifiedRun: (VerifiedRunResult) -> Void

    // Also used by Coordinator during strict message-name admission;
    // the pool owns handler registration but not the trusted name policy.
    private static let messageName = "hephaestusRunResult"

    func makeCoordinator() -> Coordinator {
        Coordinator(gameID: gameID, expectedURL: url, onProgress: onProgress,
                    onLoadFinish: onLoadFinish, onLoadFail: onLoadFail,
                    onTerminate: onTerminate,
                    onFirstSceneRenderSubmit: onFirstSceneRenderSubmit,
                    onFirstInput: onFirstInput, onVerifiedRun: onVerifiedRun)
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
            url: url, lease: handoff.lease,
            metricRegistry: context.coordinator.metricTelemetryTasks
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
        // Prewarm can submit a genuine v2 scene before SwiftUI attaches.
        // Only this acknowledged current lease may transfer its one slot.
        // Do not use didFinish as a substitute when no candidate exists.
        if let scene = PlayerWebViewPool.offerAttachedPrewarmScene(
            webView: webView, url: url, gameID: gameID, lease: handoff.lease
        ) {
            context.coordinator.acceptTransferredPrewarmScene(scene)
        }
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
        let onFirstSceneRenderSubmit: (Int) -> Void
        let onFirstInput: () -> Void
        let onVerifiedRun: (VerifiedRunResult) -> Void
        private var progressObservation: NSKeyValueObservation?
        private var prewarmLoadingObservation: NSKeyValueObservation?
        private var prewarmRecoveryArmed = false
        private var verifiedRunGate = PlayerVerifiedRunNotificationGate()
        // At most two concurrent result lookups; deferred work stays latest-only.
        private var verifiedRunFetchTasks: [String: Task<Void, Never>] = [:]
        // Bounded, cancellable first-input/perf telemetry owned by this
        // Coordinator. Detached/replaced document POSTs are never left queued.
        fileprivate let metricTelemetryTasks = PlayerNativeMetricTaskRegistry()
        private var ownsCurrentMetricAttachment: Bool {
            guard let view = attachedWebView else { return false }
            return PlayerWebViewPool.ownsCurrentMetricAttachment(view, lease: attachmentLease)
        }
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
        /// The single source of host progress is this Coordinator's reducer
        /// plus the pool-owned current lease and nonce. No GamePlayerCore
        /// transport actor is started in the shipping application.
        private var currentHostMilestone: PlayerCurrentHostMilestone? {
            guard let webView = attachedWebView else { return nil }
            return PlayerCurrentHostMilestoneProjection.project(
                phase: launchLifecycle.phase,
                gameID: expectedGameID, playerURL: expectedURL,
                attachmentLease: attachmentLease,
                nativeDocumentNonce: PlayerWebViewPool.currentNativeDocumentNonce(
                    webView, lease: attachmentLease
                ),
                validatedRuntimeSessionID: runtimeSessionID,
                ownsCurrentAttachment: ownsLiveAttachment
            )
        }

        private var isActive: Bool { launchLifecycle.isAttached }
        private var hasObservedTerminalNavigation: Bool { launchLifecycle.observedTerminalNavigation }
        lazy var messageProxy = WeakScriptMessageHandler(delegate: self)

        init(gameID: String, expectedURL: URL,
             onProgress: @escaping (Double) -> Void,
             onLoadFinish: @escaping () -> Void,
             onLoadFail: @escaping (Error) -> Void,
             onTerminate: @escaping () -> Void,
             onFirstSceneRenderSubmit: @escaping (Int) -> Void,
             onFirstInput: @escaping () -> Void,
             onVerifiedRun: @escaping (VerifiedRunResult) -> Void) {
            self.expectedGameID = gameID
            self.expectedURL = expectedURL
            self.onProgress = onProgress
            self.onLoadFinish = onLoadFinish
            self.onLoadFail = onLoadFail
            self.onTerminate = onTerminate
            self.onFirstSceneRenderSubmit = onFirstSceneRenderSubmit
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

        /// This is not a JS callback. The pooled native listener already
        /// verified the original WebKit frame, current nonce/schema, URL
        /// and credential epoch, but has NOT consumed its one-slot record.
        /// Recheck Coordinator ownership and stage ALL reducers first; only
        /// then commit the exact offered candidate under its current lease.
        func acceptTransferredPrewarmScene(
            _ scene: PlayerPrewarmSceneMilestoneLedger.Submission
        ) {
            let identity = scene.identity
            guard acceptsCurrentHostCallbacks,
                  identity.gameID == expectedGameID,
                  identity.playerURL == expectedURL,
                  let view = attachedWebView,
                  PlayerWebViewPool.acceptsCurrentDocumentNonce(
                      view, nonce: identity.documentNonce
                  ),
                  nativeBridgeVersionGate.allows(2),
                  PlayerNativeRuntimeIdentifierPolicy.validSessionID(
                      identity.runtimeSessionID
                  ) else { return }

            var nextMetric = metricSequenceGate
            var nextScene = firstSceneRenderSubmissionGate
            var nextLaunch = launchLifecycle
            var nextSession = runtimeSessionGate
            guard nextMetric.accept(
                    metric: "first_scene_render_submit", sequence: scene.sequence
                  ),
                  nextScene.accept(milliseconds: scene.milliseconds),
                  nextLaunch.sceneSubmitted(),
                  nextSession.bind(identity.runtimeSessionID),
                  // An old Coordinator or altered native session cannot burn
                  // the valid one-slot scene belonging to a newer owner.
                  PlayerWebViewPool.commitAttachedPrewarmScene(
                      scene, webView: view, url: expectedURL,
                      gameID: expectedGameID, lease: attachmentLease
                  )
            else { return }
            metricSequenceGate = nextMetric
            firstSceneRenderSubmissionGate = nextScene
            launchLifecycle = nextLaunch
            runtimeSessionGate = nextSession
            nativeBridgeVersionGate.didAccept(2)
            reportAcceptedFirstSceneSubmission(
                milliseconds: scene.milliseconds,
                runtimeSessionID: identity.runtimeSessionID
            )
        }

        private func reportAcceptedFirstSceneSubmission(
            milliseconds: Int, runtimeSessionID: String
        ) {
            // Before any host-visible milestone, prove the current native
            // lease/nonce/session projection. A scene may arrive after the
            // first input; never regress an already interactive host.
            guard let milestone = currentHostMilestone,
                  milestone.validatedRuntimeSessionID == runtimeSessionID,
                  milestone.stage == .rendererSubmitted ||
                      milestone.stage == .firstInputAdmitted else { return }
            PlayerTelemetry.report(
                gameID: expectedGameID, kind: "perf",
                name: "FirstSceneRenderSubmitted",
                message: "renderer-submitted-ms=\(milliseconds); not display-presented or interactive"
            )
            Task { @MainActor [weak self] in
                guard let self, self.acceptsCurrentHostCallbacks,
                      self.runtimeSessionID == runtimeSessionID else { return }
                self.onFirstSceneRenderSubmit(milliseconds)
            }
        }

        private func handleMetric(_ body: [String: Any], runtimeSessionID: String) {
            // Never consume a per-kind sequence or a first-scene/input reducer
            // if the current attachment lacks a native nonce/session proof.
            guard PlayerCurrentHostMilestoneProjection.permitsMetricAdmission(
                currentHostMilestone, forSession: runtimeSessionID
            ) else { return }
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
                // Both attached and prewarm-transfer paths report the same
                // bounded renderer-submission milestone, never GPU-present.
                reportAcceptedFirstSceneSubmission(
                    milliseconds: ms, runtimeSessionID: runtimeSessionID
                )
            case .firstInput(let ms):
                guard launchLifecycle.firstInput(milliseconds: ms),
                      currentHostMilestone?.stage == .firstInputAdmitted else { return }
                Task { @MainActor [weak self] in
                    // After a retry, session equality alone cannot authorize
                    // the retired Coordinator to update the old player sheet.
                    guard let self, self.acceptsCurrentHostCallbacks,
                          self.runtimeSessionID == runtimeSessionID else { return }
                    self.onFirstInput()
                }
                let registry = metricTelemetryTasks
                registry.submit { [weak self, weak registry] taskID, epoch in
                    Task { @MainActor [weak self, weak registry] in
                        defer { registry?.complete(taskID: taskID, epoch: epoch) }
                        // Snapshot only a native-vetted, currently attached ID.
                        // Never retain the old Coordinator over URLSession await.
                        let validGameID: String? = {
                            guard let self, PlayerRuntimeMetricDispatchPolicy.mayStart(
                                ownsCurrentAttachment: self.ownsCurrentMetricAttachment,
                                permitsRuntimeEvents: self.launchLifecycle.permitsRuntimeEvents,
                                taskCancelled: Task<Never, Never>.isCancelled,
                                expectedSessionID: runtimeSessionID,
                                currentSessionID: self.runtimeSessionID
                            ) else { return nil }
                            return self.expectedGameID
                        }()
                        guard let validGameID, !Task<Never, Never>.isCancelled else { return }
                        await BackendAPI.shared.trackSocialEvent(
                            gameID: validGameID, kind: "player_first_input",
                            timeToFirstInputMS: ms, eventID: "ios-metric:\(metricID)"
                        )
                    }
                }
            case .perfWindow(let p95, let avg, let count):
                let registry = metricTelemetryTasks
                registry.submit { [weak self, weak registry] taskID, epoch in
                    Task { @MainActor [weak self, weak registry] in
                        defer { registry?.complete(taskID: taskID, epoch: epoch) }
                        let validGameID: String? = {
                            guard let self, PlayerRuntimeMetricDispatchPolicy.mayStart(
                                ownsCurrentAttachment: self.ownsCurrentMetricAttachment,
                                permitsRuntimeEvents: self.launchLifecycle.permitsRuntimeEvents,
                                taskCancelled: Task<Never, Never>.isCancelled,
                                expectedSessionID: runtimeSessionID,
                                currentSessionID: self.runtimeSessionID
                            ) else { return nil }
                            return self.expectedGameID
                        }()
                        guard let validGameID, !Task<Never, Never>.isCancelled else { return }
                        await BackendAPI.shared.trackSocialEvent(
                            gameID: validGameID, kind: "player_perf_window",
                            frameTimeP95MS: p95, frameTimeAvgMS: avg,
                            frameCount: count, eventID: "ios-metric:\(metricID)"
                        )
                    }
                }
            }
        }

        private func sameOrigin(_ origin: WKSecurityOrigin) -> Bool {
            PlayerWebKitOriginPolicy.matches(
                backendURL: BackendConfig.baseURL,
                originScheme: origin.protocol, originHost: origin.host,
                originPort: origin.port
            )
        }

        func observeProgress(of webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                guard let self, self.acceptsCurrentHostCallbacks else { return }
                self.onProgress(view.estimatedProgress)
            }
        }

        func stopObserving() {
            metricTelemetryTasks.revoke()
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
            metricTelemetryTasks.revoke()
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
            metricTelemetryTasks.revoke()
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
            guard navigationResponse.isForMainFrame else {
                decisionHandler(.allow)
                return
            }
            guard let response = navigationResponse.response as? HTTPURLResponse else {
                // Non-HTTP main-document response is not a usable player.
                // Reuse a bounded generic category, never log raw Location.
                reportNavigationFailure(PlayerLoadFailure.httpError(statusCode: 0))
                decisionHandler(.cancel)
                return
            }
            guard PlayerMainDocumentHTTPPolicy.permitsMainDocument(
                statusCode: response.statusCode
            ) else {
                // Navigation-finished cannot make a 302 login game-ready.
                reportNavigationFailure(PlayerLoadFailure.httpError(statusCode: response.statusCode))
                decisionHandler(.cancel)
                return
            }
            PlayerWebViewPool.observeMainDocumentResponse(
                webView, response: response, lease: attachmentLease
            )
            decisionHandler(.allow)
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
            metricTelemetryTasks.revoke()
            disarmPrewarmRecovery()
            PlayerWebViewPool.revokeDocumentNonce(webView)
            onTerminate()
        }
    }
}
