import Foundation

/// Deşifre çıktısının üst sınırını yöneten saf bütçe katmanı.
///
/// Neden var: Whisper ailesi modelleri sessizlik veya arka plan gürültüsünde
/// tekrara girebilir ("... teşekkürler teşekkürler ..." gibi) ve üretimi
/// durduracak bir sınır olmadığında çıkarım süresi saniyelerden onlarca
/// saniyeye çıkabilir. AlwaysWhisper bunu ses süresine bağlı bir token tavanıyla
/// sınırlar: `16 * saniye + 32`.
///
/// Sağlayıcı gerçekleri (canlı API testiyle doğrulandı, bkz. implementation_plan):
/// - **Gemini** `generateContent` `generationConfig.maxOutputTokens` kabul eder
///   → `tokenCap(audioSeconds:)` doğrudan kullanılır.
/// - **Groq** `/audio/transcriptions` `max_tokens` parametresini **reddeder**
///   (HTTP 400 `unknown_param`). Bu yüzden orada tavan parametre olarak değil,
///   istek başına ses penceresi olarak uygulanır → `maxChunkSeconds(...)`.
public enum DecodeBudget {

    /// Saniye başına izin verilen token. Gerçek Türkçe konuşma ölçümlerinde
    /// en hızlı oranın yaklaşık 3 katı; konuşmayı kırpmayacak kadar geniş,
    /// tekrar döngüsünü kesecek kadar dar.
    public static let defaultTokensPerSecond = 16

    /// Sabit taban payı: çok kısa kayıtların bile anlamlı bir bütçesi olsun.
    public static let defaultTokenBase = 32

    /// Alt sınır: formülün tabanı. `16 * 0 + 32 = 32` olduğu için hiçbir
    /// pozitif süre bu değerin altına inmez; yapay bir taban koymak
    /// AlwaysWhisper'ın formülünü kısa kayıtlarda bozardı.
    public static let minimumTokenCap = 32

    /// Üst sınır: sağlayıcıların kabul ettiği makul çıktı aralığı.
    public static let maximumTokenCap = 4096

    /// `audioSeconds` sesi için izin verilen en yüksek token sayısı.
    ///
    /// `tokensPerSecond <= 0` ise `nil` döner; bu "tavan uygulanmasın"
    /// anlamına gelir ve çağıran ilgili alanı isteğe hiç koymamalıdır.
    /// NaN/negatif/aşırı büyük süreler güvenli biçimde kırpılır.
    public static func tokenCap(
        audioSeconds: Double,
        tokensPerSecond: Int = DecodeBudget.defaultTokensPerSecond,
        base: Int = DecodeBudget.defaultTokenBase
    ) -> Int? {
        guard tokensPerSecond > 0 else { return nil }
        // Sonsuz süre → en yüksek tavan. NaN/negatif/geçersiz → en düşük.
        if audioSeconds == .infinity { return maximumTokenCap }
        guard audioSeconds.isFinite, audioSeconds > 0 else { return minimumTokenCap }

        let raw = Double(tokensPerSecond) * audioSeconds + Double(base)
        // Aşırı büyük sürelerde Int dönüşümü taşmasın diye önce üst sınıra kırp.
        guard raw < Double(maximumTokenCap) else { return maximumTokenCap }
        return min(maximumTokenCap, max(minimumTokenCap, Int(raw.rounded())))
    }

    /// Belirtilen token tavanını aşmayan en uzun ses penceresi (saniye).
    ///
    /// Groq gibi tavan parametresi kabul etmeyen sağlayıcılarda kaydı bu
    /// uzunlukta dilimlemek için kullanılır. `tokensPerSecond <= 0` ise
    /// `.infinity` döner: dilimleme yapılmaz.
    public static func maxChunkSeconds(
        tokenCap: Int = DecodeBudget.maximumTokenCap,
        tokensPerSecond: Int = DecodeBudget.defaultTokensPerSecond,
        base: Int = DecodeBudget.defaultTokenBase
    ) -> Double {
        guard tokensPerSecond > 0 else { return .infinity }
        let usable = Double(tokenCap - base)
        guard usable > 0 else { return 0 }
        return usable / Double(tokensPerSecond)
    }

    /// 16-bit mono PCM bayt sayısından süre (saniye).
    public static func audioSeconds(
        pcm16ByteCount: Int,
        sampleRate: Int = 16_000
    ) -> Double {
        guard pcm16ByteCount > 0, sampleRate > 0 else { return 0 }
        let samples = pcm16ByteCount / MemoryLayout<Int16>.size
        return Double(samples) / Double(sampleRate)
    }
}
