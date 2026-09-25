import Foundation

/// Deşifre çıktısındaki kontrolsüz tekrarları temizleyen koruma.
///
/// Neden gerekli: Whisper ailesi modelleri sessizlik, arka plan gürültüsü veya
/// müzik üzerinde tekrara girebilir ve aynı ifadeyi onlarca kez üretir
/// ("teşekkürler teşekkürler teşekkürler …"). Bu, hem yapıştırılan metni
/// bozar hem de deşifre gecikmesini saniyelerden onlarca saniyeye çıkarır.
///
/// Groq `/audio/transcriptions` çıktı uzunluğunu sınırlayan bir parametre
/// **kabul etmez** (canlı testte `max_tokens` → HTTP 400 `unknown_param`).
/// Bu yüzden koruma, sağlayıcıdan bağımsız olarak çıktı metni üzerinde
/// uygulanır: sağlayıcı neyi desteklerse desteklesin çalışır.
public enum RepetitionGuard {

    /// Bir ifadenin "kontrolsüz tekrar" sayılması için gereken en az ardışık
    /// tekrar sayısı. 3, gerçek konuşmadaki vurgu tekrarlarını ("çok çok çok
    /// güzel") korur; 4+ pratikte yalnızca model arızasında görülür.
    public static let defaultMinimumRepeats = 4

    /// Tekrar aranırken dikkate alınacak en uzun ifade (karakter).
    /// Çok uzun pencereler hem yavaş hem gereksizdir.
    public static let maximumPhraseLength = 60

    /// Metindeki kontrolsüz ardışık tekrarları tek bir örneğe indirger.
    ///
    /// Algoritma: en uzun ifadeden en kısaya doğru, metni `minimumRepeats`
    /// kez art arda tekrarlayan en kısa bloğu arar ve o bloğu bir kez bırakır.
    /// Böylece "teşekkürler teşekkürler teşekkürler teşekkürler" → "teşekkürler"
    /// olurken, gerçek bir cümle içindeki ikili vurgu korunur.
    ///
    /// - Returns: Temizlenmiş metin ve kaç tekrar grubunun kaldırıldığı.
    public static func collapse(
        _ text: String,
        minimumRepeats: Int = RepetitionGuard.defaultMinimumRepeats
    ) -> (text: String, collapsedGroups: Int) {
        guard minimumRepeats >= 2, text.count >= minimumRepeats else {
            return (text, 0)
        }

        let tokens = tokenize(text)
        guard tokens.count >= minimumRepeats else { return (text, 0) }

        var result: [Token] = []
        var collapsedGroups = 0
        var index = 0

        while index < tokens.count {
            var bestBlockLength = 0
            // Bloğu EN KISADAN başlayarak dene: tekrarın temel periyodu en kısa
            // olanıdır. En uzunu seçmek yanlış olurdu — düzgün tekrarlanan bir
            // metinde uzun blok da "tekrar ediyor" görünür ve geriye 60 kelime
            // bırakırdı (ör. 500×"tekrar" → 60×"tekrar").
            let maxBlock = min(
                tokens.count - index,
                maximumPhraseLength,
                max(1, (tokens.count - index) / minimumRepeats)
            )
            if maxBlock >= 1 {
                for blockLength in 1...maxBlock {
                    var repeats = 1
                    while index + (repeats + 1) * blockLength <= tokens.count {
                        let current = Array(tokens[(index + repeats * blockLength)..<(index + (repeats + 1) * blockLength)])
                        let first = Array(tokens[index..<(index + blockLength)])
                        // Normalize anahtarlarla karşılaştır: "Tamam," ile
                        // "Tamam!" aynı tekrarın parçasıdır.
                        if keysEqual(current, first) {
                            repeats += 1
                        } else {
                            break
                        }
                    }
                    if repeats >= minimumRepeats {
                        bestBlockLength = blockLength
                        break
                    }
                }
            }

            if bestBlockLength > 0 {
                // Tekrar eden bloğu tek bir örnekle temsil et. ÖZGÜN parçalar
                // yazılır: kullanıcının noktalaması ve büyük harfi korunur.
                result.append(contentsOf: tokens[index..<(index + bestBlockLength)])
                collapsedGroups += 1
                // Tüm ardışık tekrarları atla.
                var consumed = bestBlockLength
                while index + consumed + bestBlockLength <= tokens.count {
                    let next = Array(tokens[(index + consumed)..<(index + consumed + bestBlockLength)])
                    let first = Array(tokens[index..<(index + bestBlockLength)])
                    if keysEqual(next, first) { consumed += bestBlockLength } else { break }
                }
                index += consumed
            } else {
                result.append(tokens[index])
                index += 1
            }
        }

        guard collapsedGroups > 0 else { return (text, 0) }
        return (detokenize(result), collapsedGroups)
    }

