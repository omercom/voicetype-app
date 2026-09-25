import XCTest
import AppKit
@testable import VoiceTypingCore

/// Dinamik yazı boyutlandırmayı GERÇEK font metrikleriyle doğrular.
///
/// Diğer tipografi testleri sahte (doğrusal) ölçüm kullanır; bu dosya
/// gerçek SF Pro ölçümüyle çalışır ki "sahada gerçekten küçülüyor mu"
/// sorusu yanıtsız kalmasın.
final class NotchTypographyRealFontTests: XCTestCase {

    /// Üretimdekiyle AYNI ölçüm: SF Pro Medium, verilen puntoda genişlik.
    private func realMeasure(_ text: String, _ size: CGFloat) -> CGFloat {
        ceil((text as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]
        ).width)
    }

    /// Üretimdekiyle aynı ada genişliği (sabit).
    private var panelWidth: CGFloat {
        NotchTypography.panelWidth(cameraWidth: 179, screenWidth: 1470)
    }

    private var availableTextWidth: CGFloat {
        panelWidth - 2 * NotchTypography.horizontalPadding
    }

    private func fittedSize(for text: String) -> CGFloat {
        NotchTypography.fittedFontSize(
            text: text,
            availableWidth: availableTextWidth,
            measure: realMeasure
        )
    }

    // MARK: - Gerçek metinlerle davranış

    func testShortUtteranceKeepsBaseFont() {
        let size = fittedSize(for: "Merhaba nasılsın")
        print("[gerçek] kısa metin -> \(size)pt (ada \(panelWidth)pt, alan \(availableTextWidth)pt)")
        XCTAssertEqual(size, NotchTypography.baseFontSize)
    }

    func testMediumUtteranceStillFitsWithoutShrinking() {
        // Tipik bir dikte cümlesi: sarma ile çözülmeli, küçültme gerekmemeli.
        let text = "Merhaba nasılsın iyi misin bugün hava çok güzel görünüyor"
        let size = fittedSize(for: text)
        let lines = NotchTypography.lineCount(
            text: text, availableWidth: availableTextWidth, fontSize: size, measure: realMeasure)
        print("[gerçek] orta metin (\(text.count) karakter) -> \(size)pt, \(lines) satır")
        XCTAssertEqual(size, NotchTypography.baseFontSize)
        XCTAssertLessThanOrEqual(lines, NotchTypography.maximumLines)
    }

    func testLongUtteranceShrinksDynamically() {
        // Uzun dikte: satır sınırını aşınca yazı KÜÇÜLMELİ.
        let text = String(repeating: "Bu uzun bir dikte cümlesidir ve küçülmeyi tetiklemelidir ", count: 3)
        let size = fittedSize(for: text)
        let lines = NotchTypography.lineCount(
            text: text, availableWidth: availableTextWidth, fontSize: size, measure: realMeasure)
        print("[gerçek] uzun metin (\(text.count) karakter) -> \(size)pt, \(lines) satır")
        XCTAssertLessThan(size, NotchTypography.baseFontSize,
                          "Uzun metinde yazı dinamik olarak küçülmeli")
        // Alt sınırın üstündeyse satır sınırına sığmalı; alt sınırda ise
        // sığmayabilir (o durumda metin kırpılır, daha fazla küçültülmez).
        if size > NotchTypography.minimumFontSize {
            XCTAssertLessThanOrEqual(lines, NotchTypography.maximumLines)
        }
    }

    func testFontMonotonicallyShrinksAsTextGrows() {
        // Kritik davranış: metin uzadıkça punto ASLA artmamalı.
        var previous = CGFloat.greatestFiniteMagnitude
        var sizes: [CGFloat] = []
        for words in [3, 8, 16, 30, 60, 120, 300] {
            let text = Array(repeating: "kelime", count: words).joined(separator: " ")
            let size = fittedSize(for: text)
            sizes.append(size)
            XCTAssertLessThanOrEqual(size, previous,
                                     "\(words) kelimede punto öncekinden büyük olmamalı")
            previous = size
        }
        print("[gerçek] kelime sayısı -> punto: \(sizes)")
    }

    func testFontNeverGoesBelowReadabilityFloor() {
        // Ne kadar uzun olursa olsun alt sınırın altına inilmez.
        let absurd = String(repeating: "kelime ", count: 2000)
        let size = fittedSize(for: absurd)
        print("[gerçek] aşırı uzun metin -> \(size)pt (alt sınır \(NotchTypography.minimumFontSize))")
        XCTAssertEqual(size, NotchTypography.minimumFontSize)
    }

    func testMeasuredWidthFitsWithinAvailableWhenAboveFloor() {
        // Seçilen punto gerçekten sığıyor mu? (Taban üstü olduğu sürece)
        let text = String(repeating: "dikte ", count: 40)
        let size = fittedSize(for: text)
        guard size > NotchTypography.minimumFontSize else { return }
        let lines = NotchTypography.lineCount(
            text: text, availableWidth: availableTextWidth, fontSize: size, measure: realMeasure)
        XCTAssertLessThanOrEqual(lines, NotchTypography.maximumLines)
    }
}
