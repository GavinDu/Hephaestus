import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Hephaestus

// The Game IR runtime test suite retired with the native Swift
// interpreter (removed 2026-10-20 in the single-runtime consolidation).
// Runtime conformance now lives with the PixiJS + Rapier runtime in the
// backend repository, which interprets the same Game IR packages.
// App-level tests will regrow around the WebView player and the
// creation flow.
struct HephaestusTests {
    @Test func arcadePulseActionGlyphHonorsLargeTextWithoutShrinkingCaptions() {
        // Ordinary compact rails retain the visual caption, but at a large
        // size the 48pt icon-only target avoids clipped words or a blocked
        // Play CTA. Buttons, menus, and ShareLink keep full VoiceOver labels.
        #expect(ArcadePulseActionGlyph.showsCaption("Like", for: .large))
        #expect(ArcadePulseActionGlyph.showsCaption("More", for: .xLarge))
        #expect(!ArcadePulseActionGlyph.showsCaption("Comment", for: .xxLarge))
        #expect(!ArcadePulseActionGlyph.showsCaption("Share", for: .xxxLarge))
        #expect(!ArcadePulseActionGlyph.showsCaption("Save", for: .accessibility3))
        #expect(!ArcadePulseActionGlyph.showsCaption(nil, for: .large))
        #expect(!ArcadePulseActionGlyph.showsCaption("", for: .large))
        #expect(!ArcadePulseActionGlyph.usesAccessibleMenu(for: .large))
        #expect(!ArcadePulseActionGlyph.usesAccessibleMenu(for: .xLarge))
        #expect(ArcadePulseActionGlyph.usesAccessibleMenu(for: .xxLarge))
        #expect(ArcadePulseActionGlyph.usesAccessibleMenu(for: .xxxLarge))
        #expect(ArcadePulseActionGlyph.usesAccessibleMenu(for: .accessibility1))
        #expect(ArcadePulseActionGlyph.usesAccessibleMenu(for: .accessibility5))
    }

    @Test func arcadePulseSocialActionErrorCopyDoesNotExposeRawBackendFailures() {
        let anonymous = FeedSocialErrorPresentation.message(
            action: "Saving this game", error: APIError.badStatus(401), signedIn: false)
        #expect(anonymous.contains("Sign in from Profile"))
        #expect(!anonymous.localizedCaseInsensitiveContains("HTTP"))

        let expired = FeedSocialErrorPresentation.message(
            action: "Liking this game", error: APIError.badStatus(401), signedIn: true)
        #expect(expired.contains("session has expired"))

        let forbidden = FeedSocialErrorPresentation.message(
            action: "Following this creator", error: APIError.badStatus(403), signedIn: true)
        #expect(forbidden.contains("isn't allowed"))
        #expect(!forbidden.contains("403"))

        let uncertain = FeedSocialErrorPresentation.message(
            action: "Saving this game",
            error: URLError(.networkConnectionLost), signedIn: true)
        #expect(uncertain.contains("couldn't be confirmed"))
        #expect(uncertain.contains("displayed status has not changed"))
        #expect(!uncertain.localizedCaseInsensitiveContains("URL"))
    }

    @Test func arcadePulseSocialMutationLeasesRejectDoubleTapAndStaleAccountCompletion() throws {
        var gate = FeedSocialMutationGate()
        // Swift Testing macros internally capture the expression's receiver
        // as an immutable value. Evaluate mutating actions beforehand, then
        // assert against their immutable results (Xcode 26 compiler fix).
        let invalid = gate.begin(.like, id: "")
        #expect(invalid == nil)
        let maybeFirst = gate.begin(.save, id: "public-game")
        let first = try #require(maybeFirst)
        let repeatedSave = gate.begin(.save, id: "public-game")
        #expect(repeatedSave == nil)
        let maybeLike = gate.begin(.like, id: "public-game")
        let like = try #require(maybeLike)
        let maybeFollow = gate.begin(.follow, id: "creator-a")
        let follow = try #require(maybeFollow)
        #expect(gate.pending.count == 3)
        gate.finish(.like, id: "public-game", lease: like)
        #expect(gate.pending.count == 2)
        gate.finish(.save, id: "public-game", lease: UUID())
        let staleSave = gate.begin(.save, id: "public-game")
        #expect(staleSave == nil)
        gate.finish(.save, id: "public-game", lease: first)
        let resumedSave = gate.begin(.save, id: "public-game")
        #expect(resumedSave != nil)

        // Logout invalidates earlier account leases; stale completions must
        // not release the next viewer's pending request for the same creator.
        gate.revokeAll()
        #expect(gate.pending.isEmpty)
        let maybeSecond = gate.begin(.follow, id: "creator-a")
        let second = try #require(maybeSecond)
        gate.finish(.follow, id: "creator-a", lease: follow)
        let staleFollow = gate.begin(.follow, id: "creator-a")
        #expect(staleFollow == nil)
        gate.finish(.follow, id: "creator-a", lease: second)
        let resumedFollow = gate.begin(.follow, id: "creator-a")
        #expect(resumedFollow != nil)
    }

    @Test func arcadePulseFoundationUsesSinglePaletteAndAccessibleTargetSizes() {
        #expect(ArcadePulseTheme.fallbackPalettes.count == 5)
        #expect(ArcadePulseTheme.minimumTarget >= 44)
        #expect(ArcadePulseTheme.playHeight >= ArcadePulseTheme.minimumTarget)
        #expect(ArcadePulseTheme.pillRadius > 0)
        for gameID in ["sample-ribbon-sky", "sample-rainbow-bear",
                       "escape-from-injection", "penguin-heartlight-rescue"] {
            #expect(ArcadePulseTheme.fallbackPalette(gameID: gameID).count == 2)
        }
        // Play is a real 48pt native action, not a fake recorded preview
        // or a zero-distance gesture layered over the feed pager.
    }

    @Test func shippedFeedFallbackPalettesDoNotCollide() {
        // Run against the same real game IDs used by native screenshot QA.
        // The old scalar sum and an in-loop modulo five both mapped Ribbon
        // and Bobo to one fallback gradient, even after a successful swipe.
        let ids = ["sample-ribbon-sky", "sample-rainbow-bear",
                   "escape-from-injection", "penguin-heartlight-rescue"]
        let slots = ids.map {
            ForYouPageLayout.fallbackPaletteIndex(gameID: $0, paletteCount: 5)
        }
        #expect(Set(slots).count == ids.count)
        #expect(slots == [4, 0, 1, 2])
        #expect(ForYouPageLayout.fallbackPaletteIndex(gameID: "anything", paletteCount: 0) == 0)
    }

    @Test func compactHeightFeedUsesAccessibleScopeMenuWithoutHidingSearchNavigation() {
        #expect(ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: .compact, searchText: ""))
        #expect(ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: .compact, searchText: "   "))
        #expect(!ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: .compact, searchText: "Bobo"))
        #expect(!ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: .regular, searchText: ""))
        #expect(!ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: nil, searchText: ""))
        #expect(ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: .regular, horizontalSizeClass: .compact, searchText: ""))
        #expect(ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: .regular, horizontalSizeClass: .compact, searchText: "   "))
        #expect(!ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: .regular, horizontalSizeClass: .compact, searchText: "Bobo"))
        #expect(!ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: .regular, horizontalSizeClass: .regular, searchText: ""))
    }

