import Foundation

// MARK: - Sağlayıcı Yetenekleri (Capabilities)

/// Her deşifre sağlayıcısının hangi yetenekleri desteklediğini bildirimsel
/// olarak tanımlar. Bu sayede arayüz katmanı hangi alanların gösterileceğine,
/// ses işleme hattının hangi yolu seçeceğine ve çağrı katmanının hangi
/// parametreleri gönderebileceğine tek bir kaynaktan karar verir.
///
/// Tasarım kaynağı: Speakr'ın `TranscriptionCapability` enum'u
/// (reference/speakr/src/services/transcription/base.py). Swift'te OptionSet
/// olarak modellendi; sağlayıcı başına bir bit maskesi tutulur.
public struct TranscriptionCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Gerçek zamanlı akış (WebSocket / canlı tanıma oturumu) destekler.
    public static let streaming = TranscriptionCapabilities(rawValue: 1 << 0)
    /// Tek seferlik dosya/tampon deşifresi destekler.
    public static let batch = TranscriptionCapabilities(rawValue: 1 << 1)
    /// Dili otomatik algılar; `language` alanı boş bırakılabilir.
    public static let languageDetection = TranscriptionCapabilities(rawValue: 1 << 2)
    /// Anahtar kelime/terim önyargısı (hotwords, keyterms, contextual strings).
    public static let hotwords = TranscriptionCapabilities(rawValue: 1 << 3)
    /// Serbest metin bağlam istemi (initial prompt / system instruction).
    public static let initialPrompt = TranscriptionCapabilities(rawValue: 1 << 4)
    /// Cihaz üzerinde (yerel) çalışır; ağa ses gönderilmez.
    public static let onDevice = TranscriptionCapabilities(rawValue: 1 << 5)
    /// API anahtarı gerektirir.
    public static let requiresAPIKey = TranscriptionCapabilities(rawValue: 1 << 6)
    /// Zaman damgalı segment çıktısı üretir.
    public static let timestamps = TranscriptionCapabilities(rawValue: 1 << 7)
}

// MARK: - Sağlayıcı Tanımı (Registry)

/// Sağlayıcının hangi API anahtarı alanını kullandığını belirtir.
/// `KeyPath<AppConfig, String>` Sendable olmadığı için enum tercih edildi;
/// bu sayede tanım Swift 6 dil modunda da geçerli kalır.
public enum ProviderAPIKeyKind: Sendable, Hashable {
    case none
    case groq
    case gemini
    case assemblyAI

    /// Bu anahtar türü için geçerli anahtarı döndürür (anahtar yoksa nil).
    public func value(in config: AppConfig) -> String? {
        switch self {
        case .none: return nil
        case .groq: return config.groq_api_key
        case .gemini: return config.gemini_api_key
        case .assemblyAI: return config.assemblyai_api_key
        }
    }
}

/// Bir deşifre sağlayıcısının statik tanımı. Sağlayıcılar bu tanım üzerinden
/// kaydedilir; çalışma zamanı kararları bu tanımdan türetilir.
public struct TranscriptionProviderDescriptor: Sendable, Hashable {
    /// `AppConfig.provider` ile eşleşen kimlik (örn. "apple", "groq").
    public let id: String
    /// Arayüzde gösterilen ad.
    public let displayName: String
    /// Hazırlık/uyarı mesajlarında kullanılan kısa ad. `displayName`'den ayrı
    /// tutulur çünkü menüdeki uyarı metinleri kısa biçimi kullanır.
    public let readinessShortName: String
    /// Yetenek bit maskesi.
    public let capabilities: TranscriptionCapabilities
    /// Kayıt başına ses işleme yolu tercihi.
    public let processingMode: RecordingAudioProcessingMode
    /// Bu sağlayıcının kullandığı API anahtarı alanı.
    public let apiKeyKind: ProviderAPIKeyKind

