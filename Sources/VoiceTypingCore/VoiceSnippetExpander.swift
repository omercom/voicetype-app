import Foundation

/// Kullanıcı tanımlı sesli kısayolları (Voice Snippets) tespit edip
/// deşifre edilmiş metindeki ilgili ifadeyi tam metinle değiştiren metin genişletici.
/// 
/// Türkçe konuşma ve ses tanıma özelliklerine tam uyumludur:
/// 1. "kısayol" ve "kısa yol" (ayrı veya bitişik) eşdeğerliğini otomatik tanır.
/// 2. Türkçe I/İ/ı/i büyük-küçük harf ve ASCII uyumsuzluklarını (örn: "IBAN" -> "ıban") normalleştirir.
/// 3. Kullanıcının konuşma sırasındaki eklerini ("kısayol ibanı", "kısayol ibanım", "kısayol mailime") tolere eder.
/// 4. Bulanık eşleme (Fuzzy matching) ile küçük telaffuz ve yazım hatalarını (örn: "kisayol ibn") algılar.
public final class VoiceSnippetExpander {
    public static let shared = VoiceSnippetExpander()

    private init() {}

    /// Metni Türkçe ses tanıma varyasyonlarına göre normalize eder (ı->i, kısa yol->kisayol vb.)
    public static func normalizeKey(_ text: String) -> String {
        var s = text.lowercased(with: Locale(identifier: "tr_TR"))
        s = s.replacingOccurrences(of: "ı", with: "i")
        s = s.replacingOccurrences(of: "I", with: "i")
        s = s.replacingOccurrences(of: "İ", with: "i")
        s = s.replacingOccurrences(of: "kisa yol", with: "kisayol")
        s = s.replacingOccurrences(of: "kısa yol", with: "kisayol")
        s = s.replacingOccurrences(of: "e posta", with: "eposta")
        s = s.replacingOccurrences(of: "e-posta", with: "eposta")
        // Noktalama işaretlerini ve boşlukları temizle
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?:;\"'()[]{}<>-–—"))
        return s
    }

    /// Levenshtein düzenleme mesafesi
    public static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var d = Array(0...n)
        for i in 1...m {
            var prev = d[0]
            d[0] = i
            for j in 1...n {
                let temp = d[j]
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + cost)
                prev = temp
            }
        }
        return d[n]
    }

    /// Verilen metindeki tüm sesli kısayolları genişletir.
    public func expand(text: String, snippets: [String: String]) -> String {
        guard !text.isEmpty, !snippets.isEmpty else { return text }

        let normInput = Self.normalizeKey(text)

        // 1. TAM EŞLEŞME VEYA TEK CÜMLELİK DİKTE (Kullanıcı yalnızca kısayolu söylemişse)
        // Örnekler: "Kısa yol IBAN", "kısayol iban", "kısa yol ibanı", "kısayol ibanım", "kisayol ibn"
        for (trigger, expansion) in snippets {
            let normTrigger = Self.normalizeKey(trigger)
            guard !normTrigger.isEmpty else { continue }

            // Birebir eşleşme
            if normInput == normTrigger {
                return expansion
            }

            // Ek toleransı ("kısayol ibanı", "kısayol ibanım" -> normTrigger ile başlar ve en fazla 4 harf ek alır)
            if normInput.hasPrefix(normTrigger) && (normInput.count - normTrigger.count <= 4) {
                return expansion
            }

            // Bulanık eşleme (Levenshtein mesafesi: 4 harften uzun tetikleyicilerde 2 harfe kadar hata toleransı)
            if normTrigger.count >= 4 && Self.levenshteinDistance(normInput, normTrigger) <= 2 {
                return expansion
            }
        }

        // 2. CÜMLE İÇİ KISAYOL GENİŞLETMESİ
        // Örnek: "Lütfen bana Kısa yol IBAN hesabınızı gönderin" -> "Lütfen bana TR33 ... hesabınızı gönderin"
        var result = text
        let sortedSnippets = snippets.sorted { $0.key.count > $1.key.count }

        for (trigger, expansion) in sortedSnippets {
            let pattern = buildFlexibleRegexPattern(for: trigger)
            guard !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: expansion)
            )
        }

        return result
    }

    /// Bir tetikleyici için "kısayol"/"kısa yol" ve Türkçe harf varyasyonlarını kapsayan regex üretir
    private func buildFlexibleRegexPattern(for trigger: String) -> String {
        let clean = trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
        let words = clean.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }

        var parts: [String] = []
        for (idx, word) in words.enumerated() {
            let isLast = (idx == words.count - 1)
            var p = ""
            if word == "kısayol" || word == "kısa" || word == "kisayol" {
                p = "(?:kısayol|kısa\\s+yol|kisayol|kisa\\s+yol)"
            } else if word == "iban" || word == "ıban" {
                p = "(?:iban|ıban|ibn)"
            } else if word == "mail" || word == "eposta" || word == "e-posta" {
                p = "(?:mail|eposta|e-posta|e\\s+posta)"
            } else if word == "adres" {
                p = "(?:adres)"
            } else {
                // Genel kelime: i ve ı harflerini eşdeğer yap
                var charPattern = ""
                for ch in word {
                    if ch == "i" || ch == "ı" {
                        charPattern += "[iıİI]"
                    } else {
                        charPattern += NSRegularExpression.escapedPattern(for: String(ch))
                    }
                }
                p = "(?:" + charPattern + ")"
            }
            if isLast {
                p += "(?:\\b|[ıiİI]m|[ıiİI]|e|a|da|de|ta|te|in|ın)?"
            }
            parts.append(p)
        }
        return "(?i)\\b" + parts.joined(separator: "\\s+")
    }
}