    @Test func arcadePulseIPadContextPanelNeverCrushesTheGameStage() {
        #expect(ForYouPageLayout.showsIPadContextPanel(
            width: 1_366, height: 1_024, isRegular: true, isAccessibilityText: false))
        #expect(!ForYouPageLayout.showsIPadContextPanel(
            width: 1_024, height: 1_366, isRegular: true, isAccessibilityText: false))
        #expect(!ForYouPageLayout.showsIPadContextPanel(
            width: 860, height: 700, isRegular: true, isAccessibilityText: false))
        #expect(!ForYouPageLayout.showsIPadContextPanel(
            width: 1_366, height: 1_024, isRegular: true, isAccessibilityText: true))
        #expect(!ForYouPageLayout.showsIPadContextPanel(
            width: 1_366, height: 1_024, isRegular: false, isAccessibilityText: false))
        for width: CGFloat in [1_024, 1_194, 1_366] {
            let stage = ForYouPageLayout.adaptiveLandscapeStageWidth(containerWidth: width)
            let panel = ForYouPageLayout.contextPanelWidth(containerWidth: width)
            #expect(stage / width > 0.60)
            #expect(stage + panel + 44 <= width)
        }
    }

    @Test func arcadePulseIPadGameDetailsKeepsMediaAndActionsReadable() {
        #expect(ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_366, height: 1_024, isRegular: true, isLargeText: false))
        #expect(ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_194, height: 834, isRegular: true, isLargeText: false))
        // Portrait, compact Split View, short Stage Manager and high text
        // must have one readable scrolling detail column, not clipped media.
        #expect(!ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_024, height: 1_366, isRegular: true, isLargeText: false))
        #expect(!ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 860, height: 700, isRegular: true, isLargeText: false))
        #expect(!ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_366, height: 600, isRegular: true, isLargeText: false))
        #expect(!ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_366, height: 1_024, isRegular: true, isLargeText: true))
        #expect(!ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_366, height: 1_024, isRegular: false, isLargeText: false))
        for width: CGFloat in [960, 1_024, 1_194, 1_366] {
            let media = ForYouPageLayout.gameDetailsPreviewWidth(containerWidth: width)
            let content = min(width - 36, 1_200)
            let metadata = content - media - 24
            #expect(media >= 480)
            #expect(metadata >= 350)
            #expect(media + metadata + 24 <= content)
        }
        #expect(ForYouPageLayout.gameDetailsPreviewWidth(containerWidth: 20) == 0)
        // Landscape Game Details must use the available safe viewport height
        // rather than the previous hard 520pt media ceiling. This expands
        // genuine artwork or an honest no-preview fallback identically.
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(containerHeight: 1_000) == 640)
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(containerHeight: 760) >= 550)
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(containerHeight: 620) >= 450)
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(containerHeight: 0) == 0)
    }

    @Test func compactLandscapeOverlayPreservesPlayerSpaceAndNavigation() {
        #expect(ForYouPageLayout.usesCompactLandscapeOverlay(
            verticalSizeClass: .compact, horizontalSizeClass: .compact, hasImmersivePager: true))
        #expect(!ForYouPageLayout.usesCompactLandscapeOverlay(
            verticalSizeClass: .regular, horizontalSizeClass: .compact, hasImmersivePager: true))
        #expect(ForYouPageLayout.usesCompactLandscapeOverlay(
            verticalSizeClass: .compact, horizontalSizeClass: .regular, hasImmersivePager: true))
        #expect(!ForYouPageLayout.usesCompactLandscapeOverlay(
            verticalSizeClass: .compact, horizontalSizeClass: .compact, hasImmersivePager: false))
    }

    @Test func studioProjectDecodingNeverMistakesPrivateDraftForPublishedPlayableGame() throws {
        let payload = """
        {"projects":[
            {"game_id":"private-draft-1","title":"My draft","status":"draft",
             "visibility":"private","created_at":"2026-11-10T12:00:00Z",
             "updated_at":"2026-11-10T12:30:00Z"},
            {"game_id":"public-ready-2","title":"Public title","status":"ready",
             "visibility":"public","moderation_status":"approved","published_version":1,
             "preview_poster_url":"/v1/games/public-ready-2/previews/1/poster.png",
             "created_at":"2026-11-09T12:00:00Z","updated_at":"2026-11-10T12:00:00Z"}
        ],"next_cursor":null}
        """
        let response = try JSONDecoder().decode(
            CreatorProjectsResponse.self, from: Data(payload.utf8))
        #expect(response.projects.count == 2)
        #expect(response.projects[0].id == "private-draft-1")
        #expect(response.projects[0].displayStatus == "Draft")
        #expect(!response.projects[0].isPubliclyPlayable)
        #expect(response.projects[1].displayStatus == "Published")
        #expect(response.projects[1].isPubliclyPlayable)
        #expect(response.projects[0].resolvedPosterURL == nil)
        #expect(response.projects[1].resolvedPosterURL?.absoluteString ==
            BackendConfig.baseURL.absoluteString + "/v1/games/public-ready-2/previews/1/poster.png")
        #expect(response.nextCursor == nil)
    }

    @Test func socialFeedScopesAreStableAndDistinct() {
        #expect(SocialFeedScope.allCases.map(\.rawValue) == ["for_you", "following", "friends"])
        #expect(SocialFeedScope.allCases.map(\.title) == ["For You", "Following", "Friends"])
    }

    @Test func moderationAppealAndContactResponsesDecode() throws {
        let appealJSON = """
        {"appeal_id":"appeal-1","status":"open","message":"queued for moderator review"}
        """.data(using: .utf8)!
        let appeal = try JSONDecoder().decode(BackendAPI.ModerationAppealResponse.self, from: appealJSON)
        #expect(appeal.appeal_id == "appeal-1")
        #expect(appeal.status == "open")

        let contactJSON = """
        {"contact_url":"https://example.test/moderation","contact_email":"safety@example.test","appeals_endpoint":"POST /v1/games/{id}/moderation-appeals","external_contact_configured":true}
        """.data(using: .utf8)!
        let contact = try JSONDecoder().decode(BackendAPI.ModerationContactResponse.self, from: contactJSON)
        #expect(contact.external_contact_configured)
        #expect(contact.contact_email == "safety@example.test")
    }

    @Test func productionRequestsDoNotTrustCallerSuppliedIdentity() {
        var request = URLRequest(url: URL(string: "https://example.test/v1/users/me")!)
        BackendConfig.applyAuthentication(to: &request)
        #expect(request.value(forHTTPHeaderField: "X-User-ID") == nil)
        if let token = BackendConfig.loadSessionToken() {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
        } else {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }
    @Test func backendConfigIsSane() {
        #expect(BackendConfig.baseURL.scheme == "https")
        #expect(!BackendConfig.userID.isEmpty)
    }

    @MainActor @Test func nativePlayerURLUsesPlayPresentation() {
        let url = PlayerWebViewPool.playerURL(gameID: "game-1", quality: "low")
        #expect(url != nil)
        guard let url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let values = Dictionary(uniqueKeysWithValues: (query ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(values["game"] == "game-1")
        #expect(values["quality"] == "low")
        #expect(values["presentation"] == "play")
    }

    @Test func devLogRecordsAndExports() {
        let before = DevLog.shared.count
        DevLog.info(.app, "test entry")
        #expect(DevLog.shared.count == before + 1)
        #expect(DevLog.shared.exportText().contains("test entry"))
    }

    @Test func offlineOverlayOnlyAppearsWhileLoading() {
        #expect(PlayerLoadingPolicy.shouldShowOfflineOverlay(isOffline: true, isLoading: true, hasError: false))
        #expect(!PlayerLoadingPolicy.shouldShowOfflineOverlay(isOffline: true, isLoading: false, hasError: false))
        #expect(!PlayerLoadingPolicy.shouldShowOfflineOverlay(isOffline: true, isLoading: true, hasError: true))
        #expect(!PlayerLoadingPolicy.shouldShowOfflineOverlay(isOffline: false, isLoading: true, hasError: false))
    }
    @Test func playerLoadFailureMapsToFixedMessages() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline. https://example.test/player"])
        #expect(PlayerLoadFailure.category(for: offline) == .network)
        #expect(PlayerLoadFailure.userMessage(for: offline) == "Check your connection and try again.")
        // The raw detail (including the URL) must never reach the UI string.
        #expect(!PlayerLoadFailure.userMessage(for: offline).contains("example.test"))
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        #expect(PlayerLoadFailure.category(for: timedOut) == .network)
        let tlsHandshakeFailed = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed, userInfo: [NSLocalizedDescriptionKey: "TLS connection failed"])
        #expect(PlayerLoadFailure.category(for: tlsHandshakeFailed) == .network)
        #expect(PlayerLoadFailure.userMessage(for: tlsHandshakeFailed) == "Check your connection and try again.")
        let other = NSError(domain: "SomeOtherDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "internal backend detail"])
        #expect(PlayerLoadFailure.category(for: other) == .unknown)
        #expect(PlayerLoadFailure.userMessage(for: other) == "The player couldn't load this game.")
        #expect(!PlayerLoadFailure.userMessage(for: other).contains("internal backend detail"))

        #expect(PlayerLoadFailure.category(for: PlayerLoadFailure.httpError(statusCode: 404)) == .unavailable)
        #expect(PlayerLoadFailure.userMessage(for: PlayerLoadFailure.httpError(statusCode: 404)).contains("Return to the feed"))
        #expect(PlayerLoadFailure.category(for: PlayerLoadFailure.httpError(statusCode: 426)) == .incompatible)
        #expect(PlayerLoadFailure.userMessage(for: PlayerLoadFailure.httpError(statusCode: 426)).contains("Update the app"))
        #expect(PlayerLoadFailure.category(for: PlayerLoadFailure.httpError(statusCode: 403)) == .accessDenied)
        #expect(PlayerLoadFailure.userMessage(for: PlayerLoadFailure.httpError(statusCode: 403)).contains("sign in again"))
    }
    @Test func previewDwellIsMeasuredNotFixed() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(FeedPreviewDwell.dwellMS(from: start, to: start.addingTimeInterval(2.5)) == 2_500)
        #expect(FeedPreviewDwell.dwellMS(from: start, to: start) == 0)
        // A clock jump backwards can never produce a negative dwell.
        #expect(FeedPreviewDwell.dwellMS(from: start, to: start.addingTimeInterval(-5)) == 0)
    }
    @Test func gameplayTelemetryQuickExitThresholdIsBounded() {
        #expect(GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: 0))
        #expect(GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: 4_999))
        #expect(!GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: 5_000))
        #expect(!GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: 12_000))
        #expect(!GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: -1))
    }
    @Test func playableExpressionDecodesAndRoundTripsBackendContract() throws {
        let json = """
        {
          "schemaVersion":"1.0",
          "status":"ready",
          "source":{"type":"image","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
          "creator":{"ownerId":"apple:creator-1","consent":true,"visibility":"private"},
          "mode":"what_if",
          "intent":"A quiet world",
          "anchors":[{"id":"a1","kind":"place","value":"garden","preserve":true}],
          "evidence":[{"id":"e1","kind":"image_region","start":0,"end":1}],
          "chosenInterpretation":"A moon garden",
          "interpretation":{"preserved":[{"id":"p1","text":"garden","confidence":0.9,"evidenceIds":["e1"]}],"invented":[{"id":"i1","text":"moon flowers","confidence":0.7}],"uncertain":[]},
          "generation":{"seed":42,"gameIrVersion":"1.2","packageVersion":"2.0","modelVersion":"model-1","promptVersion":"prompt-1"}
        }
        """.data(using: .utf8)!
        let expression = try JSONDecoder().decode(PlayableExpression.self, from: json)
        #expect(expression.validationError() == nil)
        let encoded = try JSONEncoder().encode(expression)
        let decoded = try JSONDecoder().decode(PlayableExpression.self, from: encoded)
        #expect(decoded == expression)
        #expect(decoded.interpretation?.preserved?.first?.text == "garden")
        #expect(decoded.interpretation?.invented?.first?.text == "moon flowers")
    }

    @Test func playableExpressionRejectsUnknownEvidenceAndMissingRemixParent() throws {
        let json = """
        {
          "schemaVersion":"1.0","status":"draft",
          "source":{"type":"text","reference":"source-ref"},
          "creator":{"ownerId":"creator-1","consent":true,"visibility":"private"},
          "mode":"remix",
          "interpretation":{"preserved":[{"id":"claim-1","text":"castle","confidence":0.8,"evidenceIds":["missing"]}]},
          "generation":{"seed":1}
        }
        """.data(using: .utf8)!
        let expression = try JSONDecoder().decode(PlayableExpression.self, from: json)
        #expect(expression.validationError() != nil)
    }

    @Test func playableExpressionRejectsUnconsentedSourceAndInvalidDigest() throws {
        let json = """
        {
          "schemaVersion":"1.0","status":"draft",
          "source":{"type":"image","sha256":"not-a-digest"},
          "creator":{"ownerId":"creator-1","consent":false,"visibility":"private"},
          "mode":"make_playable",
          "generation":{"seed":1}
        }
        """.data(using: .utf8)!
        let expression = try JSONDecoder().decode(PlayableExpression.self, from: json)
        #expect(expression.validationError() != nil)
    }

}


    @Test func feedGameDecodesSocialPostMetadata() throws {
        let json = """
        {
          "game_id": "game-1",
          "title": "Tiny Adventure",
          "owner_id": "creator-1",
          "caption": "A small story",
          "topics": ["puzzle", "family"],
          "published_version": 1,
          "remix_parent_id": "parent-game",
          "moderation_status": "approved"
        }
        """.data(using: .utf8)!
        let game = try JSONDecoder().decode(FeedGame.self, from: json)
        #expect(game.id == "game-1")
        #expect(game.ownerID == "creator-1")
        #expect(game.caption == "A small story")
        #expect(game.topics == ["puzzle", "family"])
        #expect(game.remixParentID == "parent-game")
        #expect(game.publishedVersion == 1)
    }

    @Test func publicFeedDecodesRedactedPlayableExpressionSummary() throws {
        let json = """
        {
          "game_id": "expression-game",
          "title": "Moon Garden",
          "playable_expression": {
            "source_type": "image",
            "source_visibility": "public",
            "intent": "A quiet garden in the moonlight",
            "chosen_interpretation": "Moon garden",
            "preserved": [{"text": "garden", "confidence": 0.95}],
            "invented": [{"text": "moon flowers", "confidence": 0.7}],
            "uncertain": [],
            "parent_game_id": "parent-game",
            "parent_version": 2
          }
        }
        """.data(using: .utf8)!
        let game = try JSONDecoder().decode(FeedGame.self, from: json)
        #expect(game.playableExpression?.source_visibility == "public")
        #expect(game.playableExpression?.intent == "A quiet garden in the moonlight")
        #expect(game.playableExpression?.chosen_interpretation == "Moon garden")
        #expect(game.playableExpression?.preserved?.first?.text == "garden")
        #expect(game.playableExpression?.invented?.first?.text == "moon flowers")
        #expect(game.playableExpression?.parent_game_id == "parent-game")
        let encoded = try JSONEncoder().encode(game)
        let roundTrip = try JSONDecoder().decode(FeedGame.self, from: encoded)
        #expect(roundTrip.playableExpression == game.playableExpression)
    }

    @Test func creatorDiscoveryDecodesSearchResultsAndCursor() throws {
        let json = """
        {
          "creators": [
            {
              "creator_id": "alice",
              "post_count": 3,
              "topics": ["puzzle", "family"]
            }
          ],
          "next_cursor": "alice"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CreatorDiscoveryResponse.self, from: json)
        #expect(response.creators.count == 1)
        #expect(response.creators[0].id == "alice")
        #expect(response.creators[0].post_count == 3)
        #expect(response.creators[0].topics == ["puzzle", "family"])
        #expect(response.next_cursor == "alice")
    }

    @Test func creatorDiscoveryDecodesEmptyResultsWithoutCursor() throws {
        let json = """
        {
          "creators": [],
          "next_cursor": ""
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CreatorDiscoveryResponse.self, from: json)
        #expect(response.creators.isEmpty)
        #expect(response.next_cursor == "")
    }


