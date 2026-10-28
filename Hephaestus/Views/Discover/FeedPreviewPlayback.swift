import AVFoundation
import Combine
import Foundation
import Network
import SwiftUI

// MARK: - Shared pieces

/// Semantic SwiftUI tokens shared by discovery, profiles, saved games, and player entry points.
enum HephaestusDesign {
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevatedBackground = Color(uiColor: .tertiarySystemGroupedBackground)
    static let cardRadius: CGFloat = 22
    static let compactCardRadius: CGFloat = 14
    static let sectionRadius: CGFloat = 20
    static let horizontalInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let minimumActionHeight: CGFloat = 44
    static let cardPadding: CGFloat = 24
    static let stateCardMaxWidth: CGFloat = 360
    static let stateIconSize: CGFloat = 40
    static let subtleBorder = Color(uiColor: .separator).opacity(0.18)
}

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
    static func shouldAutoplay(hasClip: Bool, reduceMotion: Bool, lowPowerMode: Bool, constrainedNetwork: Bool) -> Bool {
        hasClip && !reduceMotion && !lowPowerMode && !constrainedNetwork
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
    private var pendingTask: Task<Void, Never>?
    private var pendingGameID: String?
    private var clipStartedAt: Date?
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "hephaestus.feed-preview.network")
    private(set) var isConstrained = false

    private init() {
        player.isMuted = true
        player.actionAtItemEnd = .none
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConstrained = path.isConstrained
                if path.isConstrained { self?.stop() }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    deinit {
        networkMonitor.cancel()
        pendingTask?.cancel()
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
                constrainedNetwork: isConstrained
              ) else {
            stop()
            return
        }
        // SwiftUI may call schedule repeatedly as a card re-renders. Keep
        // the active preview stable and avoid resetting its 700ms delay.
        if activeGameID == gameID || (pendingGameID == gameID && pendingTask != nil) {
            return
        }
        // Switching cards must stop the previous item and cancel its delay
        // before installing the new request.
        stop()
        pendingGameID = gameID
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
        clipStartedAt = Date()
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.play()
        pendingTask = nil
        pendingGameID = nil
    }

    func stop(gameID: String? = nil) {
        if let gameID {
            if pendingGameID == gameID {
                pendingTask?.cancel()
                pendingTask = nil
                pendingGameID = nil
            }
            guard activeGameID == gameID else { return }
        } else {
            pendingTask?.cancel()
            pendingTask = nil
            pendingGameID = nil
        }
        let stoppedGameID = activeGameID
        let startedAt = clipStartedAt
        player.pause()
        player.removeAllItems()
        looper = nil
        activeGameID = nil
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

