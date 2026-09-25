import XCTest
import CoreGraphics
@testable import VoiceTypingCore

/// NotchAnchor / NotchLayout: AlwaysWhisper'ın çentik ölçüm mantığının
/// AppKit'ten bağımsız, saf uyarlaması. Gerçek çentikli donanım gerekmez.
final class NotchGeometryTests: XCTestCase {

    /// 14" MacBook Pro benzeri ekran: 1512×982 pt, 2x Retina, çentik var.
    private func notchedScreen() -> NotchAnchor {
        NotchAnchor.make(
            safeTopInset: 32,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            auxiliaryLeftEdgeX: 656,   // sol alanın sağ kenarı (mutlak)
            auxiliaryRightEdgeX: 856,  // sağ alanın sol kenarı (mutlak) → kamera 200 pt
            backingScale: 2
        )
    }

    /// Harici monitör: çentik yok.
    private func externalScreen() -> NotchAnchor {
        NotchAnchor.make(
            safeTopInset: 0,
            screenFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            auxiliaryLeftEdgeX: nil,
            auxiliaryRightEdgeX: nil,
            backingScale: 1
        )
    }

    // MARK: - Çapa ölçümü

    func testNotchedScreenMeasuresCameraWidthFromAuxiliaryAreas() {
        let anchor = notchedScreen()
        XCTAssertTrue(anchor.hasNotch)
        XCTAssertEqual(anchor.cameraWidth, 200, accuracy: 0.001)
        // Kamera, ekranın yatay merkezinde olmalı.
        XCTAssertEqual(anchor.centerX, 756, accuracy: 0.001)
        XCTAssertEqual(anchor.cameraHeight, 32, accuracy: 0.001)
        XCTAssertEqual(anchor.top, 982, accuracy: 0.001)
    }

    func testExternalScreenHasNoNotch() {
        let anchor = externalScreen()
        XCTAssertFalse(anchor.hasNotch)
        XCTAssertEqual(anchor.cameraWidth, 0)
        XCTAssertFalse(anchor.attached)
    }

    func testMissingAuxiliaryAreasFallBackConservatively() {
        // Eski AppKit sürümleri auxiliary alanları sunmayabilir; kamera
        // şeridi yine de korunmalı.
        let anchor = NotchAnchor.make(
            safeTopInset: 32,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            auxiliaryLeftEdgeX: nil,
            auxiliaryRightEdgeX: nil,
            backingScale: 2
        )
        XCTAssertTrue(anchor.hasNotch)
        XCTAssertEqual(anchor.cameraWidth, NotchAnchor.fallbackCameraWidth, accuracy: 0.001)
    }

    func testInvertedAuxiliaryAreasFallBackInsteadOfNegativeWidth() {
        // Bozuk/ters ölçüm negatif genişlik üretmemeli.
        let anchor = NotchAnchor.make(
            safeTopInset: 32,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            auxiliaryLeftEdgeX: 900,
            auxiliaryRightEdgeX: 800,
            backingScale: 2
        )
        XCTAssertGreaterThan(anchor.cameraWidth, 0)
    }

    func testPixelPaddingIsTwoPhysicalPixels() {
        // Retina'da 2 fiziksel piksel = 1.0 pt.
        XCTAssertEqual(notchedScreen().pixelPadding, 1.0, accuracy: 0.001)
        XCTAssertEqual(externalScreen().pixelPadding, 2.0, accuracy: 0.001)
    }

    func testHeaderHeightNeverBelowMinimum() {
        let thin = NotchAnchor.make(
            safeTopInset: 12,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            auxiliaryLeftEdgeX: 656,
            auxiliaryRightEdgeX: 856,
            backingScale: 2
        )
        XCTAssertEqual(thin.headerHeight, NotchAnchor.minimumCameraHeight, accuracy: 0.001)
    }

    // MARK: - Yerleşim

