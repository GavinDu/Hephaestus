//
//  ContentView.swift
//  Hephaestus
//

import Combine
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

/// iPad sidebar rows must not shrink text to fit a fixed one-line slot.
enum ArcadePulseSidebarLabelPolicy {
    static func visibleLineLimit(for size: DynamicTypeSize) -> Int {
        size >= .xxLarge ? 2 : 1
    }

    static let minimumHitHeight: CGFloat = 44
}

/// One navigation model with compact and expanded presentations. Width size class
/// is used rather than device identity so Split View and resizable windows adapt too.
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // UI-only simulator entry for capturing the actual Create screen on iPad.
    // No fake projects, media or backend responses are injected.
    @State private var selection: AppSection? =
        ProcessInfo.processInfo.arguments.contains("--ui-test-studio") ? .studio :
        (ProcessInfo.processInfo.arguments.contains("--ui-test-create-entry") ? .create :
         (ProcessInfo.processInfo.arguments.contains("--ui-test-library-entry") ? .library : .discover))
    // On regular-width iPads, enter the full-screen playable feed first.
    // The system sidebar button still lets people reveal navigation.
    @State private var sidebarVisibility: NavigationSplitViewVisibility =
        ProcessInfo.processInfo.arguments.contains("--ui-test-sidebar-open") ? .all : .detailOnly

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                expandedLayout
            } else {
                compactLayout
            }
        }
        .onAppear {
            // Purge the old account-agnostic Recent list immediately at app
            // entry, even when the user never opens Library.
            RecentGames.discardUnscopedLegacyHistory()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .hephaestusBackendSessionDidChange
        )) { _ in
            // A previous signed-out user's local game titles should not
            // survive a login/logout boundary into the next guest shelf.
            RecentGames.clearGuestHistory()
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
            // The detail's programmatic navigation must not race a hidden
            // two-way sidebar List(selection:) binding on regular iPad.
            // Explicit sidebar buttons and a single section owner are reliable
            // both when sidebar is revealed and when an in-detail CTA fires.
            List {
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
                // Each destination has its own NavigationStack. Retire its
                // old internal path on a genuine section transition.
                .id(selection ?? .discover)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(ArcadePulseTheme.electricViolet)
        .preferredColorScheme(.dark)
    }

    private func navigate(to section: AppSection, fromSidebar: Bool = false) {
        selection = section
        // Focus routes initiated in Discover/Studio/Library. A deliberately
        // opened sidebar remains open when navigating through its own rows.
        if !fromSidebar { sidebarVisibility = .detailOnly }
    }

    private func navigationRow(_ section: AppSection) -> some View {
        Button {
            navigate(to: section, fromSidebar: true)
        } label: {
            Label(section.title, systemImage: section.symbol)
                .lineLimit(ArcadePulseSidebarLabelPolicy.visibleLineLimit(for: dynamicTypeSize))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: ArcadePulseSidebarLabelPolicy.minimumHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == section
                         ? ArcadePulseTheme.textPrimary
                         : ArcadePulseTheme.textSecondary)
        .listRowBackground(selection == section
                           ? ArcadePulseTheme.electricViolet.opacity(0.24)
                           : Color.clear)
        .accessibilityAddTraits(selection == section ? .isSelected : [])
        .accessibilityIdentifier("nav.sidebar.\(section.rawValue)")
    }

    @ViewBuilder
    private func destination(for section: AppSection) -> some View {
        switch section {
        case .discover:
            DiscoverView(onOpenLibrary: { navigate(to: .library) },
                         onOpenProfile: { navigate(to: .profile) })
        case .create:
            CreateView(onOpenProfile: { navigate(to: .profile) })
        case .studio:
            CreatorStudioView(onOpenProfile: { navigate(to: .profile) })
        case .library:
            LibraryView(onOpenProfile: { navigate(to: .profile) })
        case .profile:
            ProfileView()
        }
    }
}

#Preview {
    ContentView()
}
