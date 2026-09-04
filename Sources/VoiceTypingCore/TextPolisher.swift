import Foundation

public final class TextPolisher {
    public static let shared = TextPolisher()

    private init() {}

    /// Metni aktif ayarlara ve dikte moduna göre temizler ve biçimlendirir
    public func polish(text: String, config: AppConfig) -> String {
        var processed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processed.isEmpty else { return "" }

        // 1. Dolgu Kelimeleri Temizleme (Filler Word Removal)
        if config.remove_filler_words {
            processed = removeFillerWords(from: processed)
        }

        // 2. Özel Sözlük & Terim Eşleme (Custom Vocabulary)
        if !config.custom_vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            processed = applyCustomVocabulary(text: processed, vocabularyString: config.custom_vocabulary)
        }

        // 3. Dikte Modu Biçimlendirmesi (Dictation Mode)
        switch config.dictation_mode.lowercased() {
        case "formal", "profesyonel", "eposta":
            processed = formatFormal(text: processed)
        case "bullet_points", "bullets", "notlar", "madde":
            processed = formatBulletPoints(text: processed)
        default:
            // "direct" (birebir): sadece temel noktalama ve boşluk düzeni
            processed = cleanWhitespaceAndPunctuation(text: processed)
        }

        return processed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Dolgu Kelimeleri Temizleme

    public func removeFillerWords(from input: String) -> String {
        var result = input

        // 1. Saf duraksama sesleri (Türkçe & İngilizce ses öbekleri)
        let hesitationRegex = #"(?i)\b([ıIİi]{1,}|e{2,}|h[ıiİI]m{1,}|[öÖoO]hm+|m{3,}|uh+|um+|er+|ah+|hmm+)\b"#
        result = replaceRegex(pattern: hesitationRegex, in: result, with: "")

        // 2. Cümle başı dolgu kelimeleri (örn: "Şey, bugün...", "Yani, aslında...")
        let startFillersRegex = #"(?i)^\s*([şŞsS]ey|yani|well|like|you know)\s*[,:\-]?\s*"#
        result = replaceRegex(pattern: startFillersRegex, in: result, with: "")

        // 3. Virgül veya duraksama ile çevrelenmiş ara dolgu kelimeleri (örn: ", şey,", ", yani,")
        let midFillersRegex = #"(?i)(,\s*)([şŞsS]ey|yani|you know)(\s*,|\s+)"#
        result = replaceRegex(pattern: midFillersRegex, in: result, with: ", ")

        // 4. Noktalama ve boşluk temizliği
        result = cleanWhitespaceAndPunctuation(text: result)

        // 5. İlk harfi büyük yap (özellikle cümle başındaki dolgu temizlendiyse)
        result = capitalizeFirstLetter(result)

        return result
    }

    // MARK: - Özel Sözlük / Terim Eşleme

    public func applyCustomVocabulary(text: String, vocabularyString: String) -> String {
        let terms = vocabularyString
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result = text
        for term in terms {
            // Tam kelime eşleşmesi (büyük/küçük harf duyarsız), kullanıcının yazdığı orijinal harf düzeniyle değiştir
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let pattern = #"(?i)\b\#(escaped)\b"#
            result = replaceRegex(pattern: pattern, in: result, with: term)
        }
        return result
    }

    // MARK: - Dikte Modları (Biçimlendirme)

    /// Profesyonel / E-posta Modu: Dilbilgisi, büyük harf ve net cümle bitişleri
    public func formatFormal(text: String) -> String {
        var cleaned = cleanWhitespaceAndPunctuation(text: text)
        guard !cleaned.isEmpty else { return "" }

        // Cümle başlarını büyük yap
        cleaned = capitalizeSentences(cleaned)

        // Sonunda noktalama yoksa nokta ekle
        if let last = cleaned.last, !".!?".contains(last) {
            cleaned.append(".")
        }

        return cleaned
    }

    /// Madde İmleri / Not Modu: Cümleleri ve maddeleri "- " listesi haline getirir
    public func formatBulletPoints(text: String) -> String {
        let cleaned = cleanWhitespaceAndPunctuation(text: text)
        guard !cleaned.isEmpty else { return "" }

        // Türkçe madde geçiş belirteçlerini yeni satır ayracına dönüştür
        let bulletKeywords = [
            #"(?i)\s*([iİıI]lk olarak|[iİıI]lk|birincisi|1\.|madde 1|öğe 1)[:\s]*"#,
            #"(?i)\s*([iİıI]kinci olarak|[iİıI]kinci|2\.|madde 2|öğe 2)[:\s]*"#,
            #"(?i)\s*([üÜuU]çüncü olarak|[üÜuU]çüncü|3\.|madde 3|öğe 3)[:\s]*"#,
            #"(?i)\s*(dördüncü olarak|dördüncü|4\.|madde 4)[:\s]*"#,
            #"(?i)\s*(beşinci olarak|beşinci|5\.|madde 5)[:\s]*"#,
            #"(?i)\s*(son olarak|ayrıca|bunun yanında|bununla birlikte|ek olarak)[:\s]*"#
        ]

        var prepared = cleaned
        for kw in bulletKeywords {
            prepared = replaceRegex(pattern: kw, in: prepared, with: "\n")
        }

        // Cümle sonlarına göre de satır böl
        prepared = replaceRegex(pattern: #"([.!?])\s+"#, in: prepared, with: "$1\n")

        let lines = prepared
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•* "))) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return "- " + capitalizeFirstLetter(cleaned)
        }

        return lines.map { "- " + capitalizeFirstLetter($0) }.joined(separator: "\n")
    }

    // MARK: - Yardımcı Fonksiyonlar

    public func cleanWhitespaceAndPunctuation(text: String) -> String {
        var res = text

        // Çift/çoklu boşlukları teke indir
        res = replaceRegex(pattern: #"\s{2,}"#, in: res, with: " ")

        // Noktalama işaretlerinden önceki gereksiz boşlukları sil (örn: "merhaba , nasılsın" -> "merhaba, nasılsın")
        res = replaceRegex(pattern: #"\s+([.,!?:;])"#, in: res, with: "$1")

        // Çift virgül veya virgül-nokta hatalarını düzelt
        res = replaceRegex(pattern: #",\s*,"#, in: res, with: ",")
        res = replaceRegex(pattern: #",\s*\."#, in: res, with: ".")

        // Cümle başındaki yetim virgülleri temizle
        res = replaceRegex(pattern: #"^\s*[,:;\-]\s*"#, in: res, with: "")

        return res.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func capitalizeFirstLetter(_ string: String) -> String {
        guard let first = string.first else { return "" }
        return String(first).uppercased(with: Locale(identifier: "tr_TR")) + string.dropFirst()
    }

    public func capitalizeSentences(_ string: String) -> String {
        let pattern = #"(^|[.!?]\s+)([a-zçğıöşü])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return capitalizeFirstLetter(string)
        }

        let nsString = string as NSString
        let matches = regex.matches(in: string, options: [], range: NSRange(location: 0, length: nsString.length))
        let mutable = NSMutableString(string: string)

        for match in matches.reversed() {
            let letterRange = match.range(at: 2)
            if letterRange.location != NSNotFound {
                let letter = nsString.substring(with: letterRange)
                let upper = letter.uppercased(with: Locale(identifier: "tr_TR"))
                mutable.replaceCharacters(in: letterRange, with: upper)
            }
        }

        return mutable as String
    }

    private func replaceRegex(pattern: String, in string: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return string }
        let range = NSRange(location: 0, length: (string as NSString).length)
        return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: replacement)
    }
}
