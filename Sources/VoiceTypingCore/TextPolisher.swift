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

    private static let questionParticlesRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(mı|mi|mu|mü|mısın|misin|musun|müsün|mıyız|miyiz|kaçta|nasıl|nedir|nerede|nereden|kim|kimin|hangisi|ne zaman|niçin|neden|acaba)\b"#
    )
    private static let codeCommandPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)\b(npm\s+(?:run\s+\w+|install|test|build|start|dev))\b"#),
        try! NSRegularExpression(pattern: #"(?i)\b(git\s+(?:commit|push|pull|checkout|status|diff|stash|rebase|merge))\b"#),
        try! NSRegularExpression(pattern: #"(?i)\b(docker(?:-compose)?\s+(?:up|down|build|run|ps|exec))\b"#),
        try! NSRegularExpression(pattern: #"(?i)\b(cargo\s+(?:build|run|test|check))\b"#)
    ]

    private static let thinkBlockRegex = try! NSRegularExpression(
        pattern: #"(?is)<think>.*?(?:</think>|$)"#
    )
    private static let thoughtBlockRegex = try! NSRegularExpression(
        pattern: #"(?is)<thought>.*?(?:</thought>|$)"#
    )

    private init() {}

    /// Metni aktif ayarlara, hedef uygulamaya ve dikte moduna göre temizler ve biçimlendirir
    public func polish(text: String, config: AppConfig, targetContext: TargetContext? = nil) -> String {
        // 0. Düşünme Modeli (<think>...</think>) ve Görünmez Karakterleri Temizle
        var processed = Self.stripThinkingAndInvisibleChars(text)
        guard !processed.isEmpty else { return "" }

        // 1. Dolgu Kelimeleri ve Kekeleme Temizleme (Filler & Stutter Removal)
        if config.remove_filler_words {
            processed = removeFillerWords(from: processed)
            processed = removeStutterRepetitions(from: processed)
        }

        // 2. Sesli Kısayollar ve Metin Genişletici (Voice Snippets)
        if !config.voice_snippets.isEmpty {
            processed = VoiceSnippetExpander.shared.expand(text: processed, snippets: config.voice_snippets)
        }

        // 3. Özel Sözlük & Terim Eşleme (Custom Vocabulary - Exact & Fuzzy)
        if !config.custom_vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            processed = applyCustomVocabulary(text: processed, vocabularyString: config.custom_vocabulary)
        }

        // 4. Kod ve CLI Komutları Algılama (Terminal ve kod editörü hariç; markdown/sohbet/belge için)
        let isCodeOrTerminalTarget: Bool
        if let target = targetContext {
            let cat = AppProfileFormatter.shared.detectCategory(bundleIdentifier: target.bundleIdentifier, appName: target.appName)
            isCodeOrTerminalTarget = (cat == .terminal || cat == .codeEditor)
        } else {
            isCodeOrTerminalTarget = false
        }

        if !isCodeOrTerminalTarget {
            for regex in Self.codeCommandPatterns {
                processed = replaceRegex(regex, in: processed, with: "`$1`")
            }
        }

        // 5. Temel boşluk ve noktalama temizliği
        processed = cleanWhitespaceAndPunctuation(text: processed)

        // 6. Akıllı Soru Tespiti (Cümle soru ise ve sonunda noktalama yoksa ? ekle)
        let range = NSRange(location: 0, length: (processed as NSString).length)
        if Self.questionParticlesRegex.firstMatch(in: processed, options: [], range: range) != nil {
            if let last = processed.last, !".?!".contains(last) {
                processed.append("?")
            }
        }

        // 7. Dikte Modu Katmanı (Dictation Mode: Direct / Formal / Bullet)
        switch config.dictation_mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "formal", "resmi":
            processed = formatFormal(text: processed)
        case "bullet", "madde", "not":
            processed = formatBulletPoints(text: processed)
        default:
            break // "direct" veya varsayılan: doğrudan saf deşifre akışı korunur
        }

        // 8. Uygulamaya Özel Akıllı Biçimlendirme (Target App Profile Formatter - Tag Stacking)
        if config.enable_app_profiles {
            processed = AppProfileFormatter.shared.format(text: processed, targetContext: targetContext)
        }

        return processed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Geriye dönük uyumluluk için targetContext almayan overload
    public func polish(text: String, config: AppConfig) -> String {
        return polish(text: text, config: config, targetContext: nil)
    }

    // MARK: - Düşünme Modeli ve Görünmez Karakter Temizleme

    /// Akıl yürütme (reasoning/thinking) modellerinin ürettiği <think>...</think> etiketlerini ve
    /// sıfır genişlikli görünmez Unicode karakterleri temizler.
    public static func stripThinkingAndInvisibleChars(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var result = text

        // 1. <think> ve <thought> bloklarını temizle
        let range1 = NSRange(location: 0, length: (result as NSString).length)
        result = thinkBlockRegex.stringByReplacingMatches(in: result, options: [], range: range1, withTemplate: "")

        let range2 = NSRange(location: 0, length: (result as NSString).length)
        result = thoughtBlockRegex.stringByReplacingMatches(in: result, options: [], range: range2, withTemplate: "")

        // 2. Sıfır genişlikli görünmez karakterleri temizle (ZWSP, ZWNJ, ZWJ, BOM, Soft Hyphen)
        let invisibleChars = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}"]
        for char in invisibleChars {
            result = result.replacingOccurrences(of: char, with: "")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Levenshtein ve Bulanık Eşleme Yardımcıları

    /// İki metin arasındaki Levenshtein düzenleme mesafesini (edit distance) O(min(m,n)) bellek karmaşıklığıyla hesaplar
    public static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count
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

    /// Kelimenin başındaki ve sonundaki noktalama işaretlerini ayırır
    public static func extractPunctuation(_ word: String) -> (prefix: String, core: String, suffix: String) {
        guard !word.isEmpty else { return ("", "", "") }

        guard let firstAlphaNum = word.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let lastAlphaNum = word.lastIndex(where: { $0.isLetter || $0.isNumber }) else {
            return ("", "", word)
        }

        let prefix = String(word[..<firstAlphaNum])
        let core = String(word[firstAlphaNum...lastAlphaNum])
        let suffixStart = word.index(after: lastAlphaNum)
        let suffix = String(word[suffixStart...])

        return (prefix, core, suffix)
    }

    // MARK: - Dolgu Kelimeleri ve Kekeleme Temizleme

    public func removeStutterRepetitions(from input: String) -> String {
        let tokens = input.components(separatedBy: " ")
        guard tokens.count > 1 else { return input }
        var cleaned: [String] = []
        var prevNormalized = ""
        for token in tokens {
            let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;\"'()[]{}")).lowercased(with: Locale(identifier: "tr_TR"))
            if !normalized.isEmpty && normalized == prevNormalized && normalized.count > 1 {
                // Türkçe CLI diktesinde "tire tire" (--) meşru bayrak belirtecidir; kekeleme değildir
                if normalized == "tire" {
                    cleaned.append(token)
                    prevNormalized = ""
                    continue
                }
                continue // Mükerrer kekeleme kelimesini atla
            }
            cleaned.append(token)
            if !normalized.isEmpty {
                prevNormalized = normalized
            }
        }
        return cleaned.joined(separator: " ")
    }

    private static let standaloneFillersRegex = try! NSRegularExpression(
        pattern: #"(?i)\b([şŞsS]ey|[şŞsS]eyler|yani|well|like|you know|falan|filan|hani)\b"#
    )

    public func removeFillerWords(from input: String) -> String {
        var result = input

        // 1. Saf duraksama sesleri (Türkçe & İngilizce ses öbekleri)
        result = replaceRegex(Self.hesitationRegex, in: result, with: "")

        // 2. Cümle başı dolgu kelimeleri (örn: "Şey, bugün...", "Yani, aslında...")
        result = replaceRegex(Self.startFillersRegex, in: result, with: "")

        // 3. Virgül veya duraksama ile çevrelenmiş ara dolgu kelimeleri (örn: ", şey,", ", yani,")
        result = replaceRegex(Self.midFillersRegex, in: result, with: ", ")

        // 4. Metin içinde bağımsız duran dolgu kelimeleri
        result = replaceRegex(Self.standaloneFillersRegex, in: result, with: "")

        // 5. Noktalama ve boşluk temizliği
        result = cleanWhitespaceAndPunctuation(text: result)

        // 6. İlk harfi büyük yap (özellikle cümle başındaki dolgu temizlendiyse)
        result = capitalizeFirstLetter(result)

        return result
    }

    // MARK: - Özel Sözlük / Terim Eşleme

    public func applyCustomVocabulary(text: String, vocabularyString: String) -> String {
        let terms = vocabularyString
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return text }

        var result = text

        // 1. Aşama: Tam Regex Eşleşmesi (Büyük/küçük harf duyarsız, tüm terimler ve çok kelimeli ifadeler için)
        // Örn: "Next.js", "MacBook Pro", "PostgreSQL"
        for term in terms {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let pattern = #"(?i)\b\#(escaped)\b"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = replaceRegex(regex, in: result, with: term)
            }
        }

        // 2. Aşama: Bulanık Eşleme (Fuzzy Matching - Levenshtein Mesafesi)
        // Kullanıcı sözlüğe "Antigravity" eklediğinde model "antigraviti" veya "antigrafiti" yazsa bile
        // Levenshtein mesafesiyle bunu otomatik olarak "Antigravity" formatına getirir.
        let singleWordTerms = terms.filter { !$0.contains(" ") && $0.count >= 4 }
        guard !singleWordTerms.isEmpty else { return result }

        let trLocale = Locale(identifier: "tr_TR")
        var processedLines: [String] = []

        for line in result.components(separatedBy: "\n") {
            let words = line.components(separatedBy: " ")
            var correctedWords: [String] = []
            var i = 0

            while i < words.count {
                let word1 = words[i]
                let (prefix1, core1, suffix1) = Self.extractPunctuation(word1)

                // 2A. İki kelimelik n-gram birleşimi kontrolü (örn: model "anti gravity" yazmışsa -> "Antigravity")
                if i + 1 < words.count && suffix1.isEmpty {
                    let word2 = words[i + 1]
                    let (prefix2, core2, suffix2) = Self.extractPunctuation(word2)
                    if prefix2.isEmpty && !core1.isEmpty && !core2.isEmpty {
                        let combined = core1 + core2
                        if combined.count >= 5 {
                            let lowerCombined = combined.lowercased(with: trLocale)
                            var bestGramTerm: String? = nil
                            var bestGramDist = Int.max

                            for term in singleWordTerms {
                                let maxLen = max(combined.count, term.count)
                                guard abs(combined.count - term.count) <= 2 else { continue }
                                let lowerTerm = term.lowercased(with: trLocale)
                                let dist = Self.levenshteinDistance(lowerCombined, lowerTerm)

                                let maxAllowedDist = maxLen >= 9 ? 2 : 1
                                if dist <= maxAllowedDist && Double(dist) / Double(maxLen) <= 0.28 {
                                    if dist < bestGramDist {
                                        bestGramDist = dist
                                        bestGramTerm = term
                                    }
                                }
                            }

                            if let matched = bestGramTerm {
                                correctedWords.append("\(prefix1)\(matched)\(suffix2)")
                                i += 2
                                continue
                            }
                        }
                    }
                }

                // 2B. Tekil kelime bulanık eşleme (örn: "antigraviti" veya "antigrafiti" -> "Antigravity")
                if !core1.isEmpty {
                    var baseStem = core1
                    var apostropheSuffix = ""
                    if let apostropheIndex = core1.firstIndex(where: { $0 == "'" || $0 == "’" }) {
                        baseStem = String(core1[..<apostropheIndex])
                        apostropheSuffix = String(core1[apostropheIndex...])
                    }

                    if baseStem.count >= 4 {
                        let lowerBaseStem = baseStem.lowercased(with: trLocale)
                        var bestMatchTerm: String? = nil
                        var bestDistance = Int.max

                        for term in singleWordTerms {
                            let maxLen = max(baseStem.count, term.count)
                            let lenDiff = abs(baseStem.count - term.count)
                            guard lenDiff <= 2 else { continue }

                            let maxAllowedDistance: Int
                            switch maxLen {
                            case 4...5:
                                maxAllowedDistance = 1
                            case 6...9:
                                maxAllowedDistance = 2
                            default:
                                maxAllowedDistance = 3
                            }

                            let lowerTerm = term.lowercased(with: trLocale)
                            let dist = Self.levenshteinDistance(lowerBaseStem, lowerTerm)

                            if dist <= maxAllowedDistance && Double(dist) / Double(maxLen) <= 0.35 {
                                if dist < bestDistance {
                                    bestDistance = dist
                                    bestMatchTerm = term
                                }
                            }
                        }

                        if let matched = bestMatchTerm {
                            correctedWords.append("\(prefix1)\(matched)\(apostropheSuffix)\(suffix1)")
                            i += 1
                            continue
                        }
                    }
                }

                correctedWords.append(word1)
                i += 1
            }

            processedLines.append(correctedWords.joined(separator: " "))
        }

        return processedLines.joined(separator: "\n")
    }

    // MARK: - Dikte Modları (Biçimlendirme)

    /// Profesyonel / E-posta Modu: Dilbilgisi, büyük harf ve net cümle bitişleri
    public func formatFormal(text: String) -> String {
        let stripped = Self.stripThinkingAndInvisibleChars(text)
        var cleaned = cleanWhitespaceAndPunctuation(text: stripped)
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
        let stripped = Self.stripThinkingAndInvisibleChars(text)
        let cleaned = cleanWhitespaceAndPunctuation(text: stripped)
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

    // MARK: - Akıllı Boşluk (Smart Spacing)

    private static let endsWithCJKRegex = try! NSRegularExpression(
        pattern: #"[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\u3000-\u303f\uff00-\uff65\ufe10-\ufe1f\ufe30-\ufe4f]$"#,
        options: []
    )

    /// Paste-time smart spacing: Metin sonuna akıllı boşluk ekler.
    /// Peş peşe yapılan diktelerde kelimelerin birbirine yapışmasını (örn: "merhabanasılsın") önler.
    public static func applySmartSpacing(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        if let last = text.last, last.isWhitespace || last.isNewline {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        if endsWithCJKRegex.firstMatch(in: text, options: [], range: range) != nil {
            return text
        }
        return text + " "
    }
}
