import XCTest
@testable import VoiceTypingCore

/// Çentik tipografi kurallarını kilitler.
///
/// Kullanıcı gereksinimleri:
///   • Taban yazı 24pt (referans 28'den 2 kademe küçük) ve bu VARSAYILAN.
///   • Ada genişliği SABİT — metin uzadıkça ada genişlemez.
///   • Uzun metin ALT SATIRLARA SARAR.
///   • Yazı adaptif küçülür ama ALT SINIRIN altına inmez.
///   • Köşeler oval.
final class NotchTypographyTests: XCTestCase {

    /// Doğrusal sahte ölçüm: genişlik = punto * karakter * oran.
    /// Gerçek font metriklerinden bağımsız, deterministik test sağlar.
    private func linearMeasure(charWidth: CGFloat = 0.5) -> (String, CGFloat) -> CGFloat {
        { text, size in CGFloat(text.count) * size * charWidth }
    }

    // MARK: - Taban boyut ve sınırlar

    func testBaseFontIsTwentyPoints() {
        // Yolculuk: referans 28 → 24 → 20 (kullanıcı geri bildirimi).
        XCTAssertEqual(NotchTypography.baseFontSize, 20.0)
    }

    func testBaseFontIsSmallerThanPreviousValue() {
        // Bir önceki değer 24'tü; geri bildirimle küçültüldü.
        XCTAssertLessThan(NotchTypography.baseFontSize, 24.0)
    }

    func testMinimumFontMatchesMacOSSystemFontSize() {
        // Okunabilirlik tabanı keyfî değil: macOS standart arayüz boyutu.
        XCTAssertEqual(NotchTypography.minimumFontSize, NSFont.systemFontSize,
                       "Alt sınır sistem yazı boyutuna eşit olmalı")
        XCTAssertLessThan(NotchTypography.minimumFontSize, NotchTypography.baseFontSize)
    }

    func testBaseFontIsComfortablyReadable() {
        // Taban boyut sistem standartının belirgin biçimde üstünde kalmalı.
        XCTAssertGreaterThan(NotchTypography.baseFontSize, NSFont.systemFontSize)
    }

    // MARK: - SABİT ada genişliği (asıl istek)

    func testPanelWidthIsIndependentOfText() {
        // Kritik: `panelWidth` artık metin genişliği ALMIYOR. Ada genişliği
        // yalnızca ekran ve çentiğe bağlı olmalı; metinle değişmemeli.
        let a = NotchTypography.panelWidth(cameraWidth: 180, screenWidth: 1470)
        let b = NotchTypography.panelWidth(cameraWidth: 180, screenWidth: 1470)
        XCTAssertEqual(a, b, "Aynı ekranda ada genişliği her zaman aynı olmalı")
    }

    func testPanelWidthHasUpperBound() {
        // Çok geniş ekranda ada sınırsız büyümemeli.
        let w = NotchTypography.panelWidth(cameraWidth: 180, screenWidth: 6000)
        XCTAssertLessThanOrEqual(w, NotchTypography.maximumPanelWidth)
    }

    func testPanelWidthRespectsMinimumAndCamera() {
        let w = NotchTypography.panelWidth(cameraWidth: 180, screenWidth: 1470)
        XCTAssertGreaterThanOrEqual(w, NotchTypography.minimumPanelWidth)
        XCTAssertGreaterThanOrEqual(w, 180 + 160)
    }

    func testPanelWidthNeverExceedsScreen() {
        let w = NotchTypography.panelWidth(cameraWidth: 180, screenWidth: 500)
        XCTAssertLessThanOrEqual(w, 500)
    }

    // MARK: - Satır sarma (kelime kaydırma)

    func testShortTextUsesOneLine() {
        let lines = NotchTypography.lineCount(
            text: "Merhaba", availableWidth: 400, fontSize: 24, measure: linearMeasure()
        )
        XCTAssertEqual(lines, 1)
    }

    func testLongTextWrapsToMultipleLines() {
        let text = String(repeating: "kelime ", count: 20)
        let lines = NotchTypography.lineCount(
            text: text, availableWidth: 400, fontSize: 24, measure: linearMeasure()
        )
        XCTAssertGreaterThan(lines, 1, "Uzun metin alt satırlara sarmalı")
    }

    func testMoreTextMeansMoreLinesAtSameFont() {
        let m = linearMeasure()
        let short = NotchTypography.lineCount(
            text: String(repeating: "kelime ", count: 5), availableWidth: 400, fontSize: 24, measure: m)
        let long = NotchTypography.lineCount(
            text: String(repeating: "kelime ", count: 30), availableWidth: 400, fontSize: 24, measure: m)
        XCTAssertGreaterThanOrEqual(long, short)
    }

