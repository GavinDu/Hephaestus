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

        // A web view appearing is not evidence that its navigation has finished.
        // The previous fixed six-second sleep captured a still-loading sheet
        // while the smoke test reported success. Wait for the *actual* loading
        // overlay to disappear, fail on an actionable retry state, and retain
        // the failure screenshot through tearDownWithError when either happens.
        let loading = app.staticTexts["player.loading"].firstMatch
        let failed = app.buttons["player.retry"].firstMatch
        let navigationDeadline = Date().addingTimeInterval(90)
        while loading.exists && !failed.exists && Date() < navigationDeadline {
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertFalse(failed.exists,
                       "Player entered a recoverable failure instead of loading its game. UI: \\(app.debugDescription)")
        XCTAssertFalse(loading.exists,
                       "Player remained on the loading overlay for 90 seconds. UI: \\(app.debugDescription)")
        // This certifies native navigation/overlay readiness, not a verified
        // in-game win or first-render frame. Browser playtest owns that gate.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "player-after-boot"
        shot.lifetime = .keepAlways
        add(shot)
    }


    /// Open a genuine creator from a published feed game, then capture
    /// its server-backed game counts and profile layout. Never inject
    /// invented profile numbers or avatars for screenshot convenience.
    @MainActor
    func testArcadePulseCreatorProfileRendersLiveData() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        self.app = app
        app.launch()
        let creator = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "View profile for ")).firstMatch
        let retry = app.buttons["Try again"].firstMatch
        let until = Date().addingTimeInterval(120)
        while !creator.exists && Date() < until {
            if retry.waitForExistence(timeout: 4) { retry.tap() }
            _ = creator.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(creator.exists,
                      "The live published game must provide a real creator identity.")
        creator.tap()
        let header = app.descendants(matching: .any)["creator.profile.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 30),
                      "Creator profile must render server-backed identity and metrics.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "arcade-pulse-creator-profile"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.exists && done.isHittable)
        done.tap()
        XCTAssertTrue(app.buttons["game.play"].firstMatch.waitForExistence(timeout: 10),
                      "Closing creator profile must preserve the playable feed.")
    }

    /// Prove the actual Create screen, not a marketing concept, exposes
    /// a reachable photo picker and blocks upload before consent and art.
    @MainActor
    func testArcadePulseCreateEntryConsentAndControls() throws {
        let app = XCUIApplication()
        self.app = app
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        // Capture the actual iPad Create destination without bypassing any
        // permission, upload or game-generation actions.
        if isPad { app.launchArguments.append("--ui-test-create-entry") }
        app.launch()
        if !isPad {
            let createTab = app.tabBars.buttons["Create"].firstMatch
            XCTAssertTrue(createTab.waitForExistence(timeout: 15),
                          "Create must remain a visible native app tab.")
            createTab.tap()
        }
        let hero = app.descendants(matching: .any)["create.pick.hero"].firstMatch
        let choose = app.descendants(matching: .any)["create.pick.chooseDrawing"].firstMatch
        let consent = app.switches["create.sourceConsent"].firstMatch
        let analyze = app.buttons["create.pick.analyze"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10))
        XCTAssertTrue(choose.exists && choose.isHittable)
        XCTAssertTrue(consent.exists && consent.isHittable)
        XCTAssertTrue(analyze.exists && !analyze.isEnabled,
                      "Analyze must stay disabled until artwork and source consent exist.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = isPad ? "arcade-pulse-create-entry-ipad" : "arcade-pulse-create-entry-iphone"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Verify the real saved/recent game library remains reachable through
    /// native tabs and preserves truthful empty/network states.
    @MainActor
    func testArcadePulseLibraryNavigation() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("iPad uses the adaptive NavigationSplitView sidebar.")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        self.app = app
        app.launch()
        let libraryTab = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 15))
        libraryTab.tap()
        let library = app.descendants(matching: .any)["library.arcadePulse"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10),
                      "Saved/recent Library should be a real navigable Arcade Pulse surface.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "arcade-pulse-library-iphone"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let discover = app.tabBars.buttons["Discover"].firstMatch
        XCTAssertTrue(discover.exists && discover.isHittable,
                      "Native tab navigation must remain reachable.")
        discover.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10),
                      "Returning from Library must restore the Discover navigation stack.")
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

            if !expectedLandscape && UIDevice.current.userInterfaceIdiom == .phone {
                let portraitScopeMenu = app.descendants(matching: .any)["feed.scope.menu"].firstMatch
                XCTAssertTrue(portraitScopeMenu.waitForExistence(timeout: 5),
                              "Arcade Pulse portrait should reclaim feed space without hiding For You/Following/Friends.")
                XCTAssertTrue(portraitScopeMenu.isHittable,
                              "Portrait feed-scope menu must remain reachable after removing the permanent picker.")
            }
            if expectedLandscape && UIDevice.current.userInterfaceIdiom == .phone {
                let scopeMenu = app.descendants(matching: .any)["feed.landscape.scope"].firstMatch
                let searchButton = app.descendants(matching: .any)["feed.landscape.search"].firstMatch
                let moreMenu = app.descendants(matching: .any)["feed.landscape.more"].firstMatch
                XCTAssertTrue(scopeMenu.waitForExistence(timeout: 5),
                              "Compact landscape needs its overlaid social-feed scope menu.")
                XCTAssertTrue(scopeMenu.isHittable,
                              "Landscape feed-scope switcher must remain reachable.")
                XCTAssertTrue(searchButton.waitForExistence(timeout: 5) && searchButton.isHittable,
                              "Landscape search must stay available after hiding navigation chrome.")
                XCTAssertTrue(moreMenu.waitForExistence(timeout: 5) && moreMenu.isHittable,
                              "Feed preferences, creators and refresh must stay reachable.")
                let visiblePager = app.scrollViews.firstMatch
                XCTAssertTrue(visiblePager.waitForExistence(timeout: 5))
                let ratio = visiblePager.frame.height / max(app.frame.height, 1)
                print("UI_EVALUATOR_COMPACT_LANDSCAPE_PAGE viewport_ratio=\(ratio) pager_height=\(visiblePager.frame.height) app_height=\(app.frame.height) scope_menu_hittable=\(scopeMenu.isHittable)")
                XCTAssertGreaterThan(ratio, 0.60,
                                     "The playable page should occupy over 60% of the landscape app height.")
            }

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
                // SwiftUI may attach a container accessibility identifier to
                // a child button, so rail.frame can describe only one 58pt
                // button, not the whole VStack. Measure the actual interactive
                // buttons and their alignment/CTA separation instead.
                let saveFrame = app.buttons["Save game"].firstMatch.frame
                let likeFrame = app.buttons["Like game"].firstMatch.frame
                let commentFrame = app.buttons["View comments"].firstMatch.frame
                for frame in [saveFrame, likeFrame, commentFrame] {
                    XCTAssertGreaterThanOrEqual(frame.height, 48,
                                                "Portrait action captions should retain tall, tappable buttons.")
                    XCTAssertGreaterThanOrEqual(frame.width, 44,
                                                "Portrait action captions should retain 44pt minimum width.")
                }
                XCTAssertLessThanOrEqual(play.frame.maxX,
                                         min(saveFrame.minX, min(likeFrame.minX, commentFrame.minX)) + 4,
                                         "The portrait action rail must not cover the primary Play CTA.")
                XCTAssertLessThan(abs(saveFrame.midX - likeFrame.midX), 4,
                                  "Portrait social actions should align vertically.")
                XCTAssertGreaterThan(abs(saveFrame.midY - likeFrame.midY), 40,
                                     "Portrait rail targets should not overlap.")
            }

            // An interaction score of 100 never means a playable poster
            // or approved clip exists. Audit the actual settled media surface
            // separately using its live accessibility label; "poster" here
            // means the native AsyncImage rendered, NOT a media-approval
            // or screenshot-pixel-quality certification.
            let mediaSurface = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed.preview.media."))
                .firstMatch
            let mediaLabel = mediaSurface.exists ? mediaSurface.label : ""
            let mediaReadiness: String
            if mediaLabel.hasPrefix("Gameplay preview not available for ") {
                mediaReadiness = "placeholder"
            } else if mediaLabel.hasPrefix("Game artwork or preview for ") {
                mediaReadiness = "poster_displayed_unverified"
            } else {
                mediaReadiness = "unmeasured"
            }
            print("UI_EVALUATOR_VISUAL_AUDIT orientation=\(profile.1) media=\(mediaReadiness) label=\(mediaLabel) interaction_score_is_not_visual_approval=true")

            let beforeCapture = app.screenshot()
            // Landscape xcresult exports have shown sideways feed chrome and a
            // large black region even while the swipe evaluator scores 100.
            // Retain a separate full-screen capture to distinguish an
            // app-window screenshot/export issue from native rendering.
            // Never replace or silently rotate the original app capture.
            if expectedLandscape {
                let fullScreen = XCUIScreen.main.screenshot()
                let fullScreenAttachment = XCTAttachment(screenshot: fullScreen)
                fullScreenAttachment.name = "feed-full-screen-before-swipe-landscape"
                fullScreenAttachment.lifetime = .keepAlways
                add(fullScreenAttachment)
                let appImageWidth = beforeCapture.image.cgImage?.width ?? 0
                let appImageHeight = beforeCapture.image.cgImage?.height ?? 0
                let fullScreenWidth = fullScreen.image.cgImage?.width ?? 0
                let fullScreenHeight = fullScreen.image.cgImage?.height ?? 0
                print("UI_EVALUATOR_LANDSCAPE_CAPTURE app_px=\(appImageWidth)x\(appImageHeight) screen_px=\(fullScreenWidth)x\(fullScreenHeight) app_frame=\(app.frame)")
                // Report the simulator snapshot-orientation mismatch
                // explicitly instead of letting a passing swipe score hide
                // a sideways/black screenshot. Preserve the ORIGINAL full
                // screen and app-window attachments for review.
                let rawStorageAspectMismatch = appImageWidth > appImageHeight &&
                    fullScreenWidth < fullScreenHeight
                // Raw pixel dimensions do not account for PNG eXIf/TIFF
                // orientation. The CI artifact verifier validates actual
                // displayed geometry and keeps every original attachment.
                print("UI_EVALUATOR_SCREENSHOT_ORIENTATION orientation=landscape app_raw_wider=\(appImageWidth > appImageHeight) screen_raw_wider=\(fullScreenWidth > fullScreenHeight) raw_storage_aspect_mismatch=\(rawStorageAspectMismatch) display_orientation_requires_exif=true raw_attachments_kept=true")
            }
            let beforeSwipe = XCTAttachment(screenshot: beforeCapture)
            beforeSwipe.name = "feed-ui-evaluator-before-swipe-\(profile.1)"
            beforeSwipe.lifetime = .keepAlways
            add(beforeSwipe)

            let pages = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed.page.title."))
            // The renderer now materializes ONLY the selected game; a
            // LazyVStack of several cards produced the verified landscape
            // bleed. Require the backend-backed total count separately so
            // one visible card cannot silently mask an untestable one-game feed.
            let pager = app.scrollViews["feed.forYou.pager"].firstMatch
            XCTAssertTrue(pager.waitForExistence(timeout: 5),
                          "For You should expose its accessible \(profile.1) swipe viewport.")
            let pageStatus = pager.value as? String ?? ""
            print("UI_EVALUATOR_PAGER_VALUE_BEFORE orientation=\(profile.1) value=\(pageStatus)")
            let totalGames = Int(pageStatus.split(separator: " ").last ?? "") ?? 0
            XCTAssertGreaterThanOrEqual(totalGames, 2,
                                         "The real For You feed needs at least two games to verify paging; status=\(pageStatus).")
            XCTAssertEqual(pages.count, 1,
                           "Only the settled game page may enter the accessibility tree in \(profile.1).")
            let pagerFrame = pager.frame
            // Swiping correctly does not excuse an undersized visual stage.
            // Geometry is checked separately from actual preview-media provenance.
            XCTAssertTrue(mediaSurface.exists,
                          "Arcade Pulse needs a media surface even when approved previews are unavailable.")
            let mediaFrame = mediaSurface.frame
            let visibleMedia = mediaFrame.intersection(pagerFrame)
            let pagerArea = max(1, pagerFrame.width * pagerFrame.height)
            let mediaOccupancy = visibleMedia.isNull ? 0 :
                max(0, visibleMedia.width * visibleMedia.height) / pagerArea
            print("UI_EVALUATOR_MEDIA_OCCUPANCY orientation=\(profile.1) ratio=\(mediaOccupancy) media_frame=\(mediaFrame) pager_frame=\(pagerFrame) preview_status=\(mediaReadiness)")
            XCTAssertGreaterThanOrEqual(mediaOccupancy, 0.55,
                "Arcade Pulse must devote 55% of its visible pager to the media stage; do not weaken this to hide a compact-layout defect.")
            let visiblePages = pages.allElementsBoundByIndex.filter {
                let frame = $0.frame
                // SwiftUI may report the layout frame for the next card
                // even though the ScrollView visually clips it. Combine
                // viewport intersection with native on-screen hit testing,
                // rather than accepting the offscreen accessibility node.
                return frame.width > 0 && frame.height > 0 &&
                    frame.intersects(pagerFrame) && $0.isHittable
            }
            let beforePage = visiblePages.first
            XCTAssertNotNil(beforePage, "The current \(profile.1) feed title should intersect the pager viewport.")
            let beforePageID = beforePage?.identifier
            if expectedLandscape && UIDevice.current.userInterfaceIdiom == .phone {
                XCTAssertEqual(visiblePages.count, 1,
                    "Exactly one game title must intersect the compact landscape pager before swipe; overlapping adjacent cards invalidate screenshot quality.")
                let tabs = app.tabBars.firstMatch
                if tabs.exists {
                    XCTAssertLessThanOrEqual(play.frame.maxY, tabs.frame.minY + 1,
                        "The landscape Play CTA must not be obscured by bottom navigation.")
                }
            }
            print("UI EVALUATOR pager frame orientation=\(profile.1): \(pagerFrame)")
            if expectedLandscape {
                // A one-card, scroll-disabled pager is driven by its own
                // DragGesture, not the UIScrollView's content scrolling.
                // Use a real touch trace inside its content area in compact
                // landscape, where XCTest's generic scroll gesture may be
                // routed to the disabled scroll view and never reach the card.
                // Only a changed LIVE game identity may pass the gate.
                let start = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.82))
                let end = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.18))
                print("UI_EVALUATOR_PHYSICAL_DRAG orientation=landscape start=0.50,0.82 end=0.50,0.18")
                start.press(forDuration: 0.1, thenDragTo: end)
            } else {
                pager.swipeUp()
            }

            // A title merely intersecting app.frame can be a neighbor under
            // the tab bar, and the accessibility tree may be sampled while
            // a SwiftUI scroll transition is still settling. Require a NEW
            // single hittable title inside the actual scroll viewport twice
            // consecutively, not a momentary offscreen element.
            let pageDeadline = Date().addingTimeInterval(20)
            var didAdvance = false
            var candidateID: String?
            var stableSamples = 0
            var latestVisibleIDs: [String] = []
            while Date() < pageDeadline {
                let visible = pages.allElementsBoundByIndex.filter {
                    let frame = $0.frame
                    return frame.width > 0 && frame.height > 0 &&
                        frame.intersects(pager.frame) && $0.isHittable
                }
                latestVisibleIDs = visible.map(\.identifier)
                if visible.count == 1, let newID = latestVisibleIDs.first,
                    newID != beforePageID {
                    stableSamples = candidateID == newID ? stableSamples + 1 : 1
                    candidateID = newID
                    if stableSamples >= 2 {
                        didAdvance = true
                        break
                    }
                } else {
                    candidateID = nil
                    stableSamples = 0
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
            print("UI_EVALUATOR_SETTLED orientation=\(profile.1) before=\(beforePageID ?? "none") after=\(latestVisibleIDs) stable_samples=\(stableSamples)")
            print("UI_EVALUATOR_PAGER_VALUE_AFTER orientation=\(profile.1) value=\(pager.value as? String ?? "missing")")
            if !didAdvance {
                // Preserve the ORIGINAL simulator screen, even when the
                // geometry assertion fails. A failed screenshot is an input
                // to review, never a passing/approved media sample.
                let failedScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                failedScreen.name = "feed-full-screen-unsettled-after-swipe-\(profile.1)"
                failedScreen.lifetime = .keepAlways
                add(failedScreen)
            }
            XCTAssertTrue(didAdvance,
                          "Swipe must settle on exactly one NEW hittable page inside the \(profile.1) pager viewport; observed \(latestVisibleIDs).")
            if expectedLandscape && UIDevice.current.userInterfaceIdiom == .phone {
                XCTAssertEqual(latestVisibleIDs.count, 1,
                    "Compact landscape must have one settled card after swipe.")
            }

            let score = (hasSwipeCue ? 10 : 0) + touchTargetsPassed * 15 +
                (totalGames >= 2 ? 15 : 0) + (didAdvance ? 15 : 0)
            print("UI_EVALUATOR_SCORE device=\(UIDevice.current.userInterfaceIdiom) orientation=\(profile.1) score=\(score)/100 touch_targets=\(touchTargetsPassed)/4 games=\(totalGames) visible_pages=\(pages.count) swipe_advanced=\(didAdvance)")

            let afterCapture = app.screenshot()
            if expectedLandscape {
                let fullScreenAfter = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                fullScreenAfter.name = "feed-full-screen-after-swipe-landscape"
                fullScreenAfter.lifetime = .keepAlways
                add(fullScreenAfter)
            }
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
        let pendingRetry = app.buttons["feed.retryLoading"].firstMatch
        let startedLoading = Date()
        let feedDeadline = startedLoading.addingTimeInterval(120)
        var pendingRetryUsed = false
        while !play.exists && Date() < feedDeadline {
            if retry.waitForExistence(timeout: 4) {
                print("UI EVALUATOR ACCESSIBILITY: feed error; retrying live backend")
                retry.tap()
            } else if !pendingRetryUsed &&
                        Date().timeIntervalSince(startedLoading) > 40 &&
                        pendingRetry.exists {
                // Accessible XXXL can remain in a pending loading skeleton
                // after the backend has warmed. This is a REAL, user-visible
                // Retry loading control, not a test fixture or mocked feed.
                // Use a bounded coordinate tap to survive the button leaving
                // the view during its dismissal animation.
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
                    print("UI EVALUATOR ACCESSIBILITY: retry stalled live feed once at XXL/XXXL")
                    point.tap()
                }
            }
            _ = play.waitForExistence(timeout: 4)
        }
        if !play.exists {
            print("UI_EVALUATOR_ACCESSIBILITY_FEED_FAILURE retry_loading_used=\(pendingRetryUsed) pending=\(pendingRetry.exists) error=\(retry.exists)")
            let failedCapture = XCTAttachment(screenshot: app.screenshot())
            failedCapture.name = "feed-accessibility-xxxl-live-loading-failed"
            failedCapture.lifetime = .keepAlways
            add(failedCapture)
        }
        XCTAssertTrue(play.exists,
                      "The feed should remain playable at accessibility text size after bounded live retry. UI: \(app.debugDescription)")

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
