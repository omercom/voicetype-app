import Foundation
import XCTest
@testable import VoiceTypingCore

final class TranslationProviderFallbackTests: XCTestCase {
    private var session: URLSession!
    private var service: TranslationService!
    private let lock = NSLock()
    private var recordedHosts: [String] = []

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        service = TranslationService(session: session)
        recordedHosts = []
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        session.invalidateAndCancel()
        session = nil
        service = nil
        super.tearDown()
    }

    private func config(provider: String = "auto") -> AppConfig {
        var config = AppConfig.defaultConfig
        config.translation_provider = provider
        config.groq_api_key = "test-groq"
        config.gemini_api_key = "test-gemini"
        return config
    }

    private func record(_ request: URLRequest) -> String {
        let host = request.url?.host ?? ""
        lock.lock()
        recordedHosts.append(host)
        lock.unlock()
        return host
    }

    private func hosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedHosts
    }

    private func response(_ request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    func testDefaultGroqModelUsesAvailableProductionModelAndLowReasoning() throws {
        let request = try TranslationService.makeGroqRequest(text: "Merhaba dünya.", apiKey: "test-groq")
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "openai/gpt-oss-120b")
        XCTAssertEqual(json["reasoning_effort"] as? String, "low")
        XCTAssertEqual(json["reasoning_format"] as? String, "hidden")
        XCTAssertEqual(json["max_tokens"] as? Int, 2048)
    }

    func testAutoRetriesGeminiWhenGroqReturns404() {
        MockURLProtocol.requestHandler = { [self] request in
            let host = record(request)
            if host == "api.groq.com" {
                return response(request, status: 404, body: #"{"error":{"message":"model unavailable"}}"#)
            }
            return response(request, status: 200, body: #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"Hello world."}]}}]}"#)
        }
        let done = expectation(description: "Gemini retry")
        service.translate(text: "Merhaba dünya.", config: config()) { result in
            XCTAssertEqual(result, TranslationResult(text: "Hello world.", wasFallback: false))
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(hosts(), ["api.groq.com", "generativelanguage.googleapis.com"])
    }

    func testExplicitGroqNeverSendsTextToGemini() {
        MockURLProtocol.requestHandler = { [self] request in
            _ = record(request)
            return response(request, status: 404, body: #"{"error":{"message":"model unavailable"}}"#)
        }
        let done = expectation(description: "explicit Groq failure")
        service.translate(text: "Merhaba dünya.", config: config(provider: "groq")) { result in
            XCTAssertTrue(result.wasFallback)
            XCTAssertEqual(result.text, "Merhaba dünya.")
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(hosts(), ["api.groq.com"])
    }

    func testAutoRetriesWhenFirstProviderReturnsUntranslatedText() {
        MockURLProtocol.requestHandler = { [self] request in
            if record(request) == "api.groq.com" {
                return response(request, status: 200, body: #"{"choices":[{"finish_reason":"stop","message":{"content":"Merhaba dünya."}}]}"#)
            }
            return response(request, status: 200, body: #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"Hello world."}]}}]}"#)
        }
        let done = expectation(description: "invalid translation retry")
        service.translate(text: "Merhaba dünya.", config: config()) { result in
            XCTAssertEqual(result.text, "Hello world.")
            XCTAssertFalse(result.wasFallback)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(hosts().count, 2)
    }

    func testBothFailuresReturnWholeOriginalOnlyOnce() {
        MockURLProtocol.requestHandler = { [self] request in
            _ = record(request)
            return response(request, status: 503, body: #"{"error":{"message":"unavailable"}}"#)
        }
        let done = expectation(description: "both providers failed")
        done.assertForOverFulfill = true
        service.translate(text: "Merhaba dünya.", config: config()) { result in
            XCTAssertTrue(result.wasFallback)
            XCTAssertEqual(result.text, "Merhaba dünya.")
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(hosts(), ["api.groq.com", "generativelanguage.googleapis.com"])
    }

    func testCancellationPreventsRetryAndCompletion() {
        let started = expectation(description: "Groq request started")
        let completed = expectation(description: "cancelled request must not complete")
        completed.isInverted = true
        MockURLProtocol.requestHandler = { [self] request in
            _ = record(request)
            started.fulfill()
            Thread.sleep(forTimeInterval: 0.2)
            return response(request, status: 404, body: #"{"error":{"message":"unavailable"}}"#)
        }
        let handle = service.translateCancellable(text: "Merhaba dünya.", config: config()) { _ in
            completed.fulfill()
        }
        wait(for: [started], timeout: 3)
        handle?.cancel()
        wait(for: [completed], timeout: 0.6)
        XCTAssertEqual(hosts(), ["api.groq.com"])
    }
}
