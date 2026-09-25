import Foundation

/// Access is serialized by LiveAppleSpeechSession's lock. The scheduler must
/// enqueue its callback, never invoke it synchronously from schedule().
final class AppleSpeechFinalization {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void

    struct Outcome: Equatable {
        let success: Bool
        let text: String
        let error: String?
    }

    static let timeout: TimeInterval = 1.8
    static let timeoutOutcome = Outcome(
        success: false,
        text: "",
        error: "Apple canlı tanıma final sonucu 1800 ms içinde alınamadı."
    )

    private let schedule: Schedule
    private var cancelTimer: (() -> Void)?
    private var hasEndedAudio = false
    private var isTerminal = false

    init(schedule: @escaping Schedule) {
        self.schedule = schedule
    }

    static func scheduler(on queue: DispatchQueue) -> Schedule {
        { delay, callback in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler(handler: callback)
            timer.resume()
            return { timer.cancel() }
        }
    }

    /// Returns whether the caller should end the recognition request's audio.
    func finishAudio(onTimeout: @escaping () -> Void) -> Bool {
        guard !isTerminal, !hasEndedAudio else { return false }
        hasEndedAudio = true
        cancelTimer = schedule(Self.timeout, onTimeout)
        return true
    }

    func receive(text: String, isFinal: Bool) -> Outcome? {
        guard isFinal else { return nil }
        return complete(Outcome(success: true, text: text, error: nil))
    }

    func complete(_ outcome: Outcome) -> Outcome? {
        guard !isTerminal else { return nil }
        cancel()
        return outcome
    }

    func cancel() {
        isTerminal = true
        cancelTimer?()
        cancelTimer = nil
    }
}
