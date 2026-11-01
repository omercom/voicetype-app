import Foundation
import XCTest
@testable import VoiceTypingCore

final class LiveTranslationCoordinatorTests: XCTestCase {
    private final class MockTranslator {
        struct Call {
            let text: String
            let completion: (TranslationResult) -> Void
            var cancelled = false
        }
        var calls: [Call] = []

        func request(_ text: String, completion: @escaping (TranslationResult) -> Void) -> (() -> Void)? {
            let index = calls.count
            calls.append(Call(text: text, completion: completion))
            return { [weak self] in self?.calls[index].cancelled = true }
        }

        func succeed(_ index: Int, _ text: String) {
            calls[index].completion(TranslationResult(text: text, wasFallback: false))
        }

        func fail(_ index: Int) {
            calls[index].completion(TranslationResult(text: calls[index].text, wasFallback: true, errorMessage: "offline"))
        }
    }

    private func drainMain() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    private func makeCoordinator(_ mock: MockTranslator, limit: Int = 600, early: Int = 20, concurrent: Int = 3) -> LiveTranslationCoordinator {
        LiveTranslationCoordinator(maxChunkLength: limit, maxEarlyRequests: early,
                                   maxConcurrentFinalRequests: concurrent,
                                   polish: { $0 }, request: mock.request)
    }

    func testStableSentencesTranslateDuringRecordingAndOnlyRemainderAtFinish() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Merhaba dünya.")
        XCTAssertTrue(mock.calls.isEmpty)
        session.observe("Merhaba dünya. Bugün")
        XCTAssertEqual(mock.calls.map(\.text), ["Merhaba dünya."])
        mock.succeed(0, "Hello world.")
        drainMain()

