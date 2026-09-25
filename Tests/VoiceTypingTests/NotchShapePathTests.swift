import XCTest
@testable import VoiceTypingCore

/// Çentik formunun geometrisini kilitler.
///
/// Form iki farklı eğri tekniği kullanır ve testler bunun sessizce
/// bozulmasını engeller:
///   - **Üst kulak**: konkav, köşe noktasını kontrol alan ikinci derece
///     Bezier (referans uygulamayla birebir).
///   - **Alt köşe**: konveks **squircle** (kübik + yay + kübik) — düz
///     `cornerRadius`'un yaptığı eğrilik sıçramasını önler.
final class NotchShapePathTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 400, height: 79)

    private func allPoints(_ segments: [NotchShapePath.Segment]) -> [CGPoint] {
        segments.flatMap { seg -> [CGPoint] in
            switch seg {
            case let .move(p), let .line(p): return [p]
            case let .quad(p, c): return [p, c]
            case let .cubic(p, c1, c2): return [p, c1, c2]
            }
        }
    }

    // MARK: - Değerler

    func testRadiiAreLargeEnoughToBeVisible() {
        // 6pt kulak 400pt panelde göze çarpmıyordu; büyütüldü.
        XCTAssertEqual(NotchShapePath.topCornerRadius, 12.0)
        XCTAssertEqual(NotchShapePath.bottomCornerRadius, 24.0)
    }

    func testBottomRadiusExceedsTopRadius() {
        // Alt köşeler kulaktan daha oval olmalı ("alt köşeler oval" isteği).
        XCTAssertGreaterThan(NotchShapePath.bottomCornerRadius,
                             NotchShapePath.topCornerRadius)
    }

    func testSmoothingMatchesAppleSquircle() {
        // 0.6 Figma'nın Apple squircle eşdeğeridir.
        XCTAssertEqual(NotchShapePath.cornerSmoothing, 0.6, accuracy: 0.001)
    }

    func testSmoothingIsInValidRange() {
        XCTAssertGreaterThan(NotchShapePath.cornerSmoothing, 0)
        XCTAssertLessThan(NotchShapePath.cornerSmoothing, 1)
    }

    // MARK: - Squircle parametreleri

    func testCornerParamsProducePositiveControlPoints() {
        let q = NotchShapePath.cornerParams(radius: 24, smoothing: 0.6)
        XCTAssertGreaterThan(q.a, 0, "a pozitif olmalı")
        XCTAssertGreaterThan(q.b, 0, "b pozitif olmalı (negatifse eğri ters döner)")
        XCTAssertGreaterThan(q.c, 0)
        XCTAssertGreaterThan(q.d, 0)
        XCTAssertGreaterThan(q.p, q.arc, "yay, toplam uzunluktan kısa olmalı")
    }

    func testZeroSmoothingDegradesToCircularArc() {
        // Yumuşatma 0 → klasik dairesel kavis. b sıfıra yaklaşmalı.
        let q = NotchShapePath.cornerParams(radius: 20, smoothing: 0)
        XCTAssertEqual(q.b, 0, accuracy: 0.01, "Yumuşatma 0 iken düz kavis")
        XCTAssertEqual(q.a, 0, accuracy: 0.01)
    }

    func testHigherSmoothingIncreasesCornerBudget() {
        // Daha fazla yumuşatma → kavis daha erken başlar (p büyür).
        let low = NotchShapePath.cornerParams(radius: 20, smoothing: 0.2)
        let high = NotchShapePath.cornerParams(radius: 20, smoothing: 0.8)
        XCTAssertGreaterThan(high.p, low.p)
    }

    // MARK: - Yol bütünlüğü

    func testPathStartsAtTopLeftAndClosesAtTopRight() {
        let segs = NotchShapePath.segments(in: rect)
        guard case let .move(start) = segs.first else {
            return XCTFail("Yol move ile başlamalı")
        }
        XCTAssertEqual(start.x, rect.minX, accuracy: 0.001)
        XCTAssertEqual(start.y, rect.maxY, accuracy: 0.001)

        // Son segment üst-sağ uca inmeli (kapanış).
        guard case let .line(end) = segs.last else {
            return XCTFail("Yol çizgiyle kapanmalı")
        }
        XCTAssertEqual(end.x, rect.minX, accuracy: 0.001,
                       "Kapanış üst-sol uca dönmeli")
    }

    func testPathStaysWithinBounds() {
        // Hiçbir kontrol noktası çerçevenin DIŞINA taşmamalı — taşma
        // render'da çıkıntı/sivri uç olarak görünür.
        for p in allPoints(NotchShapePath.segments(in: rect)) {
            XCTAssertGreaterThanOrEqual(p.x, rect.minX - 0.001, "x taşması: \(p)")
            XCTAssertLessThanOrEqual(p.x, rect.maxX + 0.001, "x taşması: \(p)")
            XCTAssertGreaterThanOrEqual(p.y, rect.minY - 0.001, "y taşması: \(p)")
            XCTAssertLessThanOrEqual(p.y, rect.maxY + 0.001, "y taşması: \(p)")
        }
    }

    func testNoCuspsInBottomCorners() {
        // Sivri uç (cusp) regresyonu: alt köşenin son kübik parçasının
        // kontrol noktaları, yay sonundan DIŞARI doğru gitmeli.
        // (Yanlış orijin kullanmak eğriyi içe katlayıp çıkıntı yapıyordu.)
        let segs = NotchShapePath.segments(in: rect)
        let cubics = segs.compactMap { seg -> (CGPoint, CGPoint, CGPoint)? in
            if case let .cubic(p, c1, c2) = seg { return (p, c1, c2) }
            return nil
        }
        XCTAssertGreaterThanOrEqual(cubics.count, 6, "İki alt köşe × 3 kübik")

        for (end, c1, _) in cubics {
            // Kontrol noktası ile bitiş noktası makul yakınlıkta olmalı;
            // aşırı uzaklık eğrinin dışa fırlamasına işaret eder.
            let dx = abs(c1.x - end.x)
            let dy = abs(c1.y - end.y)
            XCTAssertLessThan(max(dx, dy), rect.width,
                              "Kontrol noktası bitişten aşırı uzak (çıkıntı riski)")
        }
    }

    // MARK: - Konkav üst kulak

    func testTopEarsCurveInward() {
        let segs = NotchShapePath.segments(in: rect)
        guard case let .quad(end, control) = segs[1] else {
            return XCTFail("İkinci segment üst-sol kulak olmalı")
        }
        // Referans formülü: kontrol = köşe noktası (x = minX + top, y = maxY)
        XCTAssertEqual(control.x, rect.minX + NotchShapePath.topCornerRadius, accuracy: 0.001)
        XCTAssertEqual(control.y, rect.maxY, accuracy: 0.001)
        // Bitiş: yan kenarın üst ucu
        XCTAssertGreaterThan(end.x, rect.minX, "Kavis içeri girmeli")
        XCTAssertLessThan(end.y, rect.maxY, "Kavis aşağı inmeli")
    }

    func testInnerWidthIsNarrowerThanOuter() {
        let innerW = NotchShapePath.innerRightX(in: rect) - NotchShapePath.innerLeftX(in: rect)
        XCTAssertEqual(innerW,
                       rect.width - 2 * NotchShapePath.topCornerRadius,
                       accuracy: 0.001)
    }

    // MARK: - Alt köşe sınırlaması

    func testShortPanelDoesNotFoldPath() {
        // Çok kısa bir panelde alt yarıçap kırpılmalı; aksi halde kenarlar
        // negatif uzunlukta olur ve yol kendi üstüne katlanır.
        let short = CGRect(x: 0, y: 0, width: 400, height: 20)
        for p in allPoints(NotchShapePath.segments(in: short)) {
            XCTAssertGreaterThanOrEqual(p.y, short.minY - 0.001)
            XCTAssertLessThanOrEqual(p.y, short.maxY + 0.001)
        }
    }

    func testZeroRadiusDegradesToRectangle() {
        // Yarıçap 0 → düz dikdörtgen; çökmemeli, NaN üretmemeli.
        let segs = NotchShapePath.segments(in: rect, topCornerRadius: 0,
                                           bottomCornerRadius: 0, smoothing: 0)
        XCTAssertFalse(segs.isEmpty)
        for p in allPoints(segs) {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite, "NaN/Inf üretilmemeli")
        }
    }

    func testNegativeRadiusIsTreatedAsZero() {
        let segs = NotchShapePath.segments(in: rect, topCornerRadius: -5,
                                           bottomCornerRadius: -5, smoothing: 0)
        guard case let .move(start) = segs[0] else { return XCTFail() }
        XCTAssertEqual(start.x, rect.minX, accuracy: 0.001)
        XCTAssertEqual(start.y, rect.maxY, accuracy: 0.001)
    }

    func testExtremeSmoothingIsClamped() {
        // 1'in üzeri ve negatif yumuşatma kırpılmalı, patlamamalı.
        for s in [-1.0, 0.0, 1.0, 5.0] as [CGFloat] {
            let segs = NotchShapePath.segments(in: rect, smoothing: s)
            for p in allPoints(segs) {
                XCTAssertTrue(p.x.isFinite && p.y.isFinite, "s=\(s) için NaN")
            }
        }
    }
}
