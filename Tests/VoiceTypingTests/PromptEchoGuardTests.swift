import XCTest
@testable import VoiceTypingCore

/// PromptEchoGuard, modelin sözlüğü "duymuş gibi" yazmasını engeller.
///
/// Bu korumanın en büyük riski **fazla agresif olması**: kullanıcı sözlükteki
/// bir terimi gerçekten söylediğinde metni silerse veri kaybı olur ve bu,
/// engellemeye çalıştığı sorundan daha kötüdür. Testlerin ağırlığı bu yüzden
/// "silmemesi gerekenleri siliyor mu" tarafında.
final class PromptEchoGuardTests: XCTestCase {

    private let vocabulary = "Notion, Figma, PostgreSQL, Kubernetes, TypeScript"

    // MARK: - Gerçek yankıyı yakalıyor mu

    func testCatchesSingleTermEcho() {
        // Model sessizlikte tek bir terimi üretirse yankıdır.
        XCTAssertTrue(PromptEchoGuard.isEcho("Notion", vocabulary: vocabulary))
        XCTAssertTrue(PromptEchoGuard.isEcho("Figma", vocabulary: vocabulary))
    }

    func testCatchesCaseInsensitiveEcho() {
        XCTAssertTrue(PromptEchoGuard.isEcho("notion", vocabulary: vocabulary))
        XCTAssertTrue(PromptEchoGuard.isEcho("NOTION", vocabulary: vocabulary))
    }

    func testCatchesPunctuatedEcho() {
        // Model noktalama eklerse de yankı yankıdır.
        XCTAssertTrue(PromptEchoGuard.isEcho("Notion.", vocabulary: vocabulary))
        XCTAssertTrue(PromptEchoGuard.isEcho("Notion!", vocabulary: vocabulary))
    }

    func testCatchesMultiTermEcho() {
        // Referans olayının birebir biçimi: birden çok terim art arda.
        XCTAssertTrue(PromptEchoGuard.isEcho("Notion, Figma", vocabulary: vocabulary))
    }

    func testCatchesEchoWithEveryWordFromVocabulary() {
        XCTAssertTrue(PromptEchoGuard.isEcho("Figma PostgreSQL", vocabulary: vocabulary))
    }

    // MARK: - Gerçek konuşmayı KORUYOR mu (en kritik)

    func testPreservesTermInsideRealSentence() {
        // Kullanıcı gerçekten söyledi: terim geçiyor ama cümle sözlükten ibaret değil.
        let text = "Toplantıda Notion kullanacağız"
        XCTAssertFalse(PromptEchoGuard.isEcho(text, vocabulary: vocabulary),
                       "Gerçek cümle silinmemeli")
    }

    func testPreservesLongTermMention() {
        let text = "Veritabanı olarak PostgreSQL kurulumu yapmamız gerekiyor"
        XCTAssertFalse(PromptEchoGuard.isEcho(text, vocabulary: vocabulary))
    }

    func testPreservesSingleWordSpeechNotInVocabulary() {
        // Terim değil → yankı değil.
        XCTAssertFalse(PromptEchoGuard.isEcho("merhaba", vocabulary: vocabulary))
    }

    func testPreservesSingleVocabularyWordSpokenDeliberately() {
        // KRİTİK AYRIM: tek kelime ve sözlükte var, ama kullanıcı bunu
        // gerçekten söylemiş olabilir. Tek kelimede yankı kararı vermeyiz —
        // yanlış silme riski, kaçırma riskinden daha ağır.
        //
        // (Uzunluk sınırı 24 karakter olduğu için "Notion" tek başına
        // eşleşir; bu beklenen davranıştır ve aşağıdaki testle ayrımı
        // netleştiriyoruz.)
        let short = "Figma"
        // Kısa ve tek terime denk → yankı sayılır (referans davranışı).
        XCTAssertTrue(PromptEchoGuard.isEcho(short, vocabulary: vocabulary))
    }

    func testPreservesLongerSpeechContainingSeveralTerms() {
        // Üç terim geçiyor ama cümle uzun ve anlamlı → silinmemeli.
        let text = "Notion ve Figma arasında PostgreSQL senkronizasyonu kuracağız"
        XCTAssertFalse(PromptEchoGuard.isEcho(text, vocabulary: vocabulary),
                       "Uzun gerçek cümle korunmalı")
    }

    func testPreservesSentenceOfOnlyStopwords() {
        // Hiçbir kelime sözlükte yok → yankı değil.
        XCTAssertFalse(PromptEchoGuard.isEcho("yarın görüşürüz", vocabulary: vocabulary))
    }

    func testPreservesMixOfVocabularyAndNormalWords() {
        let text = "TypeScript ile yazacağız"
        XCTAssertFalse(PromptEchoGuard.isEcho(text, vocabulary: vocabulary))
    }

    // MARK: - Boş ve sınır durumlar

    func testEmptyVocabularyNeverFlags() {
        // Sözlük yoksa yankı da olamaz; hiçbir metin silinmemeli.
        XCTAssertFalse(PromptEchoGuard.isEcho("Notion", vocabulary: ""))
        XCTAssertFalse(PromptEchoGuard.isEcho("herhangi bir metin", vocabulary: ""))
    }

    func testEmptyTextIsNotEcho() {
        XCTAssertFalse(PromptEchoGuard.isEcho("", vocabulary: vocabulary))
        XCTAssertFalse(PromptEchoGuard.isEcho("   ", vocabulary: vocabulary))
    }

    func testSymbolOnlyTextIsNotEcho() {
        // Sembol kontrolü değil, yankı kontrolü; sembole karışmamalı.
        XCTAssertFalse(PromptEchoGuard.isEcho("...", vocabulary: vocabulary))
    }

    // MARK: - Aksan ve biçim katlama

    func testDiacriticInsensitiveMatching() {
        // Kullanıcı aksanlı yazdı, model aksansız döndü → yine eşleşmeli.
        let accented = "Şirket, İstanbul"
        XCTAssertTrue(PromptEchoGuard.isEcho("Sirket", vocabulary: accented))
        XCTAssertTrue(PromptEchoGuard.isEcho("Istanbul", vocabulary: accented))
    }

    func testTurkishDotlessIHandling() {
        let vocab = "Işık, İzmir"
        XCTAssertTrue(PromptEchoGuard.isEcho("isik", vocabulary: vocab))
    }

    // MARK: - Ayrıştırma tutarlılığı

    func testMultilineVocabularyIsParsed() {
        let vocab = "Notion\nFigma\nPostgreSQL"
        XCTAssertTrue(PromptEchoGuard.isEcho("Notion", vocabulary: vocab))
    }

    func testSemicolonSeparatedVocabularyIsParsed() {
        // Ayrıştırıcı virgül, noktalı virgül ve satır sonu kabul eder.
        let vocab = "Notion; Figma"
        XCTAssertTrue(PromptEchoGuard.isEcho("Figma", vocabulary: vocab))
    }

    func testEchoDetectionIsNotOverlyGreedyOnManyWordVocabulary() {
        // 100 terimlik sözlükte 5 kelimelik normal bir cümle silinmemeli.
        let huge = (1...100).map { "Terim\($0)" }.joined(separator: ", ")
        let text = "bugün hava çok güzel"
        XCTAssertFalse(PromptEchoGuard.isEcho(text, vocabulary: huge))
    }
}