    func testNotchPanelIsTopAnchoredToScreenEdge() {
        let anchor = notchedScreen()
        let frame = NotchLayout.panelFrame(contentHeight: 40, contentWidth: 300, anchor: anchor)
        XCTAssertEqual(frame.maxY, anchor.top, accuracy: 0.001,
                       "Kapsülün tepesi ekranın en üstüne yapışmalı")
        XCTAssertEqual(frame.midX, anchor.centerX, accuracy: 0.001,
                       "Kapsül yatayda ortalanmalı")
    }

    func testNotchPanelIsAtLeastCameraWidthPlusPadding() {
        let anchor = notchedScreen()
        let frame = NotchLayout.panelFrame(contentHeight: 40, contentWidth: 100, anchor: anchor)
        XCTAssertGreaterThanOrEqual(frame.width, anchor.cameraWidth + NotchLayout.cameraSidePadding)
        XCTAssertGreaterThanOrEqual(frame.width, NotchLayout.minimumPanelWidth)
    }

    func testNotchPanelHeightIncludesCameraHeader() {
        let anchor = notchedScreen()
        let frame = NotchLayout.panelFrame(contentHeight: 40, contentWidth: 300, anchor: anchor)
        // Yükseklik en az kamera yüksekliği + içerik olmalı.
        XCTAssertGreaterThanOrEqual(frame.height, anchor.headerHeight + 40)
    }

    func testContentFrameIsPanelLocalAndBelowCamera() {
        let anchor = notchedScreen()
        let panel = NotchLayout.panelFrame(contentHeight: 40, contentWidth: 300, anchor: anchor)
        let content = NotchLayout.contentFrame(in: panel, anchor: anchor, contentHeight: 40)
        // contentFrame pencere YEREL koordinat döner: alt kenardan başlar ve
        // panelin dışına taşmaz. Ekran-global koordinat dönerse bu kutu
        // pencerenin yüzlerce piksel dışında kalır ve metin görünmez olurdu.
        XCTAssertEqual(content.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(content.width, panel.width, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(content.origin.y, 0)
        XCTAssertLessThanOrEqual(content.maxY, panel.height + 0.001,
                                 "İçerik alanı panelin dışına taşmamalı")
    }

    func testExternalScreenPanelSitsBelowMenuBar() {
        let anchor = externalScreen()
        let frame = NotchLayout.panelFrame(contentHeight: 40, contentWidth: 300, anchor: anchor)
        XCTAssertLessThan(frame.maxY, anchor.top,
                          "Çentiksiz ekranda kapsül menü çubuğunun altında olmalı")
    }

    func testClampKeepsPanelOnScreen() {
        let anchor = notchedScreen()
        // Ekranın dışına taşan bir çerçeve kırpılmalı.
        let offscreen = CGRect(x: -500, y: 900, width: 400, height: 60)
        let clamped = NotchLayout.clampToScreen(offscreen, anchor: anchor)
        XCTAssertGreaterThanOrEqual(clamped.origin.x, 0)
        XCTAssertLessThanOrEqual(clamped.maxX, anchor.screenWidth)
    }

    func testClampHandlesPanelWiderThanScreen() {
        let anchor = externalScreen()
        // Ekrandan geniş bir kapsül çökmemeli.
        let tooWide = CGRect(x: 0, y: 0, width: anchor.screenWidth + 500, height: 60)
        let clamped = NotchLayout.clampToScreen(tooWide, anchor: anchor)
        XCTAssertGreaterThanOrEqual(clamped.origin.x, 0)
    }

    // MARK: - Animasyon eğrisi

    func testIslandTweenIsMonotonicAndClamped() {
        XCTAssertEqual(IslandTween.easeOut(0), 0, accuracy: 0.0001)
        XCTAssertEqual(IslandTween.easeOut(1), 1, accuracy: 0.0001)
        XCTAssertEqual(IslandTween.easeOut(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(IslandTween.easeOut(2), 1, accuracy: 0.0001)

        var previous = -1.0
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            let value = IslandTween.easeOut(p)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testIslandTweenEasesOutFasterThanLinear() {
        // ease-out: erken ilerleme doğrusaldan yüksek olmalı.
        XCTAssertGreaterThan(IslandTween.easeOut(0.25), 0.25)
        XCTAssertGreaterThan(IslandTween.easeOut(0.5), 0.5)
    }
}
