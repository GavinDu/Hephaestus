import Combine
import CryptoKit
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
    let behavior: GameIRBehavior?

    var logicalSize: CGSize {
        CGSize(width: CGFloat(max(8, size?.first ?? 48)),
               height: CGFloat(max(8, size?.dropFirst().first ?? size?.first ?? 48)))
    }

    var logicalPosition: CGPoint {
        CGPoint(x: CGFloat(position.first ?? 195), y: CGFloat(position.dropFirst().first ?? 422))
    }
}

/// Autonomous motion declared in the IR, interpreted by the runtime tick
/// loop: fall (down at speed px/s, wraps; collected falling pickups
/// respawn at the top), chase (toward the player), patrol (horizontal
/// oscillation around the authored position), oscillate (vertical).
struct GameIRBehavior: Decodable {
    let type: String
    let speed: Double?
    let range: Double?
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
    private var hazardContacts = Set<String>()
    private var anchors: [String: CGPoint] = [:]
    private var tickTask: Task<Void, Never>?
    private var lastTick: Date?
    private var elapsed: Double = 0
    private var respawnIndex = 0

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
        self.anchors = self.positions
        DevLog.info(.runtime, "start '\(document.game.id)' scene '\(scene.id)': \(scene.entities.count) entities (\(scene.entities.filter { $0.behavior != nil }.count) animated), \(document.rules.count) rules, \(images.count) images")
        emit(event: "game_start")
        startLoop()
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: - Tick loop (autonomous motion)

