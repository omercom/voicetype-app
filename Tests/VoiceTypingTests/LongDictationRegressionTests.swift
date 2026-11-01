import XCTest
@testable import VoiceTypingCore

final class LongDictationRegressionTests: XCTestCase {
    func testLongUniqueTranscriptFinishesWithinBudget() {
        let text = (0..<6000).map { "kelime\($0)" }.joined(separator: " ")
        let start = ProcessInfo.processInfo.systemUptime
        let result = LiveGeminiStreamSession.deduplicateRepeatedPhrases(text)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertEqual(result, text)
        print("[LongDictationBenchmark] words=6000 elapsed=\(elapsed)s")
        XCTAssertLessThan(elapsed, 1.5, "Kayıt bitişi uzun metin temizliğinde takılmamalı.")
    }

    func testDistantRepeatedClosingSentenceIsNotDeleted() {
        let middle = (0..<300).map { "ayrıntı\($0)" }.joined(separator: " ")
        let text = "Lütfen bunu kontrol edin. \(middle). Lütfen bunu kontrol edin."
        XCTAssertEqual(LiveGeminiStreamSession.deduplicateRepeatedPhrases(text), text)
    }

    func testLongUnicodeTranscriptKeepsParagraphsAndEnding() {
        let text = (0..<300).map { "Bölüm\($0): İğüşöç 👩🏽‍💻 e\u{301}." }.joined(separator: "\n\n")
            + "\nSon cümle burada bitiyor."
        XCTAssertEqual(LiveGeminiStreamSession.deduplicateRepeatedPhrases(text), text)
    }

    private func deliver(_ text: String, to session: LiveGeminiStreamSession) throws {
        let payload: [String: Any] = ["serverContent": ["inputTranscription": ["text": text]]]
        session.handleIncomingData(try JSONSerialization.data(withJSONObject: payload))
    }

    func testLongLiveSessionFinalizesOnceWithoutNetwork() throws {
        let session = LiveGeminiStreamSession(apiKey: "unused-offline-test")
        let text = (0..<6000).map { "kelime\($0)" }.joined(separator: " ") + " Son cümle."
        var results: [TranscriptionResult] = []
        session.onCompletion = { results.append($0) }
        try deliver(text, to: session)
        let started = ProcessInfo.processInfo.systemUptime
        session.finishAndComplete()
        session.finishAndComplete()
        try deliver("geç gelen paket", to: session)
        session.finishAudio()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, text)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        session.cancel()
    }

    func testCancelledSessionIgnoresLateCompletionAndPackets() throws {
        let session = LiveGeminiStreamSession(apiKey: "unused-offline-test")
        var completions = 0
        session.onCompletion = { _ in completions += 1 }
        try deliver("iptal edilecek metin", to: session)
        session.finishAudio()
        session.cancel()
        try deliver("geç gelen paket", to: session)
        session.finishAndComplete()
        session.finishAudio()
        XCTAssertEqual(completions, 0)
    }

    func testConcurrentFinalizersProduceOneCompletion() throws {
        let session = LiveGeminiStreamSession(apiKey: "unused-offline-test")
        let lock = NSLock()
        var completions = 0
        session.onCompletion = { _ in lock.lock(); completions += 1; lock.unlock() }
        try deliver("Tamamlanacak metin.", to: session)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in session.finishAndComplete() }
        XCTAssertEqual(completions, 1)
        session.cancel()
    }

    func testFinishAndCancelRaceNeverCompletesTwice() throws {
        for _ in 0..<20 {
            let session = LiveGeminiStreamSession(apiKey: "unused-offline-test")
            let lock = NSLock()
            var completions = 0
            session.onCompletion = { _ in lock.lock(); completions += 1; lock.unlock() }
            try deliver("Yarış testi.", to: session)
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                if index.isMultiple(of: 2) { session.finishAndComplete() } else { session.cancel() }
            }
            XCTAssertLessThanOrEqual(completions, 1)
        }
    }

    func testSafetyTimeoutFinishesOnceWithoutSocket() throws {
        let session = LiveGeminiStreamSession(apiKey: "unused-offline-test")
        let done = expectation(description: "offline safety timer")
        session.onCompletion = { result in
            XCTAssertEqual(result.text, "Zaman aşımı metni.")
            done.fulfill()
        }
        try deliver("Zaman aşımı metni.", to: session)
        session.finishAudio()
        session.finishAudio()
        wait(for: [done], timeout: 6)
        session.finishAndComplete()
        session.cancel()
    }
}
