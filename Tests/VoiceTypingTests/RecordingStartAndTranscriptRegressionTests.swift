import XCTest
@testable import VoiceTypingCore

final class RecordingStartAndTranscriptRegressionTests: XCTestCase {
    func testRapidStartFinishCyclesDoNotLeaveCoordinatorRecording() {
        let coordinator = RecordingStartCoordinator()
        for attempt in UInt64(1)...100 {
            XCTAssertEqual(coordinator.start(prepare: { _ in }, captureTarget: { true }, startRecorder: { true }), .started(attempt))
            coordinator.finish()
            coordinator.finish()
            XCTAssertEqual(coordinator.phase, .idle)
        }
    }

    func testCoordinatorPresentsPreparingBeforeTargetAndRecorderWork() {
        let coordinator = RecordingStartCoordinator()
        var order: [String] = []

        let outcome = coordinator.start(
            prepare: { _ in order.append("prepare") },
            captureTarget: {
                order.append("target")
                return true
            },
            startRecorder: {
                order.append("recorder")
                return true
            }
        )

        XCTAssertEqual(order, ["prepare", "target", "recorder"])
        XCTAssertEqual(outcome, .started(1))
        XCTAssertEqual(coordinator.phase, .recording(1))
    }

    func testPreparingToRecordingUsesOnePanelPresentation() {
        let hud = RecordingHUD.shared
        hud.dismiss(animated: false)
        hud.finishPresentationTransitions()
        let baseline = hud.presentationCount

        hud.showPreparing()
        let preparingPresentation = hud.presentationCount
        XCTAssertEqual(hud.currentState, .preparing)
        XCTAssertEqual(preparingPresentation, baseline + 1)

        hud.showRecording()
        XCTAssertEqual(hud.currentState, .recording)
        XCTAssertEqual(hud.presentationCount, preparingPresentation)
        XCTAssertTrue(hud.isVisible)

        hud.dismiss(animated: false)
        hud.finishPresentationTransitions()
    }

    func testRapidFailureThenRetriggerStartsANewSafeAttempt() {
        let coordinator = RecordingStartCoordinator()
        var prepares: [UInt64] = []

        XCTAssertEqual(
            coordinator.start(
                prepare: { prepares.append($0) },
                captureTarget: { false },
                startRecorder: { XCTFail("Recorder must not run for an invalid target"); return true }
            ),
            .targetRejected(1)
        )
        XCTAssertEqual(coordinator.phase, .idle)

        XCTAssertEqual(
            coordinator.start(
                prepare: { prepares.append($0) },
                captureTarget: { true },
                startRecorder: { true }
            ),
            .started(2)
        )
        XCTAssertEqual(prepares, [1, 2])
        XCTAssertEqual(coordinator.phase, .recording(2))
        XCTAssertEqual(
            coordinator.start(prepare: { _ in }, captureTarget: { true }, startRecorder: { true }),
            .ignored
        )
    }

