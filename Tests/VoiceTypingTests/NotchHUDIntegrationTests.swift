import XCTest
import AppKit
@testable import VoiceTypingCore

/// Çentik formunun GERÇEK `RecordingHUD` içinde kablolandığını doğrular.
///
/// Diğer testler formu tek başına çizer; bu dosya üretim yolunu sürer:
/// kayıt başlat → çentik moduna geç → şekil görünümü gerçekten ekli,
/// görünür ve doğru boyutta mı?
///
/// Bu testlerin varlık sebebi: kullanıcı "hiçbir değişiklik fark etmedim"
/// dedi. Form doğru çizilse bile HUD'a bağlanmamışsa ekranda görünmez.
final class NotchHUDIntegrationTests: XCTestCase {

    private func notchShapeViews(in view: NSView) -> [NotchShapeView] {
        var found: [NotchShapeView] = []
        if let shape = view as? NotchShapeView { found.append(shape) }
        for sub in view.subviews { found.append(contentsOf: notchShapeViews(in: sub)) }
        return found
    }

    /// Testi çentik modunda çalıştırır ve config'i geri alır.
    private func withNotchMode(_ body: (RecordingHUD) -> Void) {
        let original = ConfigManager.shared.config.hud_style
        ConfigManager.shared.update { $0.hud_style = "notch" }
        defer { ConfigManager.shared.update { $0.hud_style = original } }

        let hud = RecordingHUD.shared
        hud.dismiss(animated: false)
        hud.showRecording()
        hud.finishPresentationTransitions()
        body(hud)
        hud.dismiss(animated: false)
    }

    func testNotchShapeViewExistsInHUDHierarchy() {
        withNotchMode { hud in
            guard let root = hud.rootContentView else {
                return XCTFail("contentView bulunamadi")
            }
            XCTAssertGreaterThan(notchShapeViews(in: root).count, 0,
                                 "HUD içinde bir NotchShapeView bulunmalı")
        }
    }

    func testNotchShapeViewIsVisibleWhileRecordingInNotchMode() {
        withNotchMode { hud in
            guard let root = hud.rootContentView,
                  let shape = notchShapeViews(in: root).first else {
                return XCTFail("NotchShapeView bulunamadi")
            }
            XCTAssertFalse(shape.isHidden,
                           "Çentik modunda kayıt sırasında şekil GÖRÜNÜR olmalı")
        }
    }

    func testNotchShapeViewFillsContentView() {
        withNotchMode { hud in
            guard let root = hud.rootContentView,
                  let shape = notchShapeViews(in: root).first else {
                return XCTFail("NotchShapeView bulunamadi")
            }
            // Şekil tüm içerik alanını kaplamalı; aksi halde ada yarım çizilir.
            XCTAssertEqual(shape.frame.width, root.bounds.width, accuracy: 1.0,
                           "Şekil genişliği içerik alanına eşit olmalı")
            XCTAssertEqual(shape.frame.height, root.bounds.height, accuracy: 1.0,
                           "Şekil yüksekliği içerik alanına eşit olmalı")
        }
    }

    func testNotchShapeIsDrawnBehindTextAndMeter() {
        withNotchMode { hud in
            guard let root = hud.rootContentView,
                  let shape = notchShapeViews(in: root).first,
                  let shapeIndex = root.subviews.firstIndex(of: shape) else {
                return XCTFail("NotchShapeView bulunamadi")
            }
            // Gerçek invariant: şekil METNİN ve EKOLAYZIRIN ALTINDA olmalı,
            // yoksa siyah dolgu onları örter. En altta olması gerekmez —
            // gizlenmiş katmanlar altında kalabilir.
            let texts = root.subviews.enumerated()
                .filter { $0.element is NSTextField }
                .map(\.offset)
            let meters = root.subviews.enumerated()
                .filter { $0.element is NotchShapeView == false && $0.element.subviews.contains { $0 is NSView } && $0.element.frame.width == NotchAudioMeter.meterSize }
                .map(\.offset)

            for textIndex in texts {
                XCTAssertLessThan(shapeIndex, textIndex,
                                  "Şekil metnin altında çizilmeli (index \(shapeIndex) < \(textIndex))")
            }
            for meterIndex in meters {
                XCTAssertLessThan(shapeIndex, meterIndex,
                                  "Şekil ekolayzırın altında çizilmeli")
            }
        }
    }

    func testPillModeHidesNotchShape() {
        let original = ConfigManager.shared.config.hud_style
        ConfigManager.shared.update { $0.hud_style = "pill" }
        defer { ConfigManager.shared.update { $0.hud_style = original } }

        let hud = RecordingHUD.shared
        hud.dismiss(animated: false)
        hud.showRecording()
        hud.finishPresentationTransitions()

        if let root = hud.rootContentView,
           let shape = notchShapeViews(in: root).first {
            XCTAssertTrue(shape.isHidden,
                          "Kapsül modunda ada formu gizli olmalı")
        }
        hud.dismiss(animated: false)
    }

    func testPanelBackgroundIsTransparentSoShapeShows() {
        withNotchMode { hud in
            // Panel arka planı opak olsaydı şeklin köşeleri görünmezdi:
            // ekranda dikdörtgen bir kutu çizilirdi.
            XCTAssertLessThanOrEqual(hud.panelBackgroundColor.alphaComponent, 0.01,
                                     "Çentik modunda panel arka planı saydam olmalı")
        }
    }

    func testPanelIsOnScreenAndAtTopInNotchMode() {
        // Son doğrulanmamış halka: form doğru çizilse bile panel EKRAN
        // DIŞINDA ya da yanlış konumda olursa kullanıcı hiçbir şey görmez.
        withNotchMode { hud in
            guard let panel = hud.rootContentView?.window as? NSPanel else {
                return XCTFail("Panel bulunamadi")
            }
            let frame = panel.frame
            XCTAssertTrue(frame.width > 0 && frame.height > 0,
                          "Panel sıfır boyutlu olmamalı (frame: \(frame))")

            // Bir ekranla kesişmeli.
            let intersects = NSScreen.screens.contains { $0.frame.intersects(frame) }
            XCTAssertTrue(intersects,
                          "Panel bir ekranla kesişmeli (frame: \(frame))")

            // Çentik modunda ekranın TEPESİNE yapışmalı.
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
                XCTAssertEqual(frame.maxY, screen.frame.maxY, accuracy: 2.0,
                               "Ada ekranın tepesine yapışmalı (panel maxY: \(frame.maxY), ekran: \(screen.frame.maxY))")
            }
        }
    }
}
