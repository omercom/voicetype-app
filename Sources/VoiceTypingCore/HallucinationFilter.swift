import Foundation

/// Whisper ailesi modellerin sessizlik, nefes veya oda gürültüsü üzerinde
/// "duyduğu" bilinen altyazı kalıplarını temizler.
///
/// ## Neden gerekli
///
/// Whisper büyük ölçüde video altyazılarıyla eğitildiği için sessiz ya da
/// gürültülü bir segmentte "Altyazı M.K." veya "İzlediğiniz için
/// teşekkürler" gibi metinler üretebilir. `RepetitionGuard` bunları yakalamaz
/// (tekrar değiller), `PromptEchoGuard` da yakalamaz (sözlükte değiller).
///
/// ## Gerçek dikteyi koruma kuralı
///
/// 1. **Tüm metin** bilinen bir kalıba eşitse metin atılır. Uzun bir cümlenin
///    içinde geçen "izlediğiniz için teşekkürler" korunur.
/// 2. **Sondaki altyazı jeneriği** ("Altyazı M.K.", Amara.org) her durumda
///    kesilir; bunlar gerçek konuşmada söylenmez.
///
/// Tek başına "teşekkürler" gibi gerçek olabilecek kısa ifadeler bilerek
/// listede yoktur.
public enum HallucinationFilter {

    /// Metnin tamamı bunlardan birine eşitse metin atılır.
    static let wholeTextPhrases: [String] = [
        // Türkçe altyazı jenerikleri
        "Altyazı M.K.",
        "Alt yazı M.K.",
        "Altyazılar Amara.org topluluğu tarafından",
        "Amara.org topluluğu tarafından altyazılandı",
        // Türkçe video kapanışları
        "İzlediğiniz için teşekkürler",
        "İzlediğiniz için teşekkür ederim",
        "İzlediğiniz için teşekkür ederiz",
        "Bizi izlediğiniz için teşekkürler",
        "Bizi izlediğiniz için teşekkür ederiz",
        "Abone olmayı unutmayın",
        "Kanalıma abone olmayı unutmayın",
        "Beğenmeyi ve abone olmayı unutmayın",
        "Bir sonraki videoda görüşmek üzere",
        "Bir sonraki videoda görüşürüz",
        // İngilizce karşılıklar (dil yanlış algılandığında)
        "Thank you for watching",
        "Thanks for watching",
        "Please subscribe",
        "Subtitles by the Amara.org community",
    ]

    static let wholeTextKeys: Set<String> = Set(wholeTextPhrases.map { normalizedKey($0) })

    /// Metnin sonunda görülürse her zaman kesilen altyazı jenerikleri.
    private static let trailingCreditRegexes: [NSRegularExpression] = [
        // "Altyazı M.K." / "Alt yazı: M.K." / "altyazi mk"
        #"[\s,;:–-]*\balt\s*yaz[ıiIİ]\s*[:\-]?\s*m\s*\.?\s*k\s*\.?[\s.!]*$"#,
        // Amara.org içeren son cümle
        #"[^.!?\n]*\bamara\s*\.\s*org\b[^.!?\n]*[.!?]*\s*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Bilinen uydurma kalıpları temizler. Hiçbir şey değişmezse girdiyi
    /// olduğu gibi döndürür.
    public static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        if wholeTextKeys.contains(normalizedKey(trimmed)) {
            print("[HallucinationFilter] 🚫 Bilinen altyazı kalıbı; metin atıldı.")
            return ""
        }

        var result = trimmed
        // Jenerikler art arda gelebilir ("... Altyazı M.K. Amara.org ...").
        for _ in 0..<3 {
            var changed = false
            for regex in trailingCreditRegexes {
                let range = NSRange(result.startIndex..., in: result)
                let replaced = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if replaced != result {
                    result = replaced
                    changed = true
                }
            }
            if !changed { break }
        }

        guard result != trimmed else { return text }
        print("[HallucinationFilter] ✂️ Sondaki altyazı jeneriği kesildi.")

        // Jenerik kesildikten sonra kalan da bilinen bir kalıpsa onu da at
        // (ör. "İzlediğiniz için teşekkürler. Altyazı M.K.").
        if !result.isEmpty, wholeTextKeys.contains(normalizedKey(result)) {
            return ""
        }
        return result
    }

    /// Karşılaştırma anahtarı: Türkçe küçük harf, ı→i, aksan duyarsız,
    /// yalnızca harf/rakam ve tekil boşluk.
    static func normalizedKey(_ text: String) -> String {
        let tr = Locale(identifier: "tr_TR")
        let folded = text.lowercased(with: tr)
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: tr)
        var out = ""
        var lastWasSpace = true
        for character in folded {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasSpace = false
            } else if character.isWhitespace, !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
