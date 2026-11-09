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
        XCUIDevice.shared.orientation = .portrait
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


    /// Downsample two captured screenshots and report the fraction of
    /// pixels whose RGB distance exceeds a small threshold. The evaluator
    /// uses this as a visual evidence signal alongside semantic page IDs.
    private func screenshotDifferenceRatio(_ first: UIImage, _ second: UIImage) -> Double? {
        func pixels(_ image: UIImage) -> [UInt8]? {
            guard let cgImage = image.cgImage else { return nil }
            let width = 64
            let height = 64
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            var rendered = false
            bytes.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress,
                      let context = CGContext(
                        data: baseAddress,
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      ) else { return }
                context.interpolationQuality = .low
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                rendered = true
            }
            return rendered ? bytes : nil
        }

        guard let a = pixels(first), let b = pixels(second), a.count == b.count else {
            return nil
        }
        var changed = 0
        let pixelCount = a.count / 4
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            let distance = abs(Int(a[offset]) - Int(b[offset])) +
                abs(Int(a[offset + 1]) - Int(b[offset + 1])) +
                abs(Int(a[offset + 2]) - Int(b[offset + 2]))
            if distance > 36 { changed += 1 }
        }
        return Double(changed) / Double(pixelCount)
    }

    /// Evaluate the native feed on both phone/tablet size classes and both
    /// orientations. Each profile launches from the first page so a swipe must
    /// prove a real page transition rather than inheriting a previous scroll.
    @MainActor
    func testDiscoverFeedUIEvaluationAndSwipe() throws {
        let app = XCUIApplication()
        self.app = app
        let profiles: [(UIDeviceOrientation, String)] = [
            (.portrait, "portrait"),
            (.landscapeLeft, "landscape")
        ]

        for (index, profile) in profiles.enumerated() {
            if index > 0 {
                app.terminate()
            }
            XCUIDevice.shared.orientation = profile.0
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15),
                          "The app should launch for the \(profile.1) feed evaluation.")

            let expectedLandscape = profile.1 == "landscape"
            XCTAssertEqual(app.frame.width > app.frame.height, expectedLandscape,
                           "The simulator viewport should actually be \(profile.1).")

            // Landscape on iPad may restore the NavigationSplitView sidebar
            // while Discover remains in a loading skeleton.  Keep the
            // navigation explicit and expose the current state in CI logs.
            // Do not silently count a skeleton as a successful feed page.
            let discover = app.staticTexts["Discover"].firstMatch
            let play = app.buttons["game.play"].firstMatch
            // A fresh landscape launch already selects Discover. Re-tapping
            // an already visible sidebar row can recreate the detail view
            // and cancel the first live fetch; navigate only if the page
            // still has not appeared after its initial load window.
            if expectedLandscape && !play.waitForExistence(timeout: 10) &&
                discover.exists && discover.isHittable {
                print("UI EVALUATOR: landing page absent; explicitly opening Discover in landscape")
                discover.tap()
            }
            if UIDevice.current.userInterfaceIdiom == .pad && !expectedLandscape {
                // Portrait For You should not give away its initial viewport
                // to the persistent sidebar. Users can reveal it manually.
                let sidebarHeader = app.staticTexts["Your space"].firstMatch
                XCTAssertFalse(sidebarHeader.isHittable,
                               "iPad portrait must enter the detail-first swipe feed; sidebar remains user-toggleable.")
            }

            let retry = app.buttons["Try again"].firstMatch
            let pendingRetry = app.buttons["feed.retryLoading"].firstMatch
            let startedLoading = Date()
            let feedDeadline = startedLoading.addingTimeInterval(120)
            var pendingRetryUsed = false
            while !play.exists && Date() < feedDeadline {
                if retry.waitForExistence(timeout: 4) {
                    print("UI EVALUATOR: feed error in \(profile.1); retrying live backend")
                    retry.tap()
                } else if !pendingRetryUsed &&
                            Date().timeIntervalSince(startedLoading) > 40 &&
                            pendingRetry.exists {
                    // A network response can swap the skeleton for a real
                    // page between XCTest's isHittable query and tap(). In
                    // that case XCTest's element tap retries an element with
                    // an invalid {inf, inf} hit point and fails even though
                    // the live feed is recovering. Use a bounded snapshot
                    // coordinate instead: it remains valid if the button
                    // disappears during the animation. Do not call isHittable
                    // on this transient control: XCTest throws when its frame
                    // has an invalid activation point during dismissal.
                    // Never count a tap or
                    // synthetic page as a successful feed evaluation.
                    let frame = pendingRetry.frame
                    let bounds = app.frame
                    let valid = frame.origin.x.isFinite && frame.origin.y.isFinite &&
                        frame.width.isFinite && frame.height.isFinite &&
                        frame.width >= 44 && frame.height >= 44 &&
                        bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
                    if valid && !play.exists {
                        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                        let point = origin.withOffset(CGVector(
                            dx: frame.midX - bounds.minX,
                            dy: frame.midY - bounds.minY
                        ))
                        pendingRetryUsed = true
                        print("UI EVALUATOR: stalled skeleton in \(profile.1); tap stable retry coordinate")
                        point.tap()
                    } else {
                        print("UI EVALUATOR: retry button moved/vanished during transition; rechecking live feed")
                    }
                }
                _ = play.waitForExistence(timeout: 4)
            }
            if !play.exists {
                let loading = pendingRetry.exists
                let error = app.staticTexts["Couldn't load the feed"].firstMatch.exists
                print("UI_EVALUATOR_FEED_FAILURE orientation=\(profile.1) loading=\(loading) error=\(error) retry_attempted=\(pendingRetryUsed)")
                let failureScreenshot = XCTAttachment(screenshot: app.screenshot())
                failureScreenshot.name = "feed-live-backend-unavailable-\(profile.1)"
                failureScreenshot.lifetime = .keepAlways
                add(failureScreenshot)
            }
            XCTAssertTrue(play.exists,
                          "For You should expose a LIVE playable feed page in \(profile.1) after bounded retries, not a skeleton or fixture. UI: \(app.debugDescription)")
            // Scope captions must match the selected social feed; a Following
            // or Friends page must never claim it is the For You scope.
            let scopeCaption = app.staticTexts["feed.scope.caption"].firstMatch
            XCTAssertTrue(scopeCaption.waitForExistence(timeout: 5),
                          "The immersive feed should expose its visible scope caption.")
            XCTAssertEqual(scopeCaption.label, "FOR YOU",
                           "The default pager must identify the For You scope.")

            let swipeCue = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "SWIPE TO EXPLORE"))
                .firstMatch
            let hasSwipeCue = swipeCue.waitForExistence(timeout: 10)
            XCTAssertTrue(hasSwipeCue,
                          "The feed should communicate its vertical swipe interaction in \(profile.1).")

            @discardableResult
            func assertTouchTarget(_ element: XCUIElement, named name: String) -> Bool {
                XCTAssertTrue(element.exists, "\(name) should be present on the \(profile.1) feed page.")
                guard element.exists else { return false }
                let frame = element.frame
                let sized = frame.width >= 44 && frame.height >= 44
                XCTAssertGreaterThanOrEqual(frame.width, 44, "\(name) should be at least 44pt wide in \(profile.1).")
                XCTAssertGreaterThanOrEqual(frame.height, 44, "\(name) should be at least 44pt tall in \(profile.1).")
                let reachable = element.isHittable
                XCTAssertTrue(reachable, "\(name) should be reachable without scrolling in \(profile.1).")
                return sized && reachable
            }

            let touchTargetsPassed = [
                assertTouchTarget(play, named: "Play"),
                assertTouchTarget(app.buttons["Save game"].firstMatch, named: "Save"),
                assertTouchTarget(app.buttons["Like game"].firstMatch, named: "Like"),
                assertTouchTarget(app.buttons["View comments"].firstMatch, named: "Comments")
            ].filter { $0 }.count

            if !expectedLandscape {
                let rail = app.descendants(matching: .any)["feed.actionRail"].firstMatch
                XCTAssertTrue(rail.exists, "Portrait feed should expose the social action rail.")
                XCTAssertGreaterThanOrEqual(rail.frame.width, 56,
                                            "Portrait rail should have room for labeled actions, not clipped icons.")
                XCTAssertGreaterThanOrEqual(rail.frame.height, 290,
                                            "Portrait rail should show short action captions beneath its buttons.")
                XCTAssertLessThanOrEqual(play.frame.maxX, rail.frame.minX + 4,
                                         "The portrait action rail must not cover the primary Play CTA.")
                let saveFrame = app.buttons["Save game"].firstMatch.frame
                let likeFrame = app.buttons["Like game"].firstMatch.frame
                XCTAssertLessThan(abs(saveFrame.midX - likeFrame.midX), 4,
                                  "Portrait social actions should align vertically.")
                XCTAssertGreaterThan(abs(saveFrame.midY - likeFrame.midY), 40,
                                     "Portrait rail targets should not overlap.")
            }

            let beforeCapture = app.screenshot()
            let beforeSwipe = XCTAttachment(screenshot: beforeCapture)
            beforeSwipe.name = "feed-ui-evaluator-before-swipe-\(profile.1)"
            beforeSwipe.lifetime = .keepAlways
            add(beforeSwipe)

            let pages = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed.page.title."))
            XCTAssertGreaterThanOrEqual(pages.count, 2,
                                        "The UI evaluator needs at least two feed pages in \(profile.1) to verify paging.")

            // SwiftUI title nodes can have invalid activation points even
            // while their page is rendered. Use viewport intersection.
            let visiblePages = pages.allElementsBoundByIndex.filter {
                $0.frame.intersects(app.frame)
            }
            let beforePage = visiblePages.first
            XCTAssertNotNil(beforePage, "The current \(profile.1) feed page should intersect the app viewport.")
            let beforePageID = beforePage?.identifier

            // Scope the swipe to the first scroll view in the feed hierarchy;
            // the custom identifier is not consistently surfaced by XCTest.
            let pager = app.scrollViews.firstMatch
            XCTAssertTrue(pager.waitForExistence(timeout: 5),
                          "For You should expose a scrollable \(profile.1) feed viewport.")
            print("UI EVALUATOR pager frame orientation=\(profile.1): \(pager.frame)")
            pager.swipeUp()

            let pageDeadline = Date().addingTimeInterval(8)
            var didAdvance = false
            while Date() < pageDeadline {
                didAdvance = pages.allElementsBoundByIndex.contains {
                    $0.frame.intersects(app.frame) && $0.identifier != beforePageID
                }
                if didAdvance { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
            XCTAssertTrue(didAdvance,
                          "Swiping up should settle on a different game page in \(profile.1).")

            let score = (hasSwipeCue ? 10 : 0) + touchTargetsPassed * 15 +
                (pages.count >= 2 ? 15 : 0) + (didAdvance ? 15 : 0)
            print("UI_EVALUATOR_SCORE device=\(UIDevice.current.userInterfaceIdiom) orientation=\(profile.1) score=\(score)/100 touch_targets=\(touchTargetsPassed)/4 pages=\(pages.count) swipe_advanced=\(didAdvance)")

            let afterCapture = app.screenshot()
            let afterSwipe = XCTAttachment(screenshot: afterCapture)
            afterSwipe.name = "feed-ui-evaluator-after-swipe-\(profile.1)"
            afterSwipe.lifetime = .keepAlways
            add(afterSwipe)

            // Treat the captured screenshots as evaluator inputs, not just
            // attachments: a successful page transition must produce a
            // measurable visual change in the rendered feed viewport.
            let visualDelta = screenshotDifferenceRatio(beforeCapture.image, afterCapture.image)
            XCTAssertNotNil(visualDelta,
                            "The \(profile.1) evaluator screenshots should be decodable.")
            XCTAssertGreaterThan(visualDelta ?? 0, 0.005,
                                 "The feed should visibly change after paging in \(profile.1).")
            print("UI_EVALUATOR_SCREENSHOT device=\(UIDevice.current.userInterfaceIdiom) orientation=\(profile.1) changed_pixel_ratio=\(String(format: "%.4f", visualDelta ?? 0))")
        }

        XCUIDevice.shared.orientation = .portrait
    }

    /// Large accessibility text must not push the primary feed actions off-screen
    /// or make the Play/Save/Like/Comments targets unreachable.
    @MainActor
    func testDiscoverFeedSupportsAccessibilityDynamicType() throws {
        let app = XCUIApplication()
        self.app = app
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        let play = app.buttons["game.play"].firstMatch
        let retry = app.buttons["Try again"].firstMatch
        let feedDeadline = Date().addingTimeInterval(120)
        while !play.exists && Date() < feedDeadline {
            if retry.waitForExistence(timeout: 5) {
                retry.tap()
            }
            _ = play.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(play.exists,
                      "The feed should remain playable at accessibility text size. UI: \(app.debugDescription)")

        let targets: [(String, XCUIElement)] = [
            ("Play", play),
            ("Save", app.buttons["Save game"].firstMatch),
            ("Like", app.buttons["Like game"].firstMatch),
            ("Comments", app.buttons["View comments"].firstMatch)
        ]
        for (name, target) in targets {
            XCTAssertTrue(target.exists, "\(name) should remain present at accessibility text size.")
            guard target.exists else { continue }
            XCTAssertGreaterThanOrEqual(target.frame.width, 44,
                                        "\(name) should remain at least 44pt wide.")
            XCTAssertGreaterThanOrEqual(target.frame.height, 44,
                                        "\(name) should remain at least 44pt tall.")
            XCTAssertTrue(target.isHittable,
                          "\(name) should remain reachable at accessibility text size.")
        }

        // The previous screenshot had a Play button that remained tappable
        // while oversized decorative hints, title, and the bottom tab bar
        // visually collided. Gate actual element geometry, not only existence.
        let visibleTitles = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "feed.page.title."))
        if let title = visibleTitles.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            XCTAssertLessThanOrEqual(title.frame.maxY, play.frame.minY + 1,
                                     "Large type title must not cover the Play CTA.")
        }
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            XCTAssertLessThanOrEqual(play.frame.maxY, tabBar.frame.minY + 1,
                                     "Large type Play CTA must remain above bottom navigation.")
        }
        print("UI_EVALUATOR_ACCESSIBILITY_GEOMETRY play=\(play.frame) tabs=\(tabBar.exists ? String(describing: tabBar.frame) : "none")")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "feed-accessibility-dynamic-type-xxxl"
        shot.lifetime = .keepAlways
        add(shot)
        print("UI_EVALUATOR_ACCESSIBILITY dynamic_type=accessibility-xxxl primary_targets=4")
    }
}
