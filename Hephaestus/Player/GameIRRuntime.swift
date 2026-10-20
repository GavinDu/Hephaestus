import Foundation
import SwiftUI
import UIKit

// MARK: - Versioned Game IR wire models

struct GamePackageResponse: Decodable {
    let packageVersion: String
    let gameId: String
    let ir: GameIRDocument
    let assets: [GamePackageAsset]
}

struct GamePackageAsset: Decodable, Identifiable {
    let id: String
    let kind: String
    let uri: String
    let url: String
    let mimeType: String?
    let sha256: String?
    let source: String?
    let altText: String?
}

struct GameIRDocument: Decodable {
    let irVersion: String
    let game: GameIRGame
    let assets: [GameIRAsset]
    let scenes: [GameIRScene]
    let inputBindings: [GameIRInputBinding]
    let rules: [GameIRRule]
    let metadata: GameIRMetadata?
}

struct GameIRGame: Decodable {
    let id: String
    let title: String
    let description: String?
    let entryScene: String
    let orientation: String
    let sessionTargetSeconds: Int?
    let audience: String?
}

struct GameIRAsset: Decodable, Identifiable {
    let id: String
    let kind: String
    let uri: String
    let mimeType: String?
    let sha256: String?
    let source: String?
    let altText: String?
}

struct GameIRScene: Decodable, Identifiable {
    let id: String
    let backgroundAssetId: String?
    let entities: [GameIREntity]
}

struct GameIREntity: Decodable, Identifiable {
    let id: String
    let kind: String
    let assetId: String?
    let position: [Double]
    let size: [Double]?
    let components: [String]
    let properties: [String: JSONValue]?

    var logicalSize: CGSize {
        CGSize(width: CGFloat(max(8, size?.first ?? 48)),
               height: CGFloat(max(8, size?.dropFirst().first ?? size?.first ?? 48)))
    }

    var logicalPosition: CGPoint {
        CGPoint(x: CGFloat(position.first ?? 195), y: CGFloat(position.dropFirst().first ?? 422))
    }
}

struct GameIRInputBinding: Decodable {
    let action: String
    let input: String
}

struct GameIRRule: Decodable, Identifiable {
    let id: String
    let when: GameIRCondition
    let conditions: [GameIRPredicate]?
    let actions: [GameIRAction]
}

struct GameIRCondition: Decodable {
    let event: String
    let source: String?
    let target: String?
    let inputAction: String?
    let value: Double?
}

struct GameIRPredicate: Decodable {
    let variable: String
    let `operator`: String
    let value: JSONValue
}

struct GameIRAction: Decodable {
    let type: String
    let target: String?
    let variable: String?
    let value: JSONValue?
    let assetId: String?
    let sceneId: String?
    let durationMs: Int?
}

struct GameIRMetadata: Decodable {
    let creatorDisplayName: String?
    let parentGameId: String?
    let parentVersion: Int?
    let tags: [String]?
}

/// A bounded JSON value for declarative rule values/properties. No code is evaluated.
indirect enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
}

// MARK: - Runtime engine (only allowlisted declarative actions)

@MainActor
final class GameIRRuntime: ObservableObject {
    let document: GameIRDocument
    let scene: GameIRScene
    @Published private(set) var positions: [String: CGPoint] = [:]
    @Published private(set) var destroyedIDs = Set<String>()
    @Published private(set) var score = 0
    @Published private(set) var health = 3
    @Published private(set) var statusMessage: String?
    @Published private(set) var isEnded = false
    @Published private(set) var didWin = false
    let images: [String: UIImage]

    private var variables: [String: Double] = [:]
    private var collectedPairs = Set<String>()

    init(document: GameIRDocument, images: [String: UIImage] = [:]) throws {
        guard document.irVersion == "1.0" else {
            throw RuntimeError.unsupportedVersion(document.irVersion)
        }
        guard let scene = document.scenes.first(where: { $0.id == document.game.entryScene }) else {
            throw RuntimeError.missingEntryScene(document.game.entryScene)
        }
        self.document = document
        self.scene = scene
        self.images = images
        self.positions = Dictionary(uniqueKeysWithValues: scene.entities.map { ($0.id, $0.logicalPosition) })
        emit(event: "game_start")
    }

