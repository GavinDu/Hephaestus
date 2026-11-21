import Foundation
import Testing
@testable import Hephaestus

/// Every transport witness must originate in FeedRequestCoordinator.begin,
/// not a retry button animation, expiry generation or invented feed result.
struct FeedRequestStartEvidenceTests {
    @MainActor @Test func startedCountAdvancesOnlyOnRealBeginAcross160Timeouts() async {
        let coordinator = FeedRequestCoordinator()
        #expect(coordinator.startedRequestCount == 0)

        for iteration in 1...160 {
            let (generation, request) = coordinator.begin {
                try await Task.sleep(for: .seconds(120))
                return try JSONDecoder().decode(
                    FeedResponse.self, from: Data(#"{"games":[]}"#.utf8))
            }
            #expect(coordinator.startedRequestCount == iteration)
            #expect(coordinator.isCurrent(generation))
            #expect(coordinator.expireIfCurrent(generation))
            #expect(!coordinator.isCurrent(generation))
            #expect(coordinator.startedRequestCount == iteration)
            #expect(!coordinator.expireIfCurrent(generation))
            coordinator.finishIfCurrent(generation)
            #expect(coordinator.startedRequestCount == iteration)

            do {
                _ = try await request.value
                Issue.record("A cancelled transport yielded an unexpected fake feed.")
            } catch {
                #expect(error is CancellationError)
            }
        }
    }
}
