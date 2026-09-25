import Foundation
import CoreGraphics

/// Çentik (Dynamic Island) modunun tipografi ve biçim kuralları.
///
/// Tasarım kararı (kullanıcı geri bildirimi):
///   • Ada genişliği **SABİTTİR** — metin uzadıkça ada genişlemez.
///   • Uzun metin **alt satırlara sarar** (kelime kaydırma).
///   • Yazı boyutu adaptiftir: metin çok satıra taşarsa küçülür, ama
///     **alt sınırın altına inmez**. Alt sınırda da sığmıyorsa kırpılır.
///
/// AppKit'ten bağımsızdır: metin ölçümü closure olarak dışarıdan verilir.
public enum NotchTypography {

    /// Çentik modunda taban (en büyük) yazı boyutu.
    ///
    /// Yolculuk: referans 28pt → geri bildirimle 24pt → şimdi 20pt.
    /// 20pt seçildi çünkü sabit ada genişliğinde (400pt) tam boyutta
    /// ~105 karakter sığıyor; 24pt'de bu ~87 karakterdi. Yani yazı daha
    /// uzun süre tam boyutta kalır ve küçülme daha geç başlar — hem daha
    /// okunaklı hem daha az titrek.
    public static let baseFontSize: CGFloat = 20.0

    /// Otomatik küçültmede inilebilecek en küçük boyut.
    ///
    /// 13pt, macOS'un standart arayüz yazı boyutudur (NSFont.systemFontSize).
    /// Keyfî bir taban yerine sistem standardını kullanmak, "okunabilirlik
    /// sınırı" kararını savunulabilir kılar.
    public static let minimumFontSize: CGFloat = 13.0

    /// Metnin iki yanında bırakılacak boşluk (tek kenar).
    public static let horizontalPadding: CGFloat = 24.0

    /// Ada genişliğinin alt sınırı (pt).
    public static let minimumPanelWidth: CGFloat = 400.0

    /// Ada genişliğinin üst sınırı (pt). Sabit genişliğin tavanı.
    public static let maximumPanelWidth: CGFloat = 560.0

    /// Metnin altına/üstüne eklenecek dikey boşluk.
    public static let verticalPadding: CGFloat = 12.0

    /// Satırlar arası ek boşluk.
    public static let lineSpacing: CGFloat = 2.0

    /// Metnin sarabileceği en fazla satır sayısı.
    /// Bu sınırı aşan metin küçültülür, sonra yine sığmazsa kırpılır.
    public static let maximumLines: Int = 3

    /// Ada yüksekliğinin üst sınırı (metin alanı için, pt).
    ///
    /// Sonsuz tekrar üreten bir sağlayıcı ya da aşırı uzun bir metin, satır
    /// sayısını sınırsız büyütüp adayı ekranın altına taşırabilirdi. Bu tavan
    /// aşıldığında pencere büyümez, metin kırpılır.
    public static let maximumContentHeight: CGFloat = 160.0

    /// Oval köşe yarıçapı (basit yuvarlama gerektiğinde).
    ///
    /// NOT: Çentiğin gerçek formu artık `NotchShapePath` ile çizilir
    /// (üst konkav 6pt + alt konveks 14pt). Bu fonksiyon yalnızca düz
    /// yuvarlatma gereken yerler için basit bir yardımcıdır.
    public static func cornerRadius(panelHeight: CGFloat) -> CGFloat {
        max(0.0, min(30.0, panelHeight / 2.0))
    }

    /// Alt köşelerin yuvarlaması için metin alanının altına bırakılacak pay.
    /// `NotchShapePath.bottomCornerRadius` kadar yer açmazsak yazının alt
    /// satırı yuvarlamanın içine girip kırpılır.
    public static let bottomPadding: CGFloat = 6.0

