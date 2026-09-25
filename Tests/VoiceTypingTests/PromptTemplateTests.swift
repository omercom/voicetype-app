import XCTest
@testable import VoiceTypingCore

/// `PromptTemplate` için birim testler.
///
/// Bu testler özellikle güvenlik sınırlarını doğrular: değişken sayısı, değer
/// uzunluğu ve toplam istem boyutu. Bu sınırlar olmadan büyük bir özel sözlük
/// veya uzun bir pencere başlığı istemi kontrolsüzce büyütebilir.
final class PromptTemplateTests: XCTestCase {

    // MARK: - Değişken Çıkarımı

    func testExtractVariablesReturnsUniqueNamesInOrder() {
        let template = "Merhaba {{isim}}, {{konu}} hakkında {{isim}} için not."
        XCTAssertEqual(PromptTemplate.extractVariables(from: template), ["isim", "konu"])
    }

    func testExtractVariablesHandlesInnerWhitespace() {
        XCTAssertEqual(PromptTemplate.extractVariables(from: "{{  bosluklu  }}"), ["bosluklu"])
    }

    func testExtractVariablesReturnsEmptyForTemplateWithoutPlaceholders() {
        XCTAssertTrue(PromptTemplate.extractVariables(from: "Statik istem metni.").isEmpty)
        XCTAssertTrue(PromptTemplate.extractVariables(from: "").isEmpty)
    }

    func testExtractVariablesIgnoresMalformedPlaceholders() {
        // Tek parantez, boşluklu ad, rakamla başlayan ad geçersiz sayılır.
        let template = "{isim} {{}} {{ bos isim }} {{1rakam}} {{gecerli_1}}"
        XCTAssertEqual(PromptTemplate.extractVariables(from: template), ["gecerli_1"])
    }

    // MARK: - Çözümleme

    func testRenderSubstitutesValues() {
        let rendered = PromptTemplate.render(
            "Merhaba {{isim}}, bugün {{gun}}.",
            values: ["isim": "Ömer", "gun": "perşembe"]
        )
        XCTAssertEqual(rendered, "Merhaba Ömer, bugün perşembe.")
    }

    func testRenderReplacesMissingVariableWithEmptyString() {
        let rendered = PromptTemplate.render("A{{eksik}}B", values: [:])
        XCTAssertEqual(rendered, "AB", "Eksik değişken boş dizeye çözülmeli")
    }

    func testRenderWithoutPlaceholdersReturnsTrimmedTemplate() {
        XCTAssertEqual(PromptTemplate.render("  sadece metin  ", values: ["x": "y"]), "sadece metin")
    }

    func testRenderIgnoresValueForUndeclaredVariable() {
        let rendered = PromptTemplate.render("{{a}}", values: ["a": "bir", "b": "iki"])
        XCTAssertEqual(rendered, "bir")
    }

    // MARK: - Güvenlik Sınırları

    func testSanitizeEnforcesMaxVariables() {
        var values: [String: String] = [:]
        for index in 0..<(PromptTemplate.maxVariables + 20) {
            values["degisken_\(index)"] = "d"
        }
        let sanitized = PromptTemplate.sanitize(values)
        XCTAssertEqual(sanitized.count, PromptTemplate.maxVariables)
    }

    func testSanitizeClampsIndividualValueLength() {
        let longValue = String(repeating: "a", count: PromptTemplate.maxValueCharacters + 5000)
        let sanitized = PromptTemplate.sanitize(["uzun": longValue])
        XCTAssertEqual(sanitized["uzun"]?.count, PromptTemplate.maxValueCharacters)
    }

