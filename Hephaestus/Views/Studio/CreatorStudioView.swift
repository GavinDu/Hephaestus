import SwiftUI

/// Private owner workspace. The backend, not the device, authorizes every
/// project. No invented draft, graph, editor, remix or analytics affordance.
struct CreatorStudioView: View {
    // Make the signed-out empty state a navigable entry into the REAL
    // authentication flow. Studio never manufactures a project or session.
    let onOpenProfile: () -> Void

    // Never silently install a no-op for a visibly actionable sign-in
    // button. Every real caller must supply the native Profile route.
    init(onOpenProfile: @escaping () -> Void) {
        self.onOpenProfile = onOpenProfile
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var projects: [CreatorProject] = []
    @State private var selectedStatus: ProjectFilter = .all
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var requestRevision = 0
    @State private var loadError: String?
    @State private var playerRequest: PixiPlayerRequest?

    private enum ProjectFilter: String, CaseIterable, Identifiable {
        case all, draft, generating, ready, failed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All projects"
            case .draft: "Drafts"
            case .generating: "Generating"
            case .ready: "Ready"
            case .failed: "Failed"
            }
        }
    }

    private var isSignedOut: Bool { BackendConfig.currentUserID.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if isSignedOut {
                        signedOutGate
                    } else {
                        Picker("Project status", selection: $selectedStatus) {
                            ForEach(ProjectFilter.allCases) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("studio.project.filter")
                        .onChange(of: selectedStatus) { _, _ in
                            Task { await load(reset: true) }
                        }

                        if isLoading && projects.isEmpty {
                            ProgressView("Loading your projects…")
                                .frame(maxWidth: .infinity, minHeight: 240)
                        } else if let loadError, projects.isEmpty {
                            VStack(spacing: 12) {
                                ContentUnavailableView(
                                    "Couldn't load projects",
                                    systemImage: "wifi.exclamationmark",
                                    description: Text(loadError))
                                Button("Retry") { Task { await load(reset: true) } }
                                    .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity, minHeight: 240)
                        } else if projects.isEmpty {
                            ContentUnavailableView(
                                "No projects here yet",
                                systemImage: "square.stack.3d.up",
                                description: Text("Games you create will appear here with their real generation and moderation status."))
                                .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 265, maximum: 420), spacing: 16)],
                                alignment: .center, spacing: 16
                            ) {
                                ForEach(projects) { project in
                                    projectCard(project)
                                }
                            }
                            if nextCursor != nil {
                                Button {
                                    Task { await load(reset: false) }
                                } label: {
                                    if isLoadingMore { ProgressView("Loading more…") }
                                    else { Label("Load more projects", systemImage: "arrow.down.circle") }
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .disabled(isLoadingMore)
                                .accessibilityIdentifier("studio.loadMore")
                            }
                            if let loadError {
                                Label(loadError, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .frame(maxWidth: horizontalSizeClass == .regular ? 1_140 : 640)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .background(ArcadePulseTheme.canvas)
            .preferredColorScheme(.dark)
            .navigationTitle("Creator Studio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load(reset: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isSignedOut || isLoading)
                    .accessibilityLabel("Refresh my projects")
                }
            }
            .refreshable {
                if !isSignedOut { await load(reset: true) }
            }
            .task {
                if !isSignedOut { await load(reset: true) }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .hephaestusBackendSessionDidChange
            )) { _ in
                // Clear owner-only data synchronously when the session changes.
                // Scheduling the purge in a Task leaves a privacy-visible gap
                // during which the previous owner's cards may still render.
                requestRevision += 1
                projects = []
                nextCursor = nil
                loadError = nil
                isLoading = false
                isLoadingMore = false
                playerRequest = nil
                // Only the new account's fetch is asynchronous. The exact
                // credential snapshot in load rejects stale responses.
                if !BackendConfig.currentUserID.isEmpty {
                    Task { await load(reset: true) }
                }
            }
            .fullScreenCover(item: $playerRequest) { req in
                PixiPlayerSheet(gameID: req.gameID, title: req.title)
            }
            .accessibilityIdentifier("studio.arcadePulse.root")
        }
    }

    /// An iPad is a workspace, not a phone sign-in card centered in empty
    /// space. Keep every statement factual while the owner-project backend is
    /// unavailable; the two-panel guidance is editorial, never fake analytics.
    private var signedOutGate: some View {
        Group {
            if horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        studioSignInCard.frame(minWidth: 430, maxWidth: 560)
                        studioGuide.frame(minWidth: 320, maxWidth: 410)
                    }
                    .frame(maxWidth: 1_040)
                    VStack(spacing: 20) {
                        studioSignInCard.frame(maxWidth: 620)
                        studioGuide.frame(maxWidth: 620)
                    }
                }
            } else {
                studioSignInCard.frame(maxWidth: 620)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 370)
        .accessibilityElement(children: .contain)
    }

    private var studioSignInCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.square.stack.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(ArcadePulseTheme.neonMagenta)
                .frame(width: 76, height: 76)
                .background(ArcadePulseTheme.electricViolet.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 20))
            Text("Sign in to see your projects")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Your private drafts, generation status and published games belong to your account. Sign in from Profile to manage them.")
                .font(.body)
                .foregroundStyle(ArcadePulseTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOpenProfile) {
                Label("Go to Profile to sign in", systemImage: "person.crop.circle")
                    .font(.headline)
                    // Keep the real Profile navigation legible at normal text:
                    // white on this violet does not reach WCAG AA 4.5:1.
                    .foregroundStyle(ArcadePulseTheme.onElectricViolet)
                    .frame(maxWidth: 380, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(ArcadePulseTheme.electricViolet)
            .accessibilityIdentifier("studio.openProfile")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 36)
        .background(
            LinearGradient(colors: [
                ArcadePulseTheme.surface,
                ArcadePulseTheme.electricViolet.opacity(0.14)
            ], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius)
                .strokeBorder(ArcadePulseTheme.subtleBorder, lineWidth: 1)
        }
    }

    private func studioGuideRow(
        _ title: String, symbol: String, detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(ArcadePulseTheme.neonMagenta)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(ArcadePulseTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Informative content only; no fake counts, empty editor actions, or
    /// dashboard widgets claiming the service is already deployed.
    private var studioGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("YOUR STUDIO", systemImage: "square.stack.3d.up")
                .font(.caption.weight(.bold))
                .foregroundStyle(ArcadePulseTheme.neonMagenta)
            Text("From idea to playable game")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            studioGuideRow("Private drafts", symbol: "lock.shield",
                           detail: "Projects appear only after sign-in and server ownership checks.")
            studioGuideRow("Real progress", symbol: "clock.arrow.circlepath",
                           detail: "Generation and moderation statuses come from the service, never sample data.")
            studioGuideRow("Playable releases", symbol: "play.rectangle",
                           detail: "Play opens only for games the service marks publicly playable.")
            Text("These features require a connected, authorized project service.")
                .font(.caption)
                .foregroundStyle(ArcadePulseTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(ArcadePulseTheme.surface,
                    in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius)
                .strokeBorder(ArcadePulseTheme.subtleBorder, lineWidth: 1)
        }
        .accessibilityIdentifier("studio.signedOutGuide")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("YOUR CREATIVE WORKSPACE", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(ArcadePulseTheme.neonMagenta)
            Text("Your games, from idea to play.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("See real project progress and published games. Editing and remix tools appear only when the service supports them.")
                .font(.subheadline)
                .foregroundStyle(ArcadePulseTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("studio.header")
    }

    private func projectCard(_ project: CreatorProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                LinearGradient(
                    colors: ArcadePulseTheme.fallbackPalette(gameID: project.gameID),
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                if let url = project.resolvedPosterURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            noPreview
                        }
                    }
                } else {
                    noPreview
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 155)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel(project.resolvedPosterURL == nil
                                ? "No approved game preview" : "Game preview or fallback")

            HStack(alignment: .top, spacing: 8) {
                Text(project.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(project.displayStatus)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ArcadePulseTheme.playOrange)
                    .multilineTextAlignment(.trailing)
            }
            if let job = project.jobStatus, !job.isEmpty,
               project.status == "generating" {
                Text("Job: \(job.replacingOccurrences(of: "_", with: " "))")
                    .font(.caption)
                    .foregroundStyle(ArcadePulseTheme.textSecondary)
            }
            Text("Updated \(String(project.updatedAt.prefix(10)))")
                .font(.caption)
                .foregroundStyle(ArcadePulseTheme.textSecondary)
            if let remix = project.remixParentID, !remix.isEmpty {
                Label("Remix project", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(ArcadePulseTheme.neonMagenta)
            }
            if project.isPubliclyPlayable {
                ArcadePulsePlayCTA {
                    playerRequest = PixiPlayerRequest(gameID: project.gameID, title: project.title)
                }
            } else {
                Label("Not publicly playable yet", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(ArcadePulseTheme.textSecondary)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(ArcadePulseTheme.surface,
                    in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius)
                .strokeBorder(ArcadePulseTheme.subtleBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var noPreview: some View {
        VStack(spacing: 7) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 30))
            Text("No approved preview")
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.86))
    }

    private func load(reset: Bool) async {
        let ownerID = BackendConfig.currentUserID
        // A same-subject credential rotation revokes an old response even
        // before SwiftUI receives the session-change notification.
        let sessionToken = BackendConfig.loadSessionToken()
        guard !ownerID.isEmpty else {
            requestRevision += 1
            projects = []
            nextCursor = nil
            loadError = nil
            return
        }
        if reset {
            requestRevision += 1
            isLoading = true
            projects = []
            nextCursor = nil
            loadError = nil
        } else {
            guard nextCursor != nil, !isLoadingMore, !isLoading else { return }
            isLoadingMore = true
        }
        let revision = requestRevision
        let filter = selectedStatus
        let cursor = reset ? nil : nextCursor
        defer {
            if requestRevision == revision {
                isLoading = false
                isLoadingMore = false
            }
        }
        do {
            let response = try await BackendAPI.shared.fetchMyProjects(
                status: filter.rawValue, cursor: cursor
            )
            guard !Task.isCancelled,
                  CreatorStudioRequestPolicy.canApply(
                    startedRevision: revision, currentRevision: requestRevision,
                    startedOwner: ownerID, currentOwner: BackendConfig.currentUserID,
                    startedToken: sessionToken, currentToken: BackendConfig.loadSessionToken()
                  ), selectedStatus == filter else { return }
            if reset {
                projects = response.projects
            } else {
                let known = Set(projects.map(\.gameID))
                projects.append(contentsOf: response.projects.filter { !known.contains($0.gameID) })
            }
            nextCursor = response.nextCursor
            loadError = nil
        } catch {
            guard !Task.isCancelled,
                  CreatorStudioRequestPolicy.canApply(
                    startedRevision: revision, currentRevision: requestRevision,
                    startedOwner: ownerID, currentOwner: BackendConfig.currentUserID,
                    startedToken: sessionToken, currentToken: BackendConfig.loadSessionToken()
                  ), selectedStatus == filter else { return }
            // Raw localizedDescription may contain internal API hostnames,
            // request URLs or unauthorized account metadata. Keep diagnostics
            // separate from fixed, user-actionable native error copy.
            loadError = CreatorStudioErrorPresentation.message(for: error)
        }
    }
}

/// Privacy-safe, actionable source for native Studio project-fetch errors.
/// Project models, permissions and statuses always remain server-authoritative.
enum CreatorStudioErrorPresentation {
    static func message(for error: Error) -> String {
        if let apiError = error as? APIError,
           case let .badStatus(status) = apiError {
            switch status {
            case 401:
                return "Your session has expired. Open Profile to sign in again."
            case 403:
                return "Your account isn't allowed to view these projects."
            case 404:
                return "The projects service isn't available yet. Try again later."
            case 429:
                return "Too many requests. Try again in a little while."
            default:
                break
            }
        }
        if let transport = error as? URLError {
            switch transport.code {
            case .notConnectedToInternet:
                return "You're offline. Reconnect, then retry your projects."
            case .secureConnectionFailed:
                return "A secure connection couldn't be established. Try again."
            case .timedOut:
                return "Your projects took too long to load. Try again."
            default:
                break
            }
        }
        return "Couldn't load your projects. Check your connection and retry."
    }
}

/// Pure privacy invariant for asynchronous owner-project responses. Comparing
/// the actual credential snapshot also covers a same-subject token rotation
/// before SwiftUI processes the payload-free session-change notification.
/// Never log or persist either token here.
enum CreatorStudioRequestPolicy {
    static func canApply(
        startedRevision: Int, currentRevision: Int,
        startedOwner: String, currentOwner: String,
        startedToken: String?, currentToken: String?
    ) -> Bool {
        startedRevision == currentRevision &&
        !startedOwner.isEmpty && startedOwner == currentOwner &&
        startedToken == currentToken
    }
}
