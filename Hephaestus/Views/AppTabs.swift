import AuthenticationServices
import AVFoundation
import Combine
import Network
import PhotosUI
import SwiftUI
import UIKit



// MARK: - Library

/// Recently played games.
struct LibraryView: View {
    @State private var recent: [RecentGame] = []
    @State private var saved: [FeedGame] = []
    @State private var errorMessage: String?
    @State private var playerRequest: PixiPlayerRequest?
    @State private var showClearRecentConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if saved.isEmpty {
                        ContentUnavailableView(
                            "No saved games yet",
                            systemImage: "bookmark",
                            description: Text("Save a game from Discover and it will be ready to play here.")
                        )
                    }
                    ForEach(saved) { game in
                        Button {
                            playerRequest = PixiPlayerRequest(gameID: game.id, title: game.title)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(
                                        LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(game.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    if let caption = game.caption, !caption.isEmpty {
                                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the game player")
                        .contextMenu {
                            Button("Remove from saved", systemImage: "bookmark.slash", role: .destructive) {
                                Task { await removeSaved(game) }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Saved games")
                        Spacer()
                        Text("\(saved.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }

                Section {
                    if recent.isEmpty {
                        ContentUnavailableView(
                            "No recent games",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Games you play will appear here so you can jump back in.")
                        )
                    }
                    ForEach(recent) { game in
                        Button {
                            playerRequest = PixiPlayerRequest(gameID: game.gameID, title: game.title)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(
                                        LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(game.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    Text("Recently played").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the game player")
                        .contextMenu {
                            Button("Remove from recent", systemImage: "clock.badge.xmark", role: .destructive) {
                                RecentGames.remove(gameID: game.gameID)
                                recent.removeAll { $0.gameID == game.gameID }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recently played")
                        Spacer()
                        Text("\(recent.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear recent", systemImage: "trash") {
                        showClearRecentConfirmation = true
                    }
                    .disabled(recent.isEmpty)
                    .accessibilityHint("Removes recent games from this device")
                }
            }
            .confirmationDialog("Clear recently played games?", isPresented: $showClearRecentConfirmation, titleVisibility: .visible) {
                Button("Clear Recent Games", role: .destructive) {
                    RecentGames.clear()
                    recent.removeAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only clears your local recent-games list. Saved games are not affected.")
            }
            .refreshable { await load() }
            .task { await load() }
            .fullScreenCover(item: $playerRequest) { request in
                PixiPlayerSheet(gameID: request.gameID, title: request.title)
            }
        }
    }

    private func load() async {
        recent = RecentGames.load()
        do {
            saved = try await BackendAPI.shared.fetchSavedGames()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load saved games: \(error.localizedDescription)"
        }
    }

    private func removeSaved(_ game: FeedGame) async {
        do {
            try await BackendAPI.shared.setSaved(game.id, saved: false)
            saved.removeAll { $0.id == game.id }
        } catch {
            errorMessage = "Couldn't remove saved game: \(error.localizedDescription)"
        }
    }
}

// Profile and moderation appeal views live in Views/Profile/ProfileView.swift.
