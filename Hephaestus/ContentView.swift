//
//  ContentView.swift
//  Hephaestus
//

import SwiftUI

/// A destination shared by compact tabs and the expanded iPad sidebar.
private enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case discover
    case create
    case library
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: "Discover"
        case .create: "Create"
        case .library: "Library"
        case .profile: "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .discover: "play.rectangle.on.rectangle"
        case .create: "plus.circle"
        case .library: "bookmark"
        case .profile: "person.crop.circle"
        }
    }
}

/// One navigation model with compact and expanded presentations. Width size class
/// is used rather than device identity so Split View and resizable windows adapt too.
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppSection? = .discover

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
            ForEach(AppSection.allCases) { section in
                destination(for: section)
                    .tabItem {
                        Label(section.title, systemImage: section.symbol)
                    }
                    .tag(section)
            }
        }
    }

    private var expandedLayout: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Play") {
                    navigationRow(.discover)
                    navigationRow(.create)
                }
                Section("Your space") {
                    navigationRow(.library)
                    navigationRow(.profile)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Hephaestus")
        } detail: {
            destination(for: selection ?? .discover)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func navigationRow(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .tag(Optional(section))
    }

    @ViewBuilder
    private func destination(for section: AppSection) -> some View {
        switch section {
        case .discover:
            DiscoverView()
        case .create:
            CreateView()
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
