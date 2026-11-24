import Testing
@testable import Hephaestus

struct ArcadePulseImmersiveFeedStyleTests {
    @Test func whiteTextHasAAContrastAtBothGradientEnds() {
        let a = ArcadePulseImmersiveFeedStyle.violetStartRGB
        let b = ArcadePulseImmersiveFeedStyle.violetEndRGB
        #expect(ArcadePulseImmersiveFeedStyle.whiteContrast(red: a.red, green: a.green, blue: a.blue) >= 4.5)
        #expect(ArcadePulseImmersiveFeedStyle.whiteContrast(red: b.red, green: b.green, blue: b.blue) >= 4.5)
    }

    @Test func missingOrInvalidCountsAreNeverInvented() {
        #expect(ArcadePulseImmersiveFeedStyle.metric(nil) == nil)
        #expect(ArcadePulseImmersiveFeedStyle.metric(-1) == nil)
        #expect(ArcadePulseImmersiveFeedStyle.caption("Like", count: nil) == "Like")
        #expect(ArcadePulseImmersiveFeedStyle.caption("Share", count: -1) == "Share")
        #expect(ArcadePulseImmersiveFeedStyle.metric(0) == "0")
        #expect(ArcadePulseImmersiveFeedStyle.caption("Like", count: 42) == "42")
    }
}
