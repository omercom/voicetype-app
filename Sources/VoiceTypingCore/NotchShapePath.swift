import Foundation
import CoreGraphics

/// Çentik (Dynamic Island) formunun saf geometrisi.
///
/// ## Neden "düz yuvarlak dikdörtgen" gibi görünüyordu?
///
/// Basit yuvarlatma (`CALayer.cornerRadius`) düz kenardan kavise geçerken
/// **eğrilik sıçraması** yapar. İnsan gözü bunu "sert / yapıştırılmış kutu"
/// olarak algılar. Apple'ın formu (squircle) eğriliği kademeli değiştirir —
/// fark tam olarak kullanıcının işaret ettiği **kenar yumuşatması**dır.
///
/// ## Değerler
///
/// | öğe | değer | kaynak |
/// |---|---|---|
/// | üst kulak (konkav) | 12pt | Boring Notch `topCornerRadius`; 6pt görünmüyordu |
/// | alt köşe (konveks) | 24pt | kullanıcı isteği: "alt köşeler oval" |
/// | köşe yumuşatma | 0.6 | Figma corner smoothing ≈ Apple squircle |
///
/// **Üst kulak** referansla birebir aynıdır: köşe noktasını kontrol noktası
/// alan ikinci derece Bezier. Bu, kulak ucunda yatay, yan kenarda dikey
/// teğet verir — yani her iki kenara da yumuşak bağlanır.
///
/// **Alt köşeler** squircle eğrisiyle çizilir (kübik + yay + kübik).
/// Formül `figma-squircle` implementasyonundan uyarlanmıştır.
public enum NotchShapePath {

    /// Üst kulak yarıçapı — konkav (ekrana birleşen içe kavis).
    public static let topCornerRadius: CGFloat = 12.0

    /// Alt köşe yarıçapı — konveks (dışa doğru oval).
    public static let bottomCornerRadius: CGFloat = 24.0

    /// Köşe yumuşatma oranı (0...1).
    ///
    /// - `0` → düz dairesel kavis (klasik `cornerRadius`)
    /// - `0.6` → Apple squircle'ına en yakın değer
    public static let cornerSmoothing: CGFloat = 0.6