    enum RuntimeError: LocalizedError {
        case unsupportedVersion(String)
        case missingEntryScene(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "Unsupported Game IR version: \(v)"
            case .missingEntryScene(let id): return "The package entry scene '\(id)' is missing."
            }
        }
    }

    var visibleEntities: [GameIREntity] {
        scene.entities.filter { !destroyedIDs.contains($0.id) }
    }

    func restart() {
        positions = Dictionary(uniqueKeysWithValues: scene.entities.map { ($0.id, $0.logicalPosition) })
        destroyedIDs.removeAll()
        collectedPairs.removeAll()
        variables.removeAll()
        score = 0
        health = 3
        statusMessage = nil
        isEnded = false
        didWin = false
        emit(event: "game_start")
    }

    func movePlayer(to point: CGPoint) {
        guard !isEnded,
              let player = scene.entities.first(where: { $0.kind == "player" || $0.components.contains("movement") })
        else { return }
        let halfW = player.logicalSize.width / 2
        let halfH = player.logicalSize.height / 2
        positions[player.id] = CGPoint(x: min(390 - halfW, max(halfW, point.x)),
                                       y: min(844 - halfH, max(halfH, point.y)))
        checkCollections(player: player)
    }

    private func checkCollections(player: GameIREntity) {
        guard let playerPosition = positions[player.id] else { return }
        for target in visibleEntities where target.id != player.id &&
            (target.kind == "pickup" || target.components.contains("collectible")) {
            guard let targetPosition = positions[target.id] else { continue }
            let dx = abs(playerPosition.x - targetPosition.x)
            let dy = abs(playerPosition.y - targetPosition.y)
            if dx < (player.logicalSize.width + target.logicalSize.width) * 0.45 &&
               dy < (player.logicalSize.height + target.logicalSize.height) * 0.45 {
                let pair = player.id + ":" + target.id
                guard !collectedPairs.contains(pair) else { continue }
                collectedPairs.insert(pair)
                emit(event: "collected", source: player.id, target: target.id)
            }
        }
    }

    private func conditionsMatch(_ conditions: [GameIRPredicate]?) -> Bool {
        for condition in conditions ?? [] {
            guard let actual = variables[condition.variable] else { return false }
            guard let expected = condition.value.numberValue else { return false }
            switch condition.operator {
            case "eq": if actual != expected { return false }
            case "neq": if actual == expected { return false }
            case "gt": if actual <= expected { return false }
            case "gte": if actual < expected { return false }
            case "lt": if actual >= expected { return false }
            case "lte": if actual > expected { return false }
            default: return false
            }
        }
        return true
    }

    private func ruleMatches(_ rule: GameIRRule, event: String, source: String?, target: String?, value: Double?) -> Bool {
        guard rule.when.event == event,
              rule.when.source == nil || rule.when.source == source,
              rule.when.target == nil || rule.when.target == target,
              conditionsMatch(rule.conditions) else { return false }
        if let expected = rule.when.value {
            if event == "score_reached" { return Double(score) >= expected }
            guard let value else { return false }
            return expected == value
        }
        return true
    }

    private func emit(event: String, source: String? = nil, target: String? = nil, value: Double? = nil) {
        for rule in document.rules where ruleMatches(rule, event: event, source: source, target: target, value: value) {
            execute(rule.actions)
            if isEnded { break }
        }
    }

    private func execute(_ actions: [GameIRAction]) {
        for action in actions {
            switch action.type {
            case "add_score":
                let amount = Int(action.value?.numberValue ?? 1)
                score += amount
                emitScoreThresholds()
            case "set_variable":
                if let key = action.variable, let value = action.value?.numberValue { variables[key] = value }
            case "move_entity":
                if let target = action.target, let value = action.value?.numberValue,
                   let current = positions[target] { positions[target] = CGPoint(x: current.x + value, y: current.y) }
            case "destroy_entity":
                if let target = action.target { destroyedIDs.insert(target) }
            case "show_text":
                statusMessage = action.value?.stringValue ?? "Nice!"
            case "set_health":
                health = max(0, Int(action.value?.numberValue ?? 0))
                if health == 0 { isEnded = true; didWin = false }
            case "end_game":
                isEnded = true
                didWin = action.value?.boolValue ?? ((action.value?.numberValue ?? 0) != 0)
            case "change_scene", "spawn_entity", "play_sound":
                // These actions are reserved by the contract; this first iOS slice
                // fails closed by not executing unsupported scene/audio/spawn behavior.
                if action.type == "change_scene" { statusMessage = "Scene changes are not supported by this player yet." }
            default:
                break
            }
        }
    }

    private func emitScoreThresholds() {
        for rule in document.rules where ruleMatches(rule, event: "score_reached", source: "player", target: nil, value: Double(score)) {
            execute(rule.actions)
            if isEnded { return }
        }
    }
}

// MARK: - Package loading

@MainActor
final class BundledPlayerState: ObservableObject {
    enum Phase {
        case loading
        case ready(GameIRRuntime)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading

