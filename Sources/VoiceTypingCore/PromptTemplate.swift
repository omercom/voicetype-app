import Foundation

/// Sistem istemlerinde `{{degisken}}` yer tutucularını çözer.
///
/// Tasarım kaynağı: Speakr'ın `prompt_variables.py` modülü
/// (reference/speakr/src/utils/prompt_variables.py). Oradaki güvenlik
/// sınırları (değişken sayısı, değer uzunluğu, toplam uzunluk) aynen
/// korunmuştur; amaç istemin kontrolsüz büyümesini ve kullanıcı girdisinin
/// istemi boğmasını engellemektir.
public enum PromptTemplate {
    /// Tek bir istemde tanımlanabilecek en fazla değişken sayısı.
    public static let maxVariables = 50
    /// Tek bir değişken değerinin en fazla karakter sayısı.
    public static let maxValueCharacters = 8000
    /// Çözümleme sonrası istemin en fazla karakter sayısı.
    public static let maxTotalCharacters = 32000

    /// `{{isim}}` biçimindeki yer tutucuları yakalar. Değişken adı harf veya
    /// alt çizgi ile başlar; yalnızca harf, rakam ve alt çizgi içerebilir.
    private static let variablePattern = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}"#
    )

    /// İstemde geçen benzersiz değişken adlarını, ilk görülme sırasına göre döndürür.
    public static func extractVariables(from template: String) -> [String] {
        guard !template.isEmpty else { return [] }
        let range = NSRange(location: 0, length: (template as NSString).length)
        let matches = variablePattern.matches(in: template, options: [], range: range)

        var seen = Set<String>()
        var ordered: [String] = []
        for match in matches {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: template) else { continue }
            let name = String(template[nameRange])
            if seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }

    /// İstemdeki yer tutucuları verilen değerlerle değiştirir.
    ///
    /// Değeri sağlanmayan değişkenler boş dizeye çözülür ve istemde boşluk
    /// kalmasın diye çevresindeki fazla boşluk temizlenir.
    public static func render(_ template: String, values: [String: String]) -> String {
        guard !template.isEmpty else { return "" }

        let sanitized = sanitize(values)
        let range = NSRange(location: 0, length: (template as NSString).length)

        let rendered = variablePattern.stringByReplacingMatches(
            in: template,
            options: [],
            range: range
        ) { match, template in
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: template) else { return "" }
            let name = String(template[nameRange])
            return sanitized[name] ?? ""
        }

        return String(rendered.prefix(maxTotalCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Değer sözlüğünü sınırlara göre temizler: geçersiz adları atar, değerleri
    /// kısaltır ve toplam boyutu sınırlar.
    public static func sanitize(_ values: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        var totalCharacters = 0

        // Deterministik davranış için anahtarları sıralı işle; sözlük sırası
        // çalıştırmalar arasında değişebilir ve toplam sınıra takılan
        // değişkenin hangisi olacağını belirsizleştirir.
        for key in values.keys.sorted() {
            guard result.count < maxVariables else { break }
            guard isValidVariableName(key) else { continue }

            let value = values[key] ?? ""
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let clamped = String(trimmed.prefix(maxValueCharacters))
            guard totalCharacters + clamped.count <= maxTotalCharacters else { break }

            totalCharacters += clamped.count
            result[key] = clamped
        }

        return result
    }

    /// Değişken adının geçerli olup olmadığı (harf/alt çizgi ile başlar).
    public static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

private extension NSRegularExpression {
    /// Eşleşmeleri bir dönüşüm bloğuyla değiştirir. `stringByReplacingMatches`
    /// yalnızca statik şablon dizeleri kabul ettiği için bu yardımcı gerekir.
    func stringByReplacingMatches(
        in string: String,
        options: NSRegularExpression.MatchingOptions,
        range: NSRange,
        transform: (NSTextCheckingResult, String) -> String
    ) -> String {
        let matches = self.matches(in: string, options: options, range: range)
        guard !matches.isEmpty else { return string }

        let result = NSMutableString(string: string)
        // Sondan başa doğru değiştir; böylece önceki eşleşmelerin konumları kaymaz.
        for match in matches.reversed() {
            let replacement = transform(match, string)
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }
}
