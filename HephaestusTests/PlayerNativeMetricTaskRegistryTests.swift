import Foundation
import Testing
@testable import Hephaestus

/// #750 is a bounded native transport-lifetime test, NOT a mock backend
/// and NOT proof of server-side social telemetry deletion after cancellation.
@MainActor
struct PlayerNativeMetricTaskRegistryTests {
    private func makeTask(_ handles: inout [Task<Void, Never>]) -> Task<Void, Never> {
        let task = Task { @MainActor in await Task.yield() }
        handles.append(task)
        return task
    }

    @Test func twoSlotsAreBoundedAndRevocationCancelsBoth() {
        let registry = PlayerNativeMetricTaskRegistry()
        var handles: [Task<Void, Never>] = []
        #expect(PlayerNativeMetricTaskRegistry.maximumInFlight == 2)
        let first = registry.submit { _, _ in makeTask(&handles) }
        let second = registry.submit { _, _ in makeTask(&handles) }
        let third = registry.submit { _, _ in makeTask(&handles) }
        #expect(first)
        #expect(second)
        #expect(!third)
        #expect(registry.inFlightCount == 2)
        #expect(handles.count == 2)
        let firstEpoch = registry.epoch
        registry.revoke()
        #expect(registry.epoch == firstEpoch + 1)
        #expect(registry.inFlightCount == 0)
        #expect(handles.allSatisfy { $0.isCancelled })
        let next = registry.submit { _, _ in makeTask(&handles) }
        #expect(next)
        #expect(registry.inFlightCount == 1)
        // Stale document completion cannot remove the new document's task.
        registry.complete(taskID: 1, epoch: firstEpoch)
        #expect(registry.inFlightCount == 1)
        registry.complete(taskID: 3, epoch: registry.epoch)
        #expect(registry.inFlightCount == 0)
    }

    @Test func oneHundredSixtyRevokeAndLateCompletionInterleavings() {
        let registry = PlayerNativeMetricTaskRegistry()
        var handles: [Task<Void, Never>] = []
        var mostRecentTaskID: UInt64 = 0
        for iteration in 0..<160 {
            let prior = registry.epoch
            let accepted = registry.submit { taskID, epoch in
                #expect(epoch == prior)
                #expect(taskID > mostRecentTaskID)
                mostRecentTaskID = taskID
                return makeTask(&handles)
            }
            #expect(accepted)
            #expect(registry.inFlightCount == 1)
            if iteration.isMultiple(of: 2) {
                registry.complete(taskID: mostRecentTaskID, epoch: prior)
                #expect(registry.inFlightCount == 0)
            }
            registry.revoke()
            #expect(registry.inFlightCount == 0)
            #expect(registry.epoch == prior + 1)
            // Old delayed network completion cannot remove a later task ID.
            registry.complete(taskID: mostRecentTaskID, epoch: prior)
            #expect(registry.inFlightCount == 0)
        }
        #expect(handles.count == 160)
        #expect(registry.epoch == 160)
        #expect(handles.allSatisfy { $0.isCancelled })
    }

    @Test func independentTaskCompleteReleasesTheExactSlot() {
        let registry = PlayerNativeMetricTaskRegistry()
        var handles: [Task<Void, Never>] = []
        let first = registry.submit { _, _ in makeTask(&handles) }
        let second = registry.submit { _, _ in makeTask(&handles) }
        #expect(first && second)
        registry.complete(taskID: 1, epoch: registry.epoch)
        #expect(registry.inFlightCount == 1)
        // A completed ID cannot release the other concurrently live task.
        registry.complete(taskID: 1, epoch: registry.epoch)
        #expect(registry.inFlightCount == 1)
        registry.complete(taskID: 2, epoch: registry.epoch)
        #expect(registry.inFlightCount == 0)
        registry.revoke()
        #expect(handles.count == 2)
    }
}
