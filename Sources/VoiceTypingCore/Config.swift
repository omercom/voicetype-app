import Foundation

public struct ModelOption: Identifiable, Codable {
    public var id: String
    public var name: String
    public var price: String
    public var speed: String

    public init(id: String, name: String, price: String, speed: String) {
        self.id = id
        self.name = name
        self.price = price
        self.speed = speed
    }
}

public struct TriggerKeyOption: Identifiable, Equatable {
    public var id: Int { return keyCode }
    public var keyCode: Int
    public var name: String
    public var shortName: String
    public var isModifier: Bool

    public init(keyCode: Int, name: String, shortName: String, isModifier: Bool) {
        self.keyCode = keyCode
        self.name = name
        self.shortName = shortName
        self.isModifier = isModifier
    }

    public static let standardKeys: [TriggerKeyOption] = [
        TriggerKeyOption(keyCode: 54, name: "Sağ Command (Right ⌘) - Varsayılan", shortName: "Sağ Cmd", isModifier: true),
        TriggerKeyOption(keyCode: 58, name: "Sol Option (Left ⌥)", shortName: "Sol Option", isModifier: true),
        TriggerKeyOption(keyCode: 61, name: "Sağ Option (Right ⌥)", shortName: "Sağ Option", isModifier: true),
        TriggerKeyOption(keyCode: 62, name: "Sağ Control (Right ⌃)", shortName: "Sağ Ctrl", isModifier: true),
        TriggerKeyOption(keyCode: 59, name: "Sol Control (Left ⌃)", shortName: "Sol Ctrl", isModifier: true),
        TriggerKeyOption(keyCode: 63, name: "Fn / Globe (Fonksiyon / 🌐 fn)", shortName: "Fn/Globe", isModifier: true),
        TriggerKeyOption(keyCode: 55, name: "Sol Command (Left ⌘)", shortName: "Sol Cmd", isModifier: true),
        TriggerKeyOption(keyCode: 96, name: "F5 Tuşu", shortName: "F5", isModifier: false),
        TriggerKeyOption(keyCode: 97, name: "F6 Tuşu", shortName: "F6", isModifier: false),
        TriggerKeyOption(keyCode: 98, name: "F7 Tuşu", shortName: "F7", isModifier: false),
        TriggerKeyOption(keyCode: 100, name: "F8 Tuşu", shortName: "F8", isModifier: false)
    ]

    public static func name(for keyCode: Int) -> String {
        if let found = standardKeys.first(where: { $0.keyCode == keyCode }) {
            return found.name
        }
        switch keyCode {
        case 49: return "Boşluk (Space)"
        case 36: return "Return / Enter (⏎)"
        case 53: return "Escape (Esc)"
        case 56: return "Sol Shift (Left ⇧)"
        case 60: return "Sağ Shift (Right ⇧)"
        case 122: return "F1 Tuşu"
        case 120: return "F2 Tuşu"
        case 99: return "F3 Tuşu"
        case 118: return "F4 Tuşu"
        case 101: return "F9 Tuşu"
        case 109: return "F10 Tuşu"
        case 103: return "F11 Tuşu"
        case 111: return "F12 Tuşu"
        default: return "Özel Tuş (KeyCode: \(keyCode))"
        }
    }

    public static func shortName(for keyCode: Int) -> String {
        if let found = standardKeys.first(where: { $0.keyCode == keyCode }) {
            return found.shortName
        }
        switch keyCode {
        case 49: return "Space"
        case 36: return "Enter"
        case 56: return "Sol Shift"
        case 60: return "Sağ Shift"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return "Tuş #\(keyCode)"
        }
    }
}

