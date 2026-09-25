import Foundation

/// Whisper ailesinin **decoder prompt bütçesini** yönetir.
///
/// ## Neden gerekli
///
/// Whisper, `prompt` alanını 224 token'lik bir pencereye sığdırır ve **fazlasını
/// sessizce atar**. "Sessizce" kısmı kritik: ne hata döner ne uyarı. Kullanıcı
/// 40 terimlik sözlük yazar, terimlerin bir kısmı hiç uygulanmaz ve neden
/// olduğu anlaşılmaz.
///
/// Şu anki koruma **terim sayısı** (`CustomVocabularyParser.maximumTermCount = 100`).
/// Ama 100 uzun terim 224 token'ı rahatça aşar — sayı sınırı token sınırı
/// değildir. Bu dosya o boşluğu kapatır.
///
/// ## Neden SONdan kesiyoruz
///
/// Whisper prompt'un **başından** kırpar. Yani kullanıcı listeyi yukarıdan
/// aşağıya yazdıysa, **alttaki** terimler hayatta kalır. Bu yüzden biz de
/// sondan kesip baştakileri bırakırız — modelin gördüğüyle aynı sonucu
/// üretmek için, ve kullanıcıya "önemli terimleri sona yazın" diyebilmek için.
public enum PromptBudget {

    /// Whisper decoder prompt penceresi (token). Referans
    /// `WHISPER_PROMPT_TOKEN_LIMIT`.
    public static let whisperTokenLimit = 224

    /// Japonca/Çince karakter başına token tahmini.
    /// Bu dillerde bir karakter birden fazla token'a bölünür.
    public static let tokensPerCJKCharacter = 2

    /// Diğer dillerde karakter başına token oranı (4 karakter ≈ 1 token).
    public static let charactersPerToken = 4

    // MARK: - Tahmin

    /// Metnin kaç Whisper token'ı tutacağını **kabaca** tahmin eder.
    ///
    /// Bilinçli olarak **abartır**: gerçek değerden yüksek tahmin etmek, sınırı
    /// aşmamak adına güvenli tarafta kalmaktır. Referansın formülü: CJK
    /// karakterler ×2, diğer her 4 karakter için 1 token.
    public static func estimateTokens(_ text: String) -> Int {
        var cjkCount = 0
        var otherCount = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjkCount += 1
            } else {
                otherCount += 1
            }
        }
        return cjkCount * tokensPerCJKCharacter + (otherCount + charactersPerToken - 1) / charactersPerToken
    }

    /// Japonca/Çince/Korece aralıklarında mı?
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,      // Hiragana + Katakana
             0x3400...0x4DBF,      // CJK Extension A
             0x4E00...0x9FFF,      // CJK Unified Ideographs
             0xF900...0xFAFF,      // CJK Compatibility Ideographs
             0xAC00...0xD7AF,      // Hangul Syllables
             0x1100...0x11FF:      // Hangul Jamo
            return true
        default:
            return false
        }
    }

    // MARK: - Kırpma

    /// Metni token sınırına sığdırır; **sondan** keser.
    ///
    /// Kesim her zaman bir kelime sınırına oturtulur — yarım kelime bırakmak
    /// modelin anlamsız bir parça görmesine yol açardı.
    ///
    /// - Returns: Sınır içindeki metin (değişiklik yoksa aynısı) ve kırpılıp
    ///   kırpılmadığı.
    public static func truncateToTail(
        _ text: String,
        maxTokens: Int = PromptBudget.whisperTokenLimit
    ) -> (text: String, wasTruncated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxTokens > 0 else { return (trimmed, false) }
        guard estimateTokens(trimmed) > maxTokens else { return (trimmed, false) }

        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard words.count > 1 else {
            // Tek kelime ama sınırı aşıyor: karakter bazlı kesmektense
            // dokunmamak daha güvenli — yarım terim işe yaramaz.
            return (trimmed, false)
        }

        // Sondan biriktir: Whisper'ın tuttuğu uç. Sıra korunur.
        var kept: [String] = []
        var total = 0
        for word in words.reversed() {
            let candidate = total + estimateTokens(word) + 1   // +1: ayırıcı boşluk
            if candidate > maxTokens && !kept.isEmpty { break }
            kept.append(word)
            total = candidate
        }

        guard !kept.isEmpty, kept.count < words.count else { return (trimmed, false) }
        return (kept.reversed().joined(separator: " "), true)
    }

    // MARK: - Sözlük yardımcıları

    /// Sözlük metnini terimlere ayırır (mevcut ayrıştırıcıyı yeniden kullanır;
    /// ikinci bir ayrıştırma kuralı kümesi bakım yükü olurdu).
    static func parseTerms(_ vocabulary: String) -> [String] {
        CustomVocabularyParser.terms(from: vocabulary)
    }

    /// Sözlüğü token bütçesine sığdırılmış `prompt` metnine çevirir.
    ///
    /// Terimler virgülle birleştirilir, sonra sondan kırpılır. Kırpma olduysa
    /// `wasTruncated` true döner; çağıran taraf kullanıcıyı uyarabilir.
    public static func promptText(
        fromVocabulary vocabulary: String,
        maxTokens: Int = PromptBudget.whisperTokenLimit
    ) -> (text: String, wasTruncated: Bool) {
        let terms = parseTerms(vocabulary)
        guard !terms.isEmpty else { return ("", false) }
        return truncateToTail(terms.joined(separator: ", "), maxTokens: maxTokens)
    }
}
