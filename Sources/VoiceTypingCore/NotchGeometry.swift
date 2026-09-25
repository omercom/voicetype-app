import Foundation
import CoreGraphics

/// Çentikli ekranın (MacBook kamera yuvası) geometrisi.
///
/// Neden gerekli: `NSScreen.visibleFrame` kamera şeridini tamamen dışarıda
/// bırakır, dolayısıyla çentiğe yapışan bir kapsülün nereye oturacağını
/// tarif edemez. Gerçek kamera genişliği yalnızca
/// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` ile ölçülebilir.
/// Bu katman o ölçümü AppKit'ten bağımsız, saf ve test edilebilir tutar
/// (AlwaysWhisper'ın `_island_anchor` mantığından uyarlanmıştır).
public struct NotchAnchor: Equatable {
    /// Kameranın yatay merkezi (ekran koordinatı, sol-alt orijin).
    public let centerX: CGFloat
    /// Ekranın üst kenarı (çentiğin tepesi).
    public let top: CGFloat
    /// Kameranın fiziksel genişliği. 0 ise çentik yok.
    public let cameraWidth: CGFloat
    /// Kameranın fiziksel yüksekliği (= güvenli üst iç boşluk). 0 ise çentik yok.
    public let cameraHeight: CGFloat
    public let screenWidth: CGFloat
    /// Retina ölçek çarpanı (1.0 / 2.0).
    public let scale: CGFloat

    /// Eski AppKit sürümlerinde auxiliary alanlar yoksa kamerayı korumak için
    /// ayrılan ihtiyatlı genişlik (AlwaysWhisper ile aynı).
    public static let fallbackCameraWidth: CGFloat = 220.0

    /// Menü çubuğu varken çentikli ekranda gereken en küçük kamera yüksekliği.
    public static let minimumCameraHeight: CGFloat = 32.0

    /// Çentik var mı (kamera yüksekliği ölçülebildi mi).
    public var hasNotch: Bool { cameraHeight > 0 }

    /// Kapsülün çentikle birleşik mi görüneceği.
    public var attached: Bool { hasNotch }

    /// Kapsül başlık alanının yüksekliği: metin kameranın ALTINDA başlar.
    public var headerHeight: CGFloat { max(Self.minimumCameraHeight, cameraHeight) }

    /// İstenen dikey iç boşluğu tam 2 fiziksel piksele denk getirir.
    /// Nokta uzayında çalıştığımız için ölçekle bölüyoruz (Retina'da 1.0 pt).
    public var pixelPadding: CGFloat { 2.0 / max(1.0, scale) }

    /// Bir ekranın ölçümlerinden çapa üretir.
    ///
    /// - Parameters:
    ///   - safeTopInset: `NSScreen.safeAreaInsets.top` (çentik yüksekliği).
    ///   - screenFrame: `NSScreen.frame`.
    ///   - auxiliaryLeftEdgeX: Sol `auxiliaryTopLeftArea`'nın **sağ** kenarının
    ///     mutlak x'i (`origin.x + width`), yoksa nil.
    ///   - auxiliaryRightEdgeX: Sağ `auxiliaryTopRightArea`'nın **sol** kenarının
    ///     mutlak x'i (`origin.x`), yoksa nil.
    ///   - backingScale: `backingScaleFactor`.
    ///
    /// Değerler mutlak ekran koordinatıdır; böylece harici monitör birincilken
    /// çentikli ekran kaydırılmış olsa bile ada doğru yere oturur.
    public static func make(
        safeTopInset: CGFloat,
        screenFrame: CGRect,
        auxiliaryLeftEdgeX: CGFloat?,
        auxiliaryRightEdgeX: CGFloat?,
        backingScale: CGFloat
    ) -> NotchAnchor {
        let height = max(0, safeTopInset)
        var resolvedCenter = screenFrame.origin.x + screenFrame.size.width / 2
        var width: CGFloat = 0

        if height > 0 {
            if let x0 = auxiliaryLeftEdgeX,
               let x1 = auxiliaryRightEdgeX,
               x1 > x0 {
                width = x1 - x0
                resolvedCenter = (x0 + x1) / 2
            } else {
                // Eski AppKit sürümleri auxiliary alanları sunmayabilir;
                // kamera şeridini ihtiyatlı biçimde koru.
                width = fallbackCameraWidth
            }
        }

        return NotchAnchor(
            centerX: resolvedCenter,
            top: screenFrame.origin.y + screenFrame.size.height,
            cameraWidth: width,
            cameraHeight: height,
            screenWidth: screenFrame.size.width,
            scale: max(1.0, backingScale)
        )
    }
}

