import XCTest
@testable import VoiceTypingCore

/// Çentik ekolayzırının referans (AlwaysWhisper) ölçülerini kilitler.
///
/// Bu testlerin varlık sebebi: bu değerler birkaç kez yanlışlıkla değiştirildi
/// ve ekranda VU metre görünmez/kayık çıktı. Artık referans ölçüleri
/// kod içinde sabit ve burada doğrulanıyor.
final class NotchAudioMeterTests: XCTestCase {

    // MARK: - Referans sabitleri

    func testMeterBoxIsTwentyPoints() {
        // Referans: _make_audio_meter_view → NSMakeRect(0, 0, 20, 20)
        XCTAssertEqual(NotchAudioMeter.meterSize, 20.0)
    }

    func testBarCountAndWeightsMatchReference() {
        // Referans: (.45, .75, 1.0, .75, .45) — 5 simetrik çubuk.
        XCTAssertEqual(NotchAudioMeter.barWeights, [0.45, 0.75, 1.0, 0.75, 0.45])
        // Simetrik olmalı: baştan ve sondan okunuşu aynı.
        XCTAssertEqual(NotchAudioMeter.barWeights, NotchAudioMeter.barWeights.reversed())
    }

    func testBarWidthIsOneTenthOfBox() {
        // Referans: bar_width = width / 10
        XCTAssertEqual(NotchAudioMeter.barWidth, 2.0, accuracy: 0.0001)
    }

    func testBarsFillTheBoxExactly() {
        // Referans: spacing = (width - 5*bar_width) / 4 → çubuklar + boşluklar
        // kutuyu tam doldurur, taşma olmaz.
        let origins = NotchAudioMeter.barOriginsX()
        XCTAssertEqual(origins.count, NotchAudioMeter.barWeights.count)
        XCTAssertEqual(origins[0], 0.0, accuracy: 0.0001)
        let lastRightEdge = origins[origins.count - 1] + NotchAudioMeter.barWidth
        XCTAssertEqual(lastRightEdge, NotchAudioMeter.meterSize, accuracy: 0.0001)
    }

    func testMinimumBarHeightIsTwoPoints() {
        // Referans: 2 + (height - 2) * level * weight → level 0'da 2pt.
        XCTAssertEqual(NotchAudioMeter.barHeight(level: 0, weight: 1.0), 2.0, accuracy: 0.0001)
        XCTAssertEqual(NotchAudioMeter.minimumBarHeight, 2.0)
    }

    // MARK: - Çubuk geometrisi

    func testHeightScalesWithLevelAndWeight() {
        // Orta çubuk (ağırlık 1.0) tam seviyede kutuyu doldurur.
        XCTAssertEqual(NotchAudioMeter.barHeight(level: 1.0, weight: 1.0), 20.0, accuracy: 0.0001)
        // Kenar çubukları (ağırlık .45) daha kısa kalır.
        let edge = NotchAudioMeter.barHeight(level: 1.0, weight: 0.45)
        let center = NotchAudioMeter.barHeight(level: 1.0, weight: 1.0)
        XCTAssertLessThan(edge, center)
    }

    func testHeightIsClampedToBox() {
        // Aşırı/aşağı taşan girdiler kutuyu aşmamalı.
        XCTAssertEqual(NotchAudioMeter.barHeight(level: 5.0, weight: 1.0), 20.0, accuracy: 0.0001)
        XCTAssertEqual(NotchAudioMeter.barHeight(level: -3.0, weight: 1.0), 2.0, accuracy: 0.0001)
    }

    func testBarGrowsSymmetricallyFromCenter() {
        // Referans: y = (height - h) / 2 → çubuk dikey merkezde kalır.
        // Kısa ve uzun çubukların merkezi aynı olmalı.
        let shortH = NotchAudioMeter.barHeight(level: 0.1, weight: 1.0)
        let tallH = NotchAudioMeter.barHeight(level: 0.9, weight: 1.0)
        let shortCenter = NotchAudioMeter.barOriginY(height: shortH) + shortH / 2
        let tallCenter = NotchAudioMeter.barOriginY(height: tallH) + tallH / 2
        XCTAssertEqual(shortCenter, tallCenter, accuracy: 0.0001)
        // Ve merkez kutunun tam ortası olmalı.
        XCTAssertEqual(shortCenter, NotchAudioMeter.meterSize / 2, accuracy: 0.0001)
    }

    // MARK: - Yumuşatma (referans AudioLevelMeter)

    func testSmoothRisesFasterThanItFalls() {
        // Referans tau: attack .035, release .18 → yükseliş daha çevik.
        let dt = 1.0 / 30.0
        let rising = NotchAudioMeter.smooth(level: 0.0, target: 1.0, dt: dt)
        let falling = NotchAudioMeter.smooth(level: 1.0, target: 0.0, dt: dt)
        XCTAssertGreaterThan(rising - 0.0, 1.0 - falling,
                             "Yükseliş, düşüşten daha hızlı olmalı (referans davranışı)")
    }

    func testSmoothIsFrameRateIndependent() {
        // Zaman-tabanlı olduğu için 30 FPS'te 30 adım ≈ 60 FPS'te 60 adım.
        let target: CGFloat = 1.0
        var a: CGFloat = 0
        for _ in 0..<30 { a = NotchAudioMeter.smooth(level: a, target: target, dt: 1.0 / 30.0) }
        var b: CGFloat = 0
        for _ in 0..<60 { b = NotchAudioMeter.smooth(level: b, target: target, dt: 1.0 / 60.0) }
        XCTAssertEqual(a, b, accuracy: 0.01,
                       "Aynı süre sonunda aynı seviyeye ulaşmalı (kare hızından bağımsız)")
    }

    func testSmoothSnapsToZeroBelowThreshold() {
        // Referans: level < .005 → 0.0 (sessizlikte göstergenin titremesini önler).
        let result = NotchAudioMeter.smooth(level: 0.004, target: 0.0, dt: 0.1)
        XCTAssertEqual(result, 0.0)
    }

    func testSmoothHandlesNegativeDeltaTime() {
        // Geçersiz dt çökmeye veya NaN'a yol açmamalı.
        let result = NotchAudioMeter.smooth(level: 0.5, target: 1.0, dt: -1.0)
        XCTAssertTrue(result.isFinite)
        XCTAssertEqual(result, 0.5, accuracy: 0.0001, "Negatif dt hiç ilerlememeli")
    }

    // MARK: - Renk eşiği

    func testActiveThresholdMatchesReference() {
        // Referans: level > .02 → systemGreen, aksi halde systemGray.
        XCTAssertEqual(NotchAudioMeter.activeThreshold, 0.02)
        XCTAssertFalse(NotchAudioMeter.isActive(level: 0.0))
        XCTAssertFalse(NotchAudioMeter.isActive(level: 0.02), "Eşitlik aktif sayılmaz")
        XCTAssertTrue(NotchAudioMeter.isActive(level: 0.021))
    }
}
