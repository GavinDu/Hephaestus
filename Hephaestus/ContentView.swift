//
//  ContentView.swift
//  Hephaestus
//

import SwiftUI

/// A destination shared by compact tabs and the expanded iPad sidebar.
private enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case discover
    case create
    case studio
    case library
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: "Discover"
        case .create: "Create"
        case .studio: "Studio"
        case .library: "Library"
        case .profile: "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .discover: "play.rectangle.on.rectangle"
        case .create: "plus.circle"
        case .studio: "square.stack.3d.up"
        case .library: "bookmark"
        case .profile: "person.crop.circle"
        }
    }
}

/// One navigation model with compact and expanded presentations. Width size class
/// is used rather than device identity so Split View and resizable windows adapt too.
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // UI-only simulator entry for capturing the actual Create screen on iPad.
    // No fake projects, media or backend responses are injected.
    @State private var selection: AppSection? =
        ProcessInfo.processInfo.arguments.contains("--ui-test-studio") ? .studio :
        (ProcessInfo.processInfo.arguments.contains("--ui-test-create-entry") ? .create : .discover)
    // On regular-width iPads, enter the full-screen playable feed first.
    // The system sidebar button still lets people reveal navigation.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                expandedLayout
            } else {
                compactLayout
            }
        }
    }

    private var compactLayout: some View {
        TabView(selection: Binding(
            get: { selection ?? .discover },
            set: { selection = $0 }
        )) {
            ForEach(AppSection.allCases.filter { $0 != .studio }) { section in
                destination(for: section)
                    .tabItem {
                        Label(section.title, systemImage: section.symbol)
                    }
                    .tag(section)
            }
        }
        .tint(ArcadePulseTheme.electricViolet)
        .toolbarBackground(ArcadePulseTheme.canvas, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .preferredColorScheme(.dark)
    }

    private var expandedLayout: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            List(selection: $selection) {
                Section("Play") {
                    navigationRow(.discover)
                    navigationRow(.create)
                }
                Section("Your space") {
                    navigationRow(.studio)
                    navigationRow(.library)
                    navigationRow(.profile)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(ArcadePulseTheme.surface)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 250)
            .navigationTitle("Hephaestus")
        } detail: {
            destination(for: selection ?? .discover)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(ArcadePulseTheme.electricViolet)
        .preferredColorScheme(.dark)
    }

    private func navigationRow(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .tag(Optional(section))
    }

    @ViewBuilder
    private func destination(for section: AppSection) -> some View {
        switch section {
        case .discover:
            DiscoverView()
        case .create:
            CreateView()
        case .studio:
            CreatorStudioView()
        case .library:
            LibraryView()
        case .profile:
            ProfileView()
        }
    }
}

#Preview {
    ContentView()
}
