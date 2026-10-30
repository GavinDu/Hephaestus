import Foundation

/// Source-expression provenance and interpretation metadata.
///
/// This is deliberately not a runtime format. Games continue to execute from
/// the validated Game IR/package; this model explains how that IR relates to
/// a creator's source expression.
struct PlayableExpression: Codable, Equatable {
    enum Status: String, Codable { case draft, ready }
    enum Mode: String, Codable { case makePlayable = "make_playable", whatIf = "what_if", remix }
    enum Visibility: String, Codable { case privateSource = "private", groups, publicSource = "public" }
    enum SourceType: String, Codable { case text, image, drawing, audio, video }
    enum AnchorKind: String, Codable { case character, object, place, word, event, feeling }
    enum EvidenceKind: String, Codable { case textSpan = "text_span", imageRegion = "image_region", videoTimestamp = "video_timestamp", audioTimestamp = "audio_timestamp" }

    struct Source: Codable, Equatable {
        var type: SourceType
        var reference: String?
        var sha256: String?
    }

    struct Creator: Codable, Equatable {
        var ownerId: String
        var consent: Bool
        var visibility: Visibility
    }

    struct Anchor: Codable, Equatable, Identifiable {
        var id: String
        var kind: AnchorKind
        var value: String
        var preserve: Bool
    }

    struct Evidence: Codable, Equatable, Identifiable {
        var id: String
        var kind: EvidenceKind
        var sourceReference: String?
        var start: Double?
        var end: Double?
        var quote: String?
    }

    struct Claim: Codable, Equatable, Identifiable {
        var id: String
        var text: String
        var confidence: Double
        var evidenceIds: [String]?
    }

    struct Interpretation: Codable, Equatable {
        var preserved: [Claim]?
        var invented: [Claim]?
        var uncertain: [Claim]?
    }

    struct Generation: Codable, Equatable {
        var seed: Int64
        var gameIrVersion: String?
        var packageVersion: String?
        var modelVersion: String?
        var promptVersion: String?
    }

    struct Lineage: Codable, Equatable {
        var parentGameId: String?
        var parentVersion: Int?
        var parentExpressionId: String?
    }

    var schemaVersion: String
    var status: Status
    var source: Source
    var creator: Creator
    var mode: Mode
    var intent: String?
    var anchors: [Anchor]?
    var motifs: [String]?
    var optionalDetails: [String]?
    var evidence: [Evidence]?
    var interactiveVerbs: [String]?
    var candidateMechanics: [String]?
    var chosenInterpretation: String?
    var interpretation: Interpretation?
    var generation: Generation
    var lineage: Lineage?

    func validationError() -> String? {
        guard schemaVersion == "1.0" else { return "Unsupported playable expression schema version." }
        guard !creator.ownerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, creator.consent else {
            return "Creator identity and consent are required."
        }
        guard source.reference?.isEmpty == false || source.sha256?.isEmpty == false else {
            return "A source reference or SHA-256 digest is required."
        }
        if let digest = source.sha256 {
            let isHex = digest.count == 64 && digest.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }
            guard isHex else { return "Source SHA-256 must be a 64-character hexadecimal digest." }
        }
        let anchors = anchors ?? []
        guard Set(anchors.map(\.id)).count == anchors.count,
              anchors.allSatisfy({ !$0.id.isEmpty && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return "Anchor identifiers must be unique and anchor values cannot be empty."
        }
        let evidence = evidence ?? []
        guard Set(evidence.map(\.id)).count == evidence.count,
              evidence.allSatisfy({ !$0.id.isEmpty && ($0.start ?? 0) >= 0 && ($0.end ?? 0) >= ($0.start ?? 0) }) else {
            return "Evidence identifiers and ranges are invalid."
        }
        let evidenceIDs = Set(evidence.map(\.id))
        let claims = (interpretation?.preserved ?? []) + (interpretation?.invented ?? []) + (interpretation?.uncertain ?? [])
        guard Set(claims.map(\\.id)).count == claims.count else {
            return "Interpretation claim identifiers must be unique."
        }
        guard claims.allSatisfy({
            !$0.id.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.confidence.isFinite && (0...1).contains($0.confidence) &&
            ($0.evidenceIds ?? []).allSatisfy { evidenceIDs.contains($0) }
        }) else {
            return "Interpretation claims must have valid confidence and reference known evidence."
        }
        if status == .ready {
            guard !(intent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !anchors.isEmpty,
                  !(chosenInterpretation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !claims.isEmpty,
                  !(generation.gameIrVersion ?? "").isEmpty,
                  !(generation.packageVersion ?? "").isEmpty else {
                return "A ready expression requires intent, anchors, interpretation, and runtime versions."
            }
        }
        if mode == .remix && (lineage?.parentGameId ?? "").isEmpty {
            return "A remix expression requires a parent game."
        }
        if let parentVersion = lineage?.parentVersion, parentVersion < 0 {
            return "Parent version cannot be negative."
        }
        return nil
    }
}