        var result: TranslationResult?
        session.finish(text: "Merhaba dünya. Bugün nasılsın?") { result = $0 }
        XCTAssertEqual(mock.calls.map(\.text), ["Merhaba dünya.", "Bugün nasılsın?"])
        mock.succeed(1, "How are you today?")
        drainMain()
        XCTAssertEqual(result, TranslationResult(text: "Hello world. How are you today?", wasFallback: false))
    }

    func testMultipleStableSentencesPreserveOrderAndSeparators() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Birinci cümle.")
        session.observe("Birinci cümle.\nİkinci cümle.")
        mock.succeed(0, "First sentence.")
        drainMain()
        session.observe("Birinci cümle.\nİkinci cümle. Son")
        XCTAssertEqual(mock.calls.map(\.text), ["Birinci cümle.", "İkinci cümle."])
        mock.succeed(1, "Second sentence.")
        drainMain()
        var result: TranslationResult?
        session.finish(text: "Birinci cümle.\nİkinci cümle. Son") { result = $0 }
        XCTAssertEqual(mock.calls[2].text, "Son")
        mock.succeed(2, "Last")
        drainMain()
        XCTAssertEqual(result?.text, "First sentence.\nSecond sentence. Last")
    }

    func testEntireFinalTextCanReuseCompletedTranslation() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Merhaba dünya.")
        session.observe("Merhaba dünya. Devam")
        mock.succeed(0, "Hello world.")
        drainMain()
        var result: TranslationResult?
        session.finish(text: "Merhaba dünya.") { result = $0 }
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(result?.text, "Hello world.")
    }

    func testFailedInterimDoesNotProduceMixedLanguageOutput() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Merhaba dünya.")
        session.observe("Merhaba dünya. Devam")
        mock.fail(0)
        drainMain()
        session.observe("Merhaba dünya. Devam ediyor.")
        var result: TranslationResult?
        session.finish(text: "Merhaba dünya. Devam ediyor.") { result = $0 }
        XCTAssertEqual(mock.calls.map(\.text), ["Merhaba dünya.", "Merhaba dünya. Devam ediyor."])
        mock.fail(1)
        drainMain()
        XCTAssertEqual(result, TranslationResult(text: "Merhaba dünya. Devam ediyor.", wasFallback: true, errorMessage: "offline"))
    }

    func testRevisedInterimInvalidatesCachedPrefix() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Ali geldi.")
        session.observe("Ali geldi. Sonra")
        mock.succeed(0, "Ali arrived.")
        drainMain()
        session.observe("Veli geldi. Sonra")
        var result: TranslationResult?
        session.finish(text: "Veli geldi. Sonra gitti.") { result = $0 }
        XCTAssertEqual(mock.calls.last?.text, "Veli geldi. Sonra gitti.")
        mock.succeed(1, "Veli arrived. Then he left.")
        drainMain()
        XCTAssertEqual(result?.text, "Veli arrived. Then he left.")
    }

    func testFinalPolishedTextMustMatchCachedPrefixExactly() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Ali geldi.")
        session.observe("Ali geldi. Sonra")
        mock.succeed(0, "Ali arrived.")
        drainMain()
        var result: TranslationResult?
        session.finish(text: "Ali gelmedi. Sonra gitti.") { result = $0 }
        XCTAssertEqual(mock.calls.last?.text, "Ali gelmedi. Sonra gitti.")
        mock.succeed(1, "Ali did not arrive. Then he left.")
        drainMain()
        XCTAssertEqual(result?.text, "Ali did not arrive. Then he left.")
    }

    func testFinalFailureAfterCachedPrefixReturnsEntireOriginal() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Ali geldi.")
        session.observe("Ali geldi. Sonra")
        mock.succeed(0, "Ali arrived.")
        drainMain()
        let original = "Ali geldi. Sonra gitti."
        var result: TranslationResult?
        session.finish(text: original) { result = $0 }
        mock.fail(1)
        drainMain()
        XCTAssertEqual(result, TranslationResult(text: original, wasFallback: true, errorMessage: "offline"))
    }

    func testFinishingCancelsPendingInterimAndRejectsLateCallback() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Merhaba dünya.")
        session.observe("Merhaba dünya. Yeni")
        var outputs: [TranslationResult] = []
        session.finish(text: "Merhaba dünya. Yeni metin.") { outputs.append($0) }
        XCTAssertTrue(mock.calls[0].cancelled)
        XCTAssertEqual(mock.calls[1].text, "Merhaba dünya. Yeni metin.")
        mock.succeed(0, "Stale text.")
        mock.succeed(1, "Hello world. New text.")
        drainMain()
        XCTAssertEqual(outputs.map(\.text), ["Hello world. New text."])
    }

    func testChangedPendingPrefixIsCancelled() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Ali geldi.")
        session.observe("Ali geldi. Sonra")
        session.observe("Veli geldi. Sonra")
        XCTAssertTrue(mock.calls[0].cancelled)
        mock.succeed(0, "Wrong old text.")
        drainMain()
        var result: TranslationResult?
        session.finish(text: "Veli geldi. Sonra") { result = $0 }
        XCTAssertEqual(mock.calls.last?.text, "Veli geldi. Sonra")
        mock.succeed(1, "Veli arrived. Then")
        drainMain()
        XCTAssertEqual(result?.text, "Veli arrived. Then")
    }

    func testLongFinalTextUsesBoundedParallelRequestsAndKeepsOrder() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock, limit: 20, concurrent: 3)
        let source = "Birinci cümle. İkinci cümle. Üçüncü cümle. Dördüncü cümle. Beşinci cümle."
        var result: TranslationResult?
        session.finish(text: source) { result = $0 }
        XCTAssertEqual(mock.calls.count, 3)
        mock.succeed(2, mock.calls[2].text.uppercased())
        drainMain()
        XCTAssertEqual(mock.calls.count, 4)
        mock.succeed(1, mock.calls[1].text.uppercased())
        drainMain()
        XCTAssertEqual(mock.calls.count, 5)
        for index in [4, 3, 0] {
            mock.succeed(index, mock.calls[index].text.uppercased())
            drainMain()
        }
        XCTAssertEqual(result?.text, source.uppercased())
        XCTAssertTrue(mock.calls.allSatisfy { $0.text.count <= 20 })
    }

    func testFinalFailureReturnsWholeOriginalAndCancelsOtherRequests() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock, limit: 12)
        let source = "Birinci cümle. İkinci cümle. Üçüncü cümle."
        var outputs: [TranslationResult] = []
        session.finish(text: source) { outputs.append($0) }
        XCTAssertEqual(mock.calls.count, 3)
        mock.succeed(0, "First.")
        mock.fail(1)
        drainMain()
        XCTAssertTrue(mock.calls[2].cancelled)
        XCTAssertEqual(outputs, [TranslationResult(text: source, wasFallback: true, errorMessage: "offline")])
        mock.succeed(2, "Late.")
        drainMain()
        XCTAssertEqual(outputs.count, 1)
    }

    func testCancelStopsRequestsAndIgnoresLateResults() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock, limit: 10)
        var called = false
        session.finish(text: "Birinci cümle. İkinci cümle.") { _ in called = true }
        session.cancel()
        XCTAssertTrue(mock.calls.allSatisfy(\.cancelled))
        for index in mock.calls.indices { mock.succeed(index, "Late") }
        drainMain()
        XCTAssertFalse(called)
    }

    func testFallbackProviderInvalidatesOldInterims() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Ali geldi.")
        session.observe("Ali geldi. Sonra")
        mock.succeed(0, "Ali arrived.")
        drainMain()
        session.invalidateInterims()
        session.observe("Ali geldi. Sonra gitti.")
        var result: TranslationResult?
        session.finish(text: "Ali geldi. Sonra gitti.") { result = $0 }
        XCTAssertEqual(mock.calls[1].text, "Ali geldi. Sonra gitti.")
        mock.succeed(1, "Fresh translation.")
        drainMain()
        XCTAssertEqual(result?.text, "Fresh translation.")
    }

    func testRealPolisherPrefixMatchesFinalTranscript() {
        let mock = MockTranslator()
        let config = AppConfig.defaultConfig
        let session = LiveTranslationCoordinator(
            polish: { TextPolisher.shared.polish(text: $0, config: config, targetContext: nil) },
            request: mock.request
        )
        session.observe("merhaba dünya.")
        session.observe("merhaba dünya. bugün")
        XCTAssertEqual(mock.calls.first?.text, "Merhaba dünya.")
        mock.succeed(0, "Hello world.")
        drainMain()
        let final = TextPolisher.shared.polish(text: "merhaba dünya. bugün nasılsın?", config: config, targetContext: nil)
        var result: TranslationResult?
        session.finish(text: final) { result = $0 }
        XCTAssertEqual(mock.calls.last?.text, "bugün nasılsın?")
        mock.succeed(1, "How are you today?")
        drainMain()
        XCTAssertEqual(result?.text, "Hello world. How are you today?")
    }

    func testNoSpeculationForIncompleteSentenceOrAbbreviation() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        session.observe("Dr.")
        session.observe("Dr. Ali")
        session.observe("Dr. Ali geldi")
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testSplitKeepsLongTokensAndUnicodeWithoutLosingText() {
        let source = "Merhaba   dünya.\n👩🏽‍💻 çalışıyor. verylongunbrokenidentifier"
        let segments = LiveTranslationCoordinator.splitFinalText(source, maxLength: 12)
        XCTAssertEqual(segments.map { $0.separator + $0.text }.joined(), source)
        XCTAssertTrue(segments.contains { $0.text == "verylongunbrokenidentifier" })
    }

    func testTrailingWhitespaceIsNotSentAsTranslatedContent() {
        let mock = MockTranslator()
        let session = makeCoordinator(mock)
        var result: TranslationResult?
        session.finish(text: "Merhaba.\n  ") { result = $0 }
        XCTAssertEqual(mock.calls[0].text, "Merhaba.")
        mock.succeed(0, "Hello.")
        drainMain()
        XCTAssertEqual(result?.text, "Hello.\n  ")
    }

    func testDefaultGeminiModelUsesSupportedLowLatencyConfiguration() throws {
        let request = try TranslationService.makeGeminiRequest(text: "Merhaba", apiKey: "test-key")
        XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-3.6-flash:generateContent")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        let thinking = try XCTUnwrap(config["thinkingConfig"] as? [String: Any])
        XCTAssertEqual(thinking["thinkingLevel"] as? String, "minimal")
    }

    func testTruncatedProviderResponsesAreRejected() throws {
        let groq = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"Partial"}}]}"#.utf8)
        let gemini = Data(#"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"Partial"}]}}]}"#.utf8)
        XCTAssertThrowsError(try TranslationService.parseGroqResponse(data: groq, httpResponse: nil)) {
            XCTAssertEqual($0 as? TranslationError, .incompleteTranslation)
        }
        XCTAssertThrowsError(try TranslationService.parseGeminiResponse(data: gemini, httpResponse: nil)) {
            XCTAssertEqual($0 as? TranslationError, .incompleteTranslation)
        }
    }
}