public struct AppConfig: Codable {
    public var provider: String
    public var groq_api_key: String
    public var gemini_api_key: String
    public var assemblyai_api_key: String
    public var groq_model: String
    public var gemini_model: String
    public var language: String
    public var trigger_key: Int
    public var trigger_mode: String
    public var play_sounds: Bool
    public var restore_clipboard: Bool
    public var paste_delay_ms: Int
    public var min_record_duration: Double
    public var mute_system_audio: Bool
    public var pause_media_playback: Bool
    public var background_audio_mode: String // "ducking" (varsayılan), "pause", "none"
    public var enable_microphone_boost: Bool // AGC + Tanh Limiter
    public var show_dock_icon: Bool
    public var haptic_feedback: Bool
    public var remove_filler_words: Bool
    public var custom_vocabulary: String
    public var dictation_mode: String
    public var save_history: Bool
    public var gemini_system_prompt: String
    public var only_in_text_fields: Bool
    public var enable_auto_submit: Bool
    public var auto_submit_key: String // "return", "cmd_return", "shift_return", "tab"
    /// Metni pano + Cmd+V yerine VoiceTyping Giriş Yöntemi ile yazar (ileri düzey,
    /// Klavye ayarlarından giriş kaynağının eklenmesini gerektirir). Varsayılan kapalı.
    public var use_input_method: Bool
    /// Panoyu kullanmadan yazar: Mac uygulamalarında doğrudan alana, diğerlerinde
    /// karakter olarak. Olmazsa Cmd+V'ye düşülür. Yalnızca Erişilebilirlik izni ister.
    public var type_text_directly: Bool
    public var enable_app_profiles: Bool
    public var voice_snippets: [String: String]
    public var sound_theme: String // "modern", "subtle", "tactile", "chimes"
    public var sound_volume: Double // 0.0 - 1.0
    // Gösterge stili: "pill" (alt-ortada kapsül, varsayılan) veya
    // "notch" (MacBook çentiğine yapışan Dynamic Island).
    public var hud_style: String
    // NOT: Yazı boyutu ayarı kaldırıldı. Çentik modunda yazı boyutu
    // TAMAMEN OTOMATİKTİR: sabit ada genişliğine sığacak şekilde küçülür
    // ve okunabilirlik tabanının altına inmez (bkz. NotchTypography).
    // Deşifre bütçesi: modele tek seferde üretilebilecek en fazla token.
    // 0 = tavan yok (eski davranış).
    public var decode_tokens_per_sec: Int
    public var decode_token_base: Int
    // Konuşma kapısı (VAD) eşikleri.
    public var vad_gate_db: Double
    public var vad_stay_ratio: Double
    public var vad_silence_hold_sec: Double
    public var vad_max_segment_sec: Double

    public static let defaultGeminiSystemPrompt = "Sen profesyonel bir ses deşifre asistanısın. Kullanıcının konuşmasını dinle ve doğrudan yazıya dök. Asla selamlama, özet, onaylama ('Tabii ki', 'Anladım' gibi) veya fazladan yorum ekleme; sadece konuşulan metni temiz, doğru imla ve akıcı bir dille yaz."

    public static let defaultConfig = AppConfig(
        provider: "apple",
        groq_api_key: "",
        gemini_api_key: "",
        assemblyai_api_key: "",
        groq_model: "whisper-large-v3",
        gemini_model: "gemini-3.5-transcribe-live",
        language: "tr",
        trigger_key: 54,
        trigger_mode: "hold",
        play_sounds: true,
        restore_clipboard: false,
        paste_delay_ms: 20,
        min_record_duration: 0.20,
        mute_system_audio: true,
        pause_media_playback: true,
        background_audio_mode: "ducking",
        enable_microphone_boost: true,
        show_dock_icon: false,
        haptic_feedback: true,
        remove_filler_words: true,
        custom_vocabulary: "",
        dictation_mode: "direct",
        save_history: true,
        gemini_system_prompt: AppConfig.defaultGeminiSystemPrompt,
        only_in_text_fields: true,
        enable_auto_submit: false,
        auto_submit_key: "return",
        use_input_method: false,
        type_text_directly: true,
        enable_app_profiles: true,
        voice_snippets: ["kısayol mail": "ornek@sirket.com"],
        sound_theme: "modern",
        sound_volume: 0.8,
        hud_style: "pill",
        decode_tokens_per_sec: 16,
        decode_token_base: 32,
        vad_gate_db: -60.0,
        vad_stay_ratio: 0.5,
        vad_silence_hold_sec: 0.4,
        vad_max_segment_sec: 8.0
    )