    func testSanitizeEnforcesTotalCharacterBudget() {
        // Her biri 8000 karakter olan değişkenlerden toplam sınır yalnızca
        // dördüne izin verir (4 * 8000 = 32000).
        let chunk = String(repeating: "a", count: PromptTemplate.maxValueCharacters)
        var values: [String: String] = [:]
        for index in 0..<10 { values["k\(index)"] = chunk }

        let sanitized = PromptTemplate.sanitize(values)
        let total = sanitized.values.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, PromptTemplate.maxTotalCharacters)
        XCTAssertEqual(total, PromptTemplate.maxTotalCharacters)
    }

    func testSanitizeTrimsValuesAndDropsEmptyOnes() {
        let sanitized = PromptTemplate.sanitize([
            "bosluklu": "  deger  ",
            "bos": "     ",
            "bosDize": ""
        ])
        XCTAssertEqual(sanitized["bosluklu"], "deger")
        XCTAssertNil(sanitized["bos"], "Yalnızca boşluk içeren değer atılmalı")
        XCTAssertNil(sanitized["bosDize"])
    }

    func testSanitizeRejectsInvalidVariableNames() {
        let sanitized = PromptTemplate.sanitize([
            "gecerli": "a",
            "1rakamla": "b",
            "bosluk var": "c",
            "tire-li": "d",
            "_altcizgi": "e"
        ])
        XCTAssertEqual(Set(sanitized.keys), ["gecerli", "_altcizgi"])
    }

    func testRenderOutputNeverExceedsTotalCharacterBudget() {
        let huge = String(repeating: "x", count: PromptTemplate.maxValueCharacters)
        let rendered = PromptTemplate.render("{{a}}{{b}}", values: ["a": huge, "b": huge])
        XCTAssertLessThanOrEqual(rendered.count, PromptTemplate.maxTotalCharacters)
    }

    /// Sözlük sırası çalıştırmalar arasında değişebildiği için sanitizasyon
    /// deterministik olmalıdır; aksi halde toplam sınıra takılan değişken
    /// belirsizleşir ve istem kararsız hale gelir.
    func testSanitizeIsDeterministicRegardlessOfDictionaryOrder() {
        var values: [String: String] = [:]
        for index in 0..<10 {
            values["k\(index)"] = String(repeating: "a", count: PromptTemplate.maxValueCharacters)
        }
        let first = PromptTemplate.sanitize(values)
        let second = PromptTemplate.sanitize(values.shuffled().reduce(into: [:]) { $0[$1.key] = $1.value })
        XCTAssertEqual(Set(first.keys), Set(second.keys))
    }

    // MARK: - Ad Doğrulama

    func testIsValidVariableName() {
        XCTAssertTrue(PromptTemplate.isValidVariableName("isim"))
        XCTAssertTrue(PromptTemplate.isValidVariableName("_gizli"))
        XCTAssertTrue(PromptTemplate.isValidVariableName("isim2"))
        XCTAssertFalse(PromptTemplate.isValidVariableName(""))
        XCTAssertFalse(PromptTemplate.isValidVariableName("2isim"))
        XCTAssertFalse(PromptTemplate.isValidVariableName("isim-2"))
        XCTAssertFalse(PromptTemplate.isValidVariableName("isim 2"))
    }

    // MARK: - Uçtan Uca

    /// Tipik kullanım: kullanıcı sistem istemine bağlam değişkenleri koyar.
    func testRealisticSystemPromptRendering() {
        let template = """
        Kullanıcı {{uygulama}} uygulamasında dikte yapıyor. Dil: {{dil}}. \
        Terimler: {{sozluk}}. Sadece konuşulan metni yaz.
        """
        let rendered = PromptTemplate.render(template, values: [
            "uygulama": "Xcode",
            "dil": "tr",
            "sozluk": "Swift, SwiftPM"
        ])
        XCTAssertTrue(rendered.contains("Xcode uygulamasında"))
        XCTAssertTrue(rendered.contains("Dil: tr"))
        XCTAssertTrue(rendered.contains("Terimler: Swift, SwiftPM"))
        XCTAssertFalse(rendered.contains("{{"))
        XCTAssertFalse(rendered.contains("}}"))
    }
}
