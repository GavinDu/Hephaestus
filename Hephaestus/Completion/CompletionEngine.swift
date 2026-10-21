import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - On-device completion
//
// Two-level completion for Game IR gameplay (design adopted 2026-10-20):
//
//   Level 1 — algorithmic: fast, deterministic, free. Interpolation,
//   cadence, and difficulty ramps computed from IR state. Always
//   available, on every device.
//
//   Level 2 — neural: a compact on-device model invoked ONLY when a gap
//   needs semantic judgment (which encounter next, a short behavior
//   plan). First choice is Apple Foundation Models on supported devices;
//   the engine sits behind the CompletionEngine protocol so a Core AI
//   open model can replace it without touching the IR or the runtime.
//
// Invariants:
//   - A completion produces a *plan*: declarative Game IR actions, never
//     code. Plans are validated (PlanValidator) against the same
//     allowlists as the backend Game IR contract before scheduling.
//   - A plan may never end the game, and spawn targets are limited to
//     templates the package already declares.
//   - If neural completion is unavailable, errors, or fails validation,
//     the deterministic level answers; if it has no plan, the runtime
//     keeps today's fail-closed behavior. The game runs correctly with
//     no model at all.
//
// This module is the seam. Wiring it into GameIRRuntime's scheduler
// (pre-computed plans for spawn_entity / encounter gaps) is the next
// step; nothing here changes current gameplay behavior.

// MARK: Request / plan

/// A semantic gap the runtime cannot fill deterministically.
enum CompletionGap: String {
    /// Choose the next encounter: which declared templates enter play.
    case spawnEncounter = "spawn_encounter"
    /// Choose a short behavior plan for an existing entity.
    case behaviorPlan = "behavior_plan"
    /// Decide how difficulty steps up at a threshold.
    case difficultyStep = "difficulty_step"
}

/// Everything a completer may look at: IR identity plus a state snapshot.
/// Deliberately small and Codable-shaped so it can be handed to a model
/// as structured context or logged for debugging.
struct CompletionRequest {
    let gameID: String
    let sceneID: String
    let gap: CompletionGap
    let score: Int
    let health: Int
    let elapsedSeconds: Double
    let destroyedCount: Int
    /// Entity template IDs the package declares as spawnable.
    let entityTemplates: [String]
    /// All scene IDs in the package (bounds change_scene plans).
    let sceneIDs: [String]
    let variables: [String: Double]
}

/// A validated-or-candidate plan: declarative IR actions in order.
struct CompletionPlan: Decodable {
    let actions: [GameIRAction]
    let rationale: String?
}

protocol CompletionEngine {
    /// Return a candidate plan, or nil when this engine cannot answer.
    func complete(_ request: CompletionRequest) async -> CompletionPlan?
}

// MARK: - Plan validation

/// Mirrors the backend Game IR contract (internal/gameir allowlists).
/// A plan that fails validation is discarded whole — never partially
/// executed — and the caller falls back to the next level.
enum PlanValidator {
    private static let allowedActions: Set<String> = [
        "add_score", "set_variable", "move_entity", "destroy_entity",
        "spawn_entity", "play_sound", "show_text", "change_scene",
        "set_health", "end_game",
    ]
    static let maxActions = 8

    static func validate(_ plan: CompletionPlan, for request: CompletionRequest) -> CompletionPlan? {
        guard !plan.actions.isEmpty, plan.actions.count <= maxActions else { return nil }
        for action in plan.actions {
            guard allowedActions.contains(action.type) else { return nil }
            switch action.type {
            case "end_game":
                // A completer may never end the game; endings belong to
                // authored IR rules.
                return nil
            case "spawn_entity":
                guard let target = action.target,
                      request.entityTemplates.contains(target) else { return nil }
            case "change_scene":
                guard let scene = action.sceneId,
                      request.sceneIDs.contains(scene) else { return nil }
            case "add_score", "set_health", "move_entity":
                if let value = action.value?.numberValue,
                   !value.isFinite || abs(value) > 1000 { return nil }
            default:
                break
            }
        }
        return plan
    }
}

// MARK: - Level 1: deterministic completer

