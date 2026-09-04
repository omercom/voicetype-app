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
    public var show_dock_icon: Bool
    public var haptic_feedback: Bool
    public var remove_filler_words: Bool
    public var custom_vocabulary: String
    public var dictation_mode: String
    public var save_history: Bool
    public var gemini_system_prompt: String

    public static let defaultGeminiSystemPrompt = "Sen profesyonel bir ses deşifre asistanısın. Kullanıcının konuşmasını dinle ve doğrudan yazıya dök. Asla selamlama, özet, onaylama ('Tabii ki', 'Anladım' gibi) veya fazladan yorum ekleme; sadece konuşulan metni temiz, doğru imla ve akıcı bir dille yaz."

    public static let defaultConfig = AppConfig(
        provider: "groq",
        groq_api_key: "",
        gemini_api_key: "",
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
        show_dock_icon: false,
        haptic_feedback: true,
        remove_filler_words: true,
        custom_vocabulary: "",
        dictation_mode: "direct",
        save_history: true,
        gemini_system_prompt: AppConfig.defaultGeminiSystemPrompt
    )

    enum CodingKeys: String, CodingKey {
        case provider, groq_api_key, gemini_api_key, groq_model, gemini_model
        case language, trigger_key, trigger_mode, play_sounds, restore_clipboard
        case paste_delay_ms, min_record_duration, mute_system_audio, show_dock_icon
        case haptic_feedback, remove_filler_words, custom_vocabulary, dictation_mode, save_history
        case gemini_system_prompt
    }

    public init(
        provider: String,
        groq_api_key: String,
        gemini_api_key: String,
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
        show_dock_icon: Bool = false,
        haptic_feedback: Bool = true,
        remove_filler_words: Bool = true,
        custom_vocabulary: String = "",
        dictation_mode: String = "direct",
        save_history: Bool = true,
        gemini_system_prompt: String = AppConfig.defaultGeminiSystemPrompt
    ) {
        self.provider = provider
        self.groq_api_key = groq_api_key
        self.gemini_api_key = gemini_api_key
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
        self.show_dock_icon = show_dock_icon
        self.haptic_feedback = haptic_feedback
        self.remove_filler_words = remove_filler_words
        self.custom_vocabulary = custom_vocabulary
        self.dictation_mode = dictation_mode
        self.save_history = save_history
        self.gemini_system_prompt = gemini_system_prompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "groq"
        groq_api_key = try container.decodeIfPresent(String.self, forKey: .groq_api_key) ?? ""
        gemini_api_key = try container.decodeIfPresent(String.self, forKey: .gemini_api_key) ?? ""
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
        show_dock_icon = try container.decodeIfPresent(Bool.self, forKey: .show_dock_icon) ?? false
        haptic_feedback = try container.decodeIfPresent(Bool.self, forKey: .haptic_feedback) ?? true
        remove_filler_words = try container.decodeIfPresent(Bool.self, forKey: .remove_filler_words) ?? true
        custom_vocabulary = try container.decodeIfPresent(String.self, forKey: .custom_vocabulary) ?? ""
        dictation_mode = try container.decodeIfPresent(String.self, forKey: .dictation_mode) ?? "direct"
        save_history = try container.decodeIfPresent(Bool.self, forKey: .save_history) ?? true
        gemini_system_prompt = try container.decodeIfPresent(String.self, forKey: .gemini_system_prompt) ?? AppConfig.defaultGeminiSystemPrompt
    }
}

public class ConfigManager {
    public static let shared = ConfigManager()

    public private(set) var config: AppConfig
    public private(set) var configURL: URL

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
            name: "Gemini 3.5 Transcribe Live (Canlı Akış - Saf Ses)",
            price: "Ücretsiz Kota",
            speed: "Canlı Akış"
        ),
        ModelOption(
            id: "gemini-3.6-flash",
            name: "Gemini 3.6 Flash (Sistem İstemi & Çeviri Destekli)",
            price: "Ücretsiz Kota",
            speed: "Hızlı"
        ),
        ModelOption(
            id: "gemini-3.5-flash",
            name: "Gemini 3.5 Flash (Sistem İstemi & Çeviri Destekli)",
            price: "Ücretsiz Kota",
            speed: "Hızlı"
        ),
        ModelOption(
            id: "gemini-3.5-flash-lite",
            name: "Gemini 3.5 Flash Lite (Hafif Model)",
            price: "Ücretsiz Kota",
            speed: "Hafif"
        ),
        ModelOption(
            id: "gemini-3.5-transcribe",
            name: "Gemini 3.5 Transcribe (REST - Saf Ses)",
            price: "Ücretsiz Kota",
            speed: "Standart"
        )
    ]

    public static func supportsSystemPrompt(model: String) -> Bool {
        let m = model.lowercased()
        if m.contains("transcribe") || m.contains("whisper") {
            return false
        }
        return m.contains("flash") || m.contains("pro")
    }

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let userConfigDir = homeDir.appendingPathComponent(".voice_typing")
        try? FileManager.default.createDirectory(at: userConfigDir, withIntermediateDirectories: true)
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
                } else if (!decoded.gemini_api_key.isEmpty || !decoded.groq_api_key.isEmpty) &&
                          (bestConfig!.gemini_api_key.isEmpty && bestConfig!.groq_api_key.isEmpty) {
                    bestConfig = decoded
                }
            }
        }

        var finalConfig = bestConfig ?? AppConfig.defaultConfig

        // Eski turbo modelini kaldır ve whisper-large-v3'e yükselt
        if finalConfig.groq_model == "whisper-large-v3-turbo" {
            finalConfig.groq_model = "whisper-large-v3"
        }

        self.configURL = primaryConfigURL
        self.config = finalConfig

        // Eğer birincil dosyada henüz kayıt yoksa veya API anahtarları olan yapılandırma varsa hemen senkronize et
        if !FileManager.default.fileExists(atPath: primaryConfigURL.path) || !finalConfig.gemini_api_key.isEmpty || !finalConfig.groq_api_key.isEmpty {
            _ = save()
        }
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
                self.config = decoded
                break
            }
        }
    }

    @discardableResult
    public func update(_ block: (inout AppConfig) -> Void) -> Bool {
        block(&config)
        return save()
    }

    public func save() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)

            // 1. Birincil kullanıcı yapılandırması: ~/.voice_typing/config.json
            try data.write(to: configURL, options: .atomic)

            // 2. Geriye dönük uyumluluk: ~/.voice_typing_config.json
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let legacyURL = homeDir.appendingPathComponent(".voice_typing_config.json")
            try? data.write(to: legacyURL, options: .atomic)

            return true
        } catch {
            print("[Hata] Yapılandırma dosyası kaydedilemedi: \(error.localizedDescription)")
            return false
        }
    }
}
