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
        XCTAssertTrue(play.waitForExistence(timeout: 120),
                      "For You should expose a playable feed page. UI: \\(app.debugDescription)")

        let swipeCue = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "SWIPE TO EXPLORE"))
            .firstMatch
        XCTAssertTrue(swipeCue.waitForExistence(timeout: 10),
                      "The feed should communicate its vertical swipe interaction.")

        func assertTouchTarget(_ element: XCUIElement, named name: String) {
            XCTAssertTrue(element.exists, "\\(name) should be present on the feed page.")
            guard element.exists else { return }
            let frame = element.frame
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\\(name) should be at least 44pt wide.")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\\(name) should be at least 44pt tall.")
            XCTAssertTrue(element.isHittable, "\\(name) should be reachable without scrolling.")
        }

        assertTouchTarget(play, named: "Play")
        assertTouchTarget(app.buttons["Save game"], named: "Save")
        assertTouchTarget(app.buttons["Like game"], named: "Like")
        assertTouchTarget(app.buttons["View comments"], named: "Comments")

        let beforeSwipe = XCTAttachment(screenshot: app.screenshot())
        beforeSwipe.name = "feed-ui-evaluator-before-swipe"
        beforeSwipe.lifetime = .keepAlways
        add(beforeSwipe)

        // Exercise the primary browsing gesture and ensure the feed remains
        // interactive after the transition. This is intentionally tolerant
        // of a one-item live feed, where the current page remains selected.
        app.swipeUp()
        XCTAssertTrue(play.waitForExistence(timeout: 10),
                      "The feed should remain playable after a vertical swipe.")

        let afterSwipe = XCTAttachment(screenshot: app.screenshot())
        afterSwipe.name = "feed-ui-evaluator-after-swipe"
        afterSwipe.lifetime = .keepAlways
        add(afterSwipe)
    }

}