    private func startLoop() {
        tickTask?.cancel()
        lastTick = Date()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                self.tick()
            }
        }
    }

    /// One motion step: apply each entity's IR behavior, then re-check
    /// pickups and hazards — collisions no longer depend on the player
    /// dragging. Falling pickups are renewable: on wrap or after being
    /// collected they re-enter at the top in a fresh column.
    private func tick() {
        guard !isEnded else { return }
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick ?? now), 0.05)
        lastTick = now
        guard dt > 0 else { return }
        elapsed += dt
        guard let player = scene.entities.first(where: { $0.kind == "player" || $0.components.contains("movement") }),
              let playerPos = positions[player.id] else { return }

        for entity in scene.entities {
            guard let behavior = entity.behavior else { continue }
            let size = entity.logicalSize
            if destroyedIDs.contains(entity.id) {
                if behavior.type == "fall" {
                    destroyedIDs.remove(entity.id)
                    collectedPairs.remove(player.id + ":" + entity.id)
                    respawnIndex += 1
                    positions[entity.id] = CGPoint(x: CGFloat(50 + (respawnIndex * 83) % 290),
                                                   y: -size.height / 2)
                }
                continue
            }
            guard var pos = positions[entity.id] else { continue }
            switch behavior.type {
            case "fall":
                pos.y += CGFloat(behavior.speed ?? 80) * CGFloat(dt)
                if pos.y > 844 + size.height / 2 {
                    respawnIndex += 1
                    pos = CGPoint(x: CGFloat(50 + (respawnIndex * 83) % 290), y: -size.height / 2)
                }
                positions[entity.id] = pos
            case "chase":
                let dx = playerPos.x - pos.x
                let dy = playerPos.y - pos.y
                let dist = max(1, sqrt(dx * dx + dy * dy))
                let step = min(CGFloat(behavior.speed ?? 50) * CGFloat(dt), dist)
                positions[entity.id] = CGPoint(x: pos.x + dx / dist * step,
                                               y: pos.y + dy / dist * step)
            case "patrol":
                let anchor = anchors[entity.id] ?? entity.logicalPosition
                positions[entity.id] = CGPoint(
                    x: anchor.x + CGFloat(sin(elapsed * (behavior.speed ?? 1))) * CGFloat(behavior.range ?? 60),
                    y: anchor.y)
            case "oscillate":
                let anchor = anchors[entity.id] ?? entity.logicalPosition
                positions[entity.id] = CGPoint(
                    x: anchor.x,
                    y: anchor.y + CGFloat(sin(elapsed * (behavior.speed ?? 1.2))) * CGFloat(behavior.range ?? 10))
            default:
                break
            }
        }
        checkCollections(player: player)
        checkHazards(player: player)
    }

    /// Enemy/obstacle contact, emitted once per approach as the
    /// "collision" event IR rules listen for.
    private func checkHazards(player: GameIREntity) {
        guard let playerPosition = positions[player.id] else { return }
        for target in visibleEntities where target.id != player.id &&
            (target.kind == "obstacle" || target.kind == "enemy") {
            guard let targetPosition = positions[target.id] else { continue }
            let dx = abs(playerPosition.x - targetPosition.x)
            let dy = abs(playerPosition.y - targetPosition.y)
            let touching = dx < (player.logicalSize.width + target.logicalSize.width) * 0.45 &&
                           dy < (player.logicalSize.height + target.logicalSize.height) * 0.45
            if touching {
                if !hazardContacts.contains(target.id) {
                    hazardContacts.insert(target.id)
                    DevLog.info(.runtime, "hazard contact: \(target.id)")
                    emit(event: "collision", source: player.id, target: target.id)
                }
            } else {
                hazardContacts.remove(target.id)
            }
        }
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
        anchors = positions
        destroyedIDs.removeAll()
        collectedPairs.removeAll()
        hazardContacts.removeAll()
        variables.removeAll()
        elapsed = 0
        respawnIndex = 0
        lastTick = Date()
        score = 0
        health = 3
        statusMessage = nil
        isEnded = false
        didWin = false
        DevLog.info(.runtime, "restart '\(document.game.id)'")
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
        checkHazards(player: player)
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
            DevLog.info(.runtime, "rule '\(rule.id)' fired by \(event)\(source.map { " src=\($0)" } ?? "")\(target.map { " tgt=\($0)" } ?? "")")
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
                DevLog.info(.runtime, "game ended: \(didWin ? "WIN" : "LOSE"), score \(score), health \(health)")
            case "change_scene", "spawn_entity", "play_sound":
                // These actions are reserved by the contract; this first iOS slice
                // fails closed by not executing unsupported scene/audio/spawn behavior.
                DevLog.warn(.runtime, "unsupported action '\(action.type)' skipped (fail-closed)")
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
        DevLog.info(.package, "load \(gameID): fetching package")
        do {
            guard Self.validIdentifier(gameID) else { throw PlayerError.invalidPackage }
            var request = URLRequest(url: BackendConfig.baseURL
                .appendingPathComponent("v1/games")
                .appendingPathComponent(gameID)
                .appendingPathComponent("package"))
            request.timeoutInterval = 15
            request.setValue(BackendConfig.userID, forHTTPHeaderField: "X-User-ID")
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw PlayerError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            DevLog.info(.package, "load \(gameID): package 200 (\(ms)ms, \(data.count) B)")
            guard data.count <= PlayerLimits.maxPackageBytes else { throw PlayerError.packageTooLarge }
            let package = try JSONDecoder().decode(GamePackageResponse.self, from: data)
            try package.validate(expectedGameID: gameID)
            DevLog.info(.package, "load \(gameID): validated package v\(package.packageVersion), IR v\(package.ir.irVersion), \(package.assets.count) assets, \(package.ir.scenes.count) scenes, \(package.ir.rules.count) rules")
            var images: [String: UIImage] = [:]
            var totalAssetBytes = 0
            for asset in package.assets where asset.kind == "image" {
                let url = try Self.validatedAssetURL(asset.url, gameID: gameID, assetID: asset.id)
                var assetRequest = URLRequest(url: url)
                assetRequest.timeoutInterval = 12
                // Same-origin only; never forward identity headers to package-supplied URLs.
                let (assetData, assetResponse) = try await URLSession.shared.data(for: assetRequest)
                guard let http = assetResponse as? HTTPURLResponse, http.statusCode == 200 else {
                    throw PlayerError.assetUnavailable(asset.id)
                }
                guard assetData.count <= PlayerLimits.maxAssetBytes else { throw PlayerError.assetTooLarge(asset.id) }
                totalAssetBytes += assetData.count
                guard totalAssetBytes <= PlayerLimits.maxTotalAssetBytes else { throw PlayerError.assetsTooLarge }
                if let expected = asset.sha256, !expected.isEmpty {
                    let actual = SHA256.hash(data: assetData).map { String(format: "%02x", $0) }.joined()
                    guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                        throw PlayerError.assetIntegrity(asset.id)
                    }
                }
                guard let image = UIImage(data: assetData) else { throw PlayerError.invalidImage(asset.id) }
                images[asset.id] = image
                DevLog.info(.package, "load \(gameID): asset '\(asset.id)' ok (\(assetData.count) B\(asset.sha256 != nil ? ", sha256 verified" : ""))")
            }
            DevLog.info(.package, "load \(gameID): \(images.count) images ready, \(totalAssetBytes) B total")
            phase = .ready(try GameIRRuntime(document: package.ir, images: images))
        } catch {
            DevLog.error(.package, "load \(gameID) failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
        }
    }

    private static func validatedAssetURL(_ raw: String, gameID: String, assetID: String) throws -> URL {
        guard validIdentifier(assetID),
              let url = URL(string: raw, relativeTo: BackendConfig.baseURL)?.absoluteURL,
              let base = URLComponents(url: BackendConfig.baseURL, resolvingAgainstBaseURL: false),
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              target.scheme?.lowercased() == "https",
              target.host?.lowercased() == base.host?.lowercased(),
              target.port == base.port,
              target.user == nil, target.password == nil,
              target.query == nil, target.fragment == nil else {
            throw PlayerError.invalidAssetURL(assetID)
        }
        let expectedPath = BackendConfig.baseURL
            .appendingPathComponent("v1/games")
            .appendingPathComponent(gameID)
            .appendingPathComponent("assets")
            .appendingPathComponent(assetID).path
        guard target.path == expectedPath else { throw PlayerError.invalidAssetURL(assetID) }
        return url
    }

    enum PlayerError: LocalizedError {
        case http(Int), packageVersion(String), invalidPackage, packageTooLarge
        case invalidAssetURL(String), assetUnavailable(String), assetTooLarge(String)
        case assetsTooLarge, assetIntegrity(String), invalidImage(String)
        var errorDescription: String? {
            switch self {
            case .http(let code): return "Couldn't load this game (HTTP \\(code))."
            case .packageVersion(let version): return "Unsupported package version \\(version); this app expects 2.0."
            case .invalidPackage: return "The package is malformed, inconsistent, or exceeds supported runtime capabilities."
            case .packageTooLarge: return "The game package exceeds the size limit."
            case .invalidAssetURL(let id): return "Asset \\(id) has an unsafe or invalid delivery URL."
            case .assetUnavailable(let id): return "Asset \\(id) could not be downloaded."
            case .assetTooLarge(let id): return "Asset \\(id) exceeds the size limit."
            case .assetsTooLarge: return "The game's total downloaded assets exceed the size limit."
            case .assetIntegrity(let id): return "Asset \\(id) failed its SHA-256 integrity check."
            case .invalidImage(let id): return "Asset \\(id) is not a supported image."
            }
        }
    }
}

