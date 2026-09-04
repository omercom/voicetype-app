import Foundation

public final class TextPolisher {
    public static let shared = TextPolisher()

    // MARK: - Önceden Derlenmiş Statik Regexler (Sıfır Çalışma Zamanı Derleme Gecikmesi)

    private static let hesitationRegex = try! NSRegularExpression(
        pattern: #"(?i)\b([ıIİi]{1,}|e{2,}|h[ıiİI]m{1,}|[öÖoO]hm+|m{3,}|uh+|um+|er+|ah+|hmm+)\b"#
    )
    private static let startFillersRegex = try! NSRegularExpression(
        pattern: #"(?i)^\s*([şŞsS]ey|yani|well|like|you know)\s*[,:\-]?\s*"#
    )
    private static let midFillersRegex = try! NSRegularExpression(
        pattern: #"(?i)(,\s*)([şŞsS]ey|yani|you know)(\s*,|\s+)"#
    )
    private static let whitespaceRegex = try! NSRegularExpression(
        pattern: #"\s{2,}"#
    )
    private static let punctuationSpaceRegex = try! NSRegularExpression(
        pattern: #"\s+([.,!?:;])"#
    )
    private static let doubleCommaRegex = try! NSRegularExpression(
        pattern: #",\s*,"#
    )
    private static let commaDotRegex = try! NSRegularExpression(
        pattern: #",\s*\."#
    )
    private static let leadPunctuationRegex = try! NSRegularExpression(
        pattern: #"^\s*[,:;\-]\s*"#
    )
    private static let sentenceCapitalizeRegex = try! NSRegularExpression(
        pattern: #"(^|[.!?]\s+)([a-zçğıöşü])"#,
        options: [.caseInsensitive]
    )
    private static let bulletSplitRegex = try! NSRegularExpression(
        pattern: #"([.!?])\s+"#
    )
    private static let bulletKeywordRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)\s*([iİıI]lk olarak|[iİıI]lk|birincisi|1\.|madde 1|öğe 1)[:\s]*"#),
        try! NSRegularExpression(pattern: #"(?i)\s*([iİıI]kinci olarak|[iİıI]kinci|2\.|madde 2|öğe 2)[:\s]*"#),
        try! NSRegularExpression(pattern: #"(?i)\s*([üÜuU]çüncü olarak|[üÜuU]çüncü|3\.|madde 3|öğe 3)[:\s]*"#),
        try! NSRegularExpression(pattern: #"(?i)\s*(dördüncü olarak|dördüncü|4\.|madde 4)[:\s]*"#),
        try! NSRegularExpression(pattern: #"(?i)\s*(beşinci olarak|beşinci|5\.|madde 5)[:\s]*"#),
        try! NSRegularExpression(pattern: #"(?i)\s*(son olarak|ayrıca|bunun yanında|bununla birlikte|ek olarak)[:\s]*"#)
    ]

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
        result = replaceRegex(Self.hesitationRegex, in: result, with: "")

        // 2. Cümle başı dolgu kelimeleri (örn: "Şey, bugün...", "Yani, aslında...")
        result = replaceRegex(Self.startFillersRegex, in: result, with: "")

        // 3. Virgül veya duraksama ile çevrelenmiş ara dolgu kelimeleri (örn: ", şey,", ", yani,")
        result = replaceRegex(Self.midFillersRegex, in: result, with: ", ")

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
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = replaceRegex(regex, in: result, with: term)
            }
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
        var prepared = cleaned
        for kwRegex in Self.bulletKeywordRegexes {
            prepared = replaceRegex(kwRegex, in: prepared, with: "\n")
        }

        // Cümle sonlarına göre de satır böl
        prepared = replaceRegex(Self.bulletSplitRegex, in: prepared, with: "$1\n")

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
        res = replaceRegex(Self.whitespaceRegex, in: res, with: " ")

        // Noktalama işaretlerinden önceki gereksiz boşlukları sil (örn: "merhaba , nasılsın" -> "merhaba, nasılsın")
        res = replaceRegex(Self.punctuationSpaceRegex, in: res, with: "$1")

        // Çift virgül veya virgül-nokta hatalarını düzelt
        res = replaceRegex(Self.doubleCommaRegex, in: res, with: ",")
        res = replaceRegex(Self.commaDotRegex, in: res, with: ".")

        // Cümle başındaki yetim virgülleri temizle
        res = replaceRegex(Self.leadPunctuationRegex, in: res, with: "")

        return res.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func capitalizeFirstLetter(_ string: String) -> String {
        guard let first = string.first else { return "" }
        return String(first).uppercased(with: Locale(identifier: "tr_TR")) + string.dropFirst()
    }

    public func capitalizeSentences(_ string: String) -> String {
        let nsString = string as NSString
        let matches = Self.sentenceCapitalizeRegex.matches(in: string, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else {
            return capitalizeFirstLetter(string)
        }

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

    private func replaceRegex(_ regex: NSRegularExpression, in string: String, with replacement: String) -> String {
        let range = NSRange(location: 0, length: (string as NSString).length)
        return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: replacement)
    }
}
