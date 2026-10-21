import SwiftUI

// MARK: - Player presentation
//
// The player is the PixiJS + Rapier Game IR runtime — the single runtime
// since the 2026-10-20 consolidation (the native Swift IR interpreter in
// GameIRRuntime.swift was removed, along with Defold and Godot). The
// runtime is served by the backend at /player and will be embedded here
// in a bridgeless WKWebView: no JS<->native bridge; the web player loads
// its Game IR package over HTTPS like any browser.
//
// PixiPlayerSheet is a placeholder until that WebView lands: it keeps
// the social shell's play entry points (Discover, Library, Create)
// compiling and honest — no fake gameplay — and logs the open.

struct PixiPlayerRequest: Identifiable {
    let id = UUID()
    let gameID: String
    let title: String
}

struct PixiPlayerSheet: View {
    let gameID: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text("The Pixi + Rapier player is being built. Games will play here, in the web runtime, once the WebView is wired.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                DevLog.info(.player, "player opened for \(gameID) (Pixi placeholder)")
            }
        }
    }
}
