//
//  PlayerSmokeTests.swift
//  HephaestusUITests
//
//  Phase 4 of the fused detect-and-fix flow (device matrix): the one
//  end-to-end UI test that matters — Discover loads the live feed, Play
//  opens the Pixi player sheet, and a WKWebView actually appears and
//  boots a game. It runs in its own CI job so the production backend's
//  uptime never gates the unit tests, and its failure is the signal
//  that the app <-> server path broke.
//

import XCTest
import UIKit

final class PlayerSmokeTests: XCTestCase {

    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// On failure, attach a screenshot of whatever the app was showing:
    /// a render failure without a picture of what rendered is almost
    /// unactionable for the next iteration (docs/TESTING_FRAMEWORK.md
    /// §5.4). The success-path screenshot after boot settles stays in
    /// the test body as the baseline. Verified by the Hephaestus CI
    /// xcode job — this VM has no Xcode to compile Swift locally.
    override func tearDownWithError() throws {
        if let run = testRun, run.totalFailureCount > 0, let app {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "player-on-failure"
            shot.lifetime = .keepAlways
            add(shot)
        }
        app = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testDiscoverLaunchesPlayer() throws {
        let app = XCUIApplication()
        self.app = app
        app.launch()
        print("SMOKE: app launched")

        // The Discover feed comes from the live backend; the workflow
        // warms the deployment first, but the wait still leaves room
        // for a slow first response. On failure the message carries
        // the UI hierarchy — the CI log is the only diagnostic this
        // job produces.
        // Use a stable identifier instead of matching visible copy ("Play now"),
        // which can change as the social-feed card design evolves.
        let play = app.buttons["game.play"].firstMatch
        let retry = app.buttons["Try again"].firstMatch
        let feedDeadline = Date().addingTimeInterval(120)
        while !play.exists && Date() < feedDeadline {
            if retry.waitForExistence(timeout: 5) {
                print("SMOKE: feed unavailable; retrying live request")
                retry.tap()
            }
            _ = play.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(play.exists,
                      "Discover feed should offer at least one playable game card after bounded retries. UI: \(app.debugDescription)")
        print("SMOKE: Play button visible")
        play.tap()

        // The player is a bridgeless WKWebView in a full-screen sheet;
        // the web view is in the hierarchy from the moment the sheet
        // presents (a loading overlay sits on top while it boots).
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30),
                      "Player sheet should host a WKWebView. UI: \(app.debugDescription)")
        print("SMOKE: player web view visible")

        // A loaded game must always have a stable, accessible way back to
        // the feed; this catches toolbar regressions independently of copy.
        let done = app.buttons["player.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10),
                      "Player sheet should expose its Done control. UI: \(app.debugDescription)")

        // Let the game boot, then keep a screenshot as evidence.
        _ = XCTWaiter.wait(for: [expectation(description: "boot settle")], timeout: 6)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "player-after-boot"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Lightweight UI evaluator for the swipe-first feed. This runs in the
    /// existing iPhone smoke job and the optional iPad simulator job, so the
    /// same layout and touch-target checks are exercised at both size classes.
    @MainActor
    func testDiscoverFeedUIEvaluationAndSwipe() throws {
        let app = XCUIApplication()
        self.app = app
        app.launch()

        let play = app.buttons["game.play"].firstMatch
        let retry = app.buttons["Try again"].firstMatch
        let feedDeadline = Date().addingTimeInterval(150)
        while !play.exists && Date() < feedDeadline {
            if retry.waitForExistence(timeout: 5) {
                print("UI EVALUATOR: feed unavailable; retrying live request")
                retry.tap()
            }
            _ = play.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(play.exists,
                      "For You should expose a playable feed page after bounded retries. UI: \(app.debugDescription)")

        let swipeCue = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "SWIPE TO EXPLORE"))
            .firstMatch
        let hasSwipeCue = swipeCue.waitForExistence(timeout: 10)
        XCTAssertTrue(hasSwipeCue,
                      "The feed should communicate its vertical swipe interaction.")

        @discardableResult
        func assertTouchTarget(_ element: XCUIElement, named name: String) -> Bool {
            XCTAssertTrue(element.exists, "\(name) should be present on the feed page.")
            guard element.exists else { return false }
            let frame = element.frame
            let sized = frame.width >= 44 && frame.height >= 44
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(name) should be at least 44pt wide.")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(name) should be at least 44pt tall.")
            let reachable = element.isHittable
            XCTAssertTrue(reachable, "\(name) should be reachable without scrolling.")
            return sized && reachable
        }

