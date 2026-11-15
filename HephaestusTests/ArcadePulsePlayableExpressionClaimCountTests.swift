import Testing
@testable import Hephaestus

/// No real game, source artwork or claimed engagement figures are fabricated
/// by this pure presentation-policy test.
struct ArcadePulsePlayableExpressionClaimCountTests {
    @Test func missingClassificationIsNeverAnnouncedAsZero() {
        for category in ["Preserved", "Invented", "Uncertain"] {
            #expect(PlayableExpressionClaimCountPresentation.visualLabel(
                category: category, count: nil) == "\(category) · Not reported")
            #expect(PlayableExpressionClaimCountPresentation.accessibilityLabel(
                category: category, count: nil) == "\(category) claims: not reported")
        }
    }

    @Test func actualEmptyAndPositiveCountsRemainTruthful() {
        for category in ["Preserved", "Invented", "Uncertain"] {
            #expect(PlayableExpressionClaimCountPresentation.visualLabel(
                category: category, count: 0) == "\(category) · 0")
            #expect(PlayableExpressionClaimCountPresentation.accessibilityLabel(
                category: category, count: 0) == "\(category) claims: 0")
            #expect(PlayableExpressionClaimCountPresentation.visualLabel(
                category: category, count: 8) == "\(category) · 8")
            #expect(PlayableExpressionClaimCountPresentation.accessibilityLabel(
                category: category, count: 8) == "\(category) claims: 8")
        }
    }
}