    func testHUDRevealTimingIsImmediateEnoughAndHonorsReduceMotion() {
        let normal = HUDRevealTiming.resolve(isAlreadyVisible: false, currentAlpha: 0, reduceMotion: false)
        XCTAssertEqual(normal.duration, 0.07, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(normal.initialAlpha, 0.28)

        let continuation = HUDRevealTiming.resolve(isAlreadyVisible: true, currentAlpha: 0.45, reduceMotion: false)
        XCTAssertEqual(continuation.duration, 0.07, accuracy: 0.0001)
        XCTAssertEqual(continuation.initialAlpha, 0.45, accuracy: 0.0001)

        let reduced = HUDRevealTiming.resolve(isAlreadyVisible: false, currentAlpha: 0, reduceMotion: true)
        XCTAssertEqual(reduced.duration, 0)
        XCTAssertEqual(reduced.initialAlpha, 1)
    }

    func testAppleSessionPauseTimestampResetThenDeltaFinalPreservesBothPhrasesOnce() {
        var accumulator = StreamingTranscriptAccumulator()
        let first = [TimedTranscriptSegment(startTime: 0, duration: 1.2, text: "Merhaba nasılsın")]
        let reset = [TimedTranscriptSegment(startTime: 0, duration: 1.0, text: "bugün devam ediyorum")]

        _ = AppleSpeechTranscriptProcessor.apply(
            accumulator: &accumulator,
            text: "Merhaba nasılsın",
            segments: first,
            isFinal: false,
            receivedAt: 10
        )
        _ = AppleSpeechTranscriptProcessor.apply(
            accumulator: &accumulator,
            text: "bugün devam ediyorum",
            segments: reset,
            isFinal: false,
            receivedAt: 11
        )
        let final = AppleSpeechTranscriptProcessor.apply(
            accumulator: &accumulator,
            text: "bugün devam ediyorum",
            segments: reset,
            isFinal: true,
            receivedAt: 11.1
        )

        XCTAssertEqual(final, "Merhaba nasılsın bugün devam ediyorum")
        XCTAssertEqual(StreamingTranscriptReconciler.normalizedTokens(final).filter { $0 == "merhaba" }.count, 1)
        XCTAssertEqual(StreamingTranscriptReconciler.normalizedTokens(final).filter { $0 == "bugün" }.count, 1)
    }

    func testImmediateSameTimelineRootCorrectionReplaces() {
        var accumulator = StreamingTranscriptAccumulator()
        accumulator.receivePartial(
            "kırmızı elma",
            segments: [TimedTranscriptSegment(startTime: 0, duration: 0.8, text: "kırmızı elma")],
            receivedAt: 1
        )
        accumulator.receivePartial(
            "yeşil elma",
            segments: [TimedTranscriptSegment(startTime: 0.02, duration: 0.82, text: "yeşil elma")],
            receivedAt: 1.1
        )
        XCTAssertEqual(accumulator.text, "yeşil elma")
    }

    func testShorterRepeatedPartialNeverDeletesOrResetsPauseClock() {
        var accumulator = StreamingTranscriptAccumulator()
        accumulator.receivePartial("Merhaba nasılsın", receivedAt: 2)
        accumulator.receivePartial("Merhaba", receivedAt: 2.9)
        accumulator.receivePartial("bugün devam", receivedAt: 3)
        XCTAssertEqual(accumulator.text, "Merhaba nasılsın bugün devam")
    }

    func testFinalDeltaReconcilesAgainstWholeActiveBeforeCommit() {
        var accumulator = StreamingTranscriptAccumulator()
        accumulator.receivePartial("Merhaba nasılsın bugün devam ediyorum", receivedAt: 1)
        accumulator.receiveFinal("bugün devam ediyorum")
        XCTAssertEqual(accumulator.text, "Merhaba nasılsın bugün devam ediyorum")
        XCTAssertEqual(accumulator.activeText, "")
    }

    func testFinalCorrectionReplacesActiveHypothesisWithoutDuplication() {
        var accumulator = StreamingTranscriptAccumulator()
        accumulator.receivePartial("The quick brown fox jumps", receivedAt: 1)
        accumulator.receiveFinal("The quick brown fox jumped")
        XCTAssertEqual(accumulator.text, "The quick brown fox jumped")
    }

    func testGeminiCommittedActiveAndDeltaFinalAppearExactlyOnce() {
        var accumulator = StreamingTranscriptAccumulator()
        _ = GeminiTranscriptProcessor.applyFinal(accumulator: &accumulator, text: "Merhaba nasılsın")
        _ = GeminiTranscriptProcessor.applyPartial(accumulator: &accumulator, text: "bugün devam ediyorum", receivedAt: 5)
        let final = GeminiTranscriptProcessor.applyFinal(accumulator: &accumulator, text: "bugün devam ediyorum")
        XCTAssertEqual(final, "Merhaba nasılsın bugün devam ediyorum")
    }

    func testPrefixFinalRetainsPendingActiveTail() {
        var accumulator = StreamingTranscriptAccumulator()
        accumulator.receivePartial("Merhaba dünya devam ediyor", receivedAt: 1)
        accumulator.receiveFinal("Merhaba dünya")
        XCTAssertEqual(accumulator.committedText, "Merhaba dünya")
        XCTAssertEqual(accumulator.activeText, "devam ediyor")
        XCTAssertEqual(accumulator.text, "Merhaba dünya devam ediyor")
    }
}