@Test func playerForegroundRetryRequiresBackgroundErrorAndConnectivity() {
    #expect(PlayerLifecyclePolicy.shouldRetryAfterForeground(wasBackgrounded: true, isOffline: false, hasError: true))
    #expect(!PlayerLifecyclePolicy.shouldRetryAfterForeground(wasBackgrounded: true, isOffline: true, hasError: true))
    #expect(!PlayerLifecyclePolicy.shouldRetryAfterForeground(wasBackgrounded: true, isOffline: false, hasError: false))
    #expect(!PlayerLifecyclePolicy.shouldRetryAfterForeground(wasBackgrounded: false, isOffline: false, hasError: true))
}

@Test func feedResponseMergesVersionedCardsAndKeepsLegacyCompatibility() throws {
    let cardJSON = """
    {
      "games": [{"game_id":"game-1","title":"Orbit Garden","owner_id":"creator-1","caption":"Legacy caption"}],
      "cards": [{
        "game_id":"game-1","version":"7","title":"Orbit Garden","caption":"A cozy universe","topics":["space"],
        "creator":{"id":"creator-1","display_name":"Star Maker","avatar_url":"https://cdn.example.test/avatar.png"},
        "preview":{"poster_url":"https://cdn.example.test/poster.webp","clip_url":"https://cdn.example.test/clip.mp4","aspect":1.5,"duration_ms":6000,"dominant_color":"#334455","status":"ready"},
        "stats":{"likes":12,"play_starts":30,"completions":18},
        "viewer":{"liked":true,"saved":false,"following":true},
        "package":{"url":"/v1/games/game-1/package","min_runtime_version":"2026.10.23.2"}
      }],
      "next_cursor":"next"
    }
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(FeedResponse.self, from: cardJSON)
    #expect(response.games.count == 1)
    #expect(response.games[0].creatorDisplayName == "Star Maker")
    #expect(response.games[0].creatorAvatarURL == "https://cdn.example.test/avatar.png")
    #expect(response.games[0].previewPosterURL == "https://cdn.example.test/poster.webp")
    #expect(response.games[0].previewStatus == "ready")
    #expect(response.games[0].likeCount == 12)
    #expect(response.games[0].viewerLiked == true)
    #expect(response.games[0].viewerFollowing == true)
    #expect(response.next_cursor == "next")

    let legacyJSON = """
    {"games":[{"game_id":"old-game","title":"Old client payload"}]}
    """.data(using: .utf8)!
    let legacy = try JSONDecoder().decode(FeedResponse.self, from: legacyJSON)
    #expect(legacy.games.first?.id == "old-game")
    #expect(legacy.games.first?.previewPosterURL == nil)
    #expect(legacy.games.first?.viewerSaved == nil)
}


@MainActor @Test func discoverFeedRetryCancelsPriorRequestAndProtectsNewerResults() async throws {
    let coordinator = FeedRequestCoordinator()
    let stale = coordinator.begin {
        // A transport can finish despite cancellation (for example when a
        // mocked server response has already been buffered). Simulate that
        // by deliberately swallowing sleep cancellation before returning.
        do { try await Task.sleep(for: .seconds(30)) } catch { }
        return try JSONDecoder().decode(FeedResponse.self,
                                        from: Data(#"{"games":[{"game_id":"stale","title":"Stale"}]}"#.utf8))
    }
    let current = coordinator.begin {
        try JSONDecoder().decode(FeedResponse.self,
                                 from: Data(#"{"games":[{"game_id":"fresh","title":"Fresh"}]}"#.utf8))
    }
    #expect(stale.request.isCancelled)
    #expect(!coordinator.isCurrent(stale.generation))
    #expect(coordinator.isCurrent(current.generation))

    let staleResponse = try await stale.request.value
    #expect(staleResponse.games.first?.id == "stale")
    coordinator.finishIfCurrent(stale.generation)
    #expect(coordinator.isCurrent(current.generation))
    let freshResponse = try await current.request.value
    #expect(freshResponse.games.first?.id == "fresh")
    coordinator.finishIfCurrent(current.generation)
    #expect(coordinator.isCurrent(current.generation))
}

@MainActor @Test func discoverFeedRetryCancelsCancellableTransport() async throws {
    let coordinator = FeedRequestCoordinator()
    let first = coordinator.begin {
        try await Task.sleep(for: .seconds(30))
        return try JSONDecoder().decode(FeedResponse.self, from: Data(#"{"games":[]}"#.utf8))
    }
    let second = coordinator.begin {
        try JSONDecoder().decode(FeedResponse.self, from: Data(#"{"games":[]}"#.utf8))
    }
    #expect(first.request.isCancelled)
    var wasCancelled = false
    do { _ = try await first.request.value }
    catch { wasCancelled = error is CancellationError }
    #expect(wasCancelled)
    _ = try await second.request.value
    #expect(coordinator.isCurrent(second.generation))
}

@Test func feedPreviewAutoplayRespectsMotionPowerAndNetworkPolicies() {
    #expect(FeedPreviewPolicy.shouldAutoplay(hasClip: true, reduceMotion: false, lowPowerMode: false, constrainedNetwork: false))
    #expect(!FeedPreviewPolicy.shouldAutoplay(hasClip: false, reduceMotion: false, lowPowerMode: false, constrainedNetwork: false))
    #expect(!FeedPreviewPolicy.shouldAutoplay(hasClip: true, reduceMotion: true, lowPowerMode: false, constrainedNetwork: false))
    #expect(!FeedPreviewPolicy.shouldAutoplay(hasClip: true, reduceMotion: false, lowPowerMode: true, constrainedNetwork: false))
    #expect(!FeedPreviewPolicy.shouldAutoplay(hasClip: true, reduceMotion: false, lowPowerMode: false, constrainedNetwork: true))
    #expect(!FeedPreviewPolicy.shouldAutoplay(hasClip: true, reduceMotion: false, lowPowerMode: false, constrainedNetwork: false, isOnline: false))
    #expect(FeedPreviewPolicy.shouldAutoplay(hasClip: true, reduceMotion: false, lowPowerMode: false, constrainedNetwork: false, isOnline: true))
}

@Test func settledFeedPreviewReusesOnlyTheExactVersionedClip() {
    let old = URL(string: "https://example.test/v1/games/a/previews/1/clip.mp4")!
    let fresh = URL(string: "https://example.test/v1/games/a/previews/2/clip.mp4")!
    #expect(FeedPreviewPolicy.shouldReusePreview(
        activeGameID: "a", activeURL: old,
        pendingGameID: nil, pendingURL: nil,
        nextGameID: "a", nextURL: old))
    #expect(!FeedPreviewPolicy.shouldReusePreview(
        activeGameID: "a", activeURL: old,
        pendingGameID: nil, pendingURL: nil,
        nextGameID: "a", nextURL: fresh))
    #expect(FeedPreviewPolicy.shouldReusePreview(
        activeGameID: nil, activeURL: nil,
        pendingGameID: "a", pendingURL: fresh,
        nextGameID: "a", nextURL: fresh))
    #expect(!FeedPreviewPolicy.shouldReusePreview(
        activeGameID: nil, activeURL: nil,
        pendingGameID: "a", pendingURL: old,
        nextGameID: "a", nextURL: fresh))
    #expect(!FeedPreviewPolicy.shouldReusePreview(
        activeGameID: "a", activeURL: fresh,
        pendingGameID: nil, pendingURL: nil,
        nextGameID: "b", nextURL: fresh))
}

@Test func settledFeedPreviewRetiresOldClipEvenWhenNextPageHasNoVideo() {
    #expect(FeedPreviewPolicy.shouldRetirePrevious(activeGameID: "game-a", pendingGameID: nil, nextGameID: "game-b"))
    #expect(FeedPreviewPolicy.shouldRetirePrevious(activeGameID: nil, pendingGameID: "game-a", nextGameID: "game-b"))
    #expect(FeedPreviewPolicy.shouldRetirePrevious(activeGameID: "game-a", pendingGameID: "game-a", nextGameID: "game-b"))
    #expect(!FeedPreviewPolicy.shouldRetirePrevious(activeGameID: "game-b", pendingGameID: nil, nextGameID: "game-b"))
    #expect(!FeedPreviewPolicy.shouldRetirePrevious(activeGameID: nil, pendingGameID: "game-b", nextGameID: "game-b"))
    #expect(!FeedPreviewPolicy.shouldRetirePrevious(activeGameID: nil, pendingGameID: nil, nextGameID: "game-b"))
}

@Test func verifiedRunResultDecodesOutcomeAndRank() throws {
    let json = """
    {
      "runId": "run-1",
      "gameId": "game-1",
      "status": "verified",
      "result": {"won": true, "score": 420, "durationMs": 12800, "completedAt": "2026-10-26T23:59:12Z"},
      "rank": {"scope": "weekly", "position": 7, "total": 184}
    }
    """.data(using: .utf8)!
    let result = try JSONDecoder().decode(VerifiedRunResult.self, from: json)
    #expect(result.isVerified)
    #expect(result.runID == "run-1")
    #expect(result.gameID == "game-1")
    #expect(result.result?.score == 420)
    #expect(result.result?.durationMS == 12_800)
    #expect(result.rank?.position == 7)
}

@Test func unverifiedRunResultCannotBePresented() throws {
    let json = """
    {"runId":"run-2","gameId":"game-1","status":"pending","result":null}
    """.data(using: .utf8)!
    let result = try JSONDecoder().decode(VerifiedRunResult.self, from: json)
    #expect(!result.isVerified)
}

@Test func appleSignInResponseDecodesSession() throws {
    let json = """
    {"access_token":"abc.def","token_type":"Bearer","expires_in":2592000,"subject":"apple:001"}
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(BackendAPI.AppleSignInResponse.self, from: json)
    #expect(response.access_token == "abc.def")
    #expect(response.token_type == "Bearer")
    #expect(response.expires_in == 2592000)
    #expect(response.subject == "apple:001")
}