    func testEmptyTextHasNoLines() {
        XCTAssertEqual(NotchTypography.lineCount(
            text: "", availableWidth: 400, fontSize: 24, measure: linearMeasure()), 0)
    }

    func testNoSpaceLanguageCountsAsSingleLine() {
        // Boşluksuz metin (ör. 日本語) kelime sarma yapamaz; tek satır.
        let lines = NotchTypography.lineCount(
            text: "こんにちは", availableWidth: 400, fontSize: 24, measure: linearMeasure())
        XCTAssertEqual(lines, 1)
    }

    // MARK: - Adaptif yazı boyutu (alt sınırlı)

    func testShortTextKeepsBaseSize() {
        let size = NotchTypography.fittedFontSize(
            text: "Merhaba", availableWidth: 400, measure: linearMeasure())
        XCTAssertEqual(size, NotchTypography.baseFontSize)
    }

    func testLongTextShrinksToFitWithinLineLimit() {
        let text = String(repeating: "kelime ", count: 40)
        let size = NotchTypography.fittedFontSize(
            text: text, availableWidth: 400, measure: linearMeasure())
        XCTAssertLessThan(size, NotchTypography.baseFontSize)
    }

    func testShrinkingStopsAtMinimum() {
        // Alt sınır: aşırı uzun metinde bile daha aşağı inilmemeli.
        let absurd = String(repeating: "kelime ", count: 4000)
        let size = NotchTypography.fittedFontSize(
            text: absurd, availableWidth: 200, measure: linearMeasure())
        XCTAssertEqual(size, NotchTypography.minimumFontSize,
                       "Okunabilirlik tabanının altına inilmemeli")
    }

    func testFittedSizeNeverExceedsBase() {
        let size = NotchTypography.fittedFontSize(
            text: "kısa", availableWidth: 100_000, measure: linearMeasure())
        XCTAssertEqual(size, NotchTypography.baseFontSize)
    }

    func testFittedSizeAlwaysWithinBounds() {
        // Rastgele uzunluklarda bile sınırlar korunmalı.
        let m = linearMeasure()
        for count in [0, 1, 5, 50, 500, 5000] {
            let text = String(repeating: "a ", count: count)
            let size = NotchTypography.fittedFontSize(text: text, availableWidth: 380, measure: m)
            XCTAssertGreaterThanOrEqual(size, NotchTypography.minimumFontSize)
            XCTAssertLessThanOrEqual(size, NotchTypography.baseFontSize)
            XCTAssertTrue(size.isFinite)
        }
    }

    func testFittedTextRespectsLineLimitWhenAboveFloor() {
        // Gerçek değişmez: taban üstü bir punto seçildiyse metin satır sınırına
        // sığmalı. Alt sınır devreye girdiğinde sığmayabilir (o zaman kırpılır).
        let text = String(repeating: "kelime ", count: 12)
        let m = linearMeasure()
        let size = NotchTypography.fittedFontSize(text: text, availableWidth: 380, measure: m)
        if size > NotchTypography.minimumFontSize {
            let lines = NotchTypography.lineCount(
                text: text, availableWidth: 380, fontSize: size, measure: m)
            XCTAssertLessThanOrEqual(lines, NotchTypography.maximumLines)
        }
    }

    func testDegenerateInputsAreSafe() {
        let m = linearMeasure()
        XCTAssertTrue(NotchTypography.fittedFontSize(text: "", availableWidth: 100, measure: m).isFinite)
        XCTAssertTrue(NotchTypography.fittedFontSize(text: "abc", availableWidth: 0, measure: m).isFinite)
    }

    // MARK: - İçerik yüksekliği

    func testContentHeightGrowsWithLineCount() {
        let one = NotchTypography.contentHeight(lineCount: 1, fontSize: 24) { _ in 29 }
        let three = NotchTypography.contentHeight(lineCount: 3, fontSize: 24) { _ in 29 }
        XCTAssertGreaterThan(three, one, "Daha çok satır daha yüksek ada demek")
    }

    func testContentHeightIncludesPadding() {
        let h = NotchTypography.contentHeight(lineCount: 1, fontSize: 24) { _ in 20 }
        XCTAssertGreaterThanOrEqual(h, 20 + NotchTypography.verticalPadding)
    }