    enum CodingKeys: String, CodingKey {
        case provider, groq_api_key, gemini_api_key, assemblyai_api_key, groq_model, gemini_model
        case language, trigger_key, trigger_mode, play_sounds, restore_clipboard
        case paste_delay_ms, min_record_duration, mute_system_audio, pause_media_playback
        case background_audio_mode, enable_microphone_boost, show_dock_icon
        case haptic_feedback, remove_filler_words, custom_vocabulary, dictation_mode, save_history
        case gemini_system_prompt, only_in_text_fields
        case enable_auto_submit, auto_submit_key, use_input_method, type_text_directly, enable_app_profiles, voice_snippets
        case sound_theme, sound_volume
        case hud_style
        case decode_tokens_per_sec, decode_token_base
        case vad_gate_db, vad_stay_ratio, vad_silence_hold_sec, vad_max_segment_sec
    }

    public init(
        provider: String,
        groq_api_key: String,
        gemini_api_key: String,
        assemblyai_api_key: String = "",
        groq_model: String,
        gemini_model: String,
        language: String,
        trigger_key: Int,
        trigger_mode: String,
        play_sounds: Bool,
        restore_clipboard: Bool,
        paste_delay_ms: Int,
        min_record_duration: Double,
        mute_system_audio: Bool = true,
        pause_media_playback: Bool = true,
        background_audio_mode: String = "ducking",
        enable_microphone_boost: Bool = true,
        show_dock_icon: Bool = false,
        haptic_feedback: Bool = true,
        remove_filler_words: Bool = true,
        custom_vocabulary: String = "",
        dictation_mode: String = "direct",
        save_history: Bool = true,
        gemini_system_prompt: String = AppConfig.defaultGeminiSystemPrompt,
        only_in_text_fields: Bool = true,
        enable_auto_submit: Bool = false,
        auto_submit_key: String = "return",
        use_input_method: Bool = false,
        type_text_directly: Bool = true,
        enable_app_profiles: Bool = true,
        voice_snippets: [String: String] = [:],
        sound_theme: String = "modern",
        sound_volume: Double = 0.8,
        hud_style: String = "pill",
        decode_tokens_per_sec: Int = 16,
        decode_token_base: Int = 32,
        vad_gate_db: Double = -60.0,
        vad_stay_ratio: Double = 0.5,
        vad_silence_hold_sec: Double = 0.4,
        vad_max_segment_sec: Double = 8.0
    ) {
        self.provider = provider
        self.groq_api_key = groq_api_key
        self.gemini_api_key = gemini_api_key
        self.assemblyai_api_key = assemblyai_api_key
        self.groq_model = groq_model
        self.gemini_model = gemini_model
        self.language = language
        self.trigger_key = trigger_key
        self.trigger_mode = trigger_mode
        self.play_sounds = play_sounds
        self.restore_clipboard = restore_clipboard
        self.paste_delay_ms = paste_delay_ms
        self.min_record_duration = min_record_duration
        self.mute_system_audio = mute_system_audio
        self.pause_media_playback = pause_media_playback
        self.background_audio_mode = background_audio_mode
        self.enable_microphone_boost = enable_microphone_boost
        self.show_dock_icon = show_dock_icon
        self.haptic_feedback = haptic_feedback
        self.remove_filler_words = remove_filler_words
        self.custom_vocabulary = custom_vocabulary
        self.dictation_mode = dictation_mode
        self.save_history = save_history
        self.gemini_system_prompt = gemini_system_prompt
        self.only_in_text_fields = only_in_text_fields
        self.enable_auto_submit = enable_auto_submit
        self.auto_submit_key = auto_submit_key
        self.use_input_method = use_input_method
        self.type_text_directly = type_text_directly
        self.enable_app_profiles = enable_app_profiles
        self.voice_snippets = voice_snippets
        self.sound_theme = sound_theme
        self.sound_volume = sound_volume
        self.hud_style = hud_style
        self.decode_tokens_per_sec = decode_tokens_per_sec
        self.decode_token_base = decode_token_base
        self.vad_gate_db = vad_gate_db
        self.vad_stay_ratio = vad_stay_ratio
        self.vad_silence_hold_sec = vad_silence_hold_sec
        self.vad_max_segment_sec = vad_max_segment_sec
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "apple"
        groq_api_key = try container.decodeIfPresent(String.self, forKey: .groq_api_key) ?? ""
        gemini_api_key = try container.decodeIfPresent(String.self, forKey: .gemini_api_key) ?? ""
        assemblyai_api_key = try container.decodeIfPresent(String.self, forKey: .assemblyai_api_key) ?? ""
        groq_model = try container.decodeIfPresent(String.self, forKey: .groq_model) ?? "whisper-large-v3"
        gemini_model = try container.decodeIfPresent(String.self, forKey: .gemini_model) ?? "gemini-3.5-transcribe-live"
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "tr"
        trigger_key = try container.decodeIfPresent(Int.self, forKey: .trigger_key) ?? 54
        trigger_mode = try container.decodeIfPresent(String.self, forKey: .trigger_mode) ?? "hold"
        play_sounds = try container.decodeIfPresent(Bool.self, forKey: .play_sounds) ?? true
        restore_clipboard = try container.decodeIfPresent(Bool.self, forKey: .restore_clipboard) ?? false
        paste_delay_ms = try container.decodeIfPresent(Int.self, forKey: .paste_delay_ms) ?? 20
        min_record_duration = try container.decodeIfPresent(Double.self, forKey: .min_record_duration) ?? 0.20
        mute_system_audio = try container.decodeIfPresent(Bool.self, forKey: .mute_system_audio) ?? true
        pause_media_playback = try container.decodeIfPresent(Bool.self, forKey: .pause_media_playback) ?? true
        background_audio_mode = try container.decodeIfPresent(String.self, forKey: .background_audio_mode) ?? "ducking"
        enable_microphone_boost = try container.decodeIfPresent(Bool.self, forKey: .enable_microphone_boost) ?? true
        show_dock_icon = try container.decodeIfPresent(Bool.self, forKey: .show_dock_icon) ?? false
        haptic_feedback = try container.decodeIfPresent(Bool.self, forKey: .haptic_feedback) ?? true
        remove_filler_words = try container.decodeIfPresent(Bool.self, forKey: .remove_filler_words) ?? true
        custom_vocabulary = try container.decodeIfPresent(String.self, forKey: .custom_vocabulary) ?? ""
        dictation_mode = try container.decodeIfPresent(String.self, forKey: .dictation_mode) ?? "direct"
        save_history = try container.decodeIfPresent(Bool.self, forKey: .save_history) ?? true
        gemini_system_prompt = try container.decodeIfPresent(String.self, forKey: .gemini_system_prompt) ?? AppConfig.defaultGeminiSystemPrompt
        only_in_text_fields = try container.decodeIfPresent(Bool.self, forKey: .only_in_text_fields) ?? true
        enable_auto_submit = try container.decodeIfPresent(Bool.self, forKey: .enable_auto_submit) ?? false
        auto_submit_key = try container.decodeIfPresent(String.self, forKey: .auto_submit_key) ?? "return"
        use_input_method = try container.decodeIfPresent(Bool.self, forKey: .use_input_method) ?? false
        type_text_directly = try container.decodeIfPresent(Bool.self, forKey: .type_text_directly) ?? true
        enable_app_profiles = try container.decodeIfPresent(Bool.self, forKey: .enable_app_profiles) ?? true
        voice_snippets = try container.decodeIfPresent([String: String].self, forKey: .voice_snippets) ?? [:]
        sound_theme = try container.decodeIfPresent(String.self, forKey: .sound_theme) ?? "modern"
        sound_volume = try container.decodeIfPresent(Double.self, forKey: .sound_volume) ?? 0.8
        hud_style = try container.decodeIfPresent(String.self, forKey: .hud_style) ?? "pill"
        decode_tokens_per_sec = try container.decodeIfPresent(Int.self, forKey: .decode_tokens_per_sec) ?? 16
        decode_token_base = try container.decodeIfPresent(Int.self, forKey: .decode_token_base) ?? 32
        vad_gate_db = try container.decodeIfPresent(Double.self, forKey: .vad_gate_db) ?? -60.0
        vad_stay_ratio = try container.decodeIfPresent(Double.self, forKey: .vad_stay_ratio) ?? 0.5
        vad_silence_hold_sec = try container.decodeIfPresent(Double.self, forKey: .vad_silence_hold_sec) ?? 0.4
        vad_max_segment_sec = try container.decodeIfPresent(Double.self, forKey: .vad_max_segment_sec) ?? 8.0
    }

