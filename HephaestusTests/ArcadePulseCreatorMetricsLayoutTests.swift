import SwiftUI
import Testing
@testable import Hephaestus

/// Source-level layout tests. Real backend data, VoiceOver and original
/// iPhone/iPad pixels are independently required by #266/#269.
struct ArcadePulseCreatorMetricsLayoutTests {
    @Test func ordinarySizesUseCompactThreeColumnStats() {
        for typeSize in [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge, .xxLarge] {
            #expect(!CreatorMetricLayout.stacksMetrics(isRegularWidth: false, typeSize: typeSize))
            #expect(!CreatorMetricLayout.stacksMetrics(isRegularWidth: true, typeSize: typeSize))
        }
    }

    @Test func compactXXXLAndAllAccessibilitySizesStackRealStats() {
        #expect(CreatorMetricLayout.stacksMetrics(isRegularWidth: false, typeSize: .xxxLarge))
        #expect(!CreatorMetricLayout.stacksMetrics(isRegularWidth: true, typeSize: .xxxLarge))
        for typeSize in [DynamicTypeSize.accessibility1, .accessibility2,
                         .accessibility3, .accessibility4, .accessibility5] {
            #expect(CreatorMetricLayout.stacksMetrics(isRegularWidth: false, typeSize: typeSize))
            #expect(CreatorMetricLayout.stacksMetrics(isRegularWidth: true, typeSize: typeSize))
        }
    }
}
