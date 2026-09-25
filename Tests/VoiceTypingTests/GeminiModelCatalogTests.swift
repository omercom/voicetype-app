import XCTest
@testable import VoiceTypingCore

final class GeminiModelCatalogTests: XCTestCase {
    func testBuiltInCatalogContainsOnlyDedicatedTranscriptionModels() {
        XCTAssertFalse(ConfigManager.availableGeminiModels.isEmpty)
        XCTAssertTrue(ConfigManager.availableGeminiModels.allSatisfy { $0.id.contains("transcribe") })
        XCTAssertTrue(ConfigManager.availableGeminiModels.contains { $0.id == "gemini-3.5-transcribe-live" })
        XCTAssertTrue(ConfigManager.availableGeminiModels.contains { $0.id == "gemini-3.5-transcribe" })
        XCTAssertFalse(ConfigManager.availableGeminiModels.contains { $0.id == "gemini-3.8-live" })
        XCTAssertFalse(ConfigManager.availableGeminiModels.contains { $0.id.contains("flash") })
    }

    func testWebModelResponseFiltersGeneralLiveAndFlashModels() throws {
        let payload: [String: Any] = [
            "models": [
                [
                    "name": "models/gemini-3.8-live",
                    "baseModelId": "gemini-3.8-live",
                    "displayName": "Gemini 3.8 Live",
                    "supportedGenerationMethods": ["bidiGenerateContent"]
                ],
                [
                    "name": "models/gemini-3.8-live-extended-thinking",
                    "baseModelId": "gemini-3.8-live-extended-thinking",
                    "displayName": "Gemini 3.8 Live Extended Thinking",
                    "supportedGenerationMethods": ["bidiGenerateContent"]
                ],
                [
                    "name": "models/gemini-3.8-flash",
                    "baseModelId": "gemini-3.8-flash",
                    "displayName": "Gemini 3.8 Flash",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-3.5-transcribe-live",
                    "baseModelId": "gemini-3.5-transcribe-live",
                    "displayName": "Gemini 3.5 Transcribe Live",
                    "supportedGenerationMethods": ["bidiGenerateContent"]
                ],
                [
                    "name": "models/gemini-3.5-transcribe",
                    "baseModelId": "gemini-3.5-transcribe",
                    "displayName": "Gemini 3.5 Transcribe",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-3.5-live-translate-preview",
                    "baseModelId": "gemini-3.5-live-translate-preview",
                    "displayName": "Gemini Live Translate",
                    "supportedGenerationMethods": ["bidiGenerateContent"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let options = try GeminiModelCatalog.parse(data: data)

        XCTAssertEqual(Set(options.map(\.id)), Set(["gemini-3.5-transcribe-live", "gemini-3.5-transcribe"]))
        XCTAssertTrue(options.allSatisfy { $0.name.contains("Saf Ses") || $0.name.contains("Transcribe") })
    }

    func testGemini38LiveSetupUsesNativeAudioAndExtendedThinkingConfig() throws {
        let livePayload = LiveGeminiStreamSession.setupPayload(
            model: "gemini-3.8-live",
            language: "tr",
            systemPrompt: "Yalnızca konuşulanı yaz."
        )
        let liveSetup = try XCTUnwrap(livePayload["setup"] as? [String: Any])
        let liveGeneration = try XCTUnwrap(liveSetup["generationConfig"] as? [String: Any])
        XCTAssertEqual(liveGeneration["responseModalities"] as? [String], ["AUDIO"])
        XCTAssertTrue((liveSetup["inputAudioTranscription"] as? [String: Any] ?? [:]).isEmpty)
        XCTAssertNil(liveSetup["thinkingConfig"])
        XCTAssertNotNil(liveSetup["systemInstruction"])

        let extendedPayload = LiveGeminiStreamSession.setupPayload(
            model: "models/gemini-3.8-live-extended-thinking",
            language: "tr",
            systemPrompt: "Yalnızca konuşulanı yaz."
        )
        let extendedSetup = try XCTUnwrap(extendedPayload["setup"] as? [String: Any])
        let thinking = try XCTUnwrap(extendedSetup["thinkingConfig"] as? [String: Any])
        XCTAssertEqual(thinking["thinkingLevel"] as? String, "low")

        let transcribePayload = LiveGeminiStreamSession.setupPayload(
            model: "gemini-3.5-transcribe-live",
            language: "tr",
            systemPrompt: "Bu istem gönderilmemeli."
        )
        let transcribeSetup = try XCTUnwrap(transcribePayload["setup"] as? [String: Any])
        let transcribeGeneration = try XCTUnwrap(transcribeSetup["generationConfig"] as? [String: Any])
        XCTAssertEqual(transcribeGeneration["responseModalities"] as? [String], ["TEXT"])
        let transcription = try XCTUnwrap(transcribeSetup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["languageCodes"] as? [String], ["tr"])
        XCTAssertNil(transcribeSetup["systemInstruction"])
    }

    func testModelRoutingSeparatesLiveAndRESTTranscription() {
        XCTAssertTrue(ConfigManager.isGeminiLiveModel("gemini-3.5-transcribe-live"))
        XCTAssertFalse(ConfigManager.supportsGeminiGenerateContent(model: "gemini-3.5-transcribe-live"))
        XCTAssertTrue(ConfigManager.supportsGeminiGenerateContent(model: "gemini-3.5-transcribe"))
        XCTAssertTrue(ConfigManager.isGeminiLiveModel("gemini-3.8-live"))
        XCTAssertTrue(ConfigManager.isGeminiExtendedThinkingModel("gemini-3.8-live-extended-thinking"))
    }

    func testMissingKeyDoesNotStartNetworkRequest() {
        let expectation = expectation(description: "missing key")
        GeminiModelCatalog.fetch(apiKey: "   ") { result in
            guard case .failure(let error) = result else {
                return XCTFail("Missing key must fail before network")
            }
            XCTAssertEqual(error as? GeminiModelCatalogError, .missingAPIKey)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.1)
    }
}