    /// İki parça bloğunun normalize anahtarlarını karşılaştırır.
    private static func keysEqual(_ lhs: [Token], _ rhs: [Token]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where left.key != right.key {
            return false
        }
        return true
    }

    /// Karşılaştırılabilir parça: özgün metin + normalleştirilmiş anahtar.
    ///
    /// Anahtar yalnızca **karşılaştırma** içindir; çıktıya her zaman `original`
    /// yazılır, böylece kullanıcının noktalaması ve büyük harfi korunur.
    private struct Token {
        let original: String
        let key: String

        init(_ original: String) {
            self.original = original
            let k = RepetitionGuard.comparisonKey(original)
            // Noktalamadan ibaret parçalar (ör. "…") boş anahtar üretir;
            // hepsinin eşleşmemesi için özgün metne düşülür.
            self.key = k.isEmpty ? original.lowercased() : k
        }
    }

    /// Karşılaştırma anahtarı: noktalama atılır, büyük/küçük harf katlanır.
    ///
    /// ## Neden gerekli (ölçümle bulundu)
    ///
    /// Eski karşılaştırma ham parçaları kullanıyordu, bu yüzden model aynı
    /// kelimeyi farklı noktalama veya büyük/küçük harfle tekrarladığında
    /// tekrar **hiç yakalanmıyordu**:
    ///
    /// ```
    /// "Tamam. Tamam. Tamam. Tamam."   → yakalanıyordu
    /// "Tamam. Tamam, Tamam! Tamam."   → KAÇIYORDU  (noktalama farklı)
    /// "Tamam. tamam. Tamam. tamam."   → KAÇIYORDU  (harf farklı)
    /// ```
    ///
    /// ## Aksanlar bilinçli olarak katlanmaz
    ///
    /// Türkçe'de aksanlar kelimeyi değiştirir: `yaş` (yaş/age) ve `yas`
    /// (yas/mourning) ayrı kelimelerdir. Aksan katlamak gerçek kelimeleri
    /// birbirine karıştırırdı. Yalnızca harf **büyüklüğü** ve noktalama
    /// katlanır — bu, gerçek tekrarların tamamını yakalamak için yeter.
    static func comparisonKey(_ token: String) -> String {
        var key = ""
        for character in token.lowercased() where character.isLetter || character.isNumber {
            // Türkçe noktasız-ı: "TAMAM" ve "tamam" aynı anahtarı vermeli.
            // (`I` → `ı` dönüşümü yerel ayardan bağımsız `lowercased()` ile
            // gelmez, bu yüzden burada eşitliyoruz.)
            key.append(character == "ı" ? "i" : character)
        }
        return key
    }

    /// Metni karşılaştırılabilir parçalara ayırır. Kelime sınırları varsa
    /// kelimeler, yoksa (Japonca/Çince gibi boşluksuz diller) karakterler.
    private static func tokenize(_ text: String) -> [Token] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        if words.count >= 2 {
            return words.map { Token(String($0)) }
        }
        return text.map { Token(String($0)) }
    }

    /// Kelime parçalarını boşlukla birleştirir; karakter parçalarını birleştirir.
    private static func detokenize(_ tokens: [Token]) -> String {
        guard !tokens.isEmpty else { return "" }
        // Tek karakterlik parçalar boşluksuz dil demektir.
        let allSingleCharacter = tokens.allSatisfy { $0.original.count <= 1 }
        if allSingleCharacter {
            return tokens.map(\.original).joined()
        }
        return tokens.map(\.original).joined(separator: " ")
    }
}
