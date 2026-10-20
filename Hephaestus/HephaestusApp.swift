//
//  HephaestusApp.swift
//  Hephaestus
//

import SwiftUI

@main
struct HephaestusApp: App {
    init() {
        DevLog.shared.recordLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
