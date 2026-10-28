import PhotosUI
import SwiftUI
import UIKit

/// Photograph a drawing → analyze → generate → confirm → play.
struct CreateView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    enum Phase {
        case pick
        case analyzing
        case review(result: IngestResult, image: UIImage)
        case generating(JobStatus)
        case confirming(JobStatus)
        case done(gameID: String)
        case failed(String)
    }

    @State private var phase: Phase = .pick
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var keywordsText = ""
    @State private var intentText = ""
    @State private var publishCaption = ""
    @State private var publishTopics = ""
    @State private var publishMessage: String?
    @State private var isPublishing = false
    @State private var playerRequest: PixiPlayerRequest?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .pick:
                    pickView
                case .analyzing:
                    ProgressView("Analyzing drawing…")
                case .review(let result, let image):
                    reviewView(result: result, image: image)
                case .generating(let job):
                    ProgressView("Generating game… (\(job.status))")
                        .task(id: job.job_id) { await pollJob(job.job_id) }
                case .confirming(let job):
                    confirmingView(job: job)
                case .done(let gameID):
                    doneView(gameID: gameID)
                case .failed(let message):
                    VStack(spacing: 16) {
                        Text("Something went wrong").font(.headline)
                        Text(message).foregroundStyle(.secondary)
                        Button("Start over") { reset() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .navigationTitle("Create")
            .fullScreenCover(item: $playerRequest) { req in
                PixiPlayerSheet(gameID: req.gameID, title: req.title)
            }
        }
    }

    private var pickView: some View {
        VStack(spacing: 20) {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 220)
                    .overlay {
                        VStack {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                            Text("No drawing selected")
                                .foregroundStyle(.secondary)
                        }
                    }
            }

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose a drawing", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.bordered)
            .onChange(of: pickerItem) { _, newItem in
                Task {
                    guard let newItem else { return }
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        imageData = data
                        previewImage = UIImage(data: data)
                    }
                }
            }

            TextField("Keywords (comma separated)", text: $keywordsText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Button("Analyze drawing") {
                Task { await analyze() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(imageData == nil)

            Spacer()
        }
        .padding()
    }

    private func reviewView(result: IngestResult, image: UIImage) -> some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 12) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 560)
                            .frame(maxWidth: .infinity)
                        Text("Your drawing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)

                    List {
                        Section("Elements found") {
                            ForEach(result.elements, id: \.name) { el in
                                HStack {
                                    Text(el.name)
                                    Spacer()
                                    Text(el.role).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section("What should the game be about?") {
                            TextField("Intent", text: $intentText, axis: .vertical)
                                .lineLimit(3...6)
                        }
                        Section {
                            Button("Generate game") {
                                Task { await generate(result: result) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .frame(maxWidth: 620)
                }
                .padding(.horizontal, 24)
                .accessibilityIdentifier("create.review.regular")
            } else {
                List {
                    Section("Drawing") {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Section("Elements found") {
                        ForEach(result.elements, id: \.name) { el in
                            HStack {
                                Text(el.name)
                                Spacer()
                                Text(el.role).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("What should the game be about?") {
                        TextField("Intent", text: $intentText)
                    }
                    Section {
                        Button("Generate game") {
                            Task { await generate(result: result) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func confirmingView(job: JobStatus) -> some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 12) {
                        if let previewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 560)
                                .frame(maxWidth: .infinity)
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(maxWidth: .infinity)
                                .frame(height: 320)
                                .overlay {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                }
                        }
                        Text("Your drawing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)

                    List {
                        Section("Design doc") {
                            if let doc = job.design_doc {
                                Text(doc.title).font(.headline)
                                if let plot = doc.plot { Text(plot) }
                                if let mechanics = doc.mechanics {
                                    Text("How it plays: \(mechanics)")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("The design is ready to review.")
                            }
                        }
                        Section {
                            Button("Looks good — build it") {
                                Task { await confirm(job: job) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .frame(maxWidth: 620)
                }
                .padding(.horizontal, 24)
                .accessibilityIdentifier("create.confirming.regular")
            } else {
                List {
                    Section("Design doc") {
                        if let doc = job.design_doc {
                            Text(doc.title).font(.headline)
                            if let plot = doc.plot { Text(plot) }
                            if let mechanics = doc.mechanics {
                                Text("How it plays: \(mechanics)")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("The design is ready to review.")
                        }
                    }
                    Section {
                        Button("Looks good — build it") {
                            Task { await confirm(job: job) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func doneView(gameID: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Your game is ready!").font(.title2)
            Button("Play now") {
                playerRequest = PixiPlayerRequest(gameID: gameID, title: "Your game")
            }
            .buttonStyle(.borderedProminent)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Share it with the community").font(.headline)
                TextField("Add a caption", text: $publishCaption, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                TextField("Topics, separated by commas", text: $publishTopics)
                    .textFieldStyle(.roundedBorder)
                Text("Published games enter moderation before appearing in public feeds.")
                    .font(.caption).foregroundStyle(.secondary)
                if let publishMessage {
                    Text(publishMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await publish(gameID: gameID) }
                } label: {
                    if isPublishing { ProgressView() }
                    else { Label("Publish game", systemImage: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPublishing)
            }
            .frame(maxWidth: 420)
            Button("Make another") { reset() }
        }
        .padding()
    }

    private func publish(gameID: String) async {
        isPublishing = true
        defer { isPublishing = false }
        let topics = publishTopics.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        do {
            _ = try await BackendAPI.shared.publishPost(gameID: gameID, caption: publishCaption, topics: topics)
            publishMessage = "Submitted for moderation. The post appears in feeds after approval."
        } catch {
            publishMessage = "Couldn't publish: \(error.localizedDescription)"
        }
    }

    private func reset() {
        phase = .pick
        pickerItem = nil
        imageData = nil
        previewImage = nil
        keywordsText = ""
        intentText = ""
        publishCaption = ""
        publishTopics = ""
        publishMessage = nil
    }

    private func analyze() async {
        guard let imageData else { return }
        phase = .analyzing
        let keywords = keywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            let result = try await BackendAPI.shared.ingest(imageData: imageData, keywords: keywords)
            intentText = result.guessed_intent ?? ""
            if let image = UIImage(data: imageData) {
                phase = .review(result: result, image: image)
            } else {
                phase = .failed("Couldn't read the selected image.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func generate(result: IngestResult) async {
        do {
            let resp = try await BackendAPI.shared.createGame(
                ingestID: result.ingest_id,
                elements: result.elements,
                intent: intentText
            )
            phase = .generating(resp.job)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func pollJob(_ jobID: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            do {
                let job = try await BackendAPI.shared.fetchJob(id: jobID)
                switch job.status {
                case "awaiting_confirm":
                    phase = .confirming(job)
                    return
                case "done":
                    phase = .done(gameID: job.game_id)
                    return
                case "failed":
                    phase = .failed(job.error ?? "Generation failed.")
                    return
                default:
                    phase = .generating(job)
                }
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
    }

    private func confirm(job: JobStatus) async {
        do {
            try await BackendAPI.shared.confirmGame(id: job.game_id)
            phase = .generating(job)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

