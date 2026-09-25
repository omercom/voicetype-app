import XCTest
@testable import VoiceTypingCore

/// DecodeBudget: AlwaysWhisper'ın `decode_sample_len` formülünün uyarlaması.
final class DecodeBudgetTests: XCTestCase {

    // MARK: - tokenCap

    func testTokenCapFollowsAlwaysWhisperFormula() {
        // 16 * saniye + 32
        XCTAssertEqual(DecodeBudget.tokenCap(audioSeconds: 1.0), 48)
        XCTAssertEqual(DecodeBudget.tokenCap(audioSeconds: 8.0), 160)
        XCTAssertEqual(DecodeBudget.tokenCap(audioSeconds: 30.0), 512)
    }

    func testTokenCapClampsToMinimum() {
        // Çok kısa kayıtta tavan deşifreyi boğmamalı.
        XCTAssertEqual(DecodeBudget.tokenCap(audioSeconds: 0.01), DecodeBudget.minimumTokenCap)
        XCTAssertEqual(DecodeBudget.tokenCap(audioSeconds: 0.0), DecodeBudget.minimumTokenCap)
    }

    func testTokenCapClampsToMaximum() {
        // Çok uzun kayıtta Int taşması olmamalı.
        XCTAssertEqual(DecodeBudget.tokenCap(audioSeconds: 10_000.0), DecodeBudget.maximumTokenCap)
        XCTAssertEqual(DecodeBudget.tokenCap(audioSeconds: .greatestFiniteMagnitude),
                       DecodeBudget.maximumTokenCap)
    }

    func testTokenCapReturnsNilWhenDisabled() {
        // 0 = tavan yok → çağıran ilgili alanı isteğe hiç koymamalı.
        XCTAssertNil(DecodeBudget.tokenCap(audioSeconds: 5.0, tokensPerSecond: 0))
        XCTAssertNil(DecodeBudget.tokenCap(audioSeconds: 5.0, tokensPerSecond: -1))
    }

    func testTokenCapHandlesInvalidDurations() {
        XCTAssertEqual(DecodeBudget.tokenCap(audioSeconds: .nan), DecodeBudget.minimumTokenCap)
        XCTAssertEqual(DecodeBudget.tokenCap(audioSeconds: -5.0), DecodeBudget.minimumTokenCap)
        XCTAssertEqual(DecodeBudget.tokenCap(audioSeconds: .infinity), DecodeBudget.maximumTokenCap)
    }

    func testTokenCapIsMonotonic() {
        var previous = 0
        for seconds in stride(from: 0.5, through: 60.0, by: 0.5) {
            let cap = DecodeBudget.tokenCap(audioSeconds: seconds) ?? 0
            XCTAssertGreaterThanOrEqual(cap, previous, "Süre arttıkça tavan azalmamalı")
            previous = cap
        }
    }

    // MARK: - maxChunkSeconds (Groq için)

    func testMaxChunkSecondsIsInverseOfTokenCap() {
        let cap = 512
        let seconds = DecodeBudget.maxChunkSeconds(tokenCap: cap)
        // Tersine çözüm: bulunan süre için tavan, hedefi aşmamalı.
        let derived = DecodeBudget.tokenCap(audioSeconds: seconds) ?? 0
        XCTAssertLessThanOrEqual(derived, cap)
    }

    func testMaxChunkSecondsIsInfinityWhenDisabled() {
        XCTAssertEqual(DecodeBudget.maxChunkSeconds(tokensPerSecond: 0), .infinity)
        XCTAssertTrue(DecodeBudget.maxChunkSeconds(tokensPerSecond: 0).isInfinite)
    }

    func testMaxChunkSecondsPositiveForDefaultCap() {
        let seconds = DecodeBudget.maxChunkSeconds()
        XCTAssertGreaterThan(seconds, 0)
        XCTAssertTrue(seconds.isFinite)
    }

    // MARK: - audioSeconds

    func testAudioSecondsFromPCMByteCount() {
        // 16000 örnek × 2 bayt = 1 saniye
        XCTAssertEqual(DecodeBudget.audioSeconds(pcm16ByteCount: 32_000), 1.0, accuracy: 0.0001)
        XCTAssertEqual(DecodeBudget.audioSeconds(pcm16ByteCount: 160_000), 5.0, accuracy: 0.0001)
    }

    func testAudioSecondsHandlesInvalidInput() {
        XCTAssertEqual(DecodeBudget.audioSeconds(pcm16ByteCount: 0), 0)
        XCTAssertEqual(DecodeBudget.audioSeconds(pcm16ByteCount: -10), 0)
        XCTAssertEqual(DecodeBudget.audioSeconds(pcm16ByteCount: 100, sampleRate: 0), 0)
    }

    // MARK: - Sağlayıcı uyumu (canlı API testiyle doğrulanan gerçekler)

    func testDefaultConfigValuesMatchDocumentedConstants() {
        // Bu sabitler implementation_plan'da belgelenen AlwaysWhisper
        // değerleriyle eşleşmeli; sessizce sapmamalı.
        XCTAssertEqual(DecodeBudget.defaultTokensPerSecond, 16)
        XCTAssertEqual(DecodeBudget.defaultTokenBase, 32)
    }

    func testGroqSafeChunkIsUnderProviderTokenCeiling() {
        // Groq max_tokens parametresini reddettiği için girdi süresiyle
        // korunuyoruz: üretilen pencere sağlayıcı tavanını aşmamalı.
        let seconds = DecodeBudget.maxChunkSeconds(tokenCap: DecodeBudget.maximumTokenCap)
        XCTAssertLessThanOrEqual(
            DecodeBudget.tokenCap(audioSeconds: seconds) ?? .max,
            DecodeBudget.maximumTokenCap
        )
    }
}