@Test func deleteAccountResponseDecodes() throws {
    let json = """
    {"deleted":true,"subject":"apple:001"}
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(BackendAPI.DeleteAccountResponse.self, from: json)
    #expect(response.deleted)
    #expect(response.subject == "apple:001")
}


@Test func forYouPageLayoutUsesPortraitStageOnRegularWidth() {
    #expect(ForYouPageLayout.stageWidth(containerWidth: 390, containerHeight: 844, isRegular: false) == 390)
    #expect(ForYouPageLayout.stageWidth(containerWidth: 1024, containerHeight: 768, isRegular: true) > 430)
    // iPad portrait should no longer be a narrow phone-sized strip:
    // screenshots showed a center card with mostly empty side gutters.
    #expect(ForYouPageLayout.stageWidth(containerWidth: 768, containerHeight: 1024, isRegular: true) > 640)
    // A portrait iPad has enough space for a wide, media-first stage; the
    // screenshot-derived 680pt cap wasted nearly a third of the viewport.
    #expect(ForYouPageLayout.stageWidth(containerWidth: 1024, containerHeight: 1366, isRegular: true) == 820)
    #expect(ForYouPageLayout.stageWidth(containerWidth: 1032, containerHeight: 1243, isRegular: true) > 780)
    // Non-landscape explicit orientation remains conservative; never exceed
    // portrait width/height caps just because a caller passes a wide canvas.
    #expect(ForYouPageLayout.stageWidth(containerWidth: 1366, containerHeight: 1024, isRegular: true) <= 820)
    #expect(ForYouPageLayout.stageWidth(containerWidth: 1024, containerHeight: 768, isRegular: true, isLandscape: true) == 1024)
    #expect(ForYouPageLayout.stageWidth(containerWidth: 1366, containerHeight: 1024, isRegular: true, isLandscape: true) == 1120)
    #expect(ForYouPageLayout.mediaAccessibilityLabel(title: "Rainbow") ==
            "Game artwork or preview for Rainbow. Use Play now to start.")
    #expect(!ForYouPageLayout.mediaAccessibilityLabel(title: "Penguin").contains("Recorded preview"))
    #expect(ForYouPageLayout.mediaAccessibilityLabel(title: "Bobo", hasPreviewMedia: false) ==
            "Gameplay preview not available for Bobo. Use Play now to start.")
    #expect(!ForYouPageLayout.mediaAccessibilityLabel(title: "Bobo", hasPreviewMedia: false)
        .contains("artwork or preview"))
    #expect(ForYouPageLayout.contentMaxWidth(isRegular: true) == 760)
    #expect(ForYouPageLayout.contentMaxWidth(isRegular: false).isInfinite)
}

@Test func forYouPagerShortFlickUsesVerticalMomentumWithoutStealingTaps() {
    // Short deliberate flicks must work even when the finger travels
    // less than the old fixed 80pt threshold.
    #expect(ForYouPageLayout.pageOffsetForSwipe(
        translation: CGSize(width: 3, height: -45),
        predictedEndTranslation: CGSize(width: 5, height: -160)) == 1)
    #expect(ForYouPageLayout.pageOffsetForSwipe(
        translation: CGSize(width: -3, height: 42),
        predictedEndTranslation: CGSize(width: -10, height: 130)) == -1)
    // Slow deliberate drag still pages once.
    #expect(ForYouPageLayout.pageOffsetForSwipe(
        translation: CGSize(width: 2, height: -91),
        predictedEndTranslation: CGSize(width: 2, height: -94)) == 1)
    // Tap/short tug, diagonal and horizontal gestures cannot page.
    #expect(ForYouPageLayout.pageOffsetForSwipe(
        translation: CGSize(width: 1, height: -20),
        predictedEndTranslation: CGSize(width: 1, height: -220)) == 0)
    #expect(ForYouPageLayout.pageOffsetForSwipe(
        translation: CGSize(width: 88, height: -55),
        predictedEndTranslation: CGSize(width: 190, height: -150)) == 0)
    #expect(ForYouPageLayout.pageOffsetForSwipe(
        translation: CGSize(width: 45, height: -49),
        predictedEndTranslation: CGSize(width: 72, height: -140)) == 0)
    // A reversed or sideways prediction does not turn a tiny tug into a page.
    #expect(ForYouPageLayout.pageOffsetForSwipe(
        translation: CGSize(width: 2, height: -43),
        predictedEndTranslation: CGSize(width: 1, height: 180)) == 0)
    #expect(ForYouPageLayout.pageOffsetForSwipe(
        translation: CGSize(width: 2, height: -43),
        predictedEndTranslation: CGSize(width: 180, height: -180)) == 0)
}

@Test func socialFeedUsesImmersiveSwipePagerForEveryPopulatedScope() {
    // For You, Following and Friends are all full-screen vertical feeds.
    // Only explicit search uses the compact multi-result card layout.
    for scope in SocialFeedScope.allCases {
        #expect(ForYouPageLayout.shouldShowImmersivePager(
            searchText: "", hasGames: true), "pager unavailable for \(scope.rawValue)")
    }
    #expect(ForYouPageLayout.shouldShowImmersivePager(searchText: "   ", hasGames: true))
    #expect(!ForYouPageLayout.shouldShowImmersivePager(searchText: "penguin", hasGames: true))
    #expect(!ForYouPageLayout.shouldShowImmersivePager(searchText: "", hasGames: false))
}

@Test func failedCursorPagePreservesSwipeFeedAndRequiresExplicitRetry() {
    #expect(ForYouPageLayout.shouldAutoLoadNextPage(
        hasCursor: true, isLoading: false, isLoadingMore: false, hasPaginationError: false))
    #expect(!ForYouPageLayout.shouldAutoLoadNextPage(
        hasCursor: true, isLoading: false, isLoadingMore: false, hasPaginationError: true))
    #expect(!ForYouPageLayout.shouldAutoLoadNextPage(
        hasCursor: true, isLoading: true, isLoadingMore: false, hasPaginationError: false))
    #expect(!ForYouPageLayout.shouldAutoLoadNextPage(
        hasCursor: false, isLoading: false, isLoadingMore: false, hasPaginationError: false))
    #expect(!ForYouPageLayout.shouldAutoLoadNextPage(
        hasCursor: true, isLoading: false, isLoadingMore: true, hasPaginationError: false))
    // Existing cards are still immersive during an unsuccessful refresh.
    #expect(ForYouPageLayout.shouldShowImmersivePager(searchText: "", hasGames: true))
}

@Test func stalePaginationErrorsNeverLeakAcrossSocialFeedScopes() {
    for scope in SocialFeedScope.allCases {
        #expect(ForYouPageLayout.shouldApplyPaginationResult(
            requestedScope: scope, currentScope: scope,
            requestedGeneration: 4, currentGeneration: 4))
        #expect(!ForYouPageLayout.shouldApplyPaginationResult(
            requestedScope: scope, currentScope: scope,
            requestedGeneration: 3, currentGeneration: 4))
        for otherScope in SocialFeedScope.allCases where otherScope != scope {
            #expect(!ForYouPageLayout.shouldApplyPaginationResult(
                requestedScope: scope, currentScope: otherScope,
                requestedGeneration: 4, currentGeneration: 4))
        }
    }
}

@Test func playNextRetainsOriginatingSocialScopeInsteadOfOpeningForYou() {
    for scope in SocialFeedScope.allCases {
        let destination = ForYouPageLayout.contextAfterPlayingNext(
            currentScope: scope, nextGameID: "game-next")
        #expect(destination.scope == scope, "Play Next changed the originating \(scope.rawValue) feed")
        #expect(destination.searchText.isEmpty, "Play Next must reveal the target card")
        #expect(destination.selectedGameID == "game-next")
    }
}

@Test func forYouPagerSelectionReconcilesRefreshAndPaginationChanges() {
    #expect(ForYouPageLayout.reconciledSelection(currentID: "game-2", availableIDs: ["game-1", "game-2"]) == "game-2")
    #expect(ForYouPageLayout.reconciledSelection(currentID: "removed-game", availableIDs: ["game-3", "game-4"]) == "game-3")
    #expect(ForYouPageLayout.reconciledSelection(currentID: nil, availableIDs: ["game-5"]) == "game-5")
    #expect(ForYouPageLayout.reconciledSelection(currentID: "game-5", availableIDs: []) == nil)
}

@Test func forYouPagerTracksImpressionsOnlyAfterPageSettles() {
    #expect(ForYouPageLayout.impressionMinimumDwellMilliseconds == 700)
    #expect(!ForYouPageLayout.shouldTrackImpression(isSettled: false))
    #expect(!ForYouPageLayout.shouldTrackImpression(isSettled: false, dwellMilliseconds: 10_000))
    #expect(!ForYouPageLayout.shouldTrackImpression(isSettled: true, dwellMilliseconds: 699))
    #expect(ForYouPageLayout.shouldTrackImpression(isSettled: true, dwellMilliseconds: 700))
    #expect(ForYouPageLayout.shouldTrackImpression(isSettled: true, dwellMilliseconds: 1_500))
}



@Test func playerStageLayoutUsesFullWidthOnPhoneAndPortraitStageOnIPad() {
    #expect(PlayerStageLayout.width(containerWidth: 390, containerHeight: 844, isRegular: false) == 390)
    #expect(PlayerStageLayout.width(containerWidth: 1024, containerHeight: 768, isRegular: true) == 432)
    #expect(PlayerStageLayout.width(containerWidth: 768, containerHeight: 1024, isRegular: true) == 560)
}


@MainActor @Test func playerURLRejectsEmptyGameIDAndNormalizesUnsupportedQuality() {
    #expect(PlayerWebViewPool.playerURL(gameID: "   ") == nil)

    let url = PlayerWebViewPool.playerURL(gameID: " game-1 ", quality: "ultra")
    #expect(url != nil)
    guard let url else { return }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let values = Dictionary(uniqueKeysWithValues: query.compactMap { item in
        item.value.map { (item.name, $0) }
    })
    #expect(values["game"] == "game-1")
    #expect(values["quality"] == "low" || values["quality"] == "high")
    #expect(values["quality"] != "ultra")
}


@Test func playerLoadFailuresUseSafeActionableMessages() {
    let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    let malformedPackage = NSError(domain: "GamePackage", code: 1)

    #expect(PlayerLoadFailure.category(for: timeout) == .network)
    #expect(PlayerLoadFailure.userMessage(for: timeout) == "Check your connection and try again.")
    #expect(PlayerLoadFailure.category(for: malformedPackage) == .unknown)
    #expect(PlayerLoadFailure.userMessage(for: malformedPackage) == "The player couldn't load this game.")
    #expect(!PlayerLoadFailure.userMessage(for: malformedPackage).contains("GamePackage"))
}


@Test func playerNavigationFailureIsReportedOnlyOncePerAttempt() {
    var gate = PlayerNavigationFailureGate()
    #expect(gate.shouldReportFailure())
    #expect(!gate.shouldReportFailure())

    gate.beginNavigation()
    #expect(gate.shouldReportFailure())
    #expect(!gate.shouldReportFailure())
}

@Test func playerPrewarmDoesNotCacheHTTPErrorPages() {
    #expect(PlayerPrewarmResponsePolicy.shouldCacheResponse(statusCode: 200))
    #expect(PlayerPrewarmResponsePolicy.shouldCacheResponse(statusCode: 304))
    #expect(!PlayerPrewarmResponsePolicy.shouldCacheResponse(statusCode: 400))
    #expect(!PlayerPrewarmResponsePolicy.shouldCacheResponse(statusCode: 404))
    #expect(!PlayerPrewarmResponsePolicy.shouldCacheResponse(statusCode: 503))
}

@Test func playerHTTPFailuresDistinguishRetryableServerErrorsFromPermanentErrors() {
    for status in [408, 425, 429, 500, 502, 503, 504] {
        let error = PlayerLoadFailure.httpError(statusCode: status)
        #expect(PlayerLoadFailure.category(for: error) == .network)
        #expect(PlayerLoadFailure.userMessage(for: error) == "Check your connection and try again.")
    }
    #expect(PlayerLoadFailure.category(for: PlayerLoadFailure.httpError(statusCode: 404)) == .unavailable)
    #expect(PlayerLoadFailure.category(for: PlayerLoadFailure.httpError(statusCode: 426)) == .incompatible)
}

@Test func playerWebContentTerminationRecoveryIsBounded() {
    #expect(PlayerWebContentTerminationPolicy.shouldAutomaticallyReload(completedReloads: 0))
    #expect(PlayerWebContentTerminationPolicy.shouldAutomaticallyReload(completedReloads: 1))
    #expect(!PlayerWebContentTerminationPolicy.shouldAutomaticallyReload(completedReloads: 2))
    #expect(!PlayerWebContentTerminationPolicy.shouldAutomaticallyReload(completedReloads: 3))
    #expect(!PlayerWebContentTerminationPolicy.shouldAutomaticallyReload(completedReloads: -1))
    #expect(PlayerWebContentTerminationPolicy.repeatedTerminationMessage.contains("Close and reopen the game"))
}


@Test func playerHTTPErrorCategoryMatrixCoversRecoveryContracts() {
    let cases: [(status: Int, category: PlayerLoadFailure.Category, action: String)] = [
        (400, .invalidPackage, "resource limits"),
        (401, .accessDenied, "sign in again"),
        (403, .accessDenied, "sign in again"),
        (404, .unavailable, "Return to the feed"),
        (409, .invalidPackage, "resource limits"),
        (410, .unavailable, "Return to the feed"),
        (413, .invalidPackage, "resource limits"),
        (422, .invalidPackage, "resource limits"),
        (408, .network, "try again"),
        (425, .network, "try again"),
        (429, .network, "try again"),
        (500, .network, "try again"),
        (502, .network, "try again"),
        (503, .network, "try again"),
        (504, .network, "try again"),
        (426, .incompatible, "Update the app")
    ]

    for item in cases {
        let error = PlayerLoadFailure.httpError(statusCode: item.status)
        #expect(PlayerLoadFailure.category(for: error) == item.category)
        #expect(PlayerLoadFailure.userMessage(for: error).contains(item.action))
    }

    let unexpected = PlayerLoadFailure.httpError(statusCode: 418)
    #expect(PlayerLoadFailure.category(for: unexpected) == .unknown)
    #expect(PlayerLoadFailure.userMessage(for: unexpected) == "The player couldn't load this game.")
}


@Test func playableExpressionRejectsDuplicateClaimIdentifiersAcrossCategories() throws {
    let json = """
    {
      "schemaVersion":"1.0",
      "status":"draft",
      "source":{"type":"text","reference":"source-ref"},
      "creator":{"ownerId":"creator-1","consent":true,"visibility":"private"},
      "mode":"what_if",
      "generation":{"seed":1},
      "interpretation":{
        "preserved":[{"id":"same","text":"castle","confidence":0.9}],
        "invented":[{"id":"same","text":"moon","confidence":0.7}]
      }
    }
    """.data(using: .utf8)!
    let expression = try JSONDecoder().decode(PlayableExpression.self, from: json)
    #expect(expression.validationError() == "Interpretation claim identifiers must be unique.")
}


@Test func previewPlaybackFailureReturnsToPoster() {
    #expect(FeedPreviewPolicy.shouldStopOnFailure(.failed))
    #expect(!FeedPreviewPolicy.shouldStopOnFailure(.readyToPlay))
    #expect(!FeedPreviewPolicy.shouldStopOnFailure(.unknown))
}


@Test func sourceUploadRequiresAnImageAndExplicitCreatorConsent() {
    #expect(!PlayableExpression.canSubmitSource(hasImage: false, hasConsent: false))
    #expect(!PlayableExpression.canSubmitSource(hasImage: true, hasConsent: false))
    #expect(!PlayableExpression.canSubmitSource(hasImage: false, hasConsent: true))
    #expect(PlayableExpression.canSubmitSource(hasImage: true, hasConsent: true))
}


@Test func publicPublishingRequiresSeparateConsentAndRejectsDuplicateSubmission() {
    #expect(!PlayableExpression.canPublishPublicly(hasConsent: false, isPublishing: false))
    #expect(!PlayableExpression.canPublishPublicly(hasConsent: true, isPublishing: true))
    #expect(PlayableExpression.canPublishPublicly(hasConsent: true, isPublishing: false))
}

@Test func feedPreviewPathsResolveToBackendBeforeMediaLoading() throws {
    let data = """
    {"games":[{"game_id":"poster-game","title":"A drawing","preview_poster_url":"/v1/games/poster-game/previews/1/poster.png"}]}
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(FeedResponse.self, from: data)
    #expect(response.games[0].previewPosterURL == BackendConfig.baseURL.absoluteString + "/v1/games/poster-game/previews/1/poster.png")
    #expect(FeedGame.resolvePreviewURL("/v1/games/game/clip.mp4") == BackendConfig.baseURL.absoluteString + "/v1/games/game/clip.mp4")
    #expect(FeedGame.resolvePreviewURL("https://cdn.example.test/poster.png") == "https://cdn.example.test/poster.png")
    #expect(FeedGame.resolvePreviewURL("javascript:alert(1)") == nil)
    #expect(FeedGame.resolvePreviewURL("http://insecure.example.test/poster.png") == nil)
    #expect(FeedGame.resolvePreviewURL(nil) == nil)
}

