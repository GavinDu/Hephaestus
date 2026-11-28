import Testing
import UIKit
@testable import Hephaestus

@MainActor
struct GridCommentsNativeButtonTests {
    @Test func primaryActionUsesExactlyOneCurrentCallback() {
        var first = 0
        var second = 0
        let coordinator = GridCommentsNativeButton.Coordinator { first += 1 }
        let button = GridCommentsNativeButton.makeControl(coordinator: coordinator)
        button.sendActions(for: .primaryActionTriggered)
        #expect(first == 1)
        #expect(second == 0)
        coordinator.action = { second += 1 }
        button.sendActions(for: .primaryActionTriggered)
        #expect(first == 1)
        #expect(second == 1)
        GridCommentsNativeButton.dismantleUIView(button, coordinator: coordinator)
        button.sendActions(for: .primaryActionTriggered)
        #expect(second == 1)
    }

    @Test func controlExposesOneNativeAccessibleButton() {
        let coordinator = GridCommentsNativeButton.Coordinator {}
        let button = GridCommentsNativeButton.makeControl(coordinator: coordinator)
        #expect(button.isAccessibilityElement)
        #expect(button.accessibilityIdentifier == "grid.game.social.comments")
        #expect(button.accessibilityLabel == "View comments")
        #expect(button.accessibilityTraits.contains(.button))
        #expect(button.configuration?.image != nil)
        #expect(GameFeedCardSocialActionLayout.minimumHitSize >= 44)
        GridCommentsNativeButton.dismantleUIView(button, coordinator: coordinator)
    }
}
