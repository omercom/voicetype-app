import Foundation

/// Main-thread state shared by transcription, translation and delivery callbacks.
struct DictationDeliveryGate {
    private var generation: UInt64?
    private var attempt: UInt64 = 0
    private var delivering = false
    private var injectionStarted = false

    mutating func begin(_ generation: UInt64) {
        self.generation = generation
        attempt = 0
        delivering = false
        injectionStarted = false
    }

    func acceptsResult(_ generation: UInt64) -> Bool {
        self.generation == generation && !delivering
    }

    func acceptsResult(_ generation: UInt64, attempt: UInt64) -> Bool {
        acceptsResult(generation) && self.attempt == attempt
    }

    func currentAttempt(_ generation: UInt64) -> UInt64? {
        acceptsResult(generation) ? attempt : nil
    }

    /// Invalidate callbacks from the previous provider before starting a retry.
    mutating func advanceAttempt(_ generation: UInt64, after previous: UInt64) -> UInt64? {
        guard acceptsResult(generation, attempt: previous) else { return nil }
        attempt &+= 1
        return attempt
    }

    mutating func beginDelivery(_ generation: UInt64) -> Bool {
        guard acceptsResult(generation) else { return false }
        delivering = true
        return true
    }

    func isDelivering(_ generation: UInt64) -> Bool {
        self.generation == generation && delivering
    }

    /// Translation can finish asynchronously; only its first result may inject.
    mutating func beginInjection(_ generation: UInt64) -> Bool {
        guard isDelivering(generation), !injectionStarted else { return false }
        injectionStarted = true
        return true
    }

    /// A sent request may continue verification without blocking the next recording.
    mutating func releaseAfterAttempt(_ generation: UInt64) -> Bool {
        guard isDelivering(generation), injectionStarted else { return false }
        finish()
        return true
    }

    mutating func finish() {
        generation = nil
        attempt = 0
        delivering = false
        injectionStarted = false
    }
}

/// Main-thread ownership for a delivery that can outlive its recording.
final class PendingDictationDelivery {
    let generation: UInt64
    let recoveryID: UUID?
    let cancellation = TextInjector.InjectionCancellation()
    private var accessibilityLease: TargetAppAccessibilityLease?
    private(set) var attempted = false
    private(set) var cancelled = false
    private var completed = false

    init(generation: UInt64, recoveryID: UUID?, accessibilityLease: TargetAppAccessibilityLease?) {
        self.generation = generation
        self.recoveryID = recoveryID
        self.accessibilityLease = accessibilityLease
    }

    func recordAttempt(gate: inout DictationDeliveryGate) -> Bool {
        guard !cancelled, !completed, gate.releaseAfterAttempt(generation) else { return false }
        attempted = true
        return true
    }

    func shouldPresent(currentGeneration: UInt64, gate: DictationDeliveryGate) -> Bool {
        !cancelled && !completed && currentGeneration == generation && (attempted || gate.isDelivering(generation))
    }

    func cancel() {
        cancelled = true
        cancellation.cancel()
    }

    @discardableResult
    func complete() -> Bool {
        guard !completed else { return false }
        completed = true
        accessibilityLease?.end()
        accessibilityLease = nil
        return true
    }
}
