import Foundation

/// Modelin, verilen **sözlüğü ses olarak okuyup** yazıya dökmesini engeller.
///
/// ## Neden gerekli
///
/// Whisper'a `prompt` alanıyla sözlük verildiğinde model, sessizlik veya
/// gürültü üzerinde bu terimleri "duymuş gibi" üretebilir. Sonuç: kullanıcı
/// hiçbir şey söylemediği hâlde metne sözlük terimleri düşer.
///
/// Bu **gerçek bir olaydır** — referans uygulamada yaşanmış ve
/// `is_prompt_echo()` fonksiyonu tam bu yüzden yazılmıştır (girdi: sözlüğe
/// `"データベース, Notion"` yazan kullanıcı, sessizlikte bu metni çıktı olarak
/// almıştır).
///
/// ## Sözlük listesinden farkı
///
/// Bu kontrol **sabit bir kalıp listesi kullanmaz**. Karşılaştırmayı
/// kullanıcının kendi sözlüğüne karşı yapar. Bu yüzden:
/// - Dil bağımsızdır (Türkçe, İngilizce, Japonca — hepsi çalışır).
/// - Yeni kalıp eklemek gerekmez; sözlük değişince koruma otomatik uyar.
public enum PromptEchoGuard {

    /// Eko sayılabilecek en uzun metin (karakter).
    ///
    /// Referans `PROMPT_ECHO_MAX_CHARS = 24`. Daha uzun metin gerçek bir
    /// cümledir; eko değildir.
    public static let maximumEchoCharacters = 24

    /// Metnin sözlüğün yankısı olup olmadığı.
    ///
    /// İki durumda true döner:
    /// 1. Metin kısa (≤ 24 karakter) **ve** sözlük terimlerinden birine denk.
    /// 2. Metnin **her kelimesi** bir sözlük terimi.
    ///
    /// - Parameter text: Sağlayıcıdan dönen deşifre metni.
    /// - Parameter vocabulary: Kullanıcının sözlük metni (virgül/satır ayrık).
    public static func isEcho(_ text: String, vocabulary: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let terms = CustomVocabularyParser.terms(from: vocabulary)
        guard !terms.isEmpty else { return false }

        let termKeys = Set(terms.map { normalizedKey($0) }.filter { !$0.isEmpty })
        guard !termKeys.isEmpty else { return false }

        let textKey = normalizedKey(trimmed)
        guard !textKey.isEmpty else { return false }

        // Durum 1: kısa metin ve bir terime birebir denk.
        if trimmed.count <= maximumEchoCharacters, termKeys.contains(textKey) {
            return true
        }

        // Durum 2: her kelime bir terim.
        //
        // Tek kelimelik gerçek dikteyi korumak için alt sınır var: kullanıcı
        // sözlükteki bir kelimeyi bilerek söylemiş olabilir ("Notion" gibi).
        // Ancak iki ve fazlası, cümlenin tamamen sözlükten oluştuğunu gösterir
        // ve eko olasılığı baskın hâle gelir.
        let words = normalizedWords(trimmed)
        guard !words.isEmpty, words.count >= 2 else { return false }
        return words.allSatisfy { termKeys.contains($0) }
    }

    // MARK: - Normalizasyon

    /// Karşılaştırma anahtarı: NFKC + aksan/büyüklük duyarsız + yalnız harf/rakam.
    ///
    /// ## Türkçe noktasız-ı tuzağı (testlerle bulundu)
    ///
    /// Türkçe yerel ayarında `"I".lowercased()` → `"ı"` (noktasız) olur, ama
    /// `"i".lowercased()` → `"i"` kalır. Yani `"NOTION"` → `"notıon"` iken
    /// `"Notion"` → `"notion"` — **eşleşmezlerdi**. Model çıktıyı büyük harfle
    /// döndürdüğünde yankı koruması sessizce devre dışı kalırdı.
    ///
    /// Çözüm: karşılaştırma anahtarında her iki ı/i biçimini tek harfe indir.
    /// Bu yalnızca **karşılaştırma** içindir; kullanıcıya gösterilen metne
    /// dokunulmaz.
    static func normalizedKey(_ text: String) -> String {
        var key = ""
        for character in folded(text) where character.isLetter || character.isNumber {
            key.append(canonicalI(character))
        }
        return key
    }

    /// Normalize edilmiş kelimeler (kelime sınırları korunur).
    static func normalizedWords(_ text: String) -> [String] {
        var cleaned = ""
        for character in folded(text) {
            cleaned.append(character.isLetter || character.isNumber ? canonicalI(character) : " ")
        }
        return cleaned.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Noktalı/noktasız i ayrımını ortadan kaldırır.
    private static func canonicalI(_ character: Character) -> Character {
        switch character {
        case "ı", "İ", "î", "Ì", "Í", "Ï", "Ĩ", "Ī", "Ĭ", "Į", "ı":
            return "i"
        default:
            return character
        }
    }

    private static func folded(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.folding(
            options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
            locale: Locale(identifier: "tr_TR")
        )
    }
}