    /// Alt yuvarlamaların metni kırpmaması için gereken en az yükseklik.
    public static var minimumHeightForRoundedBottom: CGFloat {
        bottomCornerRadiusAllowance * 2
    }

    private static var bottomCornerRadiusAllowance: CGFloat {
        NotchShapePath.bottomCornerRadius
    }

    /// Ada genişliği — SABİT.
    ///
    /// Metne göre DEĞİŞMEZ; yalnızca ekrana ve çentiğe göre belirlenir.
    /// Bu yüzden metin geldikçe ada zıplamaz, yalnızca satır sayısı artar.
    public static func panelWidth(cameraWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let floor = max(minimumPanelWidth, cameraWidth + 160.0)
        let capped = min(maximumPanelWidth, floor)
        return min(capped, max(floor, screenWidth - 32.0))
    }

    /// Metnin verilen genişlikte kaç satıra yayılacağını hesaplar (kelime kaydırma).
    ///
    /// Ölçüm closure'ı `(metin, punto) -> genişlik` biçimindedir.
    /// Basit ve deterministik bir greedy sarma uygular.
    public static func lineCount(
        text: String,
        availableWidth: CGFloat,
        fontSize: CGFloat,
        measure: (String, CGFloat) -> CGFloat
    ) -> Int {
        guard availableWidth > 0, !text.isEmpty else { return 0 }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Boşluksuz (ör. Çince/Japonca) metin: tek "kelime" sayılır.
        guard !words.isEmpty else { return 1 }

        var lines = 1
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if measure(candidate, fontSize) <= availableWidth {
                current = candidate
            } else {
                // Sığmadı: yeni satıra geç. Kelime tek başına bile sığmıyorsa
                // (çok uzun kelime) yine de kendi satırına konur.
                lines += 1
                current = word
            }
        }
        return lines
    }

    /// Metni hedef satır sayısına sığdıracak yazı boyutunu bulur.
    ///
    /// Kısa metin taban boyutta kalır. Uzun metin, `maximumLines` satıra
    /// sığana kadar kademeli küçültülür; `minimumFontSize` altına inmez.
    public static func fittedFontSize(
        text: String,
        availableWidth: CGFloat,
        baseFontSize: CGFloat = NotchTypography.baseFontSize,
        minimumFontSize: CGFloat = NotchTypography.minimumFontSize,
        maximumLines: Int = NotchTypography.maximumLines,
        measure: (String, CGFloat) -> CGFloat
    ) -> CGFloat {
        guard availableWidth > 0, !text.isEmpty else { return minimumFontSize }
        let upper = max(minimumFontSize, baseFontSize)

        // Önce taban boyutu dene.
        if lineCount(text: text, availableWidth: availableWidth,
                     fontSize: upper, measure: measure) <= maximumLines {
            return upper
        }

        // Kademeli küçültme: 1pt adımlarla, okunabilirlik tabanına kadar.
        var size = upper
        while size > minimumFontSize {
            size = max(minimumFontSize, size - 1.0)
            let lines = lineCount(text: text, availableWidth: availableWidth,
                                  fontSize: size, measure: measure)
            if lines <= maximumLines { break }
        }
        return max(minimumFontSize, min(upper, size))
    }

    /// Sığdırma sonrası gereken toplam metin alanı yüksekliği.
    /// `maximumContentHeight` ile sınırlanır: aşırı uzun/tekrarlı metin
    /// pencereyi ekran dışına taşıramaz, kırpılır.
    public static func contentHeight(
        lineCount: Int,
        fontSize: CGFloat,
        lineHeightFor: (CGFloat) -> CGFloat
    ) -> CGFloat {
        guard lineCount > 0 else { return lineHeightFor(fontSize) + verticalPadding }
        let single = lineHeightFor(fontSize)
        let raw = single * CGFloat(lineCount)
            + lineSpacing * CGFloat(max(0, lineCount - 1))
            + verticalPadding
        return min(raw, maximumContentHeight)
    }
}
