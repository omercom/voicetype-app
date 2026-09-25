import Foundation
import XCTest
@testable import VoiceTypingCore

final class AssemblyAIDictationTests: XCTestCase {
    private let boundary = "DeterministicBoundary"

    func testRequestUsesDocumentedEndpointAndRawAuthorizationHeader() throws {
        let apiKey = "test-key-not-a-real-secret"
        let request = try makeRequest(apiKey: apiKey)

        XCTAssertEqual(request.url, URL(string: "https://dictation.assemblyai.com/v1/transcribe/live"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=\(boundary)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(authorization.hasPrefix("Bearer "))
        XCTAssertEqual(authorization, apiKey)
    }

    func testMultipartPlacesConfigBeforeAudioAndDoesNotPutKeyInBody() throws {
        let apiKey = "header-only-test-key"
        let request = try makeRequest(apiKey: apiKey)
        let body = try XCTUnwrap(request.httpBody)
        let configMarker = Data("name=\"config\"".utf8)
        let audioMarker = Data("name=\"audio\"".utf8)
        let configRange = try XCTUnwrap(body.range(of: configMarker))
        let audioRange = try XCTUnwrap(body.range(of: audioMarker))

        XCTAssertLessThan(configRange.lowerBound, audioRange.lowerBound)
        XCTAssertNotNil(body.range(of: Data("Content-Type: application/json".utf8)))
        XCTAssertNotNil(body.range(of: Data("Content-Type: audio/wav".utf8)))
        XCTAssertNil(body.range(of: Data(apiKey.utf8)))
    }

    func testConfigNormalizesTurkishAndParsesAtMostOneHundredKeyterms() throws {
        let terms = (0..<105).map { index in
            switch index % 3 {
            case 0: return " terim\(index),"
            case 1: return "terim\(index);"
            default: return "terim\(index)\n"
            }
        }.joined()

        let request = try makeRequest(language: " tr-TR ", customVocabulary: terms)
        let config = try configJSON(from: request)

        XCTAssertEqual(config["language_codes"] as? [String], ["tr"])
        XCTAssertEqual(
            config["stt_prompt"] as? String,
            "A person dictating natural Turkish text into a macOS text field, using conversational language, names, short commands, and occasional software terminology."
        )
        let keyterms = try XCTUnwrap(config["keyterms_prompt"] as? [String])
        XCTAssertEqual(keyterms.count, 100)
        XCTAssertEqual(keyterms.first, "terim0")
        XCTAssertEqual(keyterms.last, "terim99")
        XCTAssertNil(config["llm_instruction"])
        XCTAssertNil(config["model"])
        XCTAssertNil(config["speech_model"])
        XCTAssertEqual(Set(config.keys), Set(["language_codes", "stt_prompt", "keyterms_prompt"]))
    }

    func testEmptyAndAutoLanguageDefaultToTurkish() throws {
        for language in ["", "  ", "auto", "AUTO"] {
            let request = try makeRequest(language: language)
            let config = try configJSON(from: request)
            XCTAssertEqual(config["language_codes"] as? [String], ["tr"])
            XCTAssertTrue((config["stt_prompt"] as? String)?.contains("Turkish") == true)
        }
    }

    func testContextualPromptTracksEnglishAndFallsBackWithoutInventingModelFields() throws {
        let englishConfig = try configJSON(from: makeRequest(language: "en"))
        XCTAssertTrue((englishConfig["stt_prompt"] as? String)?.contains("English") == true)

        let otherConfig = try configJSON(from: makeRequest(language: "de"))
        let prompt = try XCTUnwrap(otherConfig["stt_prompt"] as? String)
        XCTAssertFalse(prompt.contains("Turkish"))
        XCTAssertFalse(prompt.contains("English"))
        XCTAssertNil(otherConfig["model"])
        XCTAssertNil(otherConfig["speech_model"])
    }

    func testSuccessfulResponsePrefersNonemptyLLMResponse() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "text": "ham metin",
            "llm_response": "düzeltilmiş metin"
        ])

