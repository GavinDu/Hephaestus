import SwiftUI

/// Source-first remix journey backed by the real Game IR generation pipeline.
/// No client preflight can authorize source copying; POST /v1/games repeats
/// the permission/IR checks before any new job exists.
struct RemixCreationSheet: View {
    let source: FeedGame
    let onOpenProfile: (() -> Void)?

    init(source: FeedGame, onOpenProfile: (() -> Void)? = nil) {
        self.source = source
        self.onOpenProfile = onOpenProfile
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var phase: Phase = .checking
    @State private var intent = ""
    @State private var sourceAcknowledged = false
    @State private var hasPublicPublishConsent = false
    @State private var allowOtherRemixes = false
    @State private var publishCaption = ""
    @State private var publishTopics = ""
    @State private var isCreating = false
    @State private var isConfirming = false
    @State private var isPublishing = false
    @State private var didSubmitPublication = false
    @State private var publishMessage: String?
    @State private var playerRequest: PixiPlayerRequest?

    private enum Phase {
        case checking
        case denied(String)
        case unavailable(String)
        case ready
        case building(JobStatus)
        case confirming(JobStatus)
        case done(String)
        case failed(String)
    }

    private var activeJobID: String? {
        if case .building(let job) = phase { return job.job_id }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Group {
                        switch phase {
                        case .checking:
                            ProgressView("Checking creator permissions…")
                                .frame(maxWidth: .infinity, minHeight: 180)
                        case .denied(let reason):
                            VStack(spacing: 14) {
                                ContentUnavailableView(
                                    "Remix not available",
                                    systemImage: "lock.shield",
                                    description: Text(reason))
                                if BackendConfig.currentUserID.isEmpty, let onOpenProfile {
                                    // Authentication is a genuine route to Profile, not
                                    // a bypass of source rights or an automatic remix.
                                    Button(action: onOpenProfile) {
                                        Label("Go to Profile to sign in",
                                              systemImage: "person.crop.circle")
                                            .frame(maxWidth: .infinity, minHeight: 48)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(ArcadePulseTheme.electricViolet)
                                    .accessibilityIdentifier("remix.openProfile")
                                }
                            }
                            .frame(maxWidth: 520, minHeight: 180)
                            .frame(maxWidth: .infinity)
                        case .unavailable(let message):
                            // An unreachable or outdated backend is not evidence
                            // that the original creator refused remix permission.
                            VStack(spacing: 16) {
                                ContentUnavailableView(
                                    "Couldn't check remix rights",
                                    systemImage: "wifi.exclamationmark",
                                    description: Text(message))
                                Button {
                                    Task { await checkEligibility() }
                                } label: {
                                    Label("Try permission check again", systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(ArcadePulseTheme.electricViolet)
                                .accessibilityIdentifier("remix.retryEligibility")
                            }
                            .frame(maxWidth: 520, minHeight: 180)
                            .frame(maxWidth: .infinity)
                        case .ready:
                            readyForm
                        case .building(let job):
                            VStack(spacing: 14) {
                                ProgressView("Building your remix…")
                                Text("Generation: \(job.status)")
                                    .foregroundStyle(ArcadePulseTheme.textSecondary)
                                Text("This uses the original game's validated mechanics and assets. The parent game is not edited.")
                                    .font(.caption)
                                    .foregroundStyle(ArcadePulseTheme.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                        case .confirming(let job):
                            confirmation(job)
                        case .done(let gameID):
                            finished(gameID: gameID)
                        case .failed(let message):
                            VStack(spacing: 16) {
                                ContentUnavailableView(
                                    "Remix couldn't continue",
                                    systemImage: "exclamationmark.triangle",
                                    description: Text(message))
                                Button("Check source again") {
                                    Task { await checkEligibility() }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .frame(maxWidth: horizontalSizeClass == .regular ? 840 : 560)
                .frame(maxWidth: .infinity)
                .padding(22)
            }
            .background(ArcadePulseTheme.canvas)
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
            .navigationTitle("Remix a game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: source.id) { await checkEligibility() }
            .task(id: activeJobID) {
                if let activeJobID { await pollJob(activeJobID) }
            }
            .fullScreenCover(item: $playerRequest) { request in
                PixiPlayerSheet(gameID: request.gameID, title: request.title)
            }
            .accessibilityIdentifier("remix.arcadePulse.root")
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("ARCADE PULSE • REMIX", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.bold))
                .foregroundStyle(ArcadePulseTheme.neonMagenta)
            Text("Make a new story from this game.")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text(source.title)
                .font(.headline)
                .foregroundStyle(ArcadePulseTheme.playOrange)
            if let creator = source.creatorDisplayName ?? source.ownerID, !creator.isEmpty {
                Text("Original creator: \(creator)")
                    .font(.subheadline)
                    .foregroundStyle(ArcadePulseTheme.textSecondary)
            }
            Text("Your remix is a new private game with source lineage. Publishing requires separate moderation and consent.")
                .font(.subheadline)
                .foregroundStyle(ArcadePulseTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var readyForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Source permission verified", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ArcadePulseTheme.neonMagenta)
            Text("Describe how your version should feel.")
                .font(.headline)
            TextField("Your remix idea", text: $intent, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("remix.intent")
            Toggle("I understand this uses the source game with its creator attribution and creates a separate private version",
                   isOn: $sourceAcknowledged)
                .tint(ArcadePulseTheme.electricViolet)
                .accessibilityIdentifier("remix.sourceAcknowledged")
            Button {
                Task { await create() }
            } label: {
                Label("Create my remix", systemImage: "wand.and.stars")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(ArcadePulseTheme.playOrangeDeep)
            .disabled(intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      !sourceAcknowledged || isCreating)
            .accessibilityIdentifier("remix.create")
        }
        .padding(18)
        .background(ArcadePulseTheme.surface,
                    in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
    }

    private func confirmation(_ job: JobStatus) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Review the generated design")
                .font(.title3.weight(.bold))
            if let doc = job.design_doc {
                Text(doc.title).font(.headline)
                if let plot = doc.plot { Text(plot) }
                if let mechanics = doc.mechanics {
                    Text("How it plays: \(mechanics)")
                        .foregroundStyle(ArcadePulseTheme.textSecondary)
                }
            } else {
                Text("The generation service is waiting for your confirmation.")
            }
            Button {
                Task { await confirm(job) }
            } label: {
                Label("Approve and build my remix", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(ArcadePulseTheme.electricViolet)
            .disabled(isConfirming)
            .accessibilityIdentifier("remix.confirm")
        }
        .padding(18)
        .background(ArcadePulseTheme.surface,
                    in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
    }

    private func finished(gameID: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your private remix is ready", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            ArcadePulsePlayCTA {
                playerRequest = PixiPlayerRequest(gameID: gameID, title: "Your remix")
            }
            Divider().overlay(ArcadePulseTheme.subtleBorder)
            Text("Share your remix")
                .font(.headline)
            TextField("Caption", text: $publishCaption, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            TextField("Topics separated by commas", text: $publishTopics)
                .textFieldStyle(.roundedBorder)
            Toggle("I agree to submit this remix for public moderation and attribution",
                   isOn: $hasPublicPublishConsent)
                .tint(ArcadePulseTheme.electricViolet)
                .accessibilityIdentifier("remix.publishConsent")
            Toggle("Allow other creators to remix my published game",
                   isOn: $allowOtherRemixes)
                .tint(ArcadePulseTheme.electricViolet)
            if let publishMessage {
                Text(publishMessage).font(.caption).foregroundStyle(ArcadePulseTheme.textSecondary)
            }
            Button {
                Task { await publish(gameID: gameID) }
            } label: {
                if isPublishing { ProgressView().frame(maxWidth: .infinity, minHeight: 44) }
                else { Label("Submit for publication", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity, minHeight: 44) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasPublicPublishConsent || isPublishing || didSubmitPublication)
            .accessibilityIdentifier("remix.publish")
        }
        .padding(18)
        .background(ArcadePulseTheme.surface,
                    in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
    }

    private func checkEligibility() async {
        guard !BackendConfig.currentUserID.isEmpty else {
            phase = .denied("Sign in with Apple on the Profile tab to check remix permissions.")
            return
        }
        phase = .checking
        do {
            let result = try await BackendAPI.shared.fetchRemixEligibility(gameID: source.id)
            phase = result.eligible ? .ready :
                .denied(result.reason.isEmpty ? "The creator has not enabled remixing." : result.reason)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .unavailable("The service couldn't verify source permissions right now. No remix was created.")
        }
    }

    private func create() async {
        guard !isCreating, sourceAcknowledged,
              !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let created = try await BackendAPI.shared.createRemix(
                parentGameID: source.id, intent: intent.trimmingCharacters(in: .whitespacesAndNewlines))
            phase = .building(created.job)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func pollJob(_ id: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            do {
                let job = try await BackendAPI.shared.fetchJob(id: id)
                switch job.status {
                case "awaiting_confirm":
                    phase = .confirming(job)
                    return
                case "done":
                    phase = .done(job.game_id)
                    return
                case "failed":
                    phase = .failed(job.error ?? "Generation failed.")
                    return
                default:
                    phase = .building(job)
                }
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
    }

    private func confirm(_ job: JobStatus) async {
        guard !isConfirming else { return }
        isConfirming = true
        defer { isConfirming = false }
        do {
            try await BackendAPI.shared.confirmGame(id: job.game_id)
            phase = .building(job)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func publish(gameID: String) async {
        guard hasPublicPublishConsent, !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        let topics = publishTopics.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        do {
            _ = try await BackendAPI.shared.publishPost(
                gameID: gameID, caption: publishCaption,
                topics: topics, remixParentID: source.id,
                allowRemixes: allowOtherRemixes)
            didSubmitPublication = true
            publishMessage = "Submitted for moderation. This remix is not in public feeds until approved."
        } catch {
            publishMessage = "Couldn't publish: \(error.localizedDescription)"
        }
    }
}
