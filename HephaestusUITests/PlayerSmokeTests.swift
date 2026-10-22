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

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDiscoverLaunchesPlayer() throws {
        let app = XCUIApplication()
        app.launch()

        // The Discover feed comes from the live backend; give it time.
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30),
                      "Discover feed should offer at least one Play button")
        play.tap()

        // The player is a bridgeless WKWebView in a full-screen sheet.
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20),
                      "Player sheet should host a WKWebView")

        // Let the game boot, then keep a screenshot as evidence.
        let bootWait = XCTWaiter.wait(for: [expectation(description: "boot settle")], timeout: 6)
        _ = bootWait
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "player-after-boot"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
