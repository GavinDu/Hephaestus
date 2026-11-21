//
//  HephaestusApp.swift
//  Hephaestus
//

import SwiftUI

@main
struct HephaestusApp: App {
    init() {
        // API traffic (feed, packages metadata, telemetry) rides
        // URLSession, so give its cache real room: repeat opens of the
        // feed and diagnostics shouldn't re-download on a family iPad.
        // (WKWebView keeps its own cache for the player page itself;
        // the player's resource controls live in PixiPlayer.swift.)
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024)
        DevLog.shared.recordLaunch()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            // UI automation can present the real native player sheet with a
            // grammar-invalid public ID. Never enabled in App Store binaries,
            // real devices, or by untrusted feed/server input.
            if ProcessInfo.processInfo.arguments.contains("--ui-test-invalid-player-id") {
                InvalidPlayerIDUITestEntry()
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Isolated negative-state launch entry. The normal feed stays genuine;
/// no fake published game, creator, network reply or run result is injected.
/// The real player owns rejection and its existing Return to feed action.
private struct InvalidPlayerIDUITestEntry: View {
    @State private var showingPlayer = false

    var body: some View {
        ContentView()
            .sheet(isPresented: $showingPlayer) {
                PixiPlayerSheet(gameID: "bad/id", title: "Invalid game identifier")
            }
            .onAppear { showingPlayer = true }
    }
}
#endif
