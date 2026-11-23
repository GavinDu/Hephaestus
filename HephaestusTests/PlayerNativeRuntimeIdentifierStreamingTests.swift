import Foundation
import Testing
@testable import Hephaestus

/// #743 is distinct from completed #451: admission already rejected >128
/// bytes, but previously allocated/copy-converted ALL untrusted UTF-8 first.
struct PlayerNativeRuntimeIdentifierStreamingTests {
    @Test func idValidatorsPreserveExistingExactGrammarAndBoundary() {
        let ids = PlayerNativeRuntimeIdentifierPolicy.self
        #expect(ids.maximumBytes == 128)
        for count in [1, 2, 64, 127, 128] {
            let id = String(repeating: "x", count: count)
            #expect(ids.validSessionID(id))
            #expect(ids.validRunID(id))
        }
        #expect(!ids.validSessionID(""))
        #expect(!ids.validRunID(""))
        #expect(!ids.validSessionID(String(repeating: "a", count: 129)))
        #expect(!ids.validRunID(String(repeating: "a", count: 129)))
        #expect(ids.validSessionID("session-01_!~"))
        #expect(ids.validSessionID("printable/ascii"))
        for id in ["run-1", "A_Z09", "a.b", "three...dots", "~", "-", "_"] {
            #expect(ids.validRunID(id))
        }
        for id in [".", "..", "a/b", "a?b", "a#b", "a%b", "a+b",
                   "a:b", "a\\b", "a@b", "a b", "\t", "\n", "🤖",
                   "e\u{301}", "zero\u{0000}"] {
            #expect(!ids.validRunID(id))
        }
        for id in ["a b", "\t", "\n", "🤖", "e\u{301}",
                   "zero\u{0000}", "\u{007F}"] {
            #expect(!ids.validSessionID(id))
        }
    }

    @Test func rejectedHugeIDsNeverPoisonFutureValidSessionOrRunLookup() {
        // A large attacker-supplied body string is presented as one Swift
        // String, but validation must not allocate a full SECOND UTF-8 copy.
        let large = String(repeating: "x", count: 262_144)
        #expect(!PlayerNativeRuntimeIdentifierPolicy.validSessionID(large))
        #expect(!PlayerNativeRuntimeIdentifierPolicy.validRunID(large))
        var binder = PlayerRuntimeSessionBindingGate()
        var runs = PlayerVerifiedRunNotificationGate()
        let assertionResultL44 = !binder.bind(large)
        #expect(assertionResultL44)
        #expect(binder.activeSessionID == nil)
        let assertionResultL46 = runs.offer(large) == nil
        #expect(assertionResultL46)
        #expect(runs.pendingCount == 0)
        #expect(runs.recentCount == 0)
        let assertionResultL49 = binder.bind("session-actual")
        #expect(assertionResultL49)
        #expect(binder.activeSessionID == "session-actual")
        let assertionResultL51 = runs.offer("run-actual") == "run-actual"
        #expect(assertionResultL51)
        #expect(runs.pendingCount == 1)
    }

    @Test func adversarial160OverlongAndUnicodeIDsDoNotMutateGates() {
        let ids = PlayerNativeRuntimeIdentifierPolicy.self
        for iteration in 0..<160 {
            let suffix = String(iteration)
            let long = String(repeating: "x", count: 129 + iteration) + suffix
            let unicode = "run-🤖" + suffix
            let control = "session\n" + suffix
            let slash = "run/" + suffix
            #expect(!ids.validSessionID(long))
            #expect(!ids.validRunID(long))
            #expect(!ids.validSessionID(unicode))
            #expect(!ids.validRunID(unicode))
            #expect(!ids.validSessionID(control))
            #expect(!ids.validRunID(slash))
            var binder = PlayerRuntimeSessionBindingGate()
            var runs = PlayerVerifiedRunNotificationGate()
            let assertionResultL71 = !binder.bind(long)
            #expect(assertionResultL71)
            let assertionResultL72 = !binder.bind(unicode)
            #expect(assertionResultL72)
            let assertionResultL73 = !binder.bind(control)
            #expect(assertionResultL73)
            let assertionResultL74 = runs.offer(long) == nil
            #expect(assertionResultL74)
            let assertionResultL75 = runs.offer(unicode) == nil
            #expect(assertionResultL75)
            let assertionResultL76 = runs.offer(slash) == nil
            #expect(assertionResultL76)
            #expect(binder.activeSessionID == nil)
            #expect(runs.pendingCount == 0)
            #expect(runs.recentCount == 0)
            let goodSession = "session-" + suffix
            let goodRun = "run-" + suffix
            let assertionResultL82 = binder.bind(goodSession)
            #expect(assertionResultL82)
            let assertionResultL83 = runs.offer(goodRun) == goodRun
            #expect(assertionResultL83)
            #expect(runs.isLatest(goodRun))
        }
    }
}