/// Çentik modunda kapsülün yerleşimi.
public enum NotchLayout {

    /// Kapsülün metin alanı için gereken en küçük genişlik.
    public static let minimumPanelWidth: CGFloat = 400.0

    /// Kameranın iki yanında bırakılacak toplam pay.
    public static let cameraSidePadding: CGFloat = 160.0

    /// Çentiksiz ekranda kapsülün üst kenardan aşağı kaydırılması.
    public static let menuBarOffset: CGFloat = 8.0

    /// Çentik modunda kapsülün çerçevesini hesaplar.
    ///
    /// Dönen `CGRect` sol-alt orijinli AppKit koordinatındadır ve kapsülün
    /// **tepesi ekranın en üstüne yapışıktır** — çentikle tek parça görünür.
    ///
    /// - Parameters:
    ///   - contentHeight: Metin satırlarının toplam yüksekliği.
    ///   - anchor: Ekranın çentik ölçümü.
    ///   - contentWidth: Metnin doğal genişliği (kapsül buna göre büyür).
    public static func panelFrame(
        contentHeight: CGFloat,
        contentWidth: CGFloat,
        anchor: NotchAnchor
    ) -> CGRect {
        guard anchor.hasNotch else {
            // Çentik yok: menü çubuğunun hemen altına, üstten hizalı yerleştir.
            let width = max(minimumPanelWidth, contentWidth)
            let visibleTop = anchor.top - anchor.headerHeight - menuBarOffset
            return CGRect(
                x: anchor.centerX - width / 2,
                y: visibleTop - contentHeight,
                width: width,
                height: contentHeight
            )
        }

        // Çentikli: kamera genişliğini her iki yandan payla birlikte kapsa.
        let width = max(
            minimumPanelWidth,
            anchor.cameraWidth + cameraSidePadding,
            contentWidth
        )
        let totalHeight = anchor.headerHeight + contentHeight + anchor.pixelPadding
        return CGRect(
            x: anchor.centerX - width / 2,
            y: anchor.top - totalHeight,
            width: width,
            height: totalHeight
        )
    }

    /// Kapsülün metin alanının (pencere içi/panel-local) çerçevesini döner.
    public static func contentFrame(
        in panelFrame: CGRect,
        anchor: NotchAnchor,
        contentHeight: CGFloat
    ) -> CGRect {
        // Panel-local koordinat: x=0, y=alt kenardan içerik yüksekliği kadar
        return CGRect(
            x: 0,
            y: anchor.pixelPadding,
            width: panelFrame.width,
            height: contentHeight
        )
    }

    /// Ekran dışına taşmayı engeller.
    public static func clampToScreen(_ frame: CGRect, anchor: NotchAnchor) -> CGRect {
        let margin: CGFloat = 16.0
        var result = frame
        let minX = margin
        let maxX = max(margin, anchor.screenWidth - margin - frame.width)
        if result.origin.x < minX { result.origin.x = minX }
        if result.origin.x > maxX { result.origin.x = maxX }
        return result
    }
}

/// Çentik morph animasyonu için tekdüze (monotone) yumuşatma.
public enum IslandTween {
    /// `1 - (1-p)^3` — hızlı başlar, yumuşak oturur. AlwaysWhisper'ın
    /// `_island_tween` eğrisiyle aynı; üst/merkez noktası sabit kalır.
    public static func easeOut(_ progress: Double) -> Double {
        let p = min(1.0, max(0.0, progress))
        return 1 - pow(1 - p, 3)
    }
}
