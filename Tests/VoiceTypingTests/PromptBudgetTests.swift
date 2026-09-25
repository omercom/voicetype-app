import XCTest
@testable import VoiceTypingCore

/// PromptBudget, Whisper'ın 224 token'lik decoder penceresini yönetir.
///
/// Neden test edilmeli: Whisper sınırı **sessizce** uygular — kırpma olursa
/// hata dönmez. Yani bu kodun yanlış olması, kullanıcının sözlüğünün bir
/// kısmının hiç çalışmaması ama sebebinin görünmemesi demektir.
final class PromptBudgetTests: XCTestCase {

    // MARK: - Token tahmini

    func testEmptyTextIsZeroTokens() {
        XCTAssertEqual(PromptBudget.estimateTokens(""), 0)
    }

    func testShortTextIsOneToken() {
        // 4 karakterden az metin yine de 1 token sayılmalı (yuvarlama yukarı).
        XCTAssertEqual(PromptBudget.estimateTokens("ab"), 1)
    }

    func testFourCharactersIsOneToken() {
        XCTAssertEqual(PromptBudget.estimateTokens("abcd"), 1)
    }

    func testEstimatorRoundsUp() {
        // 5 karakter → 2 token (yukarı yuvarlanır, aşağı değil).
        XCTAssertEqual(PromptBudget.estimateTokens("abcde"), 2)
    }

    func testCJKCharactersCostDouble() {
        // Japonca karakter başına 2 token; modelin gerçek maliyeti budur.
        let japanese = "ありがとう"
        let tokens = PromptBudget.estimateTokens(japanese)
        XCTAssertEqual(tokens, japanese.count * PromptBudget.tokensPerCJKCharacter)
    }

    func testMixedScriptCountsBoth() {
        // "abc" (3 karakter) + "あ" (1 CJK ×2) → 1 + 2 = 3
        XCTAssertEqual(PromptBudget.estimateTokens("abcあ"), 3)
    }

    func testEstimatorIsMonotonic() {
        // Uzun metin asla daha az token vermemeli.
        let short = "kısa"
        let long = "kısa bir cümle çok daha uzun"
        XCTAssertLessThanOrEqual(
            PromptBudget.estimateTokens(short),
            PromptBudget.estimateTokens(long)
        )
    }

    // MARK: - Kırpma

    func testShortTextIsNotTruncated() {
        let result = PromptBudget.truncateToTail("kısa bir sözlük")
        XCTAssertEqual(result.text, "kısa bir sözlük")
        XCTAssertFalse(result.wasTruncated)
    }

    func testLongTextIsTruncatedAndFlagged() {
        let long = Array(repeating: "uzunterim", count: 200).joined(separator: " ")
        let result = PromptBudget.truncateToTail(long)
        XCTAssertTrue(result.wasTruncated, "Kırpma bildirilmeli")
        XCTAssertLessThan(result.text.count, long.count)
        XCTAssertLessThanOrEqual(
            PromptBudget.estimateTokens(result.text),
            PromptBudget.whisperTokenLimit,
            "Sonuç sınırı aşmamalı"
        )
    }

    func testTruncationKeepsTheTailNotEmpty() {
        let long = Array(repeating: "terim", count: 300).joined(separator: " ")
        let result = PromptBudget.truncateToTail(long)
        XCTAssertFalse(result.text.isEmpty, "Boş sözlük göndermek yerine bir kısmı kalsın")
    }

    func testTruncationPreservesWordBoundaries() {
        // Yarım kelime bırakmamalı — model anlamsız parça görmemeli.
        let long = Array(repeating: "kelime", count: 200).joined(separator: " ")
        let result = PromptBudget.truncateToTail(long)
        for word in result.text.split(separator: " ") {
            XCTAssertEqual(word, "kelime", "Yarım kelime bırakılmamalı")
        }
    }

    func testOrderIsPreserved() {
        // Sondan kesildiğinde kelime SIRASI korunmalı (geri çevirme doğru mu).
        let words = (1...200).map { "terim\($0)" }
        let result = PromptBudget.truncateToTail(words.joined(separator: " "))
        let kept = result.text.split(separator: " ").map(String.init)
        let numbers = kept.compactMap { Int($0.replacingOccurrences(of: "terim", with: "")) }
        XCTAssertEqual(numbers, numbers.sorted(), "Sıra bozulmamalı")
        XCTAssertTrue(numbers.last ?? 0 > numbers.first ?? 0, "Sondaki terimler tutulmalı")
    }

    func testZeroLimitReturnsInputUnchanged() {
        // Sıfır/negatif sınır anlamsız; veriyi bozmaktansa dokunmamak doğru.
        let text = "bir iki üç"
        XCTAssertEqual(PromptBudget.truncateToTail(text, maxTokens: 0).text, text)
        XCTAssertEqual(PromptBudget.truncateToTail(text, maxTokens: -5).text, text)
    }

    func testSingleOversizedWordIsLeftAlone() {
        // Tek kelime sınırı aşıyorsa yarım kesmek yerine bırakılır.
        let giant = String(repeating: "a", count: 2000)
        let result = PromptBudget.truncateToTail(giant)
        XCTAssertEqual(result.text, giant)
        XCTAssertFalse(result.wasTruncated)
    }

    // MARK: - Sözlük yardımcıları

    func testPromptTextJoinsTermsWithComma() {
        let result = PromptBudget.promptText(fromVocabulary: "Notion, Figma")
        XCTAssertEqual(result.text, "Notion, Figma")
        XCTAssertFalse(result.wasTruncated)
    }

    func testPromptTextHandlesEmptyVocabulary() {
        let result = PromptBudget.promptText(fromVocabulary: "")
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.wasTruncated)
    }

    func testPromptTextDeduplicatesTerms() {
        // Aynı terimin tekrarı bütçeyi boşa harcar.
        let result = PromptBudget.promptText(fromVocabulary: "Notion, Notion, notion")
        XCTAssertEqual(result.text, "Notion")
    }

    func testRealisticLargeGlossaryIsHandled() {
        // Gerçekçi senaryo: 60 teknik terim. Sessizce kaybolmamalı.
        let terms = (1...60).map { "TeknikTerim\($0)" }
        let result = PromptBudget.promptText(fromVocabulary: terms.joined(separator: ", "))
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertLessThanOrEqual(
            PromptBudget.estimateTokens(result.text),
            PromptBudget.whisperTokenLimit
        )
    }

    func testLimitMatchesWhisperWindow() {
        // 224 Whisper'ın decoder prompt penceresi; değişirse testler uyarsın.
        XCTAssertEqual(PromptBudget.whisperTokenLimit, 224)
    }
}