    public static func parseVoiceSnippets(from text: String) -> [String: String] {
        var map: [String: String] = [:]
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }
            let parts = trimmed.components(separatedBy: "=")
            if parts.count >= 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && !val.isEmpty {
                    map[key] = val
                }
            }
        }
        return map
    }

    public static func formatVoiceSnippets(_ map: [String: String]) -> String {
        return map.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: "\n")
    }

    /// Gemini sistem istemini otomatik değişkenlerle çözümler.
    ///
    /// Gemini'nin `generateContent` API'sinde ayrı bir hotword/prompt alanı
    /// yoktur; bu yüzden özel sözlük metnini modele ulaştırmanın tek yolu
    /// sistem istemidir. Kullanıcı istemine `{{sozluk}}`, `{{dil}}`,
    /// `{{model}}`, `{{saglayici}}`, `{{uygulama}}`, `{{profil}}` veya
    /// `{{bundle_id}}` yazarsa ilgili değer otomatik dolar.
    /// Değişken içermeyen istemler eskisi gibi aynen döner.
    public func resolvedGeminiSystemPrompt(targetContext: TargetContext? = nil) -> String {
        let template = gemini_system_prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTemplate = template.isEmpty ? AppConfig.defaultGeminiSystemPrompt : template

        // Değişken yoksa gereksiz çözümleme ve kırpma yapmadan doğrudan dön;
        // varsayılan istemin biçimi birebir korunsun.
        guard !PromptTemplate.extractVariables(from: effectiveTemplate).isEmpty else {
            return effectiveTemplate
        }

        var values: [String: String] = [
            "dil": language,
            "model": gemini_model,
            "saglayici": TranscriptionProviderRegistry.descriptor(for: provider).displayName,
            "sozluk": custom_vocabulary
        ]

        if let target = targetContext {
            values["uygulama"] = target.appName
            values["bundle_id"] = target.bundleIdentifier
            values["rol"] = target.role
            let category = AppProfileFormatter.shared.detectCategory(
                bundleIdentifier: target.bundleIdentifier,
                appName: target.appName
            )
            values["profil"] = category.rawValue
        }

        let rendered = PromptTemplate.render(effectiveTemplate, values: values)
        return rendered.isEmpty ? effectiveTemplate : rendered
    }
}

