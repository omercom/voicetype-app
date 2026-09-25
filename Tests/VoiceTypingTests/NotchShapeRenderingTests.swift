import XCTest
import AppKit
@testable import VoiceTypingCore

/// Çentik formunun GERÇEKTEN çizildiğini piksel düzeyinde doğrular.
///
/// Neden gerekli: geometri testleri yolun doğru üretildiğini kanıtlar ama
/// ekrana bir şey çıkıp çıkmadığını kanıtlamaz. Bu test görünümü gerçekten
/// render edip dolgu piksellerini inceler.
///
/// DİKKAT: geri tampon Retina'da 2x'tir; tüm örnekleme NOKTA koordinatıyla
/// yapılır ve piksele çevrilir (bkz. `isFilled`).
final class NotchShapeRenderingTests: XCTestCase {

    private let size = NSSize(width: 400, height: 76)

    private func render(size: NSSize, hidden: Bool = false) -> NSBitmapImageRep {
        let view = NotchShapeView(frame: NSRect(origin: .zero, size: size))
        view.fillColor = NSColor(calibratedWhite: 0.0, alpha: 1.0)
        view.isHidden = hidden
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("bitmap olusturulamadi")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Pikselin gerçekten DOLGU ile boyanıp boyanmadığı (bkz. sınıf notu).
    private func isFilled(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, size: NSSize) -> Bool {
        let sx = CGFloat(rep.pixelsWide) / size.width
        let sy = CGFloat(rep.pixelsHigh) / size.height
        let px = Int((x * sx).rounded())
        let py = Int((y * sy).rounded())
        guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh else { return false }
        guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { return false }
        return c.alphaComponent > 0.5 && c.brightnessComponent < 0.15
    }

    private func filled(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> Bool {
        isFilled(rep, x: x, y: y, size: size)
    }

    func testShapeViewDrawsFilledPixels() {
        let rep = render(size: size)
        XCTAssertTrue(filled(rep, size.width / 2, size.height / 2),
                      "Ada merkezi dolgu rengiyle boyanmalı")
    }

    func testTopCornerEarsAreConcave() {
        // Konkav kulak: en üst satırda köşe pikselleri BOŞ olmalı, çünkü
        // kavis içe doğru başlar. (AppKit: y büyüdükçe yukarı.)
        let rep = render(size: size)
        let topY = size.height - 1.5

        XCTAssertFalse(filled(rep, 1, topY), "Üst-sol kulak içe kavisli olmalı")
        XCTAssertFalse(filled(rep, size.width - 1, topY), "Üst-sağ kulak içe kavisli olmalı")
        XCTAssertTrue(filled(rep, size.width / 2, topY), "Üst kenarın ortası dolu olmalı")
    }

    func testBottomCornersAreRounded() {
        // Konveks alt köşe: en alt satırda köşe pikselleri BOŞ olmalı.
        // DİKKAT: squircle köşesi + yumuşatma, kavisi alt kenar boyunca
        // ~(1+s)·r kadar yayar. Bu yüzden köşe örneklemesi kenardan uzakta
        // değil, gerçek köşe bölgesinde yapılır.
        let rep = render(size: size)
        let spread = (1 + NotchShapePath.cornerSmoothing) * NotchShapePath.bottomCornerRadius

        XCTAssertFalse(filled(rep, 1, 1), "Alt-sol köşe yuvarlak olmalı")
        XCTAssertFalse(filled(rep, size.width - 1, 1), "Alt-sağ köşe yuvarlak olmalı")
        // Alt kenarın ortası dolu olmalı (kavislerin arasında kalan düz kısım).
        XCTAssertTrue(filled(rep, size.width / 2, 1), "Alt kenarın ortası dolu olmalı")
        // Kavisin bittiği yerin içi dolu, panel köşesi boş olmalı.
        XCTAssertGreaterThan(spread, 0)
        XCTAssertTrue(filled(rep, spread + 4, 1), "Kavis sonrası alt kenar dolu olmalı")
    }

    func testShapeIsNotUniformRectangle() {
        // Düz dikdörtgen OLMA MAMALI: dört köşe boş, kenar ortaları dolu.
        // Bu, gerçek çentik formunun ayırt edici imzası.
        let rep = render(size: size)
        let w = size.width
        let h = size.height

        XCTAssertFalse(filled(rep, 1, h - 1.5), "Üst-sol boş olmalı")
        XCTAssertFalse(filled(rep, w - 1, h - 1.5), "Üst-sağ boş olmalı")
        XCTAssertFalse(filled(rep, 1, 1), "Alt-sol boş olmalı")
        XCTAssertFalse(filled(rep, w - 1, 1), "Alt-sağ boş olmalı")

        XCTAssertTrue(filled(rep, w / 2, h - 1.5), "Üst kenar ortası dolu")
        XCTAssertTrue(filled(rep, w / 2, 1), "Alt kenar ortası dolu")
        // Yan kenarlar: üst kulak 6pt içe kavisli olduğu için düz kenar
        // x = minX + 6'dadır, panel kenarında DEĞİL. Bu, konkav kulağın
        // doğrudan sonucudur.
        let inset = NotchShapePath.topCornerRadius
        XCTAssertTrue(filled(rep, inset + 1, h / 2), "Sol kenar kulak payı kadar içeride")
        XCTAssertTrue(filled(rep, w - inset - 1, h / 2), "Sağ kenar kulak payı kadar içeride")
    }

    func testSideEdgesAreInsetByTopRadius() {
        // Konkav kulağın ölçülebilir kanıtı: gövde, üst kenardan 6pt dardır.
        let rep = render(size: size)
        let w = size.width
        let midY = size.height / 2
        XCTAssertFalse(filled(rep, 0.5, midY),
                       "Panel kenarı boş olmalı — gövde kulağın kadar daralmış")
        XCTAssertTrue(filled(rep, NotchShapePath.topCornerRadius + 1, midY),
                      "Gövde kenarı dolu olmalı")
        XCTAssertFalse(filled(rep, w - 0.5, midY),
                       "Sağ panel kenarı boş olmalı")
        XCTAssertTrue(filled(rep, w - NotchShapePath.topCornerRadius - 1, midY),
                      "Sağ gövde kenarı dolu olmalı")
    }

    func testTransparentFillPaintsNothing() {
        // Dolgu saydamsa hiçbir piksel boyanmamalı. (Not: `isHidden` bu
        // yolla test EDİLEMEZ — `cacheDisplay` gizli görünümü de çizer.
        // Gizleme HUD'un kablolama sorumluluğudur.)
        let view = NotchShapeView(frame: NSRect(origin: .zero, size: size))
        view.fillColor = .clear
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("bitmap olusturulamadi")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertFalse(filled(rep, size.width / 2, size.height / 2),
                       "Saydam dolgu boya bırakmamalı")
    }

    func testPillSizedFrameStillRenders() {
        // Küçük (kapsül boyutlu) çerçevede de çökmemeli ve boyamalı.
        let small = NSSize(width: 152, height: 34)
        let rep = render(size: small)
        XCTAssertTrue(isFilled(rep, x: small.width / 2, y: small.height / 2, size: small),
                      "Küçük çerçevede de dolgu olmalı")
    }

    func testRetinaScaleIsAccountedFor() {
        // Regresyon: geri tampon 2x ise nokta→piksel dönüşümü şart.
        // Sağ taraftaki gövde kenarının doğru örneklenmesi bunu kanıtlar;
        // ölçek yok sayılırsa sağ taraf yanlış piksele düşer.
        let rep = render(size: size)
        XCTAssertGreaterThan(rep.pixelsWide, Int(size.width),
                             "Retina'da bitmap nokta sayısından büyük olmalı")
        let bodyRight = size.width - NotchShapePath.topCornerRadius - 1
        XCTAssertTrue(filled(rep, bodyRight, size.height / 2),
                      "Sağ gövde kenarı ölçekten bağımsız örneklenmeli")
    }
}
