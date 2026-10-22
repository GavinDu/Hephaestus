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
            ContentView()
        }
    }
}