    /// Yol parçası (AppKit koordinatı, sol-alt orijin).
    public enum Segment: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        /// İkinci derece Bezier (tek kontrol noktası).
        case quad(to: CGPoint, control: CGPoint)
        /// Üçüncü derece Bezier (iki kontrol noktası) — yumuşak squircle kavisi.
        case cubic(to: CGPoint, c1: CGPoint, c2: CGPoint)
    }

    // MARK: - Squircle parametreleri

    /// Bir köşenin squircle parametreleri
    /// (figma-squircle `getPathParamsForCorner`).
    struct CornerParams: Equatable {
        let a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat
        /// Kavise girmeden önce düz kenarda tüketilen uzunluk.
        let p: CGFloat
        /// Dairesel yay bölümünün uzunluğu.
        let arc: CGFloat
    }

    /// `radius` yarıçaplı, `smoothing` oranlı köşe parametreleri.
    static func cornerParams(radius r: CGFloat, smoothing s: CGFloat) -> CornerParams {
        let p = (1 + s) * r
        let arcMeasure = 90 * (1 - s)                       // derece
        let arc = sin(arcMeasure / 2 * .pi / 180) * r * sqrt(2)
        let angleAlpha = (90 - arcMeasure) / 2
        let p3ToP4 = r * tan(angleAlpha / 2 * .pi / 180)
        let angleBeta = 45 * s
        let c = p3ToP4 * cos(angleBeta * .pi / 180)
        let d = c * tan(angleBeta * .pi / 180)
        let b = (p - arc - c - d) / 3
        return CornerParams(a: 2 * b, b: b, c: c, d: d, p: p, arc: arc)
    }

    /// Konveks (dışa dönük) yumuşak köşe.
    ///
    /// - `A`: giriş noktası (gelen kenarın sonu)
    /// - `dIn`: `A`'dan köşe kesişimine doğru birim yön
    /// - `dOut`: köşe kesişiminden çıkış yönü
    ///
    /// `A`dan başlar, `A + p*(dIn + dOut)` noktasında biter. Kübik + yay +
    /// kübik olmak üzere **üç parça** üretir. Teğetler `A`da `dIn`,
    /// bitişte `dOut` yönündedir → her iki kenara yumuşak bağlanır.
    static func convexCorner(
        A: CGPoint, dIn: CGPoint, dOut: CGPoint,
        radius r: CGFloat, smoothing s: CGFloat
    ) -> [Segment] {
        let q = cornerParams(radius: r, smoothing: s)
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: A.x + u * dIn.x + v * dOut.x,
                    y: A.y + u * dIn.y + v * dOut.y)
        }

        // Yay bölümünün uç noktası (u,v cinsinden).
        let p2u = q.a + q.b + q.c + q.arc
        let p2v = q.d + q.arc

        let p1 = pt(q.a + q.b + q.c, q.d)
        let p2 = pt(p2u, p2v)

        // ÜÇÜNCÜ kübik p2'DEN başlar: kontrol noktaları p2'ye GÖRELİDİR.
        // (A'ya göre hesaplamak eğriyi dışa şişirip çıkıntı yapıyordu.)
        let c1 = pt(p2u + q.d, p2v + q.c)
        let c2 = pt(p2u + q.d, p2v + q.b + q.c)
        let end = pt(p2u + q.d, p2v + q.a + q.b + q.c)

        // Yayı kübikle temsil et: κ = (4/3)·tan(θ/4), θ = 90°·(1-s).
        let kappa = (4.0 / 3.0) * tan((1 - s) * .pi / 8)
        let arcC1 = CGPoint(x: p1.x + kappa * r * dIn.x, y: p1.y + kappa * r * dIn.y)
        let arcC2 = CGPoint(x: p2.x - kappa * r * dOut.x, y: p2.y - kappa * r * dOut.y)

        return [
            .cubic(to: p1, c1: pt(q.a, 0), c2: pt(q.a + q.b, 0)),
            .cubic(to: p2, c1: arcC1, c2: arcC2),
            .cubic(to: end, c1: c1, c2: c2),
        ]
    }

    /// Konkav (içe dönük) "kulak" — referansın birebir formülü.
    ///
    /// Uç `T`den başlar, köşe noktası `C`yi **kontrol noktası** alarak `S`de
    /// biter. Bu sayede uçta teğet yatay, yan kenarda dikey olur → iki
    /// kenara da yumuşak bağlanır. (Kontrol noktasını yanlış tarafa koymak
    /// yön tersine dönmesine ve sivri bir çıkıntı oluşmasına yol açıyordu.)
    static func concaveEar(tip T: CGPoint, corner C: CGPoint, side S: CGPoint) -> [Segment] {
        [.quad(to: S, control: C)]
    }

    // MARK: - Yol

    /// Çentik formunun çizim yolu.
    ///
    /// Koordinat sistemi **AppKit**'tir: `rect.maxY` ekranın tepesidir.
    /// Sıra: üst-sol uç → sol kulak → sol kenar → alt-sol oval → alt kenar
    /// → alt-sağ oval → sağ kenar → sağ kulak → üst kenar (kapanış).
    public static func segments(
        in rect: CGRect,
        topCornerRadius: CGFloat = NotchShapePath.topCornerRadius,
        bottomCornerRadius: CGFloat = NotchShapePath.bottomCornerRadius,
        smoothing: CGFloat = NotchShapePath.cornerSmoothing
    ) -> [Segment] {
        let limit = min(rect.width, rect.height) / 2
        let top = max(0, min(topCornerRadius, limit))
        let s = max(0, min(smoothing, 1))

        // Alt köşe yarıçapı: hem yatay hem dikey sınırlara sığmalı.
        // Aksi halde kenarlar negatif uzunlukta olur ve yol kendi üstüne katlanır.
        let verticalBudget = max(0, (rect.height - top) * 0.6)
        let botLimit = min(limit, verticalBudget / (1 + s))
        let bot = max(0, min(bottomCornerRadius, botLimit))

        let left = rect.minX
        let right = rect.maxX
        let bottom = rect.minY
        let topY = rect.maxY

        let bp = (1 + s) * bot                     // alt köşenin kenarda tükettiği boy
        let leftX = left + top                     // yan kenarların x'i (kulak payı)
        let rightX = right - top

        var out: [Segment] = []

        // Yol üst-sol uçtan BAŞLAMALI (move). Aksi halde ilk eğri orijinden
        // başlayıp istenmeyen bir çizgi çizer.
        let tipL = CGPoint(x: left, y: topY)
        out.append(.move(tipL))

        // Üst-sol uç → (köşe noktası kontrolüyle) sol kulağın yan ucuna
        let cornerL = CGPoint(x: leftX, y: topY)
        let sideL = CGPoint(x: leftX, y: topY - top)
        out.append(contentsOf: concaveEar(tip: tipL, corner: cornerL, side: sideL))

        if bot > 0 {
            // Sol kenar aşağı, alt-sol ovalin başlangıcına kadar
            out.append(.line(CGPoint(x: leftX, y: bottom + bp)))
            // Alt-sol oval: aşağı gelir, sağa çıkar
            out.append(contentsOf: convexCorner(
                A: CGPoint(x: leftX, y: bottom + bp),
                dIn: CGPoint(x: 0, y: -1),
                dOut: CGPoint(x: 1, y: 0),
                radius: bot, smoothing: s))

            // Alt kenar
            out.append(.line(CGPoint(x: rightX - bp, y: bottom)))

            // Alt-sağ oval: sağa gelir, yukarı çıkar
            out.append(contentsOf: convexCorner(
                A: CGPoint(x: rightX - bp, y: bottom),
                dIn: CGPoint(x: 1, y: 0),
                dOut: CGPoint(x: 0, y: 1),
                radius: bot, smoothing: s))
        } else {
            // Yarıçap 0 → keskin köşe
            out.append(.line(CGPoint(x: leftX, y: bottom)))
            out.append(.line(CGPoint(x: rightX, y: bottom)))
        }

        // Sağ kenar yukarı, sağ kulağın YAN ucuna kadar
        out.append(.line(CGPoint(x: rightX, y: topY - top)))

        // Sağ kulak: yan uçtan (388,64) üst-sağ uca (400,76).
        //
        // DİKKAT: yol sağ tarafta AŞAĞIDAN YUKARI ilerler, bu yüzden kulak
        // soldakinin ters yönünde çizilir. Argümanları sol ile aynı sırada
        // vermek yolu geri katlar ve üst kenarı eğik gösterir.
        let sideR = CGPoint(x: rightX, y: topY - top)
        let cornerR = CGPoint(x: rightX, y: topY)
        let tipR = CGPoint(x: right, y: topY)
        out.append(contentsOf: concaveEar(tip: sideR, corner: cornerR, side: tipR))

        // Üst kenar (kapanış): üst-sağ uçtan üst-sol uca
        out.append(.line(tipL))

        return out
    }

    /// Formun en dar yerinin sol x'i (üst kulakların içeri girdiği nokta).
    public static func innerLeftX(in rect: CGRect, topCornerRadius: CGFloat = NotchShapePath.topCornerRadius) -> CGFloat {
        rect.minX + max(0, min(topCornerRadius, min(rect.width, rect.height) / 2))
    }

    /// Formun en dar yerinin sağ x'i.
    public static func innerRightX(in rect: CGRect, topCornerRadius: CGFloat = NotchShapePath.topCornerRadius) -> CGFloat {
        rect.maxX - max(0, min(topCornerRadius, min(rect.width, rect.height) / 2))
    }
}
