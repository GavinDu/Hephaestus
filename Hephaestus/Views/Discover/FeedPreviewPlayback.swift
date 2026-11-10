import AVFoundation
import Combine
import Foundation
import Network
import SwiftUI

// MARK: - Shared pieces

// Semantic design tokens now live in Views/Design/ArcadePulseTheme.swift.

/// Recently played games, persisted locally.
struct RecentGame: Codable, Identifiable {
    var id: String { gameID }
    var gameID: String
    var title: String
}

enum RecentGames {
    private static let key = "hephaestus.recentGames"

    static func record(gameID: String, title: String) {
        var list = load()
        list.removeAll { $0.gameID == gameID }
        list.insert(RecentGame(gameID: gameID, title: title), at: 0)
        list = Array(list.prefix(20))
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> [RecentGame] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentGame].self, from: data)
        else { return [] }
        return list
    }

    static func remove(gameID: String) {
        persist(load().filter { $0.gameID != gameID })
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func persist(_ games: [RecentGame]) {
        guard let data = try? JSONEncoder().encode(games) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// A single shared queue/player keeps feed scrolling from starting multiple decoders.
enum FeedPreviewPolicy {
    static func shouldAutoplay(hasClip: Bool, reduceMotion: Bool, lowPowerMode: Bool, constrainedNetwork: Bool, isOnline: Bool = true) -> Bool {
        hasClip && isOnline && !reduceMotion && !lowPowerMode && !constrainedNetwork
    }

    /// When a different game becomes the settled page, the previous clip or
    /// delayed autoplay must retire even if the new page has no preview.
    /// A reused card with the same ID must not reset its own playback.
    static func shouldRetirePrevious(activeGameID: String?, pendingGameID: String?, nextGameID: String) -> Bool {
        (activeGameID != nil && activeGameID != nextGameID) ||
            (pendingGameID != nil && pendingGameID != nextGameID)
    }

    /// Reuse a decoder or delayed autoplay only for the exact, still-current
    /// clip. A feed refresh can replace a game's versioned preview URL
    /// without changing the game ID; playing its old clip is misleading.
    static func shouldReusePreview(activeGameID: String?, activeURL: URL?,
                                   pendingGameID: String?, pendingURL: URL?,
                                   nextGameID: String, nextURL: URL) -> Bool {
        (activeGameID == nextGameID && activeURL == nextURL) ||
            (pendingGameID == nextGameID && pendingURL == nextURL)
    }

    static func shouldStopOnFailure(_ status: AVPlayerItem.Status) -> Bool {
        status == .failed
    }
}

/// Measured preview dwell for Hephaestus #61. The previous code reported
/// a fixed 700ms at clip start — the autoplay delay, not a dwell. Dwell
/// is now measured from clip start to clip stop and clamped at zero so
/// a clock jump can never produce a negative duration the backend
/// rejects. Every measured dwell is reported; ranking thresholds belong
/// server-side, not in this helper.
enum FeedPreviewDwell {
    static func dwellMS(from startedAt: Date, to endedAt: Date) -> Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt) * 1000))
    }
}

@MainActor
final class FeedPreviewPlayback: ObservableObject {
    static let shared = FeedPreviewPlayback()

