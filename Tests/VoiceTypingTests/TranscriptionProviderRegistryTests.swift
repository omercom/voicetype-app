import XCTest
@testable import VoiceTypingCore

/// `TranscriptionProviderRegistry` için birim testler.
///
/// Bu testler, dağınık `provider == "..."` karşılaştırmalarının yerine geçen
/// bildirimsel kayıt defterinin davranış sözleşmesini sabitler.
final class TranscriptionProviderRegistryTests: XCTestCase {

    // MARK: - Normalizasyon

    func testNormalizeMapsKnownProviderIDs() {
        XCTAssertEqual(TranscriptionProviderRegistry.normalize("apple"), "apple")
        XCTAssertEqual(TranscriptionProviderRegistry.normalize("gemini"), "gemini")
        XCTAssertEqual(TranscriptionProviderRegistry.normalize("groq"), "groq")
        XCTAssertEqual(TranscriptionProviderRegistry.normalize("assemblyai"), "assemblyai")
    }

    func testNormalizeIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(TranscriptionProviderRegistry.normalize("  GEMINI  "), "gemini")
        XCTAssertEqual(TranscriptionProviderRegistry.normalize("Groq"), "groq")
        XCTAssertEqual(TranscriptionProviderRegistry.normalize("AssemblyAI"), "assemblyai")
    }

    func testNormalizeFallsBackToDefaultForUnknownAndEmptyInput() {
        XCTAssertEqual(TranscriptionProviderRegistry.normalize(""), TranscriptionProviderRegistry.defaultProviderID)
        XCTAssertEqual(TranscriptionProviderRegistry.normalize("   "), TranscriptionProviderRegistry.defaultProviderID)
        XCTAssertEqual(TranscriptionProviderRegistry.normalize("not-a-provider"), TranscriptionProviderRegistry.defaultProviderID)
    }

    /// Eski yapılandırmalarda kalan "openai" kimliği Apple Speech'e düşer.
    /// Bu davranış ConfigManager ile aynı olmalıdır.
    func testNormalizeMapsDeprecatedOpenAIToDefault() {
        XCTAssertEqual(
            TranscriptionProviderRegistry.normalize("openai"),
            TranscriptionProviderRegistry.defaultProviderID
        )
    }

    // MARK: - Tanım Arama

    func testDescriptorForUnknownProviderReturnsDefault() {
        let descriptor = TranscriptionProviderRegistry.descriptor(for: "unknown")
        XCTAssertEqual(descriptor.id, TranscriptionProviderRegistry.defaultProviderID)
    }

    func testEveryRegisteredProviderHasConsistentID() {
        for descriptor in TranscriptionProviderRegistry.all {
            XCTAssertEqual(
                descriptor.id,
                TranscriptionProviderRegistry.normalize(descriptor.id),
                "Kayıtlı sağlayıcı kimliği kendi normalizasyonuyla eşleşmeli: \(descriptor.id)"
            )
            XCTAssertEqual(
                TranscriptionProviderRegistry.descriptor(for: descriptor.id).id,
                descriptor.id
            )
        }
    }

    func testProviderIDsAreUnique() {
        let ids = TranscriptionProviderRegistry.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Sağlayıcı kimlikleri benzersiz olmalı")
    }

    // MARK: - Yetenekler

    func testAppleSupportsStreamingAndOnDeviceButNeedsNoAPIKey() {
        let descriptor = TranscriptionProviderRegistry.descriptor(for: "apple")
        XCTAssertTrue(descriptor.capabilities.contains(.streaming))
        XCTAssertTrue(descriptor.capabilities.contains(.batch))
        XCTAssertTrue(descriptor.capabilities.contains(.onDevice))
        XCTAssertTrue(descriptor.capabilities.contains(.hotwords))
        XCTAssertFalse(descriptor.capabilities.contains(.requiresAPIKey))
    }

    func testGroqSupportsBatchOnlyAndRequiresAPIKey() {
        let descriptor = TranscriptionProviderRegistry.descriptor(for: "groq")
        XCTAssertTrue(descriptor.capabilities.contains(.batch))
        XCTAssertFalse(descriptor.capabilities.contains(.streaming))
        XCTAssertTrue(descriptor.capabilities.contains(.requiresAPIKey))
        XCTAssertTrue(descriptor.capabilities.contains(.hotwords))
    }

    func testGeminiSupportsStreamingAndInitialPrompt() {
        let descriptor = TranscriptionProviderRegistry.descriptor(for: "gemini")
        XCTAssertTrue(descriptor.capabilities.contains(.streaming))
        XCTAssertTrue(descriptor.capabilities.contains(.initialPrompt))
    }

    func testSupportsHelperAgreesWithDescriptorCapabilities() {
        XCTAssertTrue(TranscriptionProviderRegistry.supports(.streaming, providerID: "apple"))
        XCTAssertFalse(TranscriptionProviderRegistry.supports(.streaming, providerID: "groq"))
        XCTAssertTrue(TranscriptionProviderRegistry.supports(.hotwords, providerID: "assemblyai"))
    }

    // MARK: - İşleme Modu

    func testProcessingModesMatchProviderAudioConsumption() {
        XCTAssertEqual(TranscriptionProviderRegistry.descriptor(for: "apple").processingMode, .realtimeBoost)
        XCTAssertEqual(TranscriptionProviderRegistry.descriptor(for: "groq").processingMode, .utteranceClarity)
        XCTAssertEqual(TranscriptionProviderRegistry.descriptor(for: "assemblyai").processingMode, .utteranceClarity)
    }

    /// Sağlayıcı kaydındaki işleme modu ile `RecordingAudioProcessingMode.resolve`
    /// aynı sonucu vermelidir; ikisi ayrışırsa ses işleme hattı sessizce yanlış
    /// yola sapar.
    func testResolveMatchesRegistryForNonGeminiProviders() {
        for descriptor in TranscriptionProviderRegistry.all where descriptor.id != "gemini" {
            var config = AppConfig.defaultConfig
            config.provider = descriptor.id
            config.enable_microphone_boost = true
            XCTAssertEqual(
                RecordingAudioProcessingMode.resolve(config: config),
                descriptor.processingMode,
                "\(descriptor.id) için işleme modu kayıt defteriyle eşleşmeli"
            )
        }
    }

    func testResolveReturnsNoneWhenMicrophoneBoostDisabled() {
        var config = AppConfig.defaultConfig
        config.provider = "groq"
        config.enable_microphone_boost = false
        XCTAssertEqual(RecordingAudioProcessingMode.resolve(config: config), .none)
    }

    func testResolveReturnsNoneForUnknownProviderWhenBoostDisabled() {
        var config = AppConfig.defaultConfig
        config.provider = "not-a-provider"
        config.enable_microphone_boost = false
        XCTAssertEqual(RecordingAudioProcessingMode.resolve(config: config), .none)
    }

    // MARK: - API Anahtarı Erişimi

    func testAPIKeyLookupReadsCorrectConfigField() {
        var config = AppConfig.defaultConfig
        config.groq_api_key = "  groq-key  "
        config.gemini_api_key = "gemini-key"
        config.assemblyai_api_key = "assembly-key"

        XCTAssertEqual(
            TranscriptionProviderRegistry.descriptor(for: "groq").apiKey(in: config),
            "groq-key",
            "Anahtar döndürülürken boşluklar kırpılmalı"
        )
        XCTAssertEqual(TranscriptionProviderRegistry.descriptor(for: "gemini").apiKey(in: config), "gemini-key")
        XCTAssertEqual(
            TranscriptionProviderRegistry.descriptor(for: "assemblyai").apiKey(in: config),
            "assembly-key"
        )
    }

    /// Apple yerel çalışır; hiçbir API anahtarı alanına bağlı olmamalıdır.
    func testAppleHasNoAPIKeyBinding() {
        var config = AppConfig.defaultConfig
        config.groq_api_key = "groq-key"
        config.gemini_api_key = "gemini-key"
        config.assemblyai_api_key = "assembly-key"
        XCTAssertNil(TranscriptionProviderRegistry.descriptor(for: "apple").apiKey(in: config))
    }

    func testEmptyAPIKeyReturnsEmptyStringNotNil() {
        var config = AppConfig.defaultConfig
        config.groq_api_key = "   "
        let key = TranscriptionProviderRegistry.descriptor(for: "groq").apiKey(in: config)
        XCTAssertEqual(key, "", "Boşluklardan oluşan anahtar boş dizeye kırpılmalı")
    }

    // MARK: - İşleme Modu Tipi

    func testProcessingModeRawValuesAreStable() {
        // Ham değerler disk üzerindeki yapılandırmada veya günlüklerde
        // görünebilir; sessizce değişmemeleri gerekir.
        XCTAssertEqual(RecordingAudioProcessingMode.none.rawValue, "none")
        XCTAssertEqual(RecordingAudioProcessingMode.realtimeBoost.rawValue, "realtimeBoost")
        XCTAssertEqual(RecordingAudioProcessingMode.utteranceClarity.rawValue, "utteranceClarity")
    }

    // MARK: - Özel Sözlük Ayrıştırma

    func testVocabularyParserSplitsOnAllSeparators() {
        let terms = CustomVocabularyParser.terms(from: "Swift, SwiftPM; Xcode\nInstruments")
        XCTAssertEqual(terms, ["Swift", "SwiftPM", "Xcode", "Instruments"])
    }

    func testVocabularyParserTrimsAndDropsEmptyEntries() {
        let terms = CustomVocabularyParser.terms(from: "  Swift  , ,, \n SwiftPM \n")
        XCTAssertEqual(terms, ["Swift", "SwiftPM"])
    }

    func testVocabularyParserDeduplicatesCaseInsensitively() {
        let terms = CustomVocabularyParser.terms(from: "Swift, swift, SWIFT, Xcode")
        XCTAssertEqual(terms, ["Swift", "Xcode"])
    }

    func testVocabularyParserReturnsEmptyForBlankInput() {
        XCTAssertTrue(CustomVocabularyParser.terms(from: "").isEmpty)
        XCTAssertTrue(CustomVocabularyParser.terms(from: "   \n , ; ").isEmpty)
    }

    func testVocabularyParserRespectsLimit() {
        let input = (0..<250).map { "terim\($0)" }.joined(separator: ",")
        XCTAssertEqual(CustomVocabularyParser.terms(from: input).count, CustomVocabularyParser.maximumTermCount)
        XCTAssertEqual(CustomVocabularyParser.terms(from: input, limit: 5).count, 5)
    }

    /// AssemblyAI keyterms ayrıştırması ortak yardımcıyı kullanmalı; ikisi
    /// ayrışırsa Apple ve AssemblyAI aynı sözlükten farklı terimler gönderir.
    func testAssemblyAIKeytermsMatchSharedParser() {
        let vocabulary = "Swift, swift;Xcode"
        XCTAssertEqual(
            AssemblyAIDictation.parsedKeyterms(vocabulary),
            CustomVocabularyParser.terms(from: vocabulary)
        )
    }

    // MARK: - Gemini Sistem İstemi Çözümlemesi

    func testResolvedPromptLeavesStaticPromptUnchanged() {
        var config = AppConfig.defaultConfig
        config.gemini_system_prompt = "Sadece konuşulan metni yaz."
        XCTAssertEqual(config.resolvedGeminiSystemPrompt(), "Sadece konuşulan metni yaz.")
    }

    func testResolvedPromptFallsBackToDefaultWhenEmpty() {
        var config = AppConfig.defaultConfig
        config.gemini_system_prompt = "   "
        XCTAssertEqual(config.resolvedGeminiSystemPrompt(), AppConfig.defaultGeminiSystemPrompt)
    }

    func testResolvedPromptSubstitutesVocabularyAndLanguage() {
        var config = AppConfig.defaultConfig
        config.language = "tr"
        config.custom_vocabulary = "Swift, Xcode"
        config.gemini_system_prompt = "Dil: {{dil}}. Terimler: {{sozluk}}."
        let resolved = config.resolvedGeminiSystemPrompt()
        XCTAssertEqual(resolved, "Dil: tr. Terimler: Swift, Xcode.")
    }

    /// Gemini'de ayrı hotword alanı olmadığı için özel sözlük yalnızca sistem
    /// istemi üzerinden modele ulaşabilir; bu test o yolun çalıştığını gösterir.
    func testResolvedPromptDeliversVocabularyToGemini() {
        var config = AppConfig.defaultConfig
        config.custom_vocabulary = "Kubernetes"
        config.gemini_system_prompt = "Terimler: {{sozluk}}"
        XCTAssertTrue(config.resolvedGeminiSystemPrompt().contains("Kubernetes"))
    }

    func testResolvedPromptResolvesProviderDisplayName() {
        var config = AppConfig.defaultConfig
        config.provider = "gemini"
        config.gemini_system_prompt = "Sağlayıcı: {{saglayici}}"
        XCTAssertEqual(config.resolvedGeminiSystemPrompt(), "Sağlayıcı: Google Gemini")
    }

    func testResolvedPromptSubstitutesTargetContextVariables() {
        var config = AppConfig.defaultConfig
        config.gemini_system_prompt = "Uygulama: {{uygulama}}, Profil: {{profil}}, Paket: {{bundle_id}}, Rol: {{rol}}."

        // Mock bir element ve TargetContext oluştur
        let dummyElement = AXUIElementCreateSystemWide()
        let context = TargetContext(
            pid: 1234,
            bundleIdentifier: "com.apple.dt.Xcode",
            appName: "Xcode",
            runningApp: nil,
            element: dummyElement,
            window: nil,
            role: "AXTextArea"
        )

        let resolved = config.resolvedGeminiSystemPrompt(targetContext: context)
        XCTAssertTrue(resolved.contains("Uygulama: Xcode"))
        XCTAssertTrue(resolved.contains("Profil: codeEditor"))
        XCTAssertTrue(resolved.contains("Paket: com.apple.dt.Xcode"))
        XCTAssertTrue(resolved.contains("Rol: AXTextArea"))
        XCTAssertFalse(resolved.contains("{{"))
    }
}