public class ConfigManager {
    public static let shared = ConfigManager()

    public private(set) var config: AppConfig
    public private(set) var configURL: URL

    public static let availableAppleModels: [ModelOption] = [
        ModelOption(
            id: "apple-speech-on-device",
            name: "Apple Speech (Canlı Akış / Sıfır Kota)",
            price: "Ücretsiz (0 USD)",
            speed: "Canlı Akış"
        )
    ]

    public static let availableGroqModels: [ModelOption] = [
        ModelOption(
            id: "whisper-large-v3",
            name: "Whisper Large v3 (Saf Ses Deşifre)",
            price: "0.111 USD / saat",
            speed: "Standart"
        )
    ]

    public static let availableGeminiModels: [ModelOption] = [
        ModelOption(
            id: "gemini-3.5-transcribe-live",
            name: "Gemini 3.5 Transcribe Live (Canlı Akış · Saf Ses)",
            price: "Maliyet: Google API",
            speed: "Canlı Akış"
        ),
        ModelOption(
            id: "gemini-3.5-transcribe",
            name: "Gemini 3.5 Transcribe (REST · Saf Ses)",
            price: "Maliyet: Google API",
            speed: "Standart"
        )
    ]

    public static func normalizedGeminiModelID(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("models/") ? String(trimmed.dropFirst("models/".count)) : trimmed
    }