/// Algorithmic completion: pure functions of the request. No model, no
/// randomness beyond a state-derived rotation, identical output for
/// identical input — safe for replays and contract tests.
final class DeterministicCompleter: CompletionEngine {
    func complete(_ request: CompletionRequest) async -> CompletionPlan? {
        switch request.gap {
        case .spawnEncounter:
            guard !request.entityTemplates.isEmpty else { return nil }
            // Cadence scales mildly with score; template choice rotates
            // deterministically by destroyed count so runs are stable.
            let count = min(1 + request.score / 5, 3, request.entityTemplates.count)
            var actions: [GameIRAction] = []
            for i in 0..<count {
                let template = request.entityTemplates[(request.destroyedCount + i) % request.entityTemplates.count]
                actions.append(GameIRAction(type: "spawn_entity", target: template,
                                            variable: nil, value: nil, assetId: nil,
                                            sceneId: nil, durationMs: nil))
            }
            return CompletionPlan(actions: actions,
                                  rationale: "deterministic spawn rotation (\(count) template(s))")
        case .difficultyStep:
            let current = request.variables["difficulty"] ?? 0
            let next = min(current + 0.1, 1.0)
            return CompletionPlan(
                actions: [GameIRAction(type: "set_variable", target: nil,
                                       variable: "difficulty", value: .number(next),
                                       assetId: nil, sceneId: nil, durationMs: nil)],
                rationale: "deterministic difficulty ramp \(current) -> \(next)")
        case .behaviorPlan:
            // No honest deterministic default; let the runtime fail closed.
            return nil
        }
    }
}

// MARK: - Level 2: Foundation Models completer

#if canImport(FoundationModels)
/// Neural completion via Apple Foundation Models (on-device, Apple
/// Intelligence devices). Returns nil whenever the model is unavailable
/// so the service falls back deterministically. The model is asked for a
/// JSON plan only; PlanValidator — not the model — decides what may run.
///
/// NOTE: first-cut integration; latency/quality must be measured on
/// target devices, and the guided-generation typed API can replace the
/// JSON prompt later without changing this protocol.
final class FoundationModelsCompleter: CompletionEngine {
    func complete(_ request: CompletionRequest) async -> CompletionPlan? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            DevLog.info(.ai, "foundation models unavailable: \(model.availability)")
            return nil
        }
        let instructions = """
            You complete declarative game plans. Reply with JSON only: \
            {"actions":[{"type":"...","target":"...","value":0}],"rationale":"..."} \
            Allowed action types: add_score, set_variable, move_entity, \
            destroy_entity, spawn_entity, play_sound, show_text, \
            change_scene, set_health. Never use end_game. At most 8 actions.
            """
        let prompt = """
            Game \(request.gameID), scene \(request.sceneID). Gap: \(request.gap.rawValue). \
            Score \(request.score), health \(request.health), elapsed \(Int(request.elapsedSeconds))s, \
            destroyed \(request.destroyedCount). Spawnable templates: \(request.entityTemplates.joined(separator: ", ")). \
            Scenes: \(request.sceneIDs.joined(separator: ", ")). Variables: \(request.variables).
            """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = text.data(using: .utf8),
                  let plan = try? JSONDecoder().decode(CompletionPlan.self, from: data) else {
                DevLog.warn(.ai, "foundation models returned an undecodable plan")
                return nil
            }
            return plan
        } catch {
            DevLog.warn(.ai, "foundation models completion failed: \(error.localizedDescription)")
            return nil
        }
    }
}
#else
/// Placeholder on OS versions without the Foundation Models framework;
/// always unavailable, so the deterministic level answers.
final class FoundationModelsCompleter: CompletionEngine {
    func complete(_ request: CompletionRequest) async -> CompletionPlan? { nil }
}
#endif

// MARK: - Service

/// Orchestrates the two levels: neural candidate -> validate ->
/// deterministic candidate -> validate -> nil (fail closed). Every
/// decision is DevLog-logged with its source and latency so a dumped
/// session log shows exactly which level answered and why.
final class CompletionService {
    private let neural: CompletionEngine
    private let deterministic: CompletionEngine

    init(neural: CompletionEngine = FoundationModelsCompleter(),
         deterministic: CompletionEngine = DeterministicCompleter()) {
        self.neural = neural
        self.deterministic = deterministic
    }

    func plan(for request: CompletionRequest) async -> CompletionPlan? {
        let started = Date()
        if let candidate = await neural.complete(request) {
            if let valid = PlanValidator.validate(candidate, for: request) {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                DevLog.info(.ai, "gap \(request.gap.rawValue) in \(request.gameID): neural plan accepted, \(valid.actions.count) actions (\(ms)ms) — \(valid.rationale ?? "no rationale")")
                return valid
            }
            DevLog.warn(.ai, "gap \(request.gap.rawValue) in \(request.gameID): neural plan rejected by validator, falling back")
        }
        if let candidate = await deterministic.complete(request),
           let valid = PlanValidator.validate(candidate, for: request) {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DevLog.info(.ai, "gap \(request.gap.rawValue) in \(request.gameID): deterministic plan, \(valid.actions.count) actions (\(ms)ms) — \(valid.rationale ?? "no rationale")")
            return valid
        }
        DevLog.info(.ai, "gap \(request.gap.rawValue) in \(request.gameID): no completion available, runtime fails closed")
        return nil
    }
}