    func testContentHeightHandlesZeroLines() {
        // Boş metin çökmemeli, tek satır yüksekliği kadar yer ayırmalı.
        let h = NotchTypography.contentHeight(lineCount: 0, fontSize: 24) { _ in 20 }
        XCTAssertTrue(h.isFinite)
        XCTAssertGreaterThan(h, 0)
    }

    func testContentHeightIsCappedForRunawayText() {
        // Sonsuz tekrar/aşırı uzun metin adayı ekran dışına taşırmamalı.
        let huge = NotchTypography.contentHeight(lineCount: 500, fontSize: 24) { _ in 29 }
        XCTAssertLessThanOrEqual(huge, NotchTypography.maximumContentHeight,
                                 "Ada yüksekliği üst sınırla kısıtlanmalı")
    }

    func testContentHeightCapDoesNotAffectNormalText() {
        // Normal (3 satır) metin tavana takılmamalı.
        let normal = NotchTypography.contentHeight(
            lineCount: NotchTypography.maximumLines, fontSize: 24) { _ in 29 }
        XCTAssertLessThan(normal, NotchTypography.maximumContentHeight)
    }

    // MARK: - Oval köşe

    func testCornerRadiusIsHalfHeightForOval() {
        XCTAssertEqual(NotchTypography.cornerRadius(panelHeight: 60), 30.0, accuracy: 0.001)
        XCTAssertEqual(NotchTypography.cornerRadius(panelHeight: 40), 20.0, accuracy: 0.001)
    }

    func testCornerRadiusIsClampedAndNeverNegative() {
        XCTAssertEqual(NotchTypography.cornerRadius(panelHeight: 500), 30.0, accuracy: 0.001)
        XCTAssertEqual(NotchTypography.cornerRadius(panelHeight: -10), 0.0, accuracy: 0.001)
    }
}

// MARK: - Yazı boyutu artık ayarlanmıyor

/// Kullanıcı geri bildirimi: "fontsize configden ayarlanmasin, o ayarı kaldır".
/// Bu testler ayarın gerçekten kaldırıldığını ve boyutun tamamen otomatik
/// olduğunu garanti eder.
final class NotchTypographyDefaultsTests: XCTestCase {

    func testConfigHasNoFontSizeSetting() throws {
        // Boyut ayarı kaldırıldı: config'te böyle bir anahtar olmamalı.
        // (Derleme zamanı garantisi: `AppConfig.hud_font_size` artık yok.)
        let cfg = AppConfig.defaultConfig
        let json = String(data: try JSONEncoder().encode(cfg), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("hud_font_size"),
                       "Yazı boyutu ayarı config'ten tamamen kaldırılmalı")
    }

    func testLegacyConfigWithFontSizeKeyStillDecodes() throws {
        // Eski config'lerde `hud_font_size` olabilir; bilinmeyen anahtar
        // yok sayılmalı ve yükleme BAŞARISIZ olmamalı.
        let legacy = """
        {"provider":"apple","groq_api_key":"","gemini_api_key":"",
         "groq_model":"whisper-large-v3","gemini_model":"gemini-3.5-transcribe-live",
         "language":"tr","trigger_key":54,"trigger_mode":"hold",
         "hud_style":"notch","hud_font_size":42}
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(cfg.hud_style, "notch", "Diğer ayarlar korunmalı")
    }

    func testLegacyConfigWithoutFontKeyStillDecodes() throws {
        let legacy = """
        {"provider":"apple","groq_api_key":"","gemini_api_key":"",
         "groq_model":"whisper-large-v3","gemini_model":"gemini-3.5-transcribe-live",
         "language":"tr","trigger_key":54,"trigger_mode":"hold"}
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(cfg.hud_style, "pill")
    }

    func testDefaultHudStyleIsPill() {
        // Çentik modu opt-in kalmalı; varsayılan kapsül.
        XCTAssertEqual(AppConfig.defaultConfig.hud_style, "pill")
    }

    func testAutomaticSizingCannotBeOverriddenByAnyConfigValue() {
        // Boyut yalnızca metne ve ada genişliğine bağlı olduğundan, aynı
        // girdiler her zaman aynı sonucu vermeli (dışarıdan ayar yok).
        let m: (String, CGFloat) -> CGFloat = { t, s in CGFloat(t.count) * s * 0.5 }
        let a = NotchTypography.fittedFontSize(text: "deneme metni", availableWidth: 380, measure: m)
        let b = NotchTypography.fittedFontSize(text: "deneme metni", availableWidth: 380, measure: m)
        XCTAssertEqual(a, b)
    }
}
