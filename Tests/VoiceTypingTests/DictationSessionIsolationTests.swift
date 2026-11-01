import Foundation
import XCTest
@testable import VoiceTypingCore

final class DictationSessionIsolationTests: XCTestCase {
    private final class RecordingSession: LiveStreamSession {
        var chunks: [Data] = []
        func sendAudioChunk(_ chunk: Data) { chunks.append(chunk) }
        func finishAudio() {}
        func cancel() {}
    }

    func testAudioForwarderStaysBoundToOriginalSession() {
        let first = RecordingSession()
        let second = RecordingSession()
        var current: (any LiveStreamSession)? = first
        var forwarded = 0
        let forward = AppDelegate.liveAudioForwarder(for: current) { forwarded += 1 }
        current = second

        let chunk = Data([1, 2, 3, 4])
        forward(chunk)
        XCTAssertEqual(first.chunks, [chunk])
        XCTAssertTrue(second.chunks.isEmpty)
        XCTAssertEqual(forwarded, 1)
        XCTAssertTrue(current === second)
    }

    func testMissingSessionDoesNotForwardOrMarkAudio() {
        var forwarded = 0
        let forward = AppDelegate.liveAudioForwarder(for: nil) { forwarded += 1 }
        forward(Data([1, 2]))
        XCTAssertEqual(forwarded, 0)
    }

    func testRetryRejectsOldProviderResultsAndInterimUpdates() {
        var gate = DictationDeliveryGate()
        gate.begin(11)
        let first = gate.currentAttempt(11)!
        XCTAssertTrue(gate.acceptsResult(11, attempt: first))

        let retry = gate.advanceAttempt(11, after: first)!
        XCTAssertNotEqual(first, retry)
        XCTAssertFalse(gate.acceptsResult(11, attempt: first))
        XCTAssertNil(gate.advanceAttempt(11, after: first))
        XCTAssertTrue(gate.acceptsResult(11, attempt: retry))
        XCTAssertTrue(gate.beginDelivery(11))
        XCTAssertFalse(gate.acceptsResult(11, attempt: retry))
    }

    func testTranslationCanStartOnlyOneInjection() {
        var gate = DictationDeliveryGate()
        gate.begin(12)
        XCTAssertTrue(gate.beginDelivery(12))
        XCTAssertTrue(gate.beginInjection(12))
        XCTAssertFalse(gate.beginInjection(12))
        gate.finish()
        XCTAssertFalse(gate.beginInjection(12))
        gate.begin(13)
        XCTAssertFalse(gate.beginInjection(12))
        XCTAssertTrue(gate.beginDelivery(13))
        XCTAssertTrue(gate.beginInjection(13))
    }

    func testNewRecordingRejectsAllAttemptsFromOldRecording() {
        var gate = DictationDeliveryGate()
        gate.begin(20)
        let old = gate.currentAttempt(20)!
        let retry = gate.advanceAttempt(20, after: old)!
        gate.begin(21)
        XCTAssertFalse(gate.acceptsResult(20, attempt: old))
        XCTAssertFalse(gate.acceptsResult(20, attempt: retry))
        XCTAssertNil(gate.advanceAttempt(20, after: retry))
        XCTAssertTrue(gate.acceptsResult(21, attempt: gate.currentAttempt(21)!))
    }
}
