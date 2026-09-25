import XCTest
@testable import VoiceTypingCore

/// RepetitionGuard, Groq'un kabul etmediği `max_tokens` parametresinin yerine
/// geçen metin-tabanlı korumadır. Bu testler hem temizleme davranışını hem de
/// gerçek konuşmayı yanlışlıkla bozmadığını doğrular.
final class RepetitionGuardTests: XCTestCase {

    // MARK: - Temizleme çalışıyor mu

    func testCollapsesRunawaySingleWordRepetition() {
        let input = "teşekkürler teşekkürler teşekkürler teşekkürler teşekkürler"
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.text, "teşekkürler")
        XCTAssertEqual(result.collapsedGroups, 1)
    }

    func testCollapsesRepeatedMultiWordPhrase() {
        let input = "bizi izlediğiniz için teşekkürler bizi izlediğiniz için teşekkürler bizi izlediğiniz için teşekkürler bizi izlediğiniz için teşekkürler"
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.text, "bizi izlediğiniz için teşekkürler")
        XCTAssertEqual(result.collapsedGroups, 1)
    }

    func testKeepsSurroundingRealSpeechWhenCollapsing() {
        let input = "bugün hava çok güzel evet evet evet evet yarın görüşürüz"
        let result = RepetitionGuard.collapse(input)
        // "evet" 4 kez tekrar etti → teke iner, kalan cümle korunur.
        XCTAssertEqual(result.text, "bugün hava çok güzel evet yarın görüşürüz")
        XCTAssertEqual(result.collapsedGroups, 1)
    }

    // MARK: - Gerçek konuşmayı bozmuyor mu (en kritik)

    func testPreservesLegitimateEmphasis() {
        // Üçlü vurgu gerçek konuşmada olur; eşik 4 olduğu için korunmalı.
        let input = "çok çok çok güzel bir gün"
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.collapsedGroups, 0)
    }

    func testPreservesDoubledWord() {
        let input = "bunu hemen hemen anladım"
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.collapsedGroups, 0)
    }

    func testPreservesOrdinarySentence() {
        let input = "Yarın sabah toplantı saat üçte başlıyor ve hepimizin orada olması gerekiyor."
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.collapsedGroups, 0)
    }

    func testPreservesSentenceThatRepeatsTwice() {
        // İki kez tekrar etmek (nadiren) meşrudur; eşiğin altında kalmalı.
        let input = "tamam tamam"
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.collapsedGroups, 0)
    }

    // MARK: - Sınır durumları

    func testEmptyAndShortInputsAreSafe() {
        XCTAssertEqual(RepetitionGuard.collapse("").text, "")
        XCTAssertEqual(RepetitionGuard.collapse("").collapsedGroups, 0)
        XCTAssertEqual(RepetitionGuard.collapse("merhaba").text, "merhaba")
        XCTAssertEqual(RepetitionGuard.collapse("merhaba").collapsedGroups, 0)
    }

    func testHandlesNoSpaceLanguageByCharacter() {
        // Japonca gibi boşluksuz dillerde karakter bazında çalışmalı.
        let input = "ありがとうありがとうありがとうありがとう"
        let result = RepetitionGuard.collapse(input)
        XCTAssertLessThan(result.text.count, input.count)
        XCTAssertGreaterThan(result.collapsedGroups, 0)
    }

    func testVeryLongRepetitionIsFullyCollapsed() {
        // Gerçek arıza senaryosu: yüzlerce tekrar. Hem temizlenmeli hem
        // makul sürede bitmeli (algoritma O(n * blok) olmalı, patlamamalı).
        let input = Array(repeating: "tekrar", count: 500).joined(separator: " ")
        let start = Date()
        let result = RepetitionGuard.collapse(input)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.text, "tekrar")
        XCTAssertLessThan(elapsed, 2.0, "Uzun tekrar temizliği makul sürede bitmeli")
    }

    // MARK: - Noktalama / büyük-küçük harf farkı (ölçümle bulunan boşluk)

    func testCollapsesAcrossDifferentPunctuation() {
        // Model aynı kelimeyi farklı noktalamayla tekrarlar; eski kod bunu
        // KAÇIRIYORDU çünkü ham parçaları karşılaştırıyordu.
        let input = "Tamam. Tamam, Tamam! Tamam."
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.collapsedGroups, 1, "Noktalama farkı tekrarı gizlememeli")
    }

    func testCollapsesAcrossCasingChanges() {
        let input = "Tamam. tamam. Tamam. tamam."
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.collapsedGroups, 1, "Büyük/küçük harf farkı tekrarı gizlememeli")
    }

    func testCollapsedOutputKeepsOriginalPunctuation() {
        // Normalize yalnızca KARŞILAŞTIRMA içindir; çıktıda kullanıcının
        // noktalaması korunmalı (ilk örnek tutulur).
        let input = "Merhaba. Merhaba, Merhaba! Merhaba?"
        let result = RepetitionGuard.collapse(input)
        XCTAssertTrue(result.text.contains("Merhaba."), "İlk örneğin noktalaması korunmalı")
        XCTAssertFalse(result.text.contains("Merhaba,"), "Tekrarlar atılmalı")
    }

    func testTurkishAccentsAreNotFolded() {
        // KRİTİK: "yaş" ve "yas" Türkçe'de AYRI kelimelerdir. Aksan katlamak
        // bunları birbirine karıştırır ve gerçek metni bozardı.
        let input = "yaş yas yaş yas"
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.text, input, "Farklı kelimeler tekrar sayılmamalı")
        XCTAssertEqual(result.collapsedGroups, 0)
    }

    func testTurkishDotlessIStillMatches() {
        // "TAMAM" → yerel ayarsız lowercased "tamam"; "tamam" ile eşleşmeli.
        let input = "TAMAM tamam TAMAM tamam"
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.collapsedGroups, 1, "ı/i farkı tekrarı gizlememeli")
    }

    func testPunctuationOnlyTokensDoNotCollapseSpuriously() {
        // Yalnızca noktalamadan oluşan parçalar boş anahtar üretir; bunların
        // yanlışlıkla "aynı" sayılmaması gerekir.
        let input = "a... b, c! d?"
        let result = RepetitionGuard.collapse(input)
        XCTAssertEqual(result.collapsedGroups, 0)
    }

    func testPunctuationVariantRepetitionOfPhrase() {
        // Çok kelimeli ifade, farklı noktalamayla.
        let input = "bugün hava güzel. bugün hava güzel! bugün hava güzel? bugün hava güzel"
        let result = RepetitionGuard.collapse(input)
        XCTAssertGreaterThan(result.collapsedGroups, 0, "Çok kelimeli noktalama varyantı yakalanmalı")
        XCTAssertLessThan(result.text.count, input.count)
    }

    func testResultNeverGrows() {
        let samples = [
            "a a a a a",
            "normal bir cümle",
            "x y z x y z x y z x y z",
            "",
            "tek kelime"
        ]
        for sample in samples {
            let result = RepetitionGuard.collapse(sample)
            XCTAssertLessThanOrEqual(result.text.count, sample.count,
                                     "Temizleme metni asla uzatmamalı: \(sample)")
        }
    }
}