        let result = AssemblyAIDictation.parseResponse(data: data, statusCode: 200, latency: 0.25)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.text, "düzeltilmiş metin")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.provider, "AssemblyAI")
        XCTAssertEqual(result.model, "universal-3.5-pro")
        XCTAssertEqual(result.latency, 0.25)
    }

    func testFailedOrEmptyRewriteFallsBackToTranscriptAsSuccess() throws {
        for llmResponse: Any in [NSNull(), "", "   "] {
            let data = try JSONSerialization.data(withJSONObject: [
                "text": "orijinal metin",
                "llm_response": llmResponse
            ])

            let result = AssemblyAIDictation.parseResponse(data: data, statusCode: 200)

            XCTAssertTrue(result.success)
            XCTAssertEqual(result.text, "orijinal metin")
            XCTAssertNil(result.error)
        }
    }

    func testErrorResponsePrefersDetailThenFallsBackToError() throws {
        let detailData = try JSONSerialization.data(withJSONObject: [
            "detail": "ayrıntılı hata",
            "error": "genel hata"
        ])
        let detailResult = AssemblyAIDictation.parseResponse(data: detailData, statusCode: 400)
        XCTAssertFalse(detailResult.success)
        XCTAssertEqual(detailResult.error, "ayrıntılı hata")

        let errorData = try JSONSerialization.data(withJSONObject: ["error": "yetkilendirme hatası"])
        let errorResult = AssemblyAIDictation.parseResponse(data: errorData, statusCode: 401)
        XCTAssertFalse(errorResult.success)
        XCTAssertEqual(errorResult.error, "yetkilendirme hatası")
    }

    func testStructuredDetailAndUnknownErrorHaveSafeMessages() throws {
        let structuredData = try JSONSerialization.data(withJSONObject: [
            "detail": [["msg": "geçersiz ses"], ["message": "çok uzun"]]
        ])
        let structuredResult = AssemblyAIDictation.parseResponse(data: structuredData, statusCode: 422)
        XCTAssertEqual(structuredResult.error, "geçersiz ses; çok uzun")

        let unknownResult = AssemblyAIDictation.parseResponse(
            data: Data("not-json-and-no-secret-echo".utf8),
            statusCode: 500
        )
        XCTAssertEqual(unknownResult.error, "AssemblyAI Dictation isteği başarısız (HTTP 500).")
    }

    func testRejectsNonSixteenBitPCMBeforeBuildingRequest() {
        XCTAssertThrowsError(
            try AssemblyAIDictation.makeRequest(
                apiKey: "test-key",
                wavData: makeWAV(bitsPerSample: 8),
                language: "tr",
                customVocabulary: ""
            )
        ) { error in
            XCTAssertEqual(error as? AssemblyAIDictationError, .unsupportedWAVFormat)
        }
    }

    func testModelAndEndpointLimitsAreExposed() {
        XCTAssertEqual(AssemblyAIDictation.model, "universal-3.5-pro")
        XCTAssertEqual(AssemblyAIDictation.maximumAudioDuration, 120)
        XCTAssertEqual(AssemblyAIDictation.requiredBitsPerSample, 16)
    }

    private func makeRequest(
        apiKey: String = "test-key",
        language: String = "tr",
        customVocabulary: String = ""
    ) throws -> URLRequest {
        try AssemblyAIDictation.makeRequest(
            apiKey: apiKey,
            wavData: makeWAV(),
            language: language,
            customVocabulary: customVocabulary,
            boundary: boundary
        )
    }

    private func configJSON(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        let header = Data("Content-Type: application/json\r\n\r\n".utf8)
        let footer = Data("\r\n--\(boundary)\r\n".utf8)
        let headerRange = try XCTUnwrap(body.range(of: header))
        let jsonStart = headerRange.upperBound
        let footerRange = try XCTUnwrap(body.range(of: footer, in: jsonStart..<body.endIndex))
        let jsonData = body.subdata(in: jsonStart..<footerRange.lowerBound)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
    }

    private func makeWAV(bitsPerSample: UInt16 = 16) -> Data {
        let channels: UInt16 = 1
        let sampleRate: UInt32 = 16_000
        let bytesPerSample = UInt32(bitsPerSample) / 8
        let byteRate = sampleRate * UInt32(channels) * bytesPerSample
        let blockAlign = channels * UInt16(bytesPerSample)
        let samples = Data(repeating: 0, count: Int(byteRate / 100))

        var wav = Data()
        wav.append(Data("RIFF".utf8))
        appendLE(UInt32(36 + samples.count), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        appendLE(UInt32(16), to: &wav)
        appendLE(UInt16(1), to: &wav)
        appendLE(channels, to: &wav)
        appendLE(sampleRate, to: &wav)
        appendLE(byteRate, to: &wav)
        appendLE(blockAlign, to: &wav)
        appendLE(bitsPerSample, to: &wav)
        wav.append(Data("data".utf8))
        appendLE(UInt32(samples.count), to: &wav)
        wav.append(samples)
        return wav
    }

    private func appendLE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendLE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}
