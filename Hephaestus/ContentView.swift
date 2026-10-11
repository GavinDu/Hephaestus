//
//  ContentView.swift
//  Hephaestus
//

import SwiftUI

/// The four main tabs: Discover, Create, Library, Profile.
struct ContentView: View {
    var body: some View {
        TabView {
            DiscoverView()
                .tabItem {
                    Label("Discover", systemImage: "gamecontroller")
                }
            CreateView()
                .tabItem {
                    Label("Create", systemImage: "plus.circle")
                }
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.circle")
                }
        }
    }
}

#Preview {
    ContentView()
}