    public static func isGeminiLiveModel(_ model: String) -> Bool {
        let normalized = normalizedGeminiModelID(model)
        return normalized.contains("live") && !normalized.contains("tts")
    }

    public static func isGeminiExtendedThinkingModel(_ model: String) -> Bool {
        normalizedGeminiModelID(model).contains("live-extended-thinking")
    }

    public static func isGeminiNativeAudioLiveModel(_ model: String) -> Bool {
        let normalized = normalizedGeminiModelID(model)
        return isGeminiLiveModel(normalized) && !normalized.contains("transcribe")
    }

    public static func supportsGeminiGenerateContent(model: String) -> Bool {
        !isGeminiLiveModel(model)
    }

    public static func supportsSystemPrompt(model: String) -> Bool {
        let m = normalizedGeminiModelID(model)
        if m.contains("transcribe") || m.contains("whisper") {
            return false
        }
        return m.contains("flash") || m.contains("pro") || isGeminiNativeAudioLiveModel(m)
    }

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let userConfigDir = homeDir.appendingPathComponent(".voice_typing")
        try? FileManager.default.createDirectory(at: userConfigDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: userConfigDir.path)
        let primaryConfigURL = userConfigDir.appendingPathComponent("config.json")
        let legacyConfigURL = homeDir.appendingPathComponent(".voice_typing_config.json")

        let potentialPaths = [
            primaryConfigURL.path,
            legacyConfigURL.path,
            FileManager.default.currentDirectoryPath + "/config.json",
            Bundle.main.bundlePath + "/Contents/Resources/config.json",
            Bundle.main.bundleURL.deletingLastPathComponent().path + "/config.json"
        ]

        var bestConfig: AppConfig? = nil

