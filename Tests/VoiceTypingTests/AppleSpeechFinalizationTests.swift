import XCTest
@testable import VoiceTypingCore

final class AppleSpeechFinalizationTests: XCTestCase {
    private final class ManualScheduler {
        final class Job {
            let deadline: Int
            let callback: () -> Void
            var cancelled = false
            init(deadline: Int, callback: @escaping () -> Void) {
                self.deadline = deadline
                self.callback = callback
            }
        }

        var now = 0
        var jobs: [Job] = []
        var scheduledDeadlines: [Int] = []

        func schedule(delay: TimeInterval, callback: @escaping () -> Void) -> () -> Void {
            let job = Job(deadline: now + Int((delay * 1000).rounded()), callback: callback)
            jobs.append(job)
            scheduledDeadlines.append(job.deadline)
            return { job.cancelled = true }
        }

        func advance(to milliseconds: Int) {
            precondition(milliseconds >= now)
            now = milliseconds
            let due = jobs.filter { $0.deadline <= now }
            jobs.removeAll { $0.deadline <= now }
            for job in due where !job.cancelled { job.callback() }
        }
    }

    private final class Harness {
        let clock = ManualScheduler()
        let policy: AppleSpeechFinalization
        var completions: [AppleSpeechFinalization.Outcome] = []
        var endAudioCount = 0

        init() {
            policy = AppleSpeechFinalization(schedule: clock.schedule)
        }

        func finish() {
            if policy.finishAudio(onTimeout: { [weak self] in
                guard let self = self else { return }
                self.record(self.policy.complete(AppleSpeechFinalization.timeoutOutcome))
            }) {
                endAudioCount += 1
            }
        }

        func receive(_ text: String, final: Bool) {
            record(policy.receive(text: text, isFinal: final))
        }

        func record(_ outcome: AppleSpeechFinalization.Outcome?) {
            if let outcome = outcome { completions.append(outcome) }
        }
    }

    func testFinalMoreThan350msAfterPartialSucceedsAndCompletesOnce() {
        let h = Harness()
        h.receive("partial", final: false)
        h.finish()
        let staleTimeout = h.clock.jobs[0].callback
        h.clock.advance(to: 351)
        XCTAssertTrue(h.completions.isEmpty)
        h.clock.advance(to: 900)
        h.receive("actual final", final: true)
        h.receive("duplicate final", final: true)
        staleTimeout()
        h.clock.advance(to: 1800)
        XCTAssertEqual(h.completions, [.init(success: true, text: "actual final", error: nil)])
        XCTAssertEqual(h.endAudioCount, 1)
    }

    func testNoFinalFailsAtDeadlineWithoutPromotingPartial() {
        let h = Harness()
        h.finish()
        h.clock.advance(to: 1200)
        h.receive("must not become success", final: false)
        h.clock.advance(to: 1799)
        XCTAssertTrue(h.completions.isEmpty)
        h.clock.advance(to: 1800)
        XCTAssertEqual(h.completions, [AppleSpeechFinalization.timeoutOutcome])
        XCTAssertFalse(h.completions[0].success)
        XCTAssertEqual(h.completions[0].text, "")
        XCTAssertNotNil(h.completions[0].error)
        h.receive("too late", final: true)
        XCTAssertEqual(h.completions.count, 1)
    }

    func testDuplicateFinishDoesNotResetDeadlineOrEndAudioAgain() {
        let h = Harness()
        h.finish()
        h.clock.advance(to: 1000)
        h.finish()
        h.receive("partial after duplicate finish", final: false)
        XCTAssertEqual(h.clock.scheduledDeadlines, [1800])
        XCTAssertEqual(h.endAudioCount, 1)
        h.clock.advance(to: 1800)
        XCTAssertEqual(h.completions, [AppleSpeechFinalization.timeoutOutcome])
        h.finish()
        XCTAssertEqual(h.clock.scheduledDeadlines, [1800])
    }

    func testCancelSuppressesFinalAndAlreadyEnqueuedTimeoutCompletion() {
        let h = Harness()
        h.finish()
        let job = h.clock.jobs[0]
        h.receive("partial", final: false)
        h.policy.cancel()
        XCTAssertTrue(job.cancelled)
        h.receive("late final", final: true)
        // Cancellation cannot retract a timer callback already queued for delivery.
        job.callback()
        h.finish()
        h.clock.advance(to: 5000)
        XCTAssertTrue(h.completions.isEmpty)
        XCTAssertEqual(h.endAudioCount, 1)
        XCTAssertEqual(h.clock.scheduledDeadlines, [1800])
    }

    func testThousandSessionsWithReorderedTerminalEventsCompleteAtMostOnce() {
        for iteration in 0..<1000 {
            let h = Harness()
            h.finish()
            let staleTimeout = h.clock.jobs[0].callback
            h.receive("henüz kesin değil", final: false)
            h.finish()
            switch iteration % 4 {
            case 0:
                h.receive("kesin sonuç", final: true)
                staleTimeout()
                XCTAssertEqual(h.completions, [.init(success: true, text: "kesin sonuç", error: nil)])
            case 1:
                h.policy.cancel()
                staleTimeout()
                h.receive("iptal sonrası", final: true)
                XCTAssertTrue(h.completions.isEmpty)
            case 2:
                h.clock.advance(to: 1800)
                h.receive("geç sonuç", final: true)
                XCTAssertEqual(h.completions, [AppleSpeechFinalization.timeoutOutcome])
            default:
                let failure = AppleSpeechFinalization.Outcome(success: false, text: "", error: "recognizer unavailable")
                h.record(h.policy.complete(failure))
                h.receive("hata sonrası", final: true)
                staleTimeout()
                XCTAssertEqual(h.completions, [failure])
            }
            h.policy.cancel()
            h.finish()
            h.clock.advance(to: 5000)
            XCTAssertLessThanOrEqual(h.completions.count, 1)
            XCTAssertEqual(h.endAudioCount, 1)
            XCTAssertEqual(h.clock.scheduledDeadlines, [1800])
        }
    }

    func testManyPartialsCannotExtendDeadline() {
        let h = Harness()
        h.finish()
        for time in stride(from: 10, through: 1790, by: 10) {
            h.clock.advance(to: time)
            h.receive("partial \(time)", final: false)
            XCTAssertTrue(h.completions.isEmpty)
        }
        h.clock.advance(to: 1800)
        XCTAssertEqual(h.completions, [AppleSpeechFinalization.timeoutOutcome])
        XCTAssertEqual(h.clock.scheduledDeadlines, [1800])
    }

    func testCancelBeforeFinishNeverSchedulesDeadline() {
        let h = Harness()
        h.policy.cancel()
        h.finish()
        h.receive("late final", final: true)
        XCTAssertTrue(h.clock.scheduledDeadlines.isEmpty)
        XCTAssertTrue(h.completions.isEmpty)
        XCTAssertEqual(h.endAudioCount, 0)
    }
}