    func load(gameID: String) async {
        phase = .loading
        do {
            var request = URLRequest(url: BackendConfig.baseURL.appendingPathComponent("v1/games/\(gameID)/package"))
            request.setValue(BackendConfig.userID, forHTTPHeaderField: "X-User-ID")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw PlayerError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let package = try JSONDecoder().decode(GamePackageResponse.self, from: data)
            guard package.packageVersion == "2.0" else {
                throw PlayerError.packageVersion(package.packageVersion)
            }
            guard package.gameId == gameID, package.irVersionIsValid else {
                throw PlayerError.invalidPackage
            }
            var images: [String: UIImage] = [:]
            for asset in package.assets where asset.kind == "image" {
                guard let url = URL(string: asset.url, relativeTo: BackendConfig.baseURL)?.absoluteURL else { continue }
                var assetRequest = URLRequest(url: url)
                assetRequest.setValue(BackendConfig.userID, forHTTPHeaderField: "X-User-ID")
                if let (assetData, assetResponse) = try? await URLSession.shared.data(for: assetRequest),
                   (assetResponse as? HTTPURLResponse)?.statusCode == 200,
                   let image = UIImage(data: assetData) {
                    images[asset.id] = image
                }
            }
            phase = .ready(try GameIRRuntime(document: package.ir, images: images))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    enum PlayerError: LocalizedError {
        case http(Int), packageVersion(String), invalidPackage
        var errorDescription: String? {
            switch self {
            case .http(let code): return "Couldn't load this game (HTTP \(code))."
            case .packageVersion(let version): return "Unsupported package version \(version); this app expects 2.0."
            case .invalidPackage: return "The package identity or Game IR version is invalid."
            }
        }
    }
}

private extension GamePackageResponse {
    var irVersionIsValid: Bool { ir.irVersion == "1.0" && ir.game.id == gameId }
}

// MARK: - Native SwiftUI player

struct BundledPlayerView: View {
    @ObservedObject var runtime: GameIRRuntime
    @State private var dragPoint: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let scaleX = geometry.size.width / 390
            let scaleY = geometry.size.height / 844
            ZStack {
                if let backgroundID = runtime.scene.backgroundAssetId,
                   let background = runtime.images[backgroundID] {
                    Image(uiImage: background)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    LinearGradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.25),
                                            Color(red: 0.22, green: 0.30, blue: 0.52)],
                                   startPoint: .top, endPoint: .bottom)
                }
                ForEach(runtime.visibleEntities) { entity in
                    entityView(entity)
                        .frame(width: entity.logicalSize.width * scaleX,
                               height: entity.logicalSize.height * scaleY)
                        .position(x: (runtime.positions[entity.id]?.x ?? entity.logicalPosition.x) * scaleX,
                                  y: (runtime.positions[entity.id]?.y ?? entity.logicalPosition.y) * scaleY)
                }
                VStack {
                    HStack {
                        Text(runtime.document.game.title).font(.headline).lineLimit(1)
                        Spacer()
                        Label("\(runtime.score)", systemImage: "star.fill")
                            .font(.headline).foregroundStyle(.yellow)
                    }
                    .padding(14)
                    Spacer()
                    if let message = runtime.statusMessage {
                        Text(message).font(.headline).padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if runtime.isEnded {
                        VStack(spacing: 12) {
                            Text(runtime.didWin ? "You did it!" : "Game over")
                                .font(.largeTitle.bold())
                            Text("Score: \(runtime.score)")
                            Button("Play again") { runtime.restart() }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .padding()
                    } else {
                        Text("Drag the character to collect items")
                            .font(.footnote).foregroundStyle(.white.opacity(0.8))
                            .padding(.bottom, 12)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                runtime.movePlayer(to: CGPoint(x: gesture.location.x / scaleX,
                                               y: gesture.location.y / scaleY))
            })
            .clipped()
        }
        .accessibilityIdentifier("gameIRCanvas")
    }

    @ViewBuilder
    private func entityView(_ entity: GameIREntity) -> some View {
        if let assetID = entity.assetId, let image = runtime.images[assetID] {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            let color: Color = switch entity.kind {
            case "player": .cyan
            case "pickup": .pink
            case "enemy", "obstacle": .red
            case "text": .white
            default: .orange
            }
            RoundedRectangle(cornerRadius: entity.kind == "pickup" ? 20 : 10)
                .fill(color.gradient)
                .overlay {
                    if entity.kind == "pickup" {
                        Image(systemName: "heart.fill").foregroundStyle(.white)
                    } else if entity.kind == "player" {
                        Image(systemName: "pawprint.fill").foregroundStyle(.white)
                    } else {
                        Text(entity.id.prefix(8)).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .shadow(radius: 3)
        }
    }
}

struct BundledPlayerRequest: Identifiable {
    let id = UUID()
    let gameID: String
    let title: String
}

struct BundledPlayerSheet: View {
    let gameID: String
    let title: String
    @StateObject private var state = BundledPlayerState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch state.phase {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading game package…").foregroundStyle(.secondary)
                    }
                case .ready(let runtime):
                    BundledPlayerView(runtime: runtime).ignoresSafeArea(edges: .bottom)
                case .failed(let message):
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 42))
                        Text("Couldn't load the game").font(.headline)
                        Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry") { Task { await state.load(gameID: gameID) } }
                            .buttonStyle(.borderedProminent)
                    }.padding()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await state.load(gameID: gameID) }
    }
}