        for path in potentialPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path),
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
                // Eğer daha önce config bulunmadıysa veya bu config dolu API anahtarlarına sahipse seç
                if bestConfig == nil {
                    bestConfig = decoded
                } else if (!decoded.gemini_api_key.isEmpty || !decoded.groq_api_key.isEmpty || !decoded.assemblyai_api_key.isEmpty) &&
                          (bestConfig!.gemini_api_key.isEmpty && bestConfig!.groq_api_key.isEmpty && bestConfig!.assemblyai_api_key.isEmpty) {
                    bestConfig = decoded
                }
            }
        }

        var finalConfig = bestConfig ?? AppConfig.defaultConfig

        // Eski turbo modelini kaldır ve whisper-large-v3'e yükselt
        if finalConfig.groq_model == "whisper-large-v3-turbo" {
            finalConfig.groq_model = "whisper-large-v3"
        }
        if finalConfig.provider.lowercased() == "openai" {
            finalConfig.provider = TranscriptionProviderRegistry.defaultProviderID
        }

        self.configURL = primaryConfigURL
        self.config = finalConfig
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primaryConfigURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyConfigURL.path)

        // Eğer birincil dosyada henüz kayıt yoksa veya API anahtarları olan yapılandırma varsa hemen senkronize et
        if !FileManager.default.fileExists(atPath: primaryConfigURL.path) || !finalConfig.gemini_api_key.isEmpty || !finalConfig.groq_api_key.isEmpty || !finalConfig.assemblyai_api_key.isEmpty {
            _ = save()
        }

        // Dosya izlemeyi başlat: dışarıdan yapılan değişiklikler uygulama
        // yeniden başlatılmadan etkili olsun. (Test sırasında gereksiz.)
        if !ConfigManager.isRunningTests {
            startWatchingConfig()
        }
    }

    /// Config dosyasını izler ve dışarıdan değiştirilirse yeniden okur.
    ///
    /// Neden gerekli: config başlangıçta bir kez okunup bellekte tutulur ve
    /// eskiden `reload()` hiçbir yerden çağrılmıyordu. Bu yüzden dosyayı elle
    /// düzenlemek (ya da başka bir araçla değiştirmek) uygulama yeniden
    /// başlatılana kadar ETKİSİZ kalıyordu — kullanıcı "hiç değişiklik yok"
    /// diyordu çünkü gerçekten yoktu.
    private var configWatcher: DispatchSourceFileSystemObject?
    private var watcherFD: CInt = -1

    private func startWatchingConfig() {
        stopWatchingConfig()
        // Yazma olaylarını izle; dosya değişince yeniden oku.
        watcherFD = open(configURL.path, O_EVTONLY)
        guard watcherFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watcherFD,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Yazma tamamlanana kadar çok kısa bekle (kısmi okuma olmasın).
            Thread.sleep(forTimeInterval: 0.15)
            DispatchQueue.main.async {
                self.reload()
                NotificationCenter.default.post(name: .configDidReload, object: nil)
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.watcherFD >= 0 else { return }
            close(self.watcherFD)
            self.watcherFD = -1
        }
        configWatcher = source
        source.resume()
    }

    private func stopWatchingConfig() {
        configWatcher?.cancel()
        configWatcher = nil
    }

    public func reload() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let legacyURL = homeDir.appendingPathComponent(".voice_typing_config.json")
        let candidateURLs = [configURL, legacyURL]

        for url in candidateURLs {
            if let data = try? Data(contentsOf: url),
               var decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
                if decoded.groq_model == "whisper-large-v3-turbo" {
                    decoded.groq_model = "whisper-large-v3"
                }
                if decoded.provider.lowercased() == "openai" {
                    decoded.provider = TranscriptionProviderRegistry.defaultProviderID
                }
                self.config = decoded
                return
            }
        }
    }

    @discardableResult
    public func update(_ block: (inout AppConfig) -> Void) -> Bool {
        block(&config)
        return save()
    }

    /// Test sürecinde miyiz?
    ///
    /// Neden gerekli: testler üretimdeki `ConfigManager.shared` ile aynı
    /// singleton'ı kullanır. Her `update()` çağrısı diske yazdığı için
    /// testler kullanıcının GERÇEK `~/.voice_typing/config.json` dosyasını
    /// eziyordu — çentik ayarı bu yüzden sürekli `pill`'e geri dönüyordu.
    private static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        // Test çalıştırıcısı yüklüyse de test sayılır.
        return NSClassFromString("XCTestCase") != nil
    }()

    public func save() -> Bool {
        // Test sırasında diske YAZMA: kullanıcının gerçek ayarlarını bozmasın.
        // Bellekteki `config` yine güncellenir, böylece testler davranışı
        // doğrulayabilir; yalnızca kalıcılaştırma atlanır.
        if Self.isRunningTests { return true }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)

            // 1. Birincil kullanıcı yapılandırması: ~/.voice_typing/config.json
            try data.write(to: configURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

            // 2. Geriye dönük uyumluluk: ~/.voice_typing_config.json
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let legacyURL = homeDir.appendingPathComponent(".voice_typing_config.json")
            try? data.write(to: legacyURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyURL.path)

            return true
        } catch {
            print("[Hata] Yapılandırma dosyası kaydedilemedi: \(error.localizedDescription)")
            return false
        }
    }
}

public extension Notification.Name {
    /// Config dosyası dışarıdan değişip yeniden okunduğunda yayınlanır.
    ///
    /// Gösterge (HUD) gibi ayara bağlı bileşenler bunu dinleyip kendini
    /// tazeleyebilir; böylece ayar değişikliği için uygulamayı yeniden
    /// başlatmak gerekmez.
    static let configDidReload = Notification.Name("VoiceTyping.configDidReload")
}
