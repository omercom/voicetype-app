import XCTest
@testable import VoiceTypingCore

/// Bitiş yolu gecikme ölçümü: zaman dışarıdan verilir, gerçek kayıt gerekmez.
final class RecordingStopLatencyTraceTests: XCTestCase {

    func testMilestonesAreRelativeToKeyRelease() {
        let trace = RecordingStopLatencyTrace(provider: "groq", now: 100.0)
        trace.mark(.postRollFinished, now: 100.18)
        trace.mark(.recorderStopped, now: 100.20)
        XCTAssertEqual(trace.elapsedMs(.keyRelease), 0)
        XCTAssertEqual(trace.elapsedMs(.postRollFinished), 180)
        XCTAssertEqual(trace.elapsedMs(.recorderStopped), 200)
        XCTAssertNil(trace.elapsedMs(.polished))
    }

    func testMilestoneIsRecordedOnlyOnce() {
        let trace = RecordingStopLatencyTrace(provider: "groq", now: 0)
        trace.mark(.polished, now: 0.5)
        trace.mark(.polished, now: 0.9)
        XCTAssertEqual(trace.elapsedMs(.polished), 500)
    }

    func testResultUpdatesProviderAndAddsProviderLatency() {
        let trace = RecordingStopLatencyTrace(provider: "gemini", now: 0)
        trace.markResult(provider: "apple", model: "apple-speech-on-device", providerLatency: 0.43, now: 0.64)
        let line = trace.summaryLine(reason: "verified")
        XCTAssertTrue(line.contains("provider=apple"), line)
        XCTAssertTrue(line.contains("model=apple-speech-on-device"), line)
        XCTAssertTrue(line.contains("resultReceived=640ms"), line)
        XCTAssertTrue(line.contains("providerLatency=430ms"), line)
        XCTAssertTrue(line.hasSuffix("end=verified"), line)
    }

    func testFinishIsIdempotent() {
        let trace = RecordingStopLatencyTrace(provider: "groq", now: 0)
        XCTAssertFalse(trace.isFinished)
        trace.finish(reason: "verified")
        trace.finish(reason: "superseded")
        XCTAssertTrue(trace.isFinished)
    }
}