@Test func feedOrientationIsCarriedThroughCardsAndCache() throws {
    let json = """
    {"games":[{"game_id":"penguin","title":"Penguin"}],"cards":[{"game_id":"penguin","title":"Penguin","orientation":"portrait","creator":{"id":"creator"},"preview":{},"viewer":{"liked":false,"saved":false,"following":false}}]}
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(FeedResponse.self, from: json)
    #expect(response.games[0].orientation == "portrait")
    #expect(response.games[0].orientationLabel == "Portrait game")
    let cached = try JSONDecoder().decode(FeedResponse.self, from: JSONEncoder().encode(response))
    #expect(cached.games[0].orientation == "portrait")
    let legacy = try JSONDecoder().decode(FeedGame.self, from: Data("{\"game_id\":\"old\",\"title\":\"Old\"}".utf8))
    #expect(legacy.orientationLabel == nil)
    let canonical = try JSONDecoder().decode(FeedGame.self, from: Data("{\"game_id\":\"old\",\"title\":\"Old\",\"game_ir\":{\"game\":{\"orientation\":\"landscape\"}}}".utf8))
    #expect(canonical.orientationLabel == "Landscape game")
}

@Test func nativeRuntimeRejectsUnboundedOrMalformedFirstRenderMetrics() {
    #expect(PlayerRuntimeMetricPolicy.firstSceneRenderSubmitMS(0) == 0)
    #expect(PlayerRuntimeMetricPolicy.firstSceneRenderSubmitMS(16) == 16)
    #expect(PlayerRuntimeMetricPolicy.firstSceneRenderSubmitMS(3_600_000) == 3_600_000)
    #expect(PlayerRuntimeMetricPolicy.firstSceneRenderSubmitMS(-1) == nil)
    #expect(PlayerRuntimeMetricPolicy.firstSceneRenderSubmitMS(3_600_001) == nil)
    #expect(PlayerRuntimeMetricPolicy.firstSceneRenderSubmitMS("16") == nil)
    #expect(PlayerRuntimeMetricPolicy.firstSceneRenderSubmitMS(nil) == nil)
}

@Test func playerPrewarmHandoffCannotLoseCompletionOrReviveDetachedGame() {
    // The handoff observer must be armed. Even then, only an active
    // sheet with completed loading and no terminal callback can reload.
    for isActive in [false, true] {
        for stillLoading in [false, true] {
            for hasObservedTerminalNavigation in [false, true] {
                for recoveryArmed in [false, true] {
                    let shouldRecover = PlayerPrewarmHandoffPolicy.shouldRecoverUnobservedFinish(
                        isActive: isActive,
                        stillLoading: stillLoading,
                        hasObservedTerminalNavigation: hasObservedTerminalNavigation,
                        recoveryArmed: recoveryArmed
                    )
                    #expect(shouldRecover == (
                        recoveryArmed && isActive && !stillLoading && !hasObservedTerminalNavigation
                    ))
                }
            }
        }
    }
}

@Test func nativeMainFrameNavigationAllowsOnlyOwnedGameDocument() {
    let expected = URL(string: "https://game.example.test/player?game=one&quality=low&presentation=play")!
    let otherGame = URL(string: "https://game.example.test/player?game=two&quality=low&presentation=play")!
    let otherQuality = URL(string: "https://game.example.test/player?game=one&quality=high&presentation=play")!
    let remote = URL(string: "https://attacker.example.test/player?game=one&quality=low&presentation=play")!
    let downgraded = URL(string: "http://game.example.test/player?game=one&quality=low&presentation=play")!
    let blank = URL(string: "about:blank")!

    func allows(_ url: URL?, expected target: URL? = expected,
                main: Bool = true, disposing: Bool = false) -> Bool {
        PlayerMainFrameNavigationPolicy.shouldAllow(
            requestURL: url, expectedURL: target,
            isMainFrame: main, isDisposing: disposing
        )
    }

    #expect(allows(expected))
    #expect(!allows(otherGame))
    #expect(!allows(otherQuality))
    #expect(!allows(remote))
    #expect(!allows(downgraded))
    #expect(!allows(nil))
    #expect(!allows(blank))
    #expect(!allows(expected, expected: nil))
    // A blank navigation is permitted only to tear down the pooled view.
    #expect(allows(blank, expected: nil, disposing: true))
    #expect(!allows(remote, expected: nil, disposing: true))
    // Images/iframes are governed by WebKit origin/CSP, not this main-frame gate.
    #expect(allows(remote, main: false))
}

@Test func firstAcceptedRuntimeInputStartsSessionExactlyOnce() {
    var gate = PlayerFirstInputGate()
    #expect(gate.accepted == false)
    // Swift Testing expectation macros wrap operands in immutable closures:
    // evaluate every mutating state-machine transition *before* #expect.
    let missing = gate.accept(milliseconds: nil)
    let negative = gate.accept(milliseconds: -1)
    let excessive = gate.accept(milliseconds: 86_400_001)
    #expect(missing == false)
    #expect(negative == false)
    #expect(excessive == false)
    let first = gate.accept(milliseconds: 0)
    #expect(first == true)
    #expect(gate.accepted == true)
    let duplicate = gate.accept(milliseconds: 16)
    let later = gate.accept(milliseconds: 86_400_000)
    #expect(duplicate == false)
    #expect(later == false)
}

@Test func firstInputGateAcceptsMaximumValidDuration() {
    var gate = PlayerFirstInputGate()
    let first = gate.accept(milliseconds: 86_400_000)
    let duplicate = gate.accept(milliseconds: 86_400_000)
    #expect(first == true)
    #expect(duplicate == false)
}

@Test func speculativePlayerPrewarmExpiresOnlyIfUnattachedAndNotSuperseded() {
    #expect(PlayerPrewarmBudgetPolicy.expiryNanoseconds == 15_000_000_000)
    #expect(PlayerPrewarmBudgetPolicy.shouldExpire(
        isAttached: false, scheduledEpoch: 8, currentEpoch: 8
    ))
    #expect(!PlayerPrewarmBudgetPolicy.shouldExpire(
        isAttached: true, scheduledEpoch: 8, currentEpoch: 8
    ))
    #expect(!PlayerPrewarmBudgetPolicy.shouldExpire(
        isAttached: false, scheduledEpoch: 8, currentEpoch: 9
    ))
    #expect(!PlayerPrewarmBudgetPolicy.shouldExpire(
        isAttached: true, scheduledEpoch: 8, currentEpoch: 9
    ))
}

@Test func playerAttachmentLeaseRejectsStaleCoordinatorDismantle() {
    func owns(_ pooled: Bool, _ attached: Bool,
              _ expected: UInt64, _ current: UInt64) -> Bool {
        PlayerAttachmentLeasePolicy.mayRecycle(
            isCurrentPooledView: pooled,
            isAttached: attached,
            expectedLease: expected,
            currentLease: current
        )
    }
    // Normal close of the currently attached game may recycle its WebView.
    #expect(owns(true, true, 1, 1))
    #expect(owns(true, true, 100, 100))
    // A retry may mount a new Coordinator before SwiftUI dismantles
    // the previous one, even when they temporarily share the SAME view.
    #expect(!owns(true, true, 1, 2))
    #expect(!owns(true, true, 2, 3))
    // A former lease must not remove a successor's script message handler
    // or blank its active WebKit navigation.
    #expect(!owns(false, true, 2, 2))
    #expect(!owns(true, false, 2, 2))
    #expect(!owns(true, true, 0, 0))
    #expect(!owns(true, true, 0, 1))
    #expect(!owns(true, true, 3, 2))
    // Account replacement/recycle invalidates the old pool owner.
    #expect(!owns(false, false, 1, 1))
}

@Test func prewarmCompletionCannotMarkOldOrSessionRevokedViewLoaded() {
    let original = URL(string: "https://example.test/player?game=sky&quality=high")!
    let same = URL(string: "https://example.test/player?game=sky&quality=high")!
    let alternateQuality = URL(string: "https://example.test/player?game=sky&quality=low")!
    let otherGame = URL(string: "https://example.test/player?game=other&quality=high")!
    func accepts(_ current: Bool, _ expected: URL?, _ actual: URL?) -> Bool {
        PlayerPrewarmCompletionPolicy.shouldRecordLoaded(
            isCurrentPooledView: current, expectedURL: expected, actualURL: actual
        )
    }
    // A canonical current WebView can finish prewarming or finish after its
    // delegate has transferred to the interactive player.
    #expect(accepts(true, original, same))
    // Credential rotation drops ownership even if the new game URL is
    // textually identical to the old view's URL.
    #expect(!accepts(false, original, same))
    #expect(!accepts(false, otherGame, otherGame))
    // A different quality/replaced game must not poison loadedURL.
    #expect(!accepts(true, original, alternateQuality))
    #expect(!accepts(true, original, otherGame))
    // Explicit recycle / invalidation sets currentURL=nil; not loaded.
    #expect(!accepts(true, nil, same))
    #expect(!accepts(true, original, nil))
    #expect(!accepts(false, nil, nil))
}

@Test func playerSessionCacheIsBoundToOneCredentialFingerprint() {
    #expect(!PlayerSessionCachePolicy.shouldPurge(
        cachedFingerprint: nil, currentFingerprint: "anonymous"
    ))
    #expect(!PlayerSessionCachePolicy.shouldPurge(
        cachedFingerprint: "session-A", currentFingerprint: "session-A"
    ))
    #expect(PlayerSessionCachePolicy.shouldPurge(
        cachedFingerprint: "session-A", currentFingerprint: "session-B"
    ))
    #expect(PlayerSessionCachePolicy.shouldPurge(
        cachedFingerprint: "session-A", currentFingerprint: "anonymous"
    ))
    #expect(PlayerSessionCachePolicy.shouldPurge(
        cachedFingerprint: "anonymous", currentFingerprint: "session-B"
    ))
}

// Owner-project data is private; a changed credential invalidates in-flight
// results even when the server subject and UI owner ID have not changed.
@Test func creatorStudioRejectsStaleOwnerAndRotatedSessionResponses() {
    func allowed(_ originalOwner: String, _ currentOwner: String,
                 _ originalToken: String?, _ currentToken: String?,
                 _ originalRevision: Int = 5, _ currentRevision: Int = 5) -> Bool {
        CreatorStudioRequestPolicy.canApply(
            startedRevision: originalRevision, currentRevision: currentRevision,
            startedOwner: originalOwner, currentOwner: currentOwner,
            startedToken: originalToken, currentToken: currentToken)
    }
    #expect(allowed("owner-A", "owner-A", "token-A", "token-A"))
    #expect(!allowed("owner-A", "owner-A", "token-A", "token-B"))
    #expect(!allowed("owner-A", "owner-B", "token-A", "token-B"))
    #expect(!allowed("owner-A", "", "token-A", nil))
    #expect(!allowed("owner-A", "owner-A", "token-A", "token-A", 5, 6))
    #expect(!allowed("owner-A", "owner-A", nil, "token-A"))
    #expect(!allowed("", "", nil, nil))
}

@Test func playerNativeSheetRejectsStaleAndRevokedEpochCallbacks() {
    #expect(PlayerLaunchCallbackGate.accepts(
        expectedEpoch: 0, currentEpoch: 0, sessionRevoked: false
    ))
    #expect(PlayerLaunchCallbackGate.accepts(
        expectedEpoch: 3, currentEpoch: 3, sessionRevoked: false
    ))
    #expect(!PlayerLaunchCallbackGate.accepts(
        expectedEpoch: 2, currentEpoch: 3, sessionRevoked: false
    ))
    #expect(!PlayerLaunchCallbackGate.accepts(
        expectedEpoch: 4, currentEpoch: 3, sessionRevoked: false
    ))
    #expect(!PlayerLaunchCallbackGate.accepts(
        expectedEpoch: 3, currentEpoch: 3, sessionRevoked: true
    ))
    #expect(!PlayerLaunchCallbackGate.accepts(
        expectedEpoch: -1, currentEpoch: -1, sessionRevoked: false
    ))
}


@Test func delayedPosterAndLoadingHintCannotMutateRetiredPlayerAttempt() {
    let fade = PlayerTransientPresentationPolicy.mayFinishPosterFade
    let hint = PlayerTransientPresentationPolicy.mayShowSlowLoadHint
    // Fresh, successful navigation can finish its poster fade, not show a
    // loading hint; active loading has the inverse permissions.
    #expect(fade(4, 4, false, false, false))
    #expect(!hint(4, 4, false, false, false))
    #expect(hint(4, 4, false, true, false))
    #expect(!fade(4, 4, false, true, false))
    // Earlier scheduled timer, later retry (or identity switch) must never
    // touch the active sheet's poster or slow-hint state.
    for (expected, current, revoked, loading, hasError) in [
        (3, 4, false, false, false),
        (3, 4, false, true, false),
        (5, 4, false, false, false),
        (4, 4, true, false, false),
        (4, 4, true, true, false),
        (4, 4, false, true, true),
        (4, 4, false, false, true),
        (-1, 4, false, false, false),
    ] {
        #expect(!fade(expected, current, revoked, loading, hasError))
        #expect(!hint(expected, current, revoked, loading, hasError))
    }
}

@Test func runtimeMetricSequenceGateIsBoundedMonotonicAndKindAllowlisted() {
    var gate = PlayerRuntimeMetricSequenceGate()
    let firstRender = gate.accept(metric: "first_scene_render_submit", sequence: 1)
    let duplicateRender = gate.accept(metric: "first_scene_render_submit", sequence: 1)
    let newerRender = gate.accept(metric: "first_scene_render_submit", sequence: 5)
    let oldRender = gate.accept(metric: "first_scene_render_submit", sequence: 3)
    let independentInput = gate.accept(metric: "first_input", sequence: 2)
    let firstWindow = gate.accept(metric: "perf_window", sequence: 8)
    let invalidKind = gate.accept(metric: "unbounded_custom_metric", sequence: 10)
    let invalidLow = gate.accept(metric: "perf_window", sequence: -1)
    let invalidHigh = gate.accept(metric: "perf_window", sequence: 100_001)
    #expect(firstRender)
    #expect(!duplicateRender)
    #expect(newerRender)
    #expect(!oldRender)
    #expect(independentInput)
    #expect(firstWindow)
    #expect(!invalidKind)
    #expect(!invalidLow)
    #expect(!invalidHigh)
    #expect(gate.highestSequenceByMetric.count == 3)
    #expect(gate.highestSequenceByMetric["first_scene_render_submit"] == 5)
    #expect(gate.highestSequenceByMetric["first_input"] == 2)
    #expect(gate.highestSequenceByMetric["perf_window"] == 8)
    gate.reset()
    #expect(gate.highestSequenceByMetric.isEmpty)
    let freshSession = gate.accept(metric: "first_scene_render_submit", sequence: 1)
    #expect(freshSession)
}

@Test func firstSceneRenderSubmissionGateAcceptsOneValidMilestoneOnly() {
    var gate = PlayerFirstSceneRenderSubmissionGate()
    let missing = gate.accept(milliseconds: nil)
    let negative = gate.accept(milliseconds: -1)
    let excessive = gate.accept(milliseconds: 3_600_001)
    let first = gate.accept(milliseconds: 0)
    let repeatedNewSequence = gate.accept(milliseconds: 50)
    #expect(!missing)
    #expect(!negative)
    #expect(!excessive)
    #expect(first)
    #expect(!repeatedNewSequence)
    #expect(gate.accepted)

    var boundary = PlayerFirstSceneRenderSubmissionGate()
    let maximum = boundary.accept(milliseconds: 3_600_000)
    #expect(maximum)
    #expect(boundary.accepted)
}



@Test func playerMemoryPressureEvictsOnlyUnattachedSpeculativePrewarm() {
    // Delayed notification callbacks must observe current pool ownership.
    // An active game is never interrupted even if it reuses a warmed view.
    func mayEvict(_ attached: Bool, _ hasView: Bool) -> Bool {
        PlayerPrewarmMemoryPressurePolicy.shouldDiscard(
            isAttached: attached, hasPooledView: hasView
        )
    }
    #expect(mayEvict(false, true))
    #expect(!mayEvict(true, true))
    #expect(!mayEvict(false, false))
    #expect(!mayEvict(true, false))
}


// Saved games are owner-private even when the UI also has on-device recent
// entries. No response from the old user or an old retry may restore titles.
@Test func arcadePulseLibrarySavedResponsesAreAccountBound() {
    func accepted(_ startedOwner: String, _ currentOwner: String,
                  _ startedToken: String?, _ currentToken: String?,
                  _ startedRevision: Int = 9, _ currentRevision: Int = 9) -> Bool {
        LibrarySavedRequestPolicy.canApply(
            startedRevision: startedRevision, currentRevision: currentRevision,
            startedOwner: startedOwner, currentOwner: currentOwner,
            startedToken: startedToken, currentToken: currentToken)
    }
    #expect(accepted("A", "A", "credential-A", "credential-A"))
    #expect(!accepted("A", "B", "credential-A", "credential-B"))
    #expect(!accepted("A", "", "credential-A", nil))
    #expect(!accepted("A", "A", "credential-A", "credential-new"))
    #expect(!accepted("A", "A", "credential-A", "credential-A", 9, 10))
    #expect(!accepted("", "", nil, nil))
    #expect(!accepted("A", "A", nil, nil))
    #expect(!accepted("A", "A", nil, "credential-A"))

    // Defensive render gate also protects views that were offscreen when
    // the account-switch notification was sent.
    let firstCredential = LibrarySavedRequestPolicy.digest("bearer-A")
    let rotatedCredential = LibrarySavedRequestPolicy.digest("bearer-rotated")
    let sameCredential = LibrarySavedRequestPolicy.digest("bearer-A")
    func visible(_ storedOwner: String?, _ currentOwner: String,
                 _ storedDigest: Data?, _ currentDigest: Data?) -> Bool {
        LibrarySavedRequestPolicy.canDisplay(
            loadedOwner: storedOwner, currentOwner: currentOwner,
            loadedSessionDigest: storedDigest, currentSessionDigest: currentDigest
        )
    }
    #expect(visible("A", "A", firstCredential, sameCredential))
    #expect(!visible("A", "B", firstCredential, sameCredential))
    #expect(!visible("A", "", firstCredential, sameCredential))
    #expect(!visible(nil, "A", firstCredential, sameCredential))
    #expect(!visible("A", "A", firstCredential, rotatedCredential))
    #expect(!visible("A", "A", nil, sameCredential))
    #expect(!visible("A", "A", firstCredential, nil))
    #expect(LibrarySavedRequestPolicy.digest(nil) == nil)
}


// Previously a single UserDefaults key persisted published and possibly
// restricted-scope feed titles across every account on the device. New
// storage keys are deterministic per subject, and the old unscoped list is
// discarded rather than migrated to whichever account logs in first.
@Test func arcadePulseRecentHistoryNeverLeaksAcrossAccounts() {
    let guest = RecentGames.storageKey(for: "")
    let ownerA = RecentGames.storageKey(for: "private-owner-A")
    let ownerB = RecentGames.storageKey(for: "private-owner-B")
    #expect(guest != ownerA)
    #expect(guest != ownerB)
    #expect(ownerA != ownerB)
    #expect(ownerA == RecentGames.storageKey(for: "private-owner-A"))
    #expect(!ownerA.contains("private-owner-A"))
    #expect(!ownerB.contains("private-owner-B"))
    #expect(ownerA != RecentGames.legacyKey)
    #expect(guest != RecentGames.legacyKey)

    let suite = "hephaestus.recent-history-privacy-tests"
    guard let defaults = UserDefaults(suiteName: suite) else {
        Issue.record("Could not create an isolated UserDefaults test suite")
        return
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacy = Data("previous account's private game title".utf8)
    defaults.set(legacy, forKey: RecentGames.legacyKey)
    let ownerAHistory = [RecentGame(gameID: "private-game-A", title: "Owner A's private title")]
    let ownerBHistory = [RecentGame(gameID: "public-game-B", title: "Owner B's recent game")]
    defaults.set(try? JSONEncoder().encode(ownerAHistory), forKey: ownerA)
    defaults.set(try? JSONEncoder().encode(ownerBHistory), forKey: ownerB)
    #expect(RecentGames.load(for: "private-owner-A", defaults: defaults).map(\.gameID) == ["private-game-A"])
    #expect(RecentGames.load(for: "private-owner-B", defaults: defaults).map(\.gameID) == ["public-game-B"])
    #expect(RecentGames.load(for: "", defaults: defaults).isEmpty)
    // The actual load path purges old unscoped history instead of gifting
    // its game title to the first account that opens Library after update.
    #expect(defaults.data(forKey: RecentGames.legacyKey) == nil)
    #expect(defaults.data(forKey: ownerA) != nil)
    #expect(defaults.data(forKey: ownerB) != nil)

    // A login/logout boundary also retires anonymous history, preserving
    // authenticated account shelves.
    defaults.set(try? JSONEncoder().encode(ownerBHistory), forKey: guest)
    #expect(RecentGames.load(for: "", defaults: defaults).count == 1)
    RecentGames.clearGuestHistory(defaults: defaults)
    #expect(RecentGames.load(for: "", defaults: defaults).isEmpty)
    #expect(RecentGames.load(for: "private-owner-A", defaults: defaults).count == 1)
    #expect(RecentGames.load(for: "private-owner-B", defaults: defaults).count == 1)
}

// A live HTTPS outage is a real error; it must produce a legible recovery
// explanation rather than raw TLS/certificate jargon or fabricated feed cards.
@Test func arcadePulseFeedFailureCopyIsActionableAndTruthful() {
    let secure = FeedErrorPresentation.message(for: URLError(.secureConnectionFailed))
    #expect(secure.contains("secure connection"))
    #expect(!secure.localizedCaseInsensitiveContains("TLS"))
    #expect(!secure.localizedCaseInsensitiveContains("certificate"))
    #expect(FeedErrorPresentation.message(for: URLError(.serverCertificateUntrusted)) == secure)

    let offline = FeedErrorPresentation.message(for: URLError(.notConnectedToInternet))
    #expect(offline.localizedCaseInsensitiveContains("offline"))
    #expect(FeedErrorPresentation.message(for: URLError(.networkConnectionLost)) == offline)

    let timeout = FeedErrorPresentation.message(for: URLError(.timedOut))
    #expect(timeout.localizedCaseInsensitiveContains("try again"))

    let unexpected = FeedErrorPresentation.message(for: NSError(domain: "other", code: 500))
    #expect(unexpected.contains("isn't available"))
    #expect(!unexpected.localizedCaseInsensitiveContains("NSError"))
}

@Test func productionHostLifecycleTransitionsKeepMilestonesDistinct() {
    var lifecycle = PlayerHostLaunchReducer()
    #expect(lifecycle.phase == .navigating)
    #expect(lifecycle.isAttached)
    #expect(!lifecycle.observedTerminalNavigation)

    let htmlLoaded = lifecycle.navigationFinished()
    #expect(htmlLoaded)
    #expect(lifecycle.phase == .documentLoaded)
    #expect(lifecycle.observedTerminalNavigation)
    // Navigation finish is NOT proof of a rendered frame or interaction.
    let sceneSubmitted = lifecycle.sceneSubmitted()
    #expect(sceneSubmitted)
    #expect(lifecycle.phase == .sceneSubmitted)
    let inputAccepted = lifecycle.firstInput(milliseconds: 120)
    #expect(inputAccepted)
    #expect(lifecycle.phase == .interactive)
    let duplicateFinish = lifecycle.navigationFinished()
    let duplicateScene = lifecycle.sceneSubmitted()
    let duplicateInput = lifecycle.firstInput(milliseconds: 200)
    #expect(!duplicateFinish)
    #expect(!duplicateScene)
    #expect(!duplicateInput)
    #expect(lifecycle.phase == .interactive)
    lifecycle.detach()
    #expect(lifecycle.phase == .detached)
    #expect(!lifecycle.permitsRuntimeEvents)
    let staleFinish = lifecycle.navigationFinished()
    let staleInput = lifecycle.firstInput(milliseconds: 5)
    let staleScene = lifecycle.sceneSubmitted()
    let staleCrash = lifecycle.webProcessTerminated()
    #expect(!staleFinish)
    #expect(!staleInput)
    #expect(!staleScene)
    #expect(!staleCrash)
}

@Test func productionHostLifecyclePrewarmAndMetricsMayArriveOutOfOrder() {
    var lifecycle = PlayerHostLaunchReducer()
    // A prewarmed page may begin sending events before the new
    // Coordinator receives didFinish. Do not lie about HTML readiness.
    let firstInput = lifecycle.firstInput(milliseconds: 10)
    #expect(firstInput)
    #expect(lifecycle.phase == .interactive)
    let lateScene = lifecycle.sceneSubmitted()
    #expect(lateScene)
    #expect(lifecycle.phase == .interactive)
    let lateFinish = lifecycle.navigationFinished()
    #expect(lateFinish)
    #expect(lifecycle.phase == .interactive)
    #expect(lifecycle.observedTerminalNavigation)
    let duplicateScene = lifecycle.sceneSubmitted()
    #expect(!duplicateScene)
}

@Test func productionHostLifecycleFailedAndTerminatedSessionsStayTerminal() {
    var failed = PlayerHostLaunchReducer()
    let failure = failed.navigationFailed()
    #expect(failure)
    #expect(failed.phase == .navigationFailed)
    #expect(failed.observedTerminalNavigation)
    failed.navigationStarted()
    #expect(failed.phase == .navigationFailed)
    let lateFinish = failed.navigationFinished()
    let lateScene = failed.sceneSubmitted()
    let lateInput = failed.firstInput(milliseconds: 3)
    let repeatedFailure = failed.navigationFailed()
    #expect(!lateFinish)
    #expect(!lateScene)
    #expect(!lateInput)
    #expect(!repeatedFailure)
    let failCannotCrashAgain = failed.webProcessTerminated()
    #expect(!failCannotCrashAgain)
    #expect(failed.phase == .navigationFailed)

    var terminated = PlayerHostLaunchReducer()
    let ready = terminated.sceneSubmitted()
    #expect(ready)
    let processDied = terminated.webProcessTerminated()
    #expect(processDied)
    #expect(terminated.phase == .webProcessTerminated)
    terminated.navigationStarted()
    #expect(terminated.phase == .webProcessTerminated)
    let postMortemInput = terminated.firstInput(milliseconds: 5)
    let repeatedCrash = terminated.webProcessTerminated()
    #expect(!postMortemInput)
    #expect(!repeatedCrash)
}

@Test func productionHostLifecycleNavigationRestartResetsMilestonesOnlyWhileActive() {
    var lifecycle = PlayerHostLaunchReducer()
    let start = lifecycle.navigationFinished()
    let input = lifecycle.firstInput(milliseconds: 20)
    #expect(start && input)
    lifecycle.navigationStarted()
    #expect(lifecycle.phase == .navigating)
    #expect(!lifecycle.observedTerminalNavigation)
    let badInput = lifecycle.firstInput(milliseconds: -1)
    let freshScene = lifecycle.sceneSubmitted()
    let freshInput = lifecycle.firstInput(milliseconds: 50)
    #expect(!badInput)
    #expect(freshScene)
    #expect(freshInput)
    #expect(lifecycle.phase == .interactive)
}


@Test func hostRuntimeSessionBindingRejectsStaleWebKitMessagesAfterReload() {
    var gate = PlayerRuntimeSessionBindingGate()
    #expect(PlayerRuntimeSessionBindingGate.maximumRetiredSessions == 8)
    let empty = gate.bind("")
    let oversized = gate.bind(String(repeating: "x", count: 129))
    let first = gate.bind("old-session")
    let repeatedFirst = gate.bind("old-session")
    let conflictingLive = gate.bind("unexpected-live")
    #expect(!empty)
    #expect(!oversized)
    #expect(first)
    #expect(repeatedFirst)
    #expect(!conflictingLive)
    #expect(gate.activeSessionID == "old-session")

    gate.beginNavigation()
    #expect(gate.activeSessionID == nil)
    #expect(gate.retiredCount == 1)
    let oldCallback = gate.bind("old-session")
    let newDocument = gate.bind("new-session")
    let oldAfterNew = gate.bind("old-session")
    let conflictingNew = gate.bind("third-session")
    #expect(!oldCallback)
    #expect(newDocument)
    #expect(!oldAfterNew)
    #expect(!conflictingNew)
    #expect(gate.activeSessionID == "new-session")
    gate.clear()
    #expect(gate.retiredCount == 0)
    #expect(gate.activeSessionID == nil)
    let freshCoordinator = gate.bind("old-session")
    #expect(freshCoordinator)
}

@Test func hostRuntimeSessionBindingRetainsOnlyEightMostRecentDocuments() {
    var gate = PlayerRuntimeSessionBindingGate()
    var accepted = [Bool]()
    for i in 0..<16 {
        accepted.append(gate.bind("session-\(i)"))
        gate.beginNavigation()
        #expect(gate.retiredCount <= 8)
    }
    #expect(accepted.allSatisfy { $0 })
    #expect(gate.retiredCount == 8)
    for i in 8..<16 {
        let rejected = gate.bind("session-\(i)")
        #expect(!rejected)
    }
    let current = gate.bind("session-16")
    #expect(current)
    #expect(gate.activeSessionID == "session-16")
}

@Test func hostNavigationRestartsMetricEpochWithoutLyingAboutReadiness() {
    var lifecycle = PlayerHostLaunchReducer()
    var sequence = PlayerRuntimeMetricSequenceGate()
    var scene = PlayerFirstSceneRenderSubmissionGate()
    // Capture all mutating transition outcomes before Swift Testing macros:
    // #expect expands closure expressions with an immutable capture context.
    let firstSequence = sequence.accept(metric: "first_scene_render_submit", sequence: 1)
    let firstScene = scene.accept(milliseconds: 30)
    let firstSubmitted = lifecycle.sceneSubmitted()
    let firstInputSequence = sequence.accept(metric: "first_input", sequence: 2)
    let firstInput = lifecycle.firstInput(milliseconds: 70)
    let firstInteractive = lifecycle.phase == .interactive
    #expect(firstSequence && firstScene && firstSubmitted && firstInputSequence && firstInput)
    #expect(firstInteractive)

    // New WK document rotates session + metric gates on navigation start.
    lifecycle.navigationStarted()
    sequence.reset()
    scene = PlayerFirstSceneRenderSubmissionGate()
    let isNavigating = lifecycle.phase == .navigating
    let nextSequence = sequence.accept(metric: "first_scene_render_submit", sequence: 1)
    let nextScene = scene.accept(milliseconds: 20)
    let nextSubmitted = lifecycle.sceneSubmitted()
    let nextInputSequence = sequence.accept(metric: "first_input", sequence: 2)
    let nextInput = lifecycle.firstInput(milliseconds: 60)
    let nextInteractive = lifecycle.phase == .interactive
    let duplicateSequence = sequence.accept(metric: "first_input", sequence: 2)
    let duplicateScene = scene.accept(milliseconds: 50)
    #expect(isNavigating)
    #expect(nextSequence && nextScene && nextSubmitted && nextInputSequence && nextInput)
    #expect(nextInteractive)
    #expect(!duplicateSequence && !duplicateScene)
}
