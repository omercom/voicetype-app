import XCTest
@testable import VoiceTypingCore

/// HallucinationFilter: Whisper'ın sessizlikte ürettiği altyazı kalıplarını
/// temizlerken gerçek dikteyi bozmadığını doğrular.
final class HallucinationFilterTests: XCTestCase {

    // MARK: - Tüm metin uydurma

    func testDropsSubtitleCreditVariants() {
        for input in ["Altyazı M.K.", "altyazı m.k.", "Alt yazı M.K.", "ALTYAZI M.K.", "Altyazi MK", "  Altyazı M.K.  "] {
            XCTAssertEqual(HallucinationFilter.clean(input), "", "Atılmalıydı: \(input)")
        }
    }

    func testDropsKnownVideoOutroPhrases() {
        XCTAssertEqual(HallucinationFilter.clean("İzlediğiniz için teşekkürler."), "")
        XCTAssertEqual(HallucinationFilter.clean("izlediginiz icin tesekkurler"), "")
        XCTAssertEqual(HallucinationFilter.clean("Abone olmayı unutmayın!"), "")
        XCTAssertEqual(HallucinationFilter.clean("Thank you for watching!"), "")
    }

    // MARK: - Sondaki jenerik

    func testStripsTrailingSubtitleCredit() {
        XCTAssertEqual(HallucinationFilter.clean("Toplantı saat üçte. Altyazı M.K."), "Toplantı saat üçte.")
    }

    func testStripsTrailingAmaraCredit() {
        XCTAssertEqual(
            HallucinationFilter.clean("Raporu yarın gönderiyorum. Altyazılar Amara.org topluluğu tarafından."),
            "Raporu yarın gönderiyorum."
        )
    }

    func testDropsOutroLeftAfterStrippingCredit() {
        XCTAssertEqual(HallucinationFilter.clean("İzlediğiniz için teşekkürler. Altyazı M.K."), "")
    }

    // MARK: - Gerçek dikte korunur

    func testKeepsPhraseInsideLongerSentence() {
        let input = "Videonun sonunda izlediğiniz için teşekkürler diyeceğim"
        XCTAssertEqual(HallucinationFilter.clean(input), input)
    }

    func testKeepsShortGenuineThanks() {
        XCTAssertEqual(HallucinationFilter.clean("Teşekkürler"), "Teşekkürler")
        XCTAssertEqual(HallucinationFilter.clean("Çok teşekkür ederim."), "Çok teşekkür ederim.")
    }

    func testKeepsSentenceMentioningSubtitlesWithoutCredit() {
        let input = "Videoya altyazı eklemeyi unutma"
        XCTAssertEqual(HallucinationFilter.clean(input), input)
    }

    func testUnchangedTextIsReturnedAsIs() {
        let input = "  merhaba dünya "
        XCTAssertEqual(HallucinationFilter.clean(input), input)
        XCTAssertEqual(HallucinationFilter.clean(""), "")
    }

    // MARK: - Zincir entegrasyonu

    func testPolishPipelineDropsHallucination() throws {
        let config = AppConfig.defaultConfig
        XCTAssertEqual(TextPolisher.shared.polish(text: "Altyazı M.K.", config: config), "")
    }
}