    @Published private(set) var activeGameID: String?
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var itemStatusObservation: NSKeyValueObservation?
    private var pendingTask: Task<Void, Never>?
    private var pendingGameID: String?
    private var pendingClipURL: URL?
    private var activeClipURL: URL?
    private var clipStartedAt: Date?
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "hephaestus.feed-preview.network")
    private(set) var isConstrained = false
    private(set) var isOnline = true

    private init() {
        player.isMuted = true
        player.actionAtItemEnd = .none
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConstrained = path.isConstrained
                self?.isOnline = path.status == .satisfied
                if path.isConstrained || path.status != .satisfied { self?.stop() }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    deinit {
        networkMonitor.cancel()
        pendingTask?.cancel()
    }

    /// Only the settled For You page owns the current preview. Retire a
    /// previous page's active or pending playback BEFORE evaluating the next
    /// clip URL/power policy, otherwise moving to a poster-only page leaves
    /// the previous game's clip running invisibly.
    func scheduleSettled(gameID: String, urlString: String?, reduceMotion: Bool) {
        if FeedPreviewPolicy.shouldRetirePrevious(
            activeGameID: activeGameID, pendingGameID: pendingGameID, nextGameID: gameID
        ) {
            stop()
        }
        schedule(gameID: gameID, urlString: urlString, reduceMotion: reduceMotion)
    }

    func schedule(gameID: String, urlString: String?, reduceMotion: Bool) {
        // A reused feed cell can become ineligible after it scheduled a
        // preview (for example, Reduce Motion or Low Power Mode changes).
        // Always cancel old work when the new request cannot autoplay, or
        // a stale game's clip can start after the user has moved on.
        guard let urlString, let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http",
              FeedPreviewPolicy.shouldAutoplay(
                hasClip: true,
                reduceMotion: reduceMotion,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                constrainedNetwork: isConstrained,
                isOnline: isOnline
              ) else {
            stop(gameID: gameID)
            return
        }
        // SwiftUI may call schedule repeatedly as a card re-renders. Keep
        // the active preview stable and avoid resetting its 700ms delay.
        if FeedPreviewPolicy.shouldReusePreview(
            activeGameID: activeGameID, activeURL: activeClipURL,
            pendingGameID: pendingTask == nil ? nil : pendingGameID,
            pendingURL: pendingTask == nil ? nil : pendingClipURL,
            nextGameID: gameID, nextURL: url
        ) {
            return
        }
        // Switching cards or updating a versioned clip URL must stop the
        // previous item and cancel its delay
        // before installing the new request.
        stop()
        pendingGameID = gameID
        pendingClipURL = url
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard !Task.isCancelled, let self,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled,
                  !self.isConstrained else {
                self?.stop(gameID: gameID)
                return
            }
            self.start(gameID: gameID, url: url)
        }
    }

    private func start(gameID: String, url: URL) {
        player.pause()
        player.removeAllItems()
        looper = nil
        activeGameID = gameID
        activeClipURL = url
        clipStartedAt = Date()
        let item = AVPlayerItem(url: url)
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard FeedPreviewPolicy.shouldStopOnFailure(observedItem.status) else { return }
            Task { @MainActor [weak self] in
                // A failed former version may report asynchronously after the
                // card has refreshed. Never stop the replacement clip merely
                // because it belongs to the same game ID.
                guard let self, self.activeGameID == gameID,
                      self.activeClipURL == url else { return }
                // Keep the poster visible when a clip fails to load or decode.
                self.stop(gameID: gameID)
            }
        }
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.play()
        pendingTask = nil
        pendingGameID = nil
        pendingClipURL = nil
    }

    func stop(gameID: String? = nil) {
        if let gameID {
            if pendingGameID == gameID {
                pendingTask?.cancel()
                pendingTask = nil
                pendingGameID = nil
                pendingClipURL = nil
            }
            guard activeGameID == gameID else { return }
        } else {
            pendingTask?.cancel()
            pendingTask = nil
            pendingGameID = nil
            pendingClipURL = nil
        }
        let stoppedGameID = activeGameID
        let startedAt = clipStartedAt
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player.pause()
        player.removeAllItems()
        looper = nil
        activeGameID = nil
        activeClipURL = nil
        clipStartedAt = nil
        if let stoppedGameID, let startedAt {
            let dwell = FeedPreviewDwell.dwellMS(from: startedAt, to: Date())
            let eventID = "ios-preview-dwell:\(stoppedGameID):\(startedAt.timeIntervalSince1970)"
            Task {
                await BackendAPI.shared.trackSocialEvent(gameID: stoppedGameID, kind: "preview_dwell",
                                                         durationMS: dwell, previewDwellMS: dwell,
                                                         eventID: eventID)
            }
        }
    }
}

