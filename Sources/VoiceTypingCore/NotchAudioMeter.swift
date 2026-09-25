import Foundation
import CoreGraphics

/// Çentik (Dynamic Island) ekolayzırının saf matematiği.
///
/// AlwaysWhisper referansındaki `AudioLevelMeter` ve `_audio_bar_rects`
/// davranışının birebir Swift karşılığıdır. AppKit'ten bağımsızdır; bu
/// sayede ses seviyesi → çubuk geometrisi dönüşümü birim testleriyle
/// kilitlenebilir ve referans ölçüleri sessizce kaymaz.
public enum NotchAudioMeter {

    /// Göstergenin kapsayıcı boyutu (pt). Referans `_make_audio_meter_view`.
    public static let meterSize: CGFloat = 20.0

    /// Çubuk ağırlıkları: ortada en uzun, kenarlara doğru simetrik kısalır.
    /// Referans: `(.45, .75, 1.0, .75, .45)`.
    public static let barWeights: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]

    /// Sessizlikte bile görünen taban çubuk yüksekliği. Referans: `2`.
    public static let minimumBarHeight: CGFloat = 2.0

    /// Bu seviyenin üstünde gösterge "aktif" sayılır (yeşil). Referans `.02`.
    public static let activeThreshold: CGFloat = 0.02

    /// Seviye yumuşatma zaman sabitleri (saniye). Referans `AudioLevelMeter`:
    /// yükselirken hızlı (`.035`), düşerken yumuşak (`.18`).
    public static let attackTau: Double = 0.035
    public static let releaseTau: Double = 0.18

    /// Bu seviyenin altı sıfıra oturtulur (referans `.005`).
    public static let zeroSnapThreshold: CGFloat = 0.005

    /// Çubuk genişliği: kutu genişliğinin onda biri. Referans `width / 10`.
    public static var barWidth: CGFloat { meterSize / 10.0 }

    /// Çubuklar arası boşluk; toplam genişlik kutuya tam oturur.
    public static var barSpacing: CGFloat {
        let count = CGFloat(barWeights.count)
        return (meterSize - count * barWidth) / (count - 1)
    }

    /// Çubukların yatay konumları (kapsayıcı yerel koordinatı).
    public static func barOriginsX() -> [CGFloat] {
        (0..<barWeights.count).map { CGFloat($0) * (barWidth + barSpacing) }
    }

    /// Tek bir çubuğun yüksekliği: `2 + (kutu-2) * level * ağırlık`.
    /// Referans `_audio_bar_rects` ile aynı formül.
    public static func barHeight(level: CGFloat, weight: CGFloat) -> CGFloat {
        let clampedLevel = max(0.0, min(1.0, level))
        let raw = minimumBarHeight + (meterSize - minimumBarHeight) * clampedLevel * weight
        return max(minimumBarHeight, min(meterSize, raw))
    }

    /// Çubuğun dikey konumu: merkezden simetrik büyüme.
    /// Referans: `y = (height - h) / 2`.
    public static func barOriginY(height: CGFloat) -> CGFloat {
        (meterSize - height) / 2.0
    }

    /// Zaman-tabanlı üstel yumuşatma; referans `AudioLevelMeter.update`.
    ///
    /// Kare hızından bağımsızdır: `dt` ne olursa olsun aynı fiziksel
    /// yanıtı verir. Referans da tam olarak bunu yapar.
    ///
    /// - Parameters:
    ///   - level: Önceki yumuşatılmış seviye.
    ///   - target: Hedef seviye (0...1).
    ///   - dt: Geçen süre (saniye). Negatif değerler 0 kabul edilir.
    public static func smooth(level: CGFloat, target: CGFloat, dt: Double) -> CGFloat {
        let elapsed = max(0.0, dt)
        let tau = target > level ? attackTau : releaseTau
        let factor = 1.0 - exp(-elapsed / tau)
        let next = level + CGFloat((Double(target) - Double(level)) * factor)
        return next < zeroSnapThreshold ? 0.0 : next
    }

    /// Seviyeye göre çubuk renginin aktif (yeşil) olup olmadığı.
    public static func isActive(level: CGFloat) -> Bool {
        level > activeThreshold
    }
}
