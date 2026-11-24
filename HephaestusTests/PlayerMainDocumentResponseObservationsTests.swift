import Testing
@testable import Hephaestus

struct PlayerMainDocumentResponseObservationsTests {
    @Test func fixedCategoriesAreBoundedAcrossNativeNavigationResets() {
        var observations = PlayerMainDocumentResponseObservations()
        for _ in 0..<160 {
            observations.reset()
            let cases: [(Bool, Int, String)] = [
                (false, 200, "player HTTP observation: prewarm 200"),
                (false, 304, "player HTTP observation: prewarm 304"),
                (true, 200, "player HTTP observation: attached 200"),
                (true, 304, "player HTTP observation: attached 304")
            ]
            for (attached, status, expected) in cases {
                let first = observations.record(statusCode: status, isAttached: attached)
                #expect(first == expected)
                for _ in 0..<8 {
                    let duplicate = observations.record(statusCode: status, isAttached: attached)
                    #expect(duplicate == nil)
                }
            }
        }
    }

    @Test func otherStatusesCannotConsumeOrCreateObservations() {
        var observations = PlayerMainDocumentResponseObservations()
        for status in [-1, 0, 100, 199, 201, 206, 299, 300, 302, 305, 401, 403, 500, Int.max] {
            for attached in [false, true] {
                let result = observations.record(statusCode: status, isAttached: attached)
                #expect(result == nil)
            }
        }
        let observation = observations.record(statusCode: 304, isAttached: true)
        #expect(observation == "player HTTP observation: attached 304")
    }
}