private enum PlayerLimits {
    static let maxPackageBytes = 2 * 1024 * 1024
    static let maxAssetBytes = 8 * 1024 * 1024
    static let maxTotalAssetBytes = 32 * 1024 * 1024
    static let maxAssets = 256
    static let maxScenes = 64
    static let maxEntitiesPerScene = 500
    static let maxTotalEntities = 2_000
    static let maxRules = 256
    static let maxInputBindings = 32
}

extension GamePackageResponse {
    func validate(expectedGameID: String) throws {
        guard packageVersion == "2.0", gameId == expectedGameID,
              ir.irVersion == "1.0", ir.game.id == gameId,
              !ir.game.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !ir.scenes.isEmpty, ir.scenes.count <= PlayerLimits.maxScenes,
              ir.assets.count <= PlayerLimits.maxAssets, assets.count <= PlayerLimits.maxAssets,
              ir.rules.count <= PlayerLimits.maxRules,
              ir.inputBindings.count <= PlayerLimits.maxInputBindings,
              ir.scenes.contains(where: { $0.id == ir.game.entryScene }) else {
            throw BundledPlayerState.PlayerError.invalidPackage
        }
        var irAssetIDs = Set<String>()
        for asset in ir.assets {
            guard irAssetIDs.insert(asset.id).inserted else {
                throw BundledPlayerState.PlayerError.invalidPackage
            }
        }
        let irAssets = Dictionary(uniqueKeysWithValues: ir.assets.map { ($0.id, $0) })
        var packageAssetIDs = Set<String>()
        for asset in assets {
            guard !asset.id.isEmpty, asset.id.utf8.count <= 64,
                  packageAssetIDs.insert(asset.id).inserted,
                  let declared = irAssets[asset.id],
                  declared.uri == asset.uri, declared.kind == asset.kind else {
                throw BundledPlayerState.PlayerError.invalidPackage
            }
        }
        guard packageAssetIDs == Set(irAssets.keys) else { throw BundledPlayerState.PlayerError.invalidPackage }
        var entityIDs = Set<String>()
        var totalEntities = 0
        for scene in ir.scenes {
            guard !scene.id.isEmpty, scene.entities.count <= PlayerLimits.maxEntitiesPerScene else {
                throw BundledPlayerState.PlayerError.invalidPackage
            }
            totalEntities += scene.entities.count
            for entity in scene.entities {
                guard !entity.id.isEmpty, entityIDs.insert(entity.id).inserted,
                      entity.position.count == 2, entity.position.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }),
                      entity.size == nil || (entity.size!.count == 2 && entity.size!.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100_000 })),
                      entity.assetId == nil || irAssets[entity.assetId!] != nil else {
                    throw BundledPlayerState.PlayerError.invalidPackage
                }
            }
        }
        guard totalEntities <= PlayerLimits.maxTotalEntities else { throw BundledPlayerState.PlayerError.invalidPackage }
        let supportedActions: Set<String> = ["add_score", "set_variable", "move_entity", "destroy_entity", "show_text", "set_health", "end_game"]
        let supportedEvents: Set<String> = ["game_start", "input", "collision", "collected", "timer_elapsed", "score_reached", "health_changed", "scene_entered"]
        for rule in ir.rules {
            guard !rule.id.isEmpty, supportedEvents.contains(rule.when.event),
                  !rule.actions.isEmpty, rule.actions.count <= 16,
                  rule.actions.allSatisfy({ supportedActions.contains($0.type) }),
                  rule.when.source == nil || entityIDs.contains(rule.when.source!),
                  rule.when.target == nil || entityIDs.contains(rule.when.target!) else {
                throw BundledPlayerState.PlayerError.invalidPackage
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