    public init(
        id: String,
        displayName: String,
        readinessShortName: String? = nil,
        capabilities: TranscriptionCapabilities,
        processingMode: RecordingAudioProcessingMode,
        apiKeyKind: ProviderAPIKeyKind = .none
    ) {
        self.id = id
        self.displayName = displayName
        self.readinessShortName = readinessShortName ?? displayName
        self.capabilities = capabilities
        self.processingMode = processingMode
        self.apiKeyKind = apiKeyKind
    }

    /// Bu sağlayıcı için geçerli API anahtarını döndürür (anahtar gerektirmiyorsa nil).
    public func apiKey(in config: AppConfig) -> String? {
        guard let raw = apiKeyKind.value(in: config) else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sağlayıcı API anahtarı gerektiriyor ama anahtar boş/eksik mi?
    public func isMissingAPIKey(in config: AppConfig) -> Bool {
        guard capabilities.contains(.requiresAPIKey) else { return false }
        return (apiKey(in: config) ?? "").isEmpty
    }
}

/// Sağlayıcı kayıt defteri. Tüm çalışma zamanı sağlayıcı kararları buradan
/// türetilir; `Transcriber`, `SettingsWindow` ve `UtteranceClarityEnhancer`
/// içindeki dağınık `provider == "..."` karşılaştırmalarının tek kaynağıdır.
public enum TranscriptionProviderRegistry {
    /// Varsayılan sağlayıcı kimliği.
    public static let defaultProviderID = "apple"

    public static let all: [TranscriptionProviderDescriptor] = [
        TranscriptionProviderDescriptor(
            id: "apple",
            displayName: "Apple Speech",
            capabilities: [.streaming, .batch, .languageDetection, .hotwords, .onDevice],
            processingMode: .realtimeBoost
        ),
        TranscriptionProviderDescriptor(
            id: "gemini",
            displayName: "Google Gemini",
            readinessShortName: "Gemini",
            capabilities: [.streaming, .batch, .languageDetection, .hotwords, .initialPrompt, .requiresAPIKey],
            processingMode: .realtimeBoost,
            apiKeyKind: .gemini
        ),
        TranscriptionProviderDescriptor(
            id: "groq",
            displayName: "Groq Whisper",
            readinessShortName: "Groq",
            capabilities: [.batch, .languageDetection, .hotwords, .requiresAPIKey],
            processingMode: .utteranceClarity,
            apiKeyKind: .groq
        ),
        TranscriptionProviderDescriptor(
            id: "assemblyai",
            displayName: "AssemblyAI Dictation",
            readinessShortName: "AssemblyAI",
            capabilities: [.batch, .languageDetection, .hotwords, .initialPrompt, .requiresAPIKey],
            processingMode: .utteranceClarity,
            apiKeyKind: .assemblyAI
        )
    ]

    /// Kimliğe göre sağlayıcı tanımı; bilinmeyen kimliklerde varsayılana düşer.
    public static func descriptor(for providerID: String) -> TranscriptionProviderDescriptor {
        let normalized = normalize(providerID)
        return all.first { $0.id == normalized }
            ?? all.first { $0.id == defaultProviderID }!
    }

    /// Sağlayıcı kimliğini normalize eder ve eski/kullanımdan kalkmış
    /// kimlikleri geçerli karşılıklarına eşler.
    ///
    /// Not: "openai" kimliği artık desteklenmiyor; eski yapılandırmalar
    /// Apple Speech'e düşürülür (Config katmanındaki mevcut davranış).
    public static func normalize(_ providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "openai" { return defaultProviderID }
        return all.contains { $0.id == trimmed } ? trimmed : defaultProviderID
    }

    /// Verilen sağlayıcının belirtilen yeteneği destekleyip desteklemediği.
    public static func supports(_ capability: TranscriptionCapabilities, providerID: String) -> Bool {
        descriptor(for: providerID).capabilities.contains(capability)
    }
}
