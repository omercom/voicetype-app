import XCTest
@testable import VoiceTypingCore

final class ConcurrentDictationDeliveryTests: XCTestCase {
    private func beginInjection(_ generation: UInt64, gate: inout DictationDeliveryGate) {
        gate.begin(generation)
        XCTAssertTrue(gate.beginDelivery(generation))
        XCTAssertTrue(gate.beginInjection(generation))
    }

    func testAttemptReleasesGateWhileLeaseRemainsUntilCompletion() {
        var gate = DictationDeliveryGate()
        beginInjection(1, gate: &gate)
        var leaseEnds = 0
        let lease = TargetAppAccessibilityLease { leaseEnds += 1 }
        let delivery = PendingDictationDelivery(generation: 1, recoveryID: UUID(), accessibilityLease: lease)

        XCTAssertTrue(delivery.recordAttempt(gate: &gate))
        XCTAssertNil(gate.currentAttempt(1))
        XCTAssertEqual(leaseEnds, 0)
        XCTAssertTrue(delivery.shouldPresent(currentGeneration: 1, gate: gate))

        gate.begin(2)
        XCTAssertFalse(delivery.shouldPresent(currentGeneration: 2, gate: gate))
        XCTAssertTrue(delivery.complete())
        XCTAssertFalse(delivery.complete())
        XCTAssertEqual(leaseEnds, 1)
        XCTAssertEqual(gate.currentAttempt(2), 0)
        XCTAssertFalse(gate.isDelivering(1))
    }

    func testOldCompletionDoesNotFinishNewDeliveryOrItsLease() {
        var gate = DictationDeliveryGate()
        var oldEnds = 0
        var newEnds = 0
        beginInjection(1, gate: &gate)
        let old = PendingDictationDelivery(generation: 1, recoveryID: UUID(),
                                           accessibilityLease: TargetAppAccessibilityLease { oldEnds += 1 })
        XCTAssertTrue(old.recordAttempt(gate: &gate))
        beginInjection(2, gate: &gate)
        let new = PendingDictationDelivery(generation: 2, recoveryID: UUID(),
                                           accessibilityLease: TargetAppAccessibilityLease { newEnds += 1 })
        XCTAssertFalse(old.shouldPresent(currentGeneration: 2, gate: gate))
        XCTAssertTrue(old.complete())
        XCTAssertEqual(oldEnds, 1)
        XCTAssertEqual(newEnds, 0)
        XCTAssertTrue(gate.isDelivering(2))
        XCTAssertTrue(new.recordAttempt(gate: &gate))
        XCTAssertTrue(new.complete())
        XCTAssertEqual(newEnds, 1)
    }

    func testLateAttemptCannotReleaseNewGenerationOrDisplayFeedback() {
        var gate = DictationDeliveryGate()
        beginInjection(1, gate: &gate)
        let old = PendingDictationDelivery(generation: 1, recoveryID: nil, accessibilityLease: nil)
        gate.begin(2)
        XCTAssertFalse(old.recordAttempt(gate: &gate))
        XCTAssertFalse(old.shouldPresent(currentGeneration: 2, gate: gate))
        XCTAssertEqual(gate.currentAttempt(2), 0)
    }

    func testCancelBeforeAttemptDoesNotDetachAndSuppressesFeedback() {
        var gate = DictationDeliveryGate()
        beginInjection(1, gate: &gate)
        let delivery = PendingDictationDelivery(generation: 1, recoveryID: nil, accessibilityLease: nil)
        delivery.cancel()
        XCTAssertFalse(delivery.recordAttempt(gate: &gate))
        XCTAssertFalse(delivery.shouldPresent(currentGeneration: 1, gate: gate))
        XCTAssertTrue(gate.isDelivering(1))
        XCTAssertTrue(delivery.complete())
    }

    func testOverlappingChromiumLeasesDisableOnlyAfterLastEnd() throws {
        var enabled = false
        var writes: [Bool] = []
        let controller = ChromiumAccessibilityController(
            readEnabled: { _ in enabled },
            setEnabled: { _, value in enabled = value; writes.append(value); return true }
        )
        let first = try XCTUnwrap(controller.beginObservation(processIdentifier: 42, bundleIdentifier: "com.google.Chrome"))
        let second = try XCTUnwrap(controller.beginObservation(processIdentifier: 42, bundleIdentifier: "com.google.Chrome"))
        XCTAssertEqual(writes, [true])
        first.end()
        first.end()
        XCTAssertTrue(enabled)
        XCTAssertEqual(writes, [true])
        second.end()
        XCTAssertFalse(enabled)
        XCTAssertEqual(writes, [true, false])
    }

    func testPreEnabledChromiumAccessibilityIsNeverDisabled() {
        var writes: [Bool] = []
        let controller = ChromiumAccessibilityController(
            readEnabled: { _ in true },
            setEnabled: { _, value in writes.append(value); return true }
        )
        XCTAssertNil(controller.beginObservation(processIdentifier: 42, bundleIdentifier: "com.google.Chrome"))
        XCTAssertNil(controller.beginObservation(processIdentifier: 42, bundleIdentifier: "com.google.Chrome"))
        XCTAssertTrue(writes.isEmpty)
    }

    func testFailedChromiumEnableDoesNotCreateOwnedLease() {
        var writes: [Bool] = []
        let controller = ChromiumAccessibilityController(
            readEnabled: { _ in false },
            setEnabled: { _, value in writes.append(value); return false }
        )
        XCTAssertNil(controller.beginObservation(processIdentifier: 42, bundleIdentifier: "com.google.Chrome"))
        XCTAssertEqual(writes, [true])
    }
}
