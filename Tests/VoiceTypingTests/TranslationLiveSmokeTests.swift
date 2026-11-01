import Foundation
import XCTest
@testable import VoiceTypingCore

/// Opt-in only: sends a fixed, non-private sentence to the configured provider.
final class TranslationLiveSmokeTests: XCTestCase {
    private func checkProvider(_ provider: String) throws {
        guard ProcessInfo.processInfo.environment["VOICETYPE_TEST_LIVE_TRANSLATION"] == "1" else {
            throw XCTSkip("Set VOICETYPE_TEST_LIVE_TRANSLATION=1 to send a synthetic sentence to configured providers.")
        }
        var config = ConfigManager.shared.config
        let key = provider == "groq" ? config.groq_api_key : config.gemini_api_key
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("No \(provider) API key is configured.")
        }
        config.translation_provider = provider
        let done = expectation(description: "\(provider) live translation")
        TranslationService.shared.translate(text: "Merhaba dünya.", from: "tr", to: "en", config: config, timeout: 15) { result in
            let errorText = result.errorMessage?.lowercased() ?? ""
            let indicators = ["api key expired", "api key not valid", "api_key_invalid", "invalid api key",
                              "permission", "quota", "billing", "location", "thinking", "model",
                              "unsupported", "invalid argument", "invalid value"]
            let matched = indicators.filter { errorText.contains($0) }.joined(separator: ", ")
            let status: String
            if let match = errorText.range(of: #"sunucu hatası \(\d+\)"#, options: .regularExpression) {
                status = String(errorText[match])
            } else {
                status = "doğrulama veya bağlantı hatası"
            }
            let safeError = matched.isEmpty ? status : "\(status); indicators: \(matched)"
            if result.wasFallback {
                XCTFail("\(provider) canlı çevirisi başarısız: \(safeError)")
            } else {
                let lower = result.text.lowercased()
                XCTAssertTrue(lower.contains("world") && (lower.contains("hello") || lower.contains("hi")),
                              "\(provider) örnek çevirisi beklenen anlamı içermiyor")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    func testConfiguredGroq() throws { try checkProvider("groq") }
    func testConfiguredGemini() throws { try checkProvider("gemini") }
}
