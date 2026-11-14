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
        // The feed has separate accessible retry affordances for an
        // unsuccessful request and an in-progress request that stalls.
        // The previous test only searched for the obsolete "Try again"
        // label and therefore never exercised the actual Retry loading
        // button visible in the failing native screenshot.
        let retries = [
            app.descendants(matching: .any)["feed.retryLoading"].firstMatch,
            app.descendants(matching: .any)["Retry loading"].firstMatch,
            app.buttons["Try again"].firstMatch,
            app.buttons["Refresh games"].firstMatch
        ]
        // URLSession may need up to two 30-second transport windows during a
        // cold worker start. Retrying every 15 seconds cancelled each in-flight
        // request before it could complete and manufactured a stuck spinner.
        // Keep the smoke strict: always require a real playable card and fail
        // after a bounded deadline rather than substituting a mock game.
        let feedDeadline = Date().addingTimeInterval(150)
        var lastRetry = Date()
        while !play.exists && Date() < feedDeadline {
            // A completed failed request can be retried immediately. While a
            // request is in flight, allow the fetch + network retry to finish
            // before cancelling it with the "Retry loading" action.
            let failedRequest = app.buttons["Try again"].firstMatch
            let hasError = failedRequest.exists && failedRequest.isEnabled
            if hasError || Date().timeIntervalSince(lastRetry) >= 65 {
                // XCTest can throw while evaluating isHittable for a loading
                // accessibility button whose frame is temporarily invalid.
                // Inspect geometry before tapping and preserve screenshot
                // failure evidence when no playable post arrives.
                for retry in retries where retry.exists && retry.isEnabled {
                    let frame = retry.frame
                    guard !frame.isNull, !frame.isEmpty,
                          frame.width.isFinite, frame.height.isFinite,
                          frame.midX.isFinite, frame.midY.isFinite,
                          app.frame.intersects(frame) else { continue }
                    print("SMOKE: retrying real live feed via \(retry.label)")
                    retry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    lastRetry = Date()
                    break
                }
            }
            _ = play.waitForExistence(timeout: 5)
        }
        if !play.exists {
            // A failed live backend must still FAIL the player smoke. Check
            // that its honest recovery screen lets the user reach Library,
            // attach the original failure view and leave the gate red.
            let libraryRecovery = app.buttons["feed.error.library"].firstMatch
            if libraryRecovery.exists {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "arcade-pulse-live-feed-unavailable-with-library-recovery"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                XCTAssertTrue(libraryRecovery.isHittable,
                              "The offline Library escape must be accessible on-screen.")
                XCTAssertGreaterThanOrEqual(libraryRecovery.frame.height, 44)
                libraryRecovery.tap()
                let library = app.descendants(matching: .any)["library.arcadePulse"].firstMatch
                XCTAssertTrue(library.waitForExistence(timeout: 10),
                              "The feed recovery action must navigate to the real Library.")
                XCTFail("Live backend did not supply a playable feed; Library fallback verified, but player smoke still fails.")
                return
            }
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
        // The initial iPhone viewport must show the *entire* source-upload
        // disclosure before an upload decision; a visible switch alone is
        // insufficient when the tab bar obscures the explanatory copy.
        let disclosure = app.staticTexts["create.sourceConsent.disclosure"].firstMatch
        XCTAssertTrue(disclosure.exists && disclosure.isHittable,
                      "Source upload disclosure must be readable without scrolling.")
        if !isPad {
            let tabBar = app.tabBars.firstMatch
            XCTAssertTrue(tabBar.exists)
            XCTAssertLessThanOrEqual(disclosure.frame.maxY, tabBar.frame.minY - 4,
                                     "Source consent disclosure must not overlap the iPhone tab bar.")
        }
        XCTAssertTrue(analyze.exists && !analyze.isEnabled,
                      "Analyze must stay disabled until artwork and source consent exist.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = isPad ? "arcade-pulse-create-entry-ipad" : "arcade-pulse-create-entry-iphone"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        if !isPad {
            let projects = app.buttons["create.myProjects"].firstMatch
            XCTAssertTrue(projects.waitForExistence(timeout: 10) && projects.isHittable,
                          "Compact Create must expose an accessible My projects entry.")
            XCTAssertGreaterThanOrEqual(projects.frame.height, 44)
            projects.tap()
            let studio = app.descendants(matching: .any)["studio.arcadePulse.root"].firstMatch
            XCTAssertTrue(studio.waitForExistence(timeout: 10),
                          "My projects must open the real owner-only Studio, not a dead CTA.")
            let evidence = XCTAttachment(screenshot: app.screenshot())
            evidence.name = "arcade-pulse-iphone-studio-signed-out"
            evidence.lifetime = .keepAlways
            add(evidence)
            let signIn = app.buttons["studio.openProfile"].firstMatch
            XCTAssertTrue(signIn.waitForExistence(timeout: 5) && signIn.isHittable)
            signIn.tap()
            XCTAssertTrue(app.buttons["Sign in with Apple"].firstMatch.waitForExistence(timeout: 10),
                          "Studio must return to the real Profile authentication entry.")
        }
    }

    /// The preferences modal may not claim a successful write until the
    /// backend confirms. Simulate a failed write without changing any user
    /// settings or generating fictitious game/creator data.
    @MainActor
    func testArcadePulseFeedPreferencesFailureStaysEditable() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        self.app = app
        app.launchArguments.append("--ui-test-feed-preferences-failure-state")
        app.launch()
        let open = app.buttons["Tune feed recommendations"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15) && open.isHittable)
        open.tap()
        let title = app.navigationBars["Tune your feed"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let save = app.descendants(matching: .any)["feed.preferences.save"].firstMatch
        let reset = app.descendants(matching: .any)["feed.preferences.reset"].firstMatch
        XCTAssertTrue(save.exists && save.isHittable)
        XCTAssertGreaterThanOrEqual(save.frame.height, 44)
        save.tap()
        let error = app.descendants(matching: .any)["feed.preferences.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10),
                      "Failed preferences update must be visible inside the still-open sheet.")
        XCTAssertTrue(title.exists && save.isEnabled,
                      "Failure must preserve selections and permit a real retry.")
        let saveShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        saveShot.name = "arcade-pulse-feed-preferences-save-failed"
        saveShot.lifetime = .keepAlways
        add(saveShot)
        XCTAssertTrue(reset.exists && reset.isHittable)
        reset.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(title.exists,
                      "Reset failure cannot close the sheet or pretend preferences were cleared.")
        let resetShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        resetShot.name = "arcade-pulse-feed-preferences-reset-failed"
        resetShot.lifetime = .keepAlways
        add(resetShot)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.exists && done.isHittable)
        done.tap()
        XCTAssertFalse(title.waitForExistence(timeout: 2),
                       "Done must still dismiss the editable preferences sheet.")
    }

    /// The social write failure is display-only and deliberately injected
    /// AFTER a genuine backend feed appears. There is no fake post, no API
    /// mutation and no invented engagement count. Even on an available
    /// media stage the failed social action must be audible and dismissible.
    @MainActor
    func testArcadePulseSocialWriteFailureDoesNotHideLiveGame() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        self.app = app
        app.launchArguments.append("--ui-test-social-action-error-state")
        app.launch()
        let alert = app.alerts["Couldn't update this action"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 150),
                      "Only a real loaded feed may trigger social error-state evaluation.")
        let signedOutGuidance = alert.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Sign in from Profile")
        ).firstMatch
        let uncertainNetworkFailure = alert.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "couldn't be confirmed")
        ).firstMatch
        XCTAssertTrue(signedOutGuidance.exists || uncertainNetworkFailure.exists,
                      "Show actionable guest authentication guidance or an honest unconfirmed-write status; never claim the server changed nothing.")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "arcade-pulse-live-feed-social-action-error"
        shot.lifetime = .keepAlways
        add(shot)
        let dismiss = alert.buttons["OK"].firstMatch
        XCTAssertTrue(dismiss.exists && dismiss.isHittable)
        dismiss.tap()
        let play = app.buttons["game.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10) && play.isHittable,
                      "Dismissed social error must retain the same live playable feed.")
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "arcade-pulse-live-feed-after-social-error"
        after.lifetime = .keepAlways
        add(after)
    }

    /// This isolated error-state screenshot exercises real navigation without
    /// pretending the production feed returned a playable game. The separate
    /// testDiscoverLaunchesPlayer still requires the live backend to work.
    @MainActor
    func testArcadePulseFeedUnavailableRecoveryToLibrary() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        self.app = app
        app.launchArguments.append("--ui-test-feed-error-state")
        app.launch()

        let recovery = app.descendants(matching: .any)["feed.error.recovery"].firstMatch
        let retry = app.buttons["feed.error.retry"].firstMatch
        let library = app.buttons["feed.error.library"].firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 10),
                      "Network error must show a real and accessible recovery surface.")
        XCTAssertTrue(app.staticTexts[
            "The game service couldn't establish a secure connection. Check your network and try again."
        ].firstMatch.exists,
                      "The native recovery card must use plain language, not raw TLS jargon.")
        XCTAssertFalse(app.staticTexts[
            "A TLS error caused the secure connection to fail"
        ].firstMatch.exists,
                       "Do not expose raw TLS implementation text to users.")
        XCTAssertTrue(retry.exists && retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        XCTAssertTrue(library.exists && library.isHittable)
        XCTAssertGreaterThanOrEqual(library.frame.height, 44)
        let snapshot = XCTAttachment(screenshot: app.screenshot())
        snapshot.name = "arcade-pulse-feed-unavailable-recovery-portrait"
        snapshot.lifetime = .keepAlways
        add(snapshot)

        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(library.waitForExistence(timeout: 10) && library.isHittable,
                          "Recovery Library action must remain visible in iPad landscape.")
            XCTAssertGreaterThanOrEqual(library.frame.height, 44)
            let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            landscape.name = "arcade-pulse-feed-unavailable-recovery-ipad-landscape"
            landscape.lifetime = .keepAlways
            add(landscape)
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(library.waitForExistence(timeout: 10) && library.isHittable)
        }

        if UIDevice.current.userInterfaceIdiom == .phone {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(retry.waitForExistence(timeout: 10) && retry.isHittable,
                          "Compact iPhone landscape must retain the real Retry control.")
            XCTAssertTrue(library.waitForExistence(timeout: 10) && library.isHittable,
                          "Compact iPhone landscape must keep Library above the fold.")
            XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
            XCTAssertGreaterThanOrEqual(library.frame.height, 44)
            let tabs = app.tabBars.firstMatch
            XCTAssertTrue(tabs.exists, "iPhone landscape has persistent native tab navigation.")
            if tabs.exists {
                XCTAssertLessThan(retry.frame.maxY, tabs.frame.minY - 4,
                                  "Retry must appear ABOVE the persistent tab bar, not underneath it.")
                XCTAssertLessThan(library.frame.maxY, tabs.frame.minY - 4,
                                  "Open Library must be wholly visible ABOVE the tab bar.")
            }
            XCTAssertFalse(retry.frame.intersects(library.frame),
                           "Compact landscape recovery buttons must not overlap each other.")
            let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            landscape.name = "arcade-pulse-feed-unavailable-recovery-iphone-landscape"
            landscape.lifetime = .keepAlways
            add(landscape)
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(library.waitForExistence(timeout: 10) && library.isHittable)
        }

        library.tap()
        let destination = app.descendants(matching: .any)["library.arcadePulse"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10),
                      "Open Library must navigate to native Library; no fake offline game.")
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
        // When signed out, an account-owned saved list must offer a real
        // Profile route rather than a misleading empty collection.
        let signIn = app.buttons["library.signIn"].firstMatch
        // Clean native CI is signed out; fail if the real CTA is absent.
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        if signIn.exists {
            XCTAssertTrue(signIn.isHittable)
            XCTAssertGreaterThanOrEqual(signIn.frame.height, 44)
            signIn.tap()
            let profile = app.tabBars.buttons["Profile"].firstMatch
            XCTAssertTrue(profile.waitForExistence(timeout: 10) && profile.isSelected,
                          "Library sign-in must navigate to the real Profile tab.")
            libraryTab.tap()
            XCTAssertTrue(library.waitForExistence(timeout: 10))
        }
        let discover = app.tabBars.buttons["Discover"].firstMatch
        XCTAssertTrue(discover.exists && discover.isHittable,
                      "Native tab navigation must remain reachable.")
        discover.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10),
                      "Returning from Library must restore the Discover navigation stack.")
    }

    /// The final privacy notice must remain readable in the native iPhone
    /// Library list, not disappear under the translucent bottom tab bar.
    /// This exercises real guest/session UI; it injects no saved games.
    @MainActor
    func testArcadePulseLibraryPrivacyNoticeCanScrollAboveTabs() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("iPhone tab bar overlap regression.")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        self.app = app
        app.launch()
        let libraryTab = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 15))
        libraryTab.tap()
        let library = app.descendants(matching: .any)["library.arcadePulse"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        let footer = app.descendants(matching: .any)["library.privacyFooter"].firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 10),
                      "The Library must show truthful account/session privacy guidance.")
        let tabs = app.tabBars.firstMatch
        for _ in 0..<5 {
            if footer.isHittable && (!tabs.exists ||
               footer.frame.maxY <= tabs.frame.minY + 2) { break }
            app.swipeUp()
        }
        XCTAssertTrue(footer.isHittable,
                      "The privacy footer must be reachable by scrolling.")
        if tabs.exists {
            XCTAssertLessThanOrEqual(footer.frame.maxY, tabs.frame.minY + 2,
                                     "Privacy notice text must not hide beneath the bottom tabs.")
        }
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "arcade-pulse-library-privacy-footer-iphone"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    /// Open the actual saved/recent Library stage in iPad portrait and landscape.
    /// No account, mock saved items or successful API response is injected.
    @MainActor
    func testArcadePulseLibraryIPadAdaptiveLayout() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The expanded Library screenshot is iPad-only.")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        self.app = app
        app.launchArguments.append("--ui-test-library-entry")
        app.launch()
        let library = app.descendants(matching: .any)["library.arcadePulse"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 15),
                      "iPad Library must render in the adaptive detail stage.")
        let signIn = app.buttons["library.signIn"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 10),
                      "A clean unauthenticated simulator must show the real saved-game sign-in route.")
        XCTAssertTrue(signIn.isHittable)
        XCTAssertGreaterThanOrEqual(signIn.frame.height, 44)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "arcade-pulse-library-ipad-portrait"
        portrait.lifetime = .keepAlways
        add(portrait)

        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let orientationDeadline = Date().addingTimeInterval(10)
        while window.frame.width <= window.frame.height && Date() < orientationDeadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertGreaterThan(window.frame.width, window.frame.height,
                             "Capture must follow a completed landscape rotation.")
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertTrue(signIn.isHittable,
                      "iPad landscape Library sign-in must not be hidden by the sidebar.")
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "arcade-pulse-library-ipad-landscape"
        landscape.lifetime = .keepAlways
        add(landscape)

        signIn.tap()
        XCTAssertTrue(app.navigationBars["Profile"].firstMatch.waitForExistence(timeout: 10),
                      "iPad Library sign-in must open the actual Profile destination.")
    }

    /// Open actual game details through the settled post's native More menu.
    /// The details use the live feed model; no fabricated ratings or updates.
    @MainActor
    func testArcadePulseGameDetailsFromLiveFeed() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        self.app = app
        app.launch()
        let more = app.descendants(matching: .any)["More game actions"].firstMatch
        let retry = app.buttons["Try again"].firstMatch
        let until = Date().addingTimeInterval(120)
        while !more.exists && Date() < until {
            if retry.waitForExistence(timeout: 4) { retry.tap() }
            _ = more.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(more.exists && more.isHittable,
                      "A real settled feed post must expose its More menu.")
        more.tap()
        let details = app.buttons["Game details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        let title = app.descendants(matching: .any)["game.details.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "Details must display the actual feed game's title.")
        XCTAssertTrue(app.descendants(matching: .any)["game.details.preview"].firstMatch.exists)
        XCTAssertTrue(app.buttons["game.play"].firstMatch.exists,
                      "The details screen must retain a working Play entry.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "arcade-pulse-real-game-details"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["game.play"].firstMatch.waitForExistence(timeout: 10),
                      "Closing game details must preserve the browsable origin post.")
    }

    /// Verify the actual social sheet on a live feed, not the design render.
    /// No synthetic comments or engagement counters are injected.
    @MainActor
    func testArcadePulseCommentsSheetAndSafeAreaComposer() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        self.app = app
        app.launch()
        let commentAction = app.buttons["View comments"].firstMatch
        let retry = app.buttons["Try again"].firstMatch
        let until = Date().addingTimeInterval(120)
        while !commentAction.exists && Date() < until {
            if retry.waitForExistence(timeout: 4) { retry.tap() }
            _ = commentAction.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(commentAction.exists,
                      "Real For You posts must offer an accessible comment action.")
        commentAction.tap()
        // An axis:.vertical SwiftUI TextField can surface as a UITextView
        // rather than the generic accessibility wrapper carrying the SwiftUI
        // identifier. Require an actual *editable* native field, not an
        // adjacent placeholder StaticText or screenshot-only decoration.
        let identifiedComposer = app.descendants(matching: .any)["comments.composer"].firstMatch
        let editView = app.textViews.firstMatch
        let editField = app.textFields.firstMatch
        let composer: XCUIElement
        if identifiedComposer.waitForExistence(timeout: 3) &&
           (identifiedComposer.elementType == .textView ||
            identifiedComposer.elementType == .textField) {
            composer = identifiedComposer
        } else if editView.waitForExistence(timeout: 5) {
            composer = editView
        } else {
            composer = editField
        }
        let send = app.buttons["comments.send"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10),
                      "Arcade Pulse comments must expose a real editable native text view or text field, not just a caption.")
        XCTAssertTrue(composer.elementType == .textView || composer.elementType == .textField,
                      "The composer must be an editable element for VoiceOver and XCTest.")
        XCTAssertTrue(composer.isHittable,
                      "Comment composer must remain reachable above the safe-area inset.")
        let unavailable = app.descendants(matching: .any)["comments.send.unavailable"].firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5),
                      "Empty comments must show an explicitly unavailable Send affordance.")
        XCTAssertFalse(send.exists,
                       "No actionable Send button may exist before the user enters a comment.")
        composer.tap()
        composer.typeText("Nice game")
        XCTAssertTrue(send.waitForExistence(timeout: 5) && send.isEnabled,
                      "Typing non-empty text must expose a real enabled Send button without submitting.")
        // Do not submit this smoke-test draft to the real public comment API.
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "arcade-pulse-comments-sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.exists && done.isHittable)
        done.tap()
        XCTAssertTrue(app.buttons["game.play"].firstMatch.waitForExistence(timeout: 10),
                      "Closing comments must return to the same browsable game feed.")
    }

    /// The Studio must not pretend to show private drafts or generated
    /// analytics when no authenticated session or backend evidence exists.
    @MainActor
    func testArcadePulseStudioSignedOutState() throws {
        XCUIDevice.shared.orientation = .portrait
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Creator Studio is a native iPad sidebar destination.")
        }
        let app = XCUIApplication()
        self.app = app
        app.launchArguments.append("--ui-test-studio")
        app.launch()
        let root = app.descendants(matching: .any)["studio.arcadePulse.root"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Sign in to see your projects"].firstMatch.exists,
                      "Signed-out Studio must explain that private drafts require sign-in.")
        XCTAssertFalse(app.buttons["game.play"].firstMatch.exists,
                       "Without an authenticated owner there can be no playable project card.")
        let openProfile = app.buttons["studio.openProfile"].firstMatch
        XCTAssertTrue(openProfile.waitForExistence(timeout: 5) && openProfile.isHittable,
                      "The signed-out Studio must offer a reachable route to real Apple sign-in.")
        XCTAssertGreaterThanOrEqual(openProfile.frame.height, 44,
                                    "The Studio sign-in CTA must meet the minimum touch target.")
        XCTAssertTrue(app.frame.intersects(openProfile.frame),
                      "Studio sign-in must be visible in the actual iPad viewport.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "arcade-pulse-ipad-creator-studio-signed-out-portrait"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // A regular-width iPad also needs a usable Studio in landscape.
        // Capture the actual simulator screen rather than rotating a portrait
        // attachment after the fact; the image exporter retains orientation.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(openProfile.waitForExistence(timeout: 10) && openProfile.isHittable,
                      "Studio sign-in must remain visible after iPad rotation.")
        XCTAssertGreaterThanOrEqual(openProfile.frame.height, 44,
                                    "Landscape Studio sign-in must remain a 44pt target.")
        // The regular-width workspace should make honest use of iPad space,
        // without inventing project cards, analytics or fake thumbnails.
        let guide = app.descendants(matching: .any)["studio.signedOutGuide"].firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 10),
                      "Regular-width signed-out Studio should explain real capabilities.")
        XCTAssertTrue(app.frame.intersects(guide.frame),
                      "The Studio guide should be visible within the landscape viewport.")
        XCTAssertFalse(openProfile.frame.intersects(guide.frame),
                       "The Studio guidance must not obscure the real sign-in CTA.")
        XCTAssertFalse(app.buttons["game.play"].firstMatch.exists,
                       "No private or publicly playable project may be synthesized.")
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "arcade-pulse-ipad-creator-studio-signed-out-landscape"
        landscape.lifetime = .keepAlways
        add(landscape)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(openProfile.waitForExistence(timeout: 10) && openProfile.isHittable)
        openProfile.tap()
        XCTAssertTrue(app.buttons["Sign in with Apple"].firstMatch.waitForExistence(timeout: 10),
                      "The Studio CTA must navigate to the actual Profile sign-in flow.")
    }

    /// In accessibility text sizes the multi-column explainer is intentionally
    /// hidden, keeping the single owner sign-in route legible and reachable.
    @MainActor
    func testArcadePulseStudioSignedOutAccessibilityTextSize() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Creator Studio is an iPad-only sidebar destination.")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        self.app = app
        app.launchArguments += [
            "--ui-test-studio",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityM"
        ]
        app.launch()
        let studio = app.descendants(matching: .any)["studio.arcadePulse.root"].firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 15))
        let signIn = app.buttons["studio.openProfile"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 10) && signIn.isHittable,
                      "Large text must keep the real Profile sign-in reachable.")
        XCTAssertGreaterThanOrEqual(signIn.frame.height, 44)
        XCTAssertFalse(app.descendants(matching: .any)["studio.signedOutGuide"].firstMatch.exists,
                       "Accessibility text sizes must prioritize the compact single-column sign-in.")
        XCTAssertFalse(app.buttons["game.play"].firstMatch.exists,
                       "Accessible signed-out UI must not imply private games exist.")
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "arcade-pulse-ipad-studio-accessibility-large-text-landscape"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCUIDevice.shared.orientation = .portrait
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
            if expectedLandscape && UIDevice.current.userInterfaceIdiom == .phone {
                // Exact native screenshot evidence exposed the swipe label and
                // orientation badge directly under the floating scope menu.
                // Assert non-overlap, independently of the swipe/delta score.
                let scope = app.descendants(matching: .any)["feed.landscape.scope"].firstMatch
                XCTAssertTrue(scope.exists && swipeCue.exists)
                XCTAssertLessThanOrEqual(swipeCue.frame.maxX + 4, scope.frame.minX,
                      "Landscape swipe guidance must not overlap the top-trailing feed controls.")
                let orientation = app.descendants(matching: .any)["feed.orientation"].firstMatch
                if orientation.exists {
                    XCTAssertLessThanOrEqual(orientation.frame.maxX + 4, scope.frame.minX,
                          "The game-orientation badge must not cover feed scope/search controls.")
                }
            }

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
                // Original full-screen raw iPhone evidence showed a long bilingual
                // title crossing the centered no-preview label even though all
                // swipe/hit-target metrics passed. Keep title in a responsive
                // left column clear of the central media placeholder.
                if let beforePage {
                    XCTAssertLessThanOrEqual(beforePage.frame.maxX,
                        mediaFrame.minX + mediaFrame.width * 0.41,
                        "Compact landscape title must not cross the centered preview fallback.")
                }
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
        var lastRetry = Date.distantPast
        while !play.exists && Date() < feedDeadline {
            if Date().timeIntervalSince(lastRetry) >= 15,
               retry.exists && retry.isHittable && retry.isEnabled {
                print("UI EVALUATOR ACCESSIBILITY: feed error; retrying live backend")
                retry.tap()
                lastRetry = Date()
            } else if Date().timeIntervalSince(lastRetry) >= 15 &&
                        Date().timeIntervalSince(startedLoading) > 20 &&
                        pendingRetry.exists && pendingRetry.isHittable && pendingRetry.isEnabled {
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
                    lastRetry = Date()
                    print("UI EVALUATOR ACCESSIBILITY: retry stalled live feed at XXL/XXXL")
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

        // At XXXL the full five-action rail would crowd the preview and
        // become icon-only. Require a *visibly labeled* native Actions menu,
        // not five microscopic captions or hidden functionality.
        let actions = app.descendants(matching: .any)["feed.actions.accessible"].firstMatch
        let targets: [(String, XCUIElement)] = [("Play", play), ("Actions", actions)]
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
        XCTAssertLessThanOrEqual(actions.frame.maxY, play.frame.minY + 1,
                                 "Large-text Actions must not overlap the real Play CTA.")

        // When the *real feed* has a public creator, the enlarged shared
        // identity must still be reachable and must not occlude Play. Never
        // inject a synthetic long name to pass a visual screenshot gate:
        // source data and signed-out/ownerless states remain authoritative.
        let profileActions = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "View profile for ")
        )
        if let creator = profileActions.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            XCTAssertGreaterThan(creator.label.count, "View profile for ".count,
                                 "Creator actions must announce real nonempty identity.")
            XCTAssertGreaterThanOrEqual(creator.frame.height, 44,
                                        "Large-type creator entry must remain a real 44pt target.")
            XCTAssertLessThanOrEqual(creator.frame.maxY, play.frame.minY + 1,
                                     "Large-type creator identity must not obscure Play.")
            print("UI_EVALUATOR_CREATOR_LARGE_TEXT source=real_creator frame=" + String(describing: creator.frame))
        } else {
            print("UI_EVALUATOR_CREATOR_LARGE_TEXT source=no_hittable_creator; no fake test account")
        }
        actions.tap()
        // This menu reflects the *real* backend viewer state: previously
        // saved/liked games correctly show the inverse action, not a mock.
        for (name, allowed) in [
            ("Save", ["Save game", "Remove from library"]),
            ("Like", ["Like game", "Unlike game"]),
            ("Comments", ["View comments"]),
            ("Share", ["Share game"]),
            ("Details", ["Game details"]),
            ("Report", ["Report game"])
        ] {
            let options = allowed.map { label in
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@", label)).firstMatch
            }
            let available = options.contains { $0.waitForExistence(timeout: 5) }
            XCTAssertTrue(available, "Large-text Actions menu must expose \(name).")
        }
        // Dismiss the real native menu without mutating a remote Like/Save
        // state or starting gameplay; preserve the settled feed screenshot.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.15)).tap()

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

        // Inspect original evidence from the *real* system sharing journey.
        // A ShareLink mounted inside a disappearing Menu may never display
        // its sheet. Do not fake a system share screenshot or silently treat
        // the mere presence of the menu item as functional acceptance.
        actions.tap()
        let shareEntry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Share game")).firstMatch
        XCTAssertTrue(shareEntry.waitForExistence(timeout: 5))
        shareEntry.tap()
        // An item visible inside the Menu does not prove the share UI works.
        // Require an actual system sheet, iPad popover or activity-list view.
        let systemSheet = app.sheets.firstMatch
        let systemPopover = app.popovers.firstMatch
        let activityList = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(
            systemSheet.waitForExistence(timeout: 8) ||
                systemPopover.waitForExistence(timeout: 3) ||
                activityList.waitForExistence(timeout: 3),
            "Share game must present a genuine system activity sheet after the menu dismisses."
        )
        let shareEvidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shareEvidence.name = "feed-accessibility-xxxl-native-share-sheet"
        shareEvidence.lifetime = .keepAlways
        add(shareEvidence)
        print("UI_EVALUATOR_ACCESSIBILITY dynamic_type=accessibility-xxxl visible_primary_targets=2 menu_actions=6 native_share_attempt=true")
    }
}