        let touchTargetsPassed = [
            assertTouchTarget(play, named: "Play"),
            assertTouchTarget(app.buttons["Save game"].firstMatch, named: "Save"),
            assertTouchTarget(app.buttons["Like game"].firstMatch, named: "Like"),
            assertTouchTarget(app.buttons["View comments"].firstMatch, named: "Comments")
        ].filter { $0 }.count

        let beforeSwipe = XCTAttachment(screenshot: app.screenshot())
        beforeSwipe.name = "feed-ui-evaluator-before-swipe"
        beforeSwipe.lifetime = .keepAlways
        add(beforeSwipe)

        // Require a real next page in the fixture-backed CI feed. A one-card
        // feed can validate launch and controls, but cannot prove paging works.
        let pages = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed.page.title."))
        XCTAssertGreaterThanOrEqual(pages.count, 2,
                                    "The UI evaluator needs at least two feed pages to verify paging.")

        // SwiftUI's title accessibility nodes can have an invalid activation
        // point even while their containing page is visibly rendered. Use
        // viewport intersection for page visibility instead of asking XCTest
        // to synthesize a tap target for a non-interactive title label.
        let visiblePages = pages.allElementsBoundByIndex.filter {
            $0.frame.intersects(app.frame)
        }
        let beforePage = visiblePages.first
        XCTAssertNotNil(beforePage, "The current feed page should intersect the app viewport.")
        let beforePageID = beforePage?.identifier

        // Scope the gesture to the feed's actual vertical ScrollView. A swipe
        // synthesized on the app root can be routed to navigation chrome or a
        // nested control instead of the pager, producing a false paging failure.
        let pager = app.scrollViews.matching(identifier: "feed.forYou.pager").firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5),
                      "For You should expose its identified vertical paging scroll view.")
        // Use an explicit long drag rather than XCTest's device-dependent swipeUp
        // heuristic. On iPad the synthesized swipe can be too short to cross a
        // full-page paging threshold even though the scroll view is hittable.
        let dragStart = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        let dragEnd = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        print("UI EVALUATOR: pager=\(pager.frame) app=\(app.frame) before=\(beforePageID ?? "nil")")

        // Poll the visible page directly instead of XCTest's app-idle
        // expectation, which can time out while SwiftUI is settling the
        // scroll animation even though the swipe gesture was delivered.
        let pageDeadline = Date().addingTimeInterval(8)
        var didAdvance = false
        while Date() < pageDeadline {
            didAdvance = pages.allElementsBoundByIndex.contains {
                $0.frame.intersects(app.frame) && $0.identifier != beforePageID
            }
            if didAdvance { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(didAdvance, "Swiping up should settle on a different game page.")

        // Emit a deterministic 0–100 score for each simulator profile. Hard
        // assertions above still fail the job; the score makes regressions
        // comparable between iPhone and iPad runs.
        let score = (hasSwipeCue ? 10 : 0) + touchTargetsPassed * 15 +
            (pages.count >= 2 ? 15 : 0) + (didAdvance ? 15 : 0)
        print("UI_EVALUATOR_SCORE device=\(UIDevice.current.userInterfaceIdiom) score=\(score)/100 touch_targets=\(touchTargetsPassed)/4 pages=\(pages.count) swipe_advanced=\(didAdvance)")

        let afterSwipe = XCTAttachment(screenshot: app.screenshot())
        afterSwipe.name = "feed-ui-evaluator-after-swipe"
        afterSwipe.lifetime = .keepAlways
        add(afterSwipe)
    }

}
